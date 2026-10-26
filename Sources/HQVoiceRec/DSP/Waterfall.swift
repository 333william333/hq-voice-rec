import CoreGraphics
import Foundation

/// Scrolling spectrogram bitmap (newest row on top), coloured like Spectroid.
final class Waterfall {
    let width: Int
    let height: Int
    private var pixels: [UInt32]
    private let palette: [UInt32]
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        palette = Self.makePalette()
    }

    func clear() {
        for i in pixels.indices { pixels[i] = 0xFF00_0000 }
    }

    func push(row: [Float], floor: Float, ceiling: Float) {
        let span = max(ceiling - floor, 1)
        pixels.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            memmove(base + width, base, (height - 1) * width * MemoryLayout<UInt32>.size)
            let count = min(row.count, width)
            for x in 0..<count {
                let t = (row[x] - floor) / span
                let index = Int(min(max(t, 0), 1) * 255)
                base[x] = palette[index]
            }
        }
    }

    func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// black → navy → violet → magenta-red → orange → yellow → white
    static let stops: [(Double, Double, Double, Double)] = [
        (0.00, 0, 0, 0),
        (0.18, 8, 10, 70),
        (0.38, 88, 18, 150),
        (0.58, 205, 30, 95),
        (0.76, 250, 120, 20),
        (0.90, 255, 225, 60),
        (1.00, 255, 255, 255),
    ]

    private static func makePalette() -> [UInt32] {
        (0..<256).map { i in
            let t = Double(i) / 255
            var j = 0
            while j < stops.count - 2 && t > stops[j + 1].0 { j += 1 }
            let (t0, r0, g0, b0) = stops[j], (t1, r1, g1, b1) = stops[j + 1]
            let u = (t - t0) / (t1 - t0)
            let r = UInt32(r0 + (r1 - r0) * u), g = UInt32(g0 + (g1 - g0) * u), b = UInt32(b0 + (b1 - b0) * u)
            return 0xFF00_0000 | (r << 16) | (g << 8) | b
        }
    }
}
