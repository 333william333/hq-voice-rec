import Foundation

/// Rewrites an MP4/M4A so the `moov` index (duration, sample tables) comes before the audio data.
///
/// Apple's writer puts `moov` last. Websites and servers that inspect only the first part of an
/// upload then can't find the duration and treat the file as empty or too short.
enum FastStart {
    private struct Atom {
        let type: String
        let offset: Int
        let size: Int
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// Returns true if the file was rewritten, false if it was already fast-start or not an MP4.
    @discardableResult
    static func apply(to url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let atoms = parse(data, from: 0, to: data.count),
              let moov = atoms.first(where: { $0.type == "moov" }),
              let firstMdat = atoms.first(where: { $0.type == "mdat" }),
              moov.offset > firstMdat.offset else { return false }

        // New order: moov right before the first mdat; padding atoms dropped.
        var layout: [Atom] = []
        for atom in atoms where !["moov", "free", "skip"].contains(atom.type) {
            if atom.type == "mdat" && !layout.contains(where: { $0.type == "moov" }) { layout.append(moov) }
            layout.append(atom)
        }
        var newOffsets: [Int: Int] = [:]
        var position = 0
        for atom in layout {
            newOffsets[atom.offset] = position
            position += atom.size
        }

        // Chunk offsets point into mdat; translate each to that atom's new position.
        var moovData = Data(data[moov.offset..<(moov.offset + moov.size)])
        let ok = patchChunkOffsets(&moovData, from: 0, to: moovData.count) { old in
            guard let owner = atoms.first(where: { old >= $0.offset && old < $0.offset + $0.size }),
                  let newStart = newOffsets[owner.offset] else { return nil }
            return newStart + (old - owner.offset)
        }
        guard ok else { return false }

        var output = Data(capacity: position)
        for atom in layout {
            output.append(atom.type == "moov" ? moovData : data[atom.offset..<(atom.offset + atom.size)])
        }
        try output.write(to: url, options: .atomic)
        return true
    }

    private static func parse(_ data: Data, from start: Int, to end: Int) -> [Atom]? {
        var atoms: [Atom] = []
        var offset = start
        while offset + 8 <= end {
            var size = Int(readUInt32(data, offset))
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if size == 1 {
                guard offset + 16 <= end else { return nil }
                size = Int(readUInt64(data, offset + 8))
            } else if size == 0 {
                size = end - offset
            }
            guard size >= 8, offset + size <= end else { return nil }
            atoms.append(Atom(type: type, offset: offset, size: size))
            offset += size
        }
        return atoms
    }

    private static func patchChunkOffsets(_ data: inout Data, from start: Int, to end: Int,
                                          translate: (Int) -> Int?) -> Bool {
        guard let atoms = parse(data, from: start, to: end) else { return false }
        for atom in atoms {
            let header = readUInt32(data, atom.offset) == 1 ? 16 : 8
            let body = atom.offset + header
            switch atom.type {
            case let type where containers.contains(type):
                if !patchChunkOffsets(&data, from: body, to: atom.offset + atom.size, translate: translate) { return false }
            case "stco":
                let count = Int(readUInt32(data, body + 4))
                guard body + 8 + count * 4 <= atom.offset + atom.size else { return false }
                for i in 0..<count {
                    let at = body + 8 + i * 4
                    guard let new = translate(Int(readUInt32(data, at))), new <= Int(UInt32.max) else { return false }
                    writeUInt32(&data, at, UInt32(new))
                }
            case "co64":
                let count = Int(readUInt32(data, body + 4))
                guard body + 8 + count * 8 <= atom.offset + atom.size else { return false }
                for i in 0..<count {
                    let at = body + 8 + i * 8
                    guard let new = translate(Int(readUInt64(data, at))) else { return false }
                    writeUInt64(&data, at, UInt64(new))
                }
            default:
                break
            }
        }
        return true
    }

    private static func readUInt32(_ data: Data, _ at: Int) -> UInt32 {
        data[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, _ at: Int) -> UInt64 {
        data[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func writeUInt32(_ data: inout Data, _ at: Int, _ value: UInt32) {
        for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
    }

    private static func writeUInt64(_ data: inout Data, _ at: Int, _ value: UInt64) {
        for i in 0..<8 { data[at + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * i)) }
    }
}
