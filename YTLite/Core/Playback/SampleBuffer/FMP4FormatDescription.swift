import CoreMedia
import Foundation

/// Builds `CMVideoFormatDescription`/`CMAudioFormatDescription` values from a
/// DASH init segment (`ftyp`+`moov`, no sample data) by walking its box tree
/// with `FMP4BoxReader` — pure Foundation, no `AVAsset` involved.
///
/// Split across this file (box walking + `mdhd`/timescale), `+H264.swift`
/// (`avc1`/`avcC`) and `+Audio.swift` (`mp4a`/`esds`) to stay under the
/// file-length lint limit.
enum FMP4FormatDescription {
    // MARK: - Subtypes

    /// Cursor over a byte range, advancing as fields are read. Used for the
    /// small, non-box-shaped structures nested inside sample entries
    /// (`avcC`, `esds`) that `FMP4BoxReader` doesn't model.
    struct ByteReader {
        let data: Data
        var pos: Int
        let end: Int

        init(_ data: Data) {
            self.data = data
            self.pos = data.startIndex
            self.end = data.endIndex
        }

        mutating func uint8() -> UInt8? {
            guard pos < end else {
                return nil
            }
            defer { pos += 1 }
            return data[pos]
        }

        mutating func uint16() -> UInt16? {
            guard pos + 2 <= end else {
                return nil
            }
            defer { pos += 2 }
            return UInt16(data[pos]) << 8 | UInt16(data[pos + 1])
        }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, pos + count <= end else {
                return nil
            }
            defer { pos += count }
            return Array(data[pos..<(pos + count)])
        }

        mutating func skip(_ count: Int) -> Bool {
            guard pos + count <= end else {
                return false
            }
            pos += count
            return true
        }
    }

    // MARK: - Type methods

    /// The track timescale from `moov/trak/mdia/mdhd`, in which
    /// `FMP4Sample.duration`/`ctsOffset` from this same track are expressed.
    static func trackTimescale(initSegment: Data) -> CMTimeScale? {
        guard let mdhd = firstMdhd(initSegment: initSegment) else {
            return nil
        }
        return parseMdhdTimescale(initSegment.subdata(in: mdhd.payloadRange))
    }

    /// Finds the `stsd` boxes of every track (`moov/trak/mdia/minf/stbl/stsd`).
    /// YouTube DASH init segments carry exactly one track, but every track is
    /// searched in case that ever changes.
    static func stsdBoxes(initSegment: Data) -> [FMP4Box] {
        let fullRange = 0..<initSegment.count
        guard let moov = FMP4BoxReader.firstBox(withType: "moov", in: initSegment, range: fullRange)
        else {
            return []
        }
        let traks = FMP4BoxReader.boxes(in: initSegment, range: moov.payloadRange)
            .filter { $0.type == "trak" }
        return traks.compactMap { stsdBox(initSegment: initSegment, trak: $0) }
    }

    /// Finds the sample entry (`avc1`/`mp4a`) of type `type` inside any
    /// track's `stsd`. `stsd`'s payload starts with an 8-byte fullbox
    /// header (version/flags + entry count) before the first entry, which
    /// isn't itself a box — so entries are scanned from `+8`, not `+0`.
    static func sampleEntry(initSegment: Data, type: String) -> FMP4Box? {
        for stsd in stsdBoxes(initSegment: initSegment) {
            let entriesStart = stsd.payloadRange.lowerBound + 8
            guard entriesStart <= stsd.payloadRange.upperBound else {
                continue
            }
            let range = entriesStart..<stsd.payloadRange.upperBound
            if let entry = FMP4BoxReader.firstBox(withType: type, in: initSegment, range: range) {
                return entry
            }
        }
        return nil
    }

    /// Finds `childType` inside a sample entry of `entryType`, skipping
    /// `headerSize` fixed bytes of that entry's payload first (78 for
    /// `avc1`'s `VisualSampleEntry` fields, 28 for `mp4a`'s
    /// `AudioSampleEntry` fields).
    static func sampleEntryChild(
        initSegment: Data,
        entryType: String,
        headerSize: Int,
        childType: String
    ) -> FMP4Box? {
        guard let entry = sampleEntry(initSegment: initSegment, type: entryType) else {
            return nil
        }
        let childStart = entry.payloadRange.lowerBound + headerSize
        guard childStart <= entry.payloadRange.upperBound else {
            return nil
        }
        return FMP4BoxReader.firstBox(
            withType: childType,
            in: initSegment,
            range: childStart..<entry.payloadRange.upperBound
        )
    }

    private static func stsdBox(initSegment: Data, trak: FMP4Box) -> FMP4Box? {
        guard
            let mdia = FMP4BoxReader.firstBox(
                withType: "mdia",
                in: initSegment,
                range: trak.payloadRange
            ),
            let minf = FMP4BoxReader.firstBox(
                withType: "minf",
                in: initSegment,
                range: mdia.payloadRange
            ),
            let stbl = FMP4BoxReader.firstBox(
                withType: "stbl",
                in: initSegment,
                range: minf.payloadRange
            )
        else {
            return nil
        }
        return FMP4BoxReader.firstBox(withType: "stsd", in: initSegment, range: stbl.payloadRange)
    }

    private static func firstMdhd(initSegment: Data) -> FMP4Box? {
        let fullRange = 0..<initSegment.count
        guard
            let moov = FMP4BoxReader.firstBox(withType: "moov", in: initSegment, range: fullRange),
            let trak = FMP4BoxReader.firstBox(
                withType: "trak",
                in: initSegment,
                range: moov.payloadRange
            ),
            let mdia = FMP4BoxReader.firstBox(
                withType: "mdia",
                in: initSegment,
                range: trak.payloadRange
            )
        else {
            return nil
        }
        return FMP4BoxReader.firstBox(withType: "mdhd", in: initSegment, range: mdia.payloadRange)
    }

    /// `mdhd` is a fullbox: version(1)+flags(3), then either
    /// version-0 (32-bit) or version-1 (64-bit) creation/modification
    /// times, then the 32-bit timescale.
    private static func parseMdhdTimescale(_ payload: Data) -> CMTimeScale? {
        guard payload.count >= 4 else {
            return nil
        }
        let versionFlags = payload.readBigUInt32(at: 0)
        let version = UInt8(versionFlags >> 24)
        let timescaleOffset = version == 1 ? 20 : 12
        guard payload.count >= timescaleOffset + 4 else {
            return nil
        }
        return Int32(exactly: payload.readBigUInt32(at: timescaleOffset))
    }
}
