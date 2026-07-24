import Foundation

/// One decodable sample located inside a media-segment `Data` buffer.
struct FMP4Sample {
    let offset: Int
    let size: Int
    let duration: UInt32
    let ctsOffset: Int32
    let isSync: Bool
}

/// Parses the `moof`/`trun` sample table of one fMP4 media segment
/// (YouTube DASH init+media layout). Pure Foundation, no AVFoundation.
///
/// Split across `FMP4SampleTable.swift` (moof/traf/tfhd) and
/// `FMP4SampleTable+Trun.swift` (trun/per-sample records) to stay under
/// the file-length lint limit.
enum FMP4SampleTable {
    // MARK: - Subtypes

    /// Cursor over a byte range, advancing as big-endian fields are read.
    struct Cursor {
        let data: Data
        var pos: Int
        let end: Int

        mutating func uint32() -> UInt32? {
            guard pos + 4 <= end else {
                return nil
            }
            defer { pos += 4 }
            return data.readBigUInt32(at: pos)
        }

        mutating func uint64() -> UInt64? {
            guard pos + 8 <= end else {
                return nil
            }
            defer { pos += 8 }
            return data.readBigUInt64(at: pos)
        }

        mutating func int32() -> Int32? {
            uint32().map { Int32(bitPattern: $0) }
        }

        mutating func skip(_ count: Int) -> Bool {
            guard pos + count <= end else {
                return false
            }
            pos += count
            return true
        }
    }

    struct TfhdInfo {
        let baseDataOffset: Int64?
        let defaultSampleDuration: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
    }

    struct TrafContext {
        let tfhd: TfhdInfo
        let baseOffset: Int
    }

    // MARK: - Type methods

    /// Parses one media segment (moof+mdat). Returns nil if malformed.
    static func parse(mediaSegment: Data) -> [FMP4Sample]? {
        let fullRange = 0..<mediaSegment.count
        guard let located = locateTraf(in: mediaSegment, range: fullRange) else {
            return nil
        }
        let trafRange = located.trafBox.payloadRange
        guard let tfhdInfo = parseTfhd(in: mediaSegment, trafRange: trafRange) else {
            return nil
        }
        let baseOffset = tfhdInfo.baseDataOffset.map(Int.init) ?? located.moofStart
        let truns = trunBoxes(in: mediaSegment, trafRange: trafRange)
        guard !truns.isEmpty else {
            return nil
        }
        let context = TrafContext(tfhd: tfhdInfo, baseOffset: baseOffset)
        return parseTruns(truns, data: mediaSegment, context: context)
    }

    private static func locateTraf(
        in data: Data,
        range: Range<Int>
    ) -> (trafBox: FMP4Box, moofStart: Int)? {
        guard let moof = FMP4BoxReader.firstBox(withType: "moof", in: data, range: range) else {
            return nil
        }
        let trafRange = moof.payloadRange
        guard let traf = FMP4BoxReader.firstBox(withType: "traf", in: data, range: trafRange) else {
            return nil
        }
        return (traf, moof.range.lowerBound)
    }

    private static func trunBoxes(in data: Data, trafRange: Range<Int>) -> [FMP4Box] {
        FMP4BoxReader.boxes(in: data, range: trafRange).filter { $0.type == "trun" }
    }

    private static func parseTfhd(in data: Data, trafRange: Range<Int>) -> TfhdInfo? {
        guard let box = FMP4BoxReader.firstBox(withType: "tfhd", in: data, range: trafRange) else {
            return nil
        }
        var cursor = Cursor(
            data: data,
            pos: box.payloadRange.lowerBound,
            end: box.payloadRange.upperBound
        )
        guard let versionFlags = cursor.uint32() else {
            return nil
        }
        guard cursor.skip(4) else {
            return nil
        }
        let flags = versionFlags & 0x00FF_FFFF
        var baseDataOffset: Int64?
        if flags & 0x1 != 0 {
            guard let value = cursor.uint64() else {
                return nil
            }
            baseDataOffset = Int64(bitPattern: value)
        }
        if flags & 0x2 != 0 {
            guard cursor.skip(4) else {
                return nil
            }
        }
        return parseTfhdDefaults(&cursor, flags: flags, baseDataOffset: baseDataOffset)
    }

    private static func parseTfhdDefaults(
        _ cursor: inout Cursor,
        flags: UInt32,
        baseDataOffset: Int64?
    ) -> TfhdInfo? {
        var duration: UInt32?
        if flags & 0x8 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            duration = value
        }
        var size: UInt32?
        if flags & 0x10 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            size = value
        }
        var sampleFlags: UInt32?
        if flags & 0x20 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            sampleFlags = value
        }
        return TfhdInfo(
            baseDataOffset: baseDataOffset,
            defaultSampleDuration: duration,
            defaultSampleSize: size,
            defaultSampleFlags: sampleFlags
        )
    }
}
