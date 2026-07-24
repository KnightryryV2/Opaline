import Foundation

/// `trun` box parsing (header + per-sample records) for `FMP4SampleTable`.
/// See `FMP4SampleTable.swift` for the moof/traf/tfhd half of the parser.
extension FMP4SampleTable {
    // MARK: - Subtypes

    struct TrunHeader {
        let version: UInt8
        let flags: UInt32
        let sampleCount: Int
        let dataOffset: Int32?
        let firstSampleFlags: UInt32?
    }

    struct TrunSampleRecord {
        let duration: UInt32
        let size: Int
        let ctsOffset: Int32
        let flags: UInt32?
    }

    struct TrunState {
        let runningOffset: Int
        let isFirstTrun: Bool
    }

    struct TrunSampleContext {
        let header: TrunHeader
        let tfhd: TfhdInfo
        let isFirstInTrun: Bool
        let isFirstOverall: Bool
    }

    // MARK: - Type methods

    /// Parses every `trun` box of a traf, chaining data offsets across them.
    static func parseTruns(
        _ truns: [FMP4Box],
        data: Data,
        context: TrafContext
    ) -> [FMP4Sample]? {
        var samples: [FMP4Sample] = []
        var runningOffset = context.baseOffset
        for (index, box) in truns.enumerated() {
            let state = TrunState(runningOffset: runningOffset, isFirstTrun: index == 0)
            guard let parsed = parseOneTrun(
                box: box,
                data: data,
                context: context,
                state: state
            ) else {
                return nil
            }
            samples.append(contentsOf: parsed.samples)
            runningOffset = parsed.endOffset
        }
        return samples.isEmpty ? nil : samples
    }

    private static func parseOneTrun(
        box: FMP4Box,
        data: Data,
        context: TrafContext,
        state: TrunState
    ) -> (samples: [FMP4Sample], endOffset: Int)? {
        guard let headerResult = parseTrunHeader(data: data, box: box) else {
            return nil
        }
        let header = headerResult.header
        var cursor = headerResult.cursor
        var offset = header.dataOffset.map { context.baseOffset + Int($0) } ?? state.runningOffset
        var samples: [FMP4Sample] = []
        samples.reserveCapacity(header.sampleCount)
        for sampleIndex in 0..<header.sampleCount {
            let sampleContext = TrunSampleContext(
                header: header,
                tfhd: context.tfhd,
                isFirstInTrun: sampleIndex == 0,
                isFirstOverall: state.isFirstTrun && sampleIndex == 0
            )
            guard let sample = nextSample(
                data: data,
                cursor: &cursor,
                context: sampleContext,
                offset: &offset
            ) else {
                return nil
            }
            samples.append(sample)
        }
        return (samples, offset)
    }

    private static func parseTrunHeader(
        data: Data,
        box: FMP4Box
    ) -> (header: TrunHeader, cursor: Cursor)? {
        var cursor = Cursor(
            data: data,
            pos: box.payloadRange.lowerBound,
            end: box.payloadRange.upperBound
        )
        guard let versionFlags = cursor.uint32() else {
            return nil
        }
        guard let sampleCountRaw = cursor.uint32() else {
            return nil
        }
        let version = UInt8(versionFlags >> 24)
        let flags = versionFlags & 0x00FF_FFFF
        let header = readTrunOptionalHeader(
            cursor: &cursor,
            version: version,
            flags: flags,
            sampleCount: Int(sampleCountRaw)
        )
        return header.map { ($0, cursor) }
    }

    private static func readTrunOptionalHeader(
        cursor: inout Cursor,
        version: UInt8,
        flags: UInt32,
        sampleCount: Int
    ) -> TrunHeader? {
        var dataOffset: Int32?
        if flags & 0x1 != 0 {
            guard let value = cursor.int32() else {
                return nil
            }
            dataOffset = value
        }
        var firstSampleFlags: UInt32?
        if flags & 0x4 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            firstSampleFlags = value
        }
        return TrunHeader(
            version: version,
            flags: flags,
            sampleCount: sampleCount,
            dataOffset: dataOffset,
            firstSampleFlags: firstSampleFlags
        )
    }

    private static func readTrunSample(
        cursor: inout Cursor,
        header: TrunHeader,
        tfhd: TfhdInfo
    ) -> TrunSampleRecord? {
        var duration = tfhd.defaultSampleDuration ?? 0
        if header.flags & 0x100 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            duration = value
        }
        var size = tfhd.defaultSampleSize ?? 0
        if header.flags & 0x200 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            size = value
        }
        return readTrunSampleTail(cursor: &cursor, header: header, duration: duration, size: size)
    }

    private static func readTrunSampleTail(
        cursor: inout Cursor,
        header: TrunHeader,
        duration: UInt32,
        size: UInt32
    ) -> TrunSampleRecord? {
        var flags: UInt32?
        if header.flags & 0x400 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            flags = value
        }
        var cts: Int32 = 0
        if header.flags & 0x800 != 0 {
            guard let value = cursor.uint32() else {
                return nil
            }
            cts = Int32(bitPattern: value)
        }
        return TrunSampleRecord(duration: duration, size: Int(size), ctsOffset: cts, flags: flags)
    }

    private static func nextSample(
        data: Data,
        cursor: inout Cursor,
        context: TrunSampleContext,
        offset: inout Int
    ) -> FMP4Sample? {
        guard let record = readTrunSample(
            cursor: &cursor,
            header: context.header,
            tfhd: context.tfhd
        ) else {
            return nil
        }
        guard offset >= 0, record.size >= 0, offset + record.size <= data.count else {
            return nil
        }
        let isSync = resolveIsSync(context: context, sampleFlags: record.flags)
        let sample = FMP4Sample(
            offset: offset,
            size: record.size,
            duration: record.duration,
            ctsOffset: record.ctsOffset,
            isSync: isSync
        )
        offset += record.size
        return sample
    }

    private static func resolveIsSync(context: TrunSampleContext, sampleFlags: UInt32?) -> Bool {
        if let flags = sampleFlags {
            return flags & 0x0001_0000 == 0
        }
        if context.isFirstInTrun, let flags = context.header.firstSampleFlags {
            return flags & 0x0001_0000 == 0
        }
        if let flags = context.tfhd.defaultSampleFlags {
            return flags & 0x0001_0000 == 0
        }
        return context.isFirstOverall
    }
}
