import CoreMedia
import Foundation

/// H.264 (`avc1`/`avcC`) half of `FMP4FormatDescription`. See
/// `FMP4FormatDescription.swift` for the box-walking half and `mdhd`.
extension FMP4FormatDescription {
    // MARK: - Subtypes

    private struct AVCDecoderConfig {
        let nals: [[UInt8]]
        let nalUnitHeaderLength: Int32
    }

    // MARK: - Type methods

    /// From `moov/trak/mdia/minf/stbl/stsd/avc1/avcC`: extracts SPS/PPS and
    /// builds an H.264 format description via
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets`.
    static func video(initSegment: Data) -> CMVideoFormatDescription? {
        guard let avcC = sampleEntryChild(
            initSegment: initSegment,
            entryType: "avc1",
            headerSize: 78,
            childType: "avcC"
        ) else {
            return nil
        }
        let payload = initSegment.subdata(in: avcC.payloadRange)
        guard let config = parseAVCC(payload) else {
            return nil
        }
        return makeVideoFormatDescription(
            nals: config.nals,
            nalUnitHeaderLength: config.nalUnitHeaderLength
        )
    }

    /// `avcC`: configurationVersion/profile/compat/level (4 bytes), a byte
    /// whose low 2 bits give `nalUnitHeaderLength - 1`, then SPS and PPS
    /// lists (each a count byte followed by that many length-prefixed NALs).
    private static func parseAVCC(_ payload: Data) -> AVCDecoderConfig? {
        var reader = ByteReader(payload)
        guard reader.skip(4), let lengthByte = reader.uint8() else {
            return nil
        }
        let nalUnitHeaderLength = Int32((lengthByte & 0x03) + 1)
        guard
            let spsList = readNalList(&reader, countMask: 0x1F),
            let ppsList = readNalList(&reader, countMask: 0xFF),
            !spsList.isEmpty, !ppsList.isEmpty
        else {
            return nil
        }
        return AVCDecoderConfig(nals: spsList + ppsList, nalUnitHeaderLength: nalUnitHeaderLength)
    }

    private static func readNalList(
        _ reader: inout ByteReader,
        countMask: UInt8
    ) -> [[UInt8]]? {
        guard let countByte = reader.uint8() else {
            return nil
        }
        let count = Int(countByte & countMask)
        var result: [[UInt8]] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = reader.uint16(), let bytes = reader.bytes(Int(length)) else {
                return nil
            }
            result.append(bytes)
        }
        return result
    }

    private static func makeVideoFormatDescription(
        nals: [[UInt8]],
        nalUnitHeaderLength: Int32
    ) -> CMVideoFormatDescription? {
        let sizes = nals.map(\.count)
        return withParameterSetPointers(nals) { pointers in
            createH264FormatDescription(
                pointers: pointers,
                sizes: sizes,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
        }
    }

    /// Recursively pins each NAL's bytes so all pointers stay valid for the
    /// single `CMVideoFormatDescriptionCreateFromH264ParameterSets` call —
    /// that API needs one contiguous pointer/size array across every SPS
    /// and PPS at once, so pointers can't be collected ahead of time.
    private static func withParameterSetPointers<T>(
        _ nals: [[UInt8]],
        collected: [UnsafePointer<UInt8>] = [],
        body: ([UnsafePointer<UInt8>]) -> T?
    ) -> T? {
        guard let head = nals.first else {
            return body(collected)
        }
        return head.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return nil
            }
            return withParameterSetPointers(
                Array(nals.dropFirst()),
                collected: collected + [base],
                body: body
            )
        }
    }

    private static func createH264FormatDescription(
        pointers: [UnsafePointer<UInt8>],
        sizes: [Int],
        nalUnitHeaderLength: Int32
    ) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
            pointers.withUnsafeBufferPointer { ptrBuffer -> OSStatus in
                guard
                    let ptrBase = ptrBuffer.baseAddress,
                    let sizeBase = sizeBuffer.baseAddress
                else {
                    return OSStatus(-1)
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: ptrBase,
                    parameterSetSizes: sizeBase,
                    nalUnitHeaderLength: nalUnitHeaderLength,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }
}
