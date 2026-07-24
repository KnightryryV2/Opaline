import Foundation

/// One parsed ISO-BMFF box: its FourCC type plus the byte ranges of the
/// whole box (header + payload) and of the payload alone, both relative
/// to the `Data` the box was read from.
struct FMP4Box {
    let type: String
    let range: Range<Int>
    let payloadRange: Range<Int>
}

/// Minimal ISO-BMFF box reader used to walk fMP4 segments (moof/traf/…)
/// with pure Foundation — no AVFoundation involved.
///
/// Reuses `Data.readBigUInt32`/`readBigUInt64`/`readFourCC` already defined
/// (as internal helpers) in `HLSPlaylistLoader.swift`.
enum FMP4BoxReader {
    // MARK: - Type methods

    /// Iterates the direct sibling boxes contained in `range` of `data`.
    static func boxes(in data: Data, range: Range<Int>) -> [FMP4Box] {
        var result: [FMP4Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            guard let box = readBox(data: data, start: pos, limit: range.upperBound) else {
                break
            }
            result.append(box)
            pos = box.range.upperBound
        }
        return result
    }

    /// Finds the first direct child box with the given FourCC.
    static func firstBox(
        withType type: String,
        in data: Data,
        range: Range<Int>
    ) -> FMP4Box? {
        boxes(in: data, range: range).first { $0.type == type }
    }

    private static func readBox(data: Data, start: Int, limit: Int) -> FMP4Box? {
        guard start + 8 <= limit else {
            return nil
        }
        let size32 = data.readBigUInt32(at: start)
        let type = data.readFourCC(at: start + 4)
        guard let sizes = boxSize(data: data, size32: size32, start: start, limit: limit) else {
            return nil
        }
        let range = start..<(start + sizes.total)
        let payloadRange = (start + sizes.header)..<(start + sizes.total)
        return FMP4Box(type: type, range: range, payloadRange: payloadRange)
    }

    /// Resolves the header length (8 or 16 bytes for size==1/largesize)
    /// and total box length (size==0 means "to the end of `limit`").
    private static func boxSize(
        data: Data,
        size32: UInt32,
        start: Int,
        limit: Int
    ) -> (header: Int, total: Int)? {
        if size32 == 1 {
            guard start + 16 <= limit else {
                return nil
            }
            let size64 = data.readBigUInt64(at: start + 8)
            guard size64 <= UInt64(Int.max), Int(size64) <= limit - start else {
                return nil
            }
            return (16, Int(size64))
        }
        let total = size32 == 0 ? limit - start : Int(size32)
        guard total >= 8, start + total <= limit else {
            return nil
        }
        return (8, total)
    }
}
