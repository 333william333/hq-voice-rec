import Accelerate
import CoreAudio
import Foundation
import os
import QuartzCore

/// Everything the UI draws, published ~60 times per second.
struct VisualSnapshot {
    var spectrum: [Float] = []
    var peakHold: [Float] = []
    var waterfall: CGImage?
    var sampleRate: Double = 48_000
    var minFrequency: Double = 20
    var peakFrequency: Double = 0
    var peakLevel: Float = -200
    var meterPeak: [Float] = []
    var meterRMS: [Float] = []
    var meterHold: [Float] = []
    var clipped: [Bool] = []
    var recordedFrames: Int64 = 0
    var recordingRate: Double = 0
    var dropped: Int = 0
    var writeError: String?
}

/// Owns the capture unit and does all non-real-time work on one serial queue:
/// metering, FFT, waterfall and streaming the recording to disk.
final class AudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hqvoicerec.processing", qos: .userInteractive)
    private let published = OSAllocatedUnfairLock(initialState: VisualSnapshot())

    private var capture: AudioCapture?
    private var timer: DispatchSourceTimer?
    private let readCapacity = 1 << 20
    private let readBuffer: UnsafeMutablePointer<Float>
    private let monoBuffer: UnsafeMutablePointer<Float>

    private let columns = 1024
    private let analyzer: SpectrumAnalyzer
    private let waterfall: Waterfall
    private var settings = AnalyzerSettings()
    private var raw: [Float] = []
    private var smooth: [Float] = []
    private var hold: [Float] = []
    private var peakFrequency: Double = 0
    private var peakLevel: Float = -200
    private var lastFrameTime: Double = 0
    private var lastTick: Double = 0

    private var channelIndices: [Int] = [0]
    private var writer: RecordingWriter?
    private var writeError: String?

    private var meterPeak: [Float] = []
    private var meterRMSPower: [Float] = []
    private var meterHold: [Float] = []
    private var meterHoldTime: [Double] = []
    private var clipped: [Bool] = []

    init() {
        readBuffer = .allocate(capacity: readCapacity)
        monoBuffer = .allocate(capacity: readCapacity)
        analyzer = SpectrumAnalyzer(columns: columns)
        waterfall = Waterfall(width: columns, height: 360)
    }

    // MARK: Control (main thread)

    /// Starts capturing from `deviceID`. Returns the effective sample rate and channel count.
    func start(deviceID: AudioDeviceID, preferredSampleRate: Double?) throws -> (sampleRate: Double, channels: Int) {
        stop()
        let capture = try AudioCapture(deviceID: deviceID, preferredSampleRate: preferredSampleRate)
        queue.sync {
            self.capture = capture
            let n = capture.channels
            meterPeak = Array(repeating: -120, count: n)
            meterRMSPower = Array(repeating: 0, count: n)
            meterHold = Array(repeating: -120, count: n)
            meterHoldTime = Array(repeating: 0, count: n)
            clipped = Array(repeating: false, count: n)
            channelIndices = channelIndices.filter { $0 < n }
            if channelIndices.isEmpty { channelIndices = [0] }
            analyzer.configure(fftSize: settings.fftSize, sampleRate: capture.sampleRate)
            resetSpectrum()
            lastTick = CACurrentMediaTime()
        }
        do {
            try capture.start()
        } catch {
            queue.sync { self.capture = nil }
            throw error
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        return (capture.sampleRate, capture.channels)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        capture?.stop()
        queue.sync {
            finishWriter()
            capture = nil
        }
    }

    func setChannels(_ indices: [Int]) {
        queue.async { if self.writer == nil { self.channelIndices = indices } }
    }

    func setAnalyzer(_ newSettings: AnalyzerSettings) {
        queue.async {
            let fftChanged = newSettings.fftSize != self.settings.fftSize
            self.settings = newSettings
            if fftChanged, let capture = self.capture {
                self.analyzer.configure(fftSize: newSettings.fftSize, sampleRate: capture.sampleRate)
                self.resetSpectrum()
            }
        }
    }

    func startRecording(url: URL, settings: RecordingSettings) throws {
        try queue.sync {
            guard let capture else { throw CaptureError.osStatus("inspelning utan aktiv ingång", -1) }
            // Throw away whatever was buffered before the button was pressed.
            while capture.ring.read(into: readBuffer, maxCount: readCapacity, granularity: capture.channels) > 0 {}
            channelIndices = settings.channelIndices(deviceChannels: capture.channels)
            writer = try RecordingWriter(url: url, settings: settings,
                                         inputSampleRate: capture.sampleRate, channels: channelIndices.count)
            writeError = nil
        }
    }

    /// Flushes everything captured so far, closes the file and returns its URL.
    @discardableResult
    func stopRecording() -> URL? {
        queue.sync {
            tick()
            return finishWriter()
        }
    }

    func resetClipIndicators() {
        queue.async { for i in self.clipped.indices { self.clipped[i] = false } }
    }

    func snapshot() -> VisualSnapshot {
        published.withLock { $0 }
    }

    // MARK: Processing queue

    @discardableResult
    private func finishWriter() -> URL? {
        guard let writer else { return nil }
        writer.finish()
        self.writer = nil
        return writer.url
    }

    private func resetSpectrum() {
        let floor = Float(settings.floorDB)
        raw = Array(repeating: floor, count: columns)
        smooth = raw
        hold = raw
        waterfall.clear()
    }

    private func tick() {
        guard let capture else { return }
        let now = CACurrentMediaTime()
        let dt = max(now - lastTick, 0.001)
        lastTick = now
        let channels = capture.channels

        var blockPeak = [Float](repeating: 0, count: channels)
        var blockSquares = [Float](repeating: 0, count: channels)
        var totalFrames = 0

        while true {
            let count = capture.ring.read(into: readBuffer, maxCount: readCapacity, granularity: channels)
            guard count > 0 else { break }
            let frames = count / channels
            totalFrames += frames

            for c in 0..<channels {
                var peak: Float = 0, squares: Float = 0
                vDSP_maxmgv(readBuffer + c, channels, &peak, vDSP_Length(frames))
                vDSP_svesq(readBuffer + c, channels, &squares, vDSP_Length(frames))
                blockPeak[c] = max(blockPeak[c], peak)
                blockSquares[c] += squares
            }

            if let writer, writeError == nil {
                do {
                    try writer.append(readBuffer, frames: frames, deviceChannels: channels, channelIndices: channelIndices)
                } catch {
                    writeError = error.localizedDescription
                }
            }

            var zero: Float = 0
            if channelIndices.count == 1 {
                vDSP_vsadd(readBuffer + channelIndices[0], channels, &zero, monoBuffer, 1, vDSP_Length(frames))
            } else {
                var half: Float = 0.5
                vDSP_vadd(readBuffer + channelIndices[0], channels, readBuffer + channelIndices[1], channels,
                          monoBuffer, 1, vDSP_Length(frames))
                vDSP_vsmul(monoBuffer, 1, &half, monoBuffer, 1, vDSP_Length(frames))
            }
            analyzer.push(monoBuffer, count: frames)
        }

        updateMeters(peaks: blockPeak, squares: blockSquares, frames: totalFrames, now: now, dt: dt)

        guard now - lastFrameTime >= 1.0 / 60.0 else { return }
        lastFrameTime = now
        (peakFrequency, peakLevel) = analyzer.analyze(into: &raw)

        let alpha = Float(settings.smoothing)
        let floor = Float(settings.floorDB)
        let holdDecay = Float(18.0 * (1.0 / 60.0))
        for i in 0..<columns {
            let value = max(raw[i], floor)
            let a = value > smooth[i] ? alpha * 0.35 : alpha
            smooth[i] = a * smooth[i] + (1 - a) * value
            hold[i] = max(value, hold[i] - holdDecay)
        }
        waterfall.push(row: raw, floor: Float(settings.waterfallFloor), ceiling: Float(settings.waterfallCeiling))
        let image = waterfall.makeImage()

        let snapshot = VisualSnapshot(
            spectrum: smooth, peakHold: hold, waterfall: image,
            sampleRate: capture.sampleRate, minFrequency: analyzer.minFrequency,
            peakFrequency: peakFrequency, peakLevel: peakLevel,
            meterPeak: meterPeak,
            meterRMS: meterRMSPower.map { 10 * log10(max($0, 1e-12)) },
            meterHold: meterHold, clipped: clipped,
            recordedFrames: writer?.framesWritten ?? 0,
            recordingRate: capture.sampleRate,
            dropped: capture.ring.dropped.load(ordering: .relaxed),
            writeError: writeError)
        published.withLock { $0 = snapshot }
    }

    private func updateMeters(peaks: [Float], squares: [Float], frames: Int, now: Double, dt: Double) {
        let decay = Float(24 * dt)              // dB per tick
        let rmsCoefficient = Float(1 - exp(-dt / 0.3))
        for c in peaks.indices {
            let peakDB = 20 * log10(max(peaks[c], 1e-7))
            meterPeak[c] = max(peakDB, meterPeak[c] - decay)
            if frames > 0 {
                let meanSquare = squares[c] / Float(frames)
                meterRMSPower[c] += (meanSquare - meterRMSPower[c]) * rmsCoefficient
            }
            if peakDB >= meterHold[c] {
                meterHold[c] = peakDB
                meterHoldTime[c] = now
            } else if now - meterHoldTime[c] > 1.5 {
                meterHold[c] = max(meterHold[c] - decay, peakDB)
            }
            if peaks[c] >= 0.9999 { clipped[c] = true }
        }
    }
}
