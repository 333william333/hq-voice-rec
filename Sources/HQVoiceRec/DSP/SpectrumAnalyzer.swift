import Accelerate
import Foundation

struct AnalyzerSettings: Codable, Equatable {
    var fftSize: Int = 8192
    var smoothing: Double = 0.55
    var floorDB: Double = -120
    var waterfallFloor: Double = -110
    var waterfallCeiling: Double = -30
    var showPeakHold: Bool = true

    static let fftSizes = [2048, 4096, 8192, 16_384, 32_768]
}

/// Hann-windowed real FFT mapped onto logarithmically spaced display columns (20 Hz – Nyquist).
/// Levels are calibrated so a full-scale sine reads 0 dBFS.
final class SpectrumAnalyzer {
    let columns: Int
    let minFrequency: Double = 20
    private(set) var fftSize = 0
    private(set) var sampleRate: Double = 48_000

    private var setup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var window: [Float] = []
    private var dbOffset: Float = 0
    private var history: [Float] = []
    private var writeIndex = 0
    private var frame: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var binDB: [Float] = []

    private var columnLow: [Int] = []
    private var columnHigh: [Int] = []
    private var columnPosition: [Float] = []

    init(columns: Int) {
        self.columns = columns
        configure(fftSize: 8192, sampleRate: 48_000)
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    func configure(fftSize: Int, sampleRate: Double) {
        guard fftSize != self.fftSize || sampleRate != self.sampleRate else { return }
        if let setup { vDSP_destroy_fftsetup(setup) }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let sum = window.reduce(0, +)
        dbOffset = -20 * log10(sum)

        history = [Float](repeating: 0, count: fftSize)
        writeIndex = 0
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        binDB = [Float](repeating: -200, count: fftSize / 2)
        buildColumnMap()
    }

    func frequency(atFraction x: Double) -> Double {
        minFrequency * pow(sampleRate / 2 / minFrequency, x)
    }

    private func buildColumnMap() {
        let binHz = sampleRate / Double(fftSize)
        let lastBin = fftSize / 2 - 1
        columnLow = []; columnHigh = []; columnPosition = []
        for c in 0..<columns {
            let f0 = frequency(atFraction: Double(c) / Double(columns)) / binHz
            let f1 = frequency(atFraction: Double(c + 1) / Double(columns)) / binHz
            let lo = Int(ceil(f0)), hi = min(Int(floor(f1)), lastBin)
            if hi >= lo {
                columnLow.append(lo); columnHigh.append(hi); columnPosition.append(-1)
            } else {
                let center = min((f0 + f1) / 2, Double(lastBin))
                columnLow.append(0); columnHigh.append(0); columnPosition.append(Float(center))
            }
        }
    }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        var source = samples
        var remaining = count
        if remaining > fftSize {
            source += remaining - fftSize
            remaining = fftSize
        }
        history.withUnsafeMutableBufferPointer { h in
            let first = min(remaining, fftSize - writeIndex)
            (h.baseAddress! + writeIndex).update(from: source, count: first)
            if first < remaining { h.baseAddress!.update(from: source + first, count: remaining - first) }
        }
        writeIndex = (writeIndex + remaining) % fftSize
    }

    /// Fills `out` (one value per column, dBFS) and returns the dominant peak.
    func analyze(into out: inout [Float]) -> (frequency: Double, level: Float) {
        guard let setup else { return (0, -200) }
        let n = fftSize, half = n / 2

        history.withUnsafeBufferPointer { h in
            frame.withUnsafeMutableBufferPointer { f in
                let tailCount = n - writeIndex
                f.baseAddress!.update(from: h.baseAddress! + writeIndex, count: tailCount)
                (f.baseAddress! + tailCount).update(from: h.baseAddress!, count: writeIndex)
            }
        }
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                let dc = r[0]
                i[0] = 0
                vDSP_zvmags(&split, 1, &binDB, 1, vDSP_Length(half))
                binDB[0] = dc * dc
            }
        }
        var tiny: Float = 1e-20
        vDSP_vsadd(binDB, 1, &tiny, &binDB, 1, vDSP_Length(half))
        var reference: Float = 1
        vDSP_vdbcon(binDB, 1, &reference, &binDB, 1, vDSP_Length(half), 0)
        vDSP_vsadd(binDB, 1, &dbOffset, &binDB, 1, vDSP_Length(half))

        if out.count != columns { out = [Float](repeating: -200, count: columns) }
        binDB.withUnsafeBufferPointer { db in
            for c in 0..<columns {
                let position = columnPosition[c]
                if position < 0 {
                    var maxValue: Float = 0
                    vDSP_maxv(db.baseAddress! + columnLow[c], 1, &maxValue, vDSP_Length(columnHigh[c] - columnLow[c] + 1))
                    out[c] = maxValue
                } else {
                    let i0 = Int(position), i1 = min(i0 + 1, half - 1)
                    let t = position - Float(i0)
                    out[c] = db[i0] * (1 - t) + db[i1] * t
                }
            }
        }

        // Dominant peak with parabolic interpolation.
        let binHz = sampleRate / Double(n)
        let start = max(2, Int(minFrequency / binHz))
        let end = half - 2
        guard end > start else { return (0, -200) }
        var peak: Float = 0
        var index: vDSP_Length = 0
        binDB.withUnsafeBufferPointer { db in
            vDSP_maxvi(db.baseAddress! + start, 1, &peak, &index, vDSP_Length(end - start))
        }
        let k = start + Int(index)
        let a = binDB[k - 1], b = binDB[k], c = binDB[k + 1]
        let denominator = a - 2 * b + c
        let p = denominator != 0 ? 0.5 * (a - c) / denominator : 0
        return ((Double(k) + Double(p)) * binHz, b - 0.25 * (a - c) * p)
    }
}
