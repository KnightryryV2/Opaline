import AudioToolbox
import CoreMedia
import Foundation

/// AAC (`mp4a`/`esds`) half of `FMP4FormatDescription`. See
/// `FMP4FormatDescription.swift` for the box-walking half and the H.264 side.
///
/// Approach: the `AudioSpecificConfig` inside `esds`'s `DecoderSpecificInfo`
/// is parsed by hand for just sample rate + channel count (both are 4-bit
/// table lookups), which is enough to build an `AudioStreamBasicDescription`.
/// The *raw* `DecoderSpecificInfo` bytes are then attached as the format
/// description's magic cookie via `CMAudioFormatDescriptionCreate`, so the
/// decoder still gets the exact codec-init bytes YouTube served — this is
/// simpler and more robust than re-deriving a `CMAudioFormatDescription`
/// through `AudioFormatGetProperty`'s ESDS-flavored property keys.
extension FMP4FormatDescription {
    // MARK: - Type methods

    /// From `moov/trak/mdia/minf/stbl/stsd/mp4a/esds`: parses the ES
    /// descriptor down to `AudioSpecificConfig` and builds an AAC format
    /// description.
    static func audio(initSegment: Data) -> CMAudioFormatDescription? {
        guard let esds = sampleEntryChild(
            initSegment: initSegment,
            entryType: "mp4a",
            headerSize: 28,
            childType: "esds"
        ) else {
            return nil
        }
        let payload = initSegment.subdata(in: esds.payloadRange)
        guard
            let asc = parseESDS(payload),
            var asbd = audioStreamBasicDescription(asc: asc)
        else {
            return nil
        }
        // The magic cookie must be the WHOLE descriptor chain (everything past
        // the fullbox's 4-byte version/flags), not just the DecoderSpecificInfo:
        // AVAssetReader hands back exactly these bytes for the same stream, and
        // CoreAudio silently fails to start the AAC decoder with only the DSI —
        // the renderer then accepts buffers, reports no error, and never plays,
        // which parks the synchronizer clock (device: frozen video, no audio).
        return createAudioFormatDescription(
            asbd: &asbd,
            magicCookie: [UInt8](payload.dropFirst(4))
        )
    }

    /// `esds`: a fullbox wrapping an `ES_Descriptor` (tag `0x03`) containing
    /// a `DecoderConfigDescriptor` (`0x04`) containing a
    /// `DecoderSpecificInfo` (`0x05`) — the raw `AudioSpecificConfig` bytes.
    private static func parseESDS(_ payload: Data) -> [UInt8]? {
        var reader = ByteReader(payload)
        guard reader.skip(4) else {
            return nil
        }
        guard let esHeader = readDescriptorHeader(&reader), esHeader.tag == 0x03 else {
            return nil
        }
        guard reader.skip(2), let esFlags = reader.uint8(), skipESOptional(&reader, flags: esFlags)
        else {
            return nil
        }
        return parseDecoderConfig(&reader)
    }

    /// `ES_Descriptor` flags gate three optional fields that precede the
    /// nested `DecoderConfigDescriptor`; skip whichever are present.
    private static func skipESOptional(_ reader: inout ByteReader, flags: UInt8) -> Bool {
        if flags & 0x80 != 0, !reader.skip(2) {
            return false
        }
        if flags & 0x40 != 0 {
            guard let urlLength = reader.uint8(), reader.skip(Int(urlLength)) else {
                return false
            }
        }
        if flags & 0x20 != 0, !reader.skip(2) {
            return false
        }
        return true
    }

    private static func parseDecoderConfig(_ reader: inout ByteReader) -> [UInt8]? {
        guard let configHeader = readDescriptorHeader(&reader), configHeader.tag == 0x04 else {
            return nil
        }
        // objectTypeIndication(1) + streamType/upstream/reserved(1)
        // + bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4) = 13 bytes.
        guard reader.skip(13) else {
            return nil
        }
        guard let ascHeader = readDescriptorHeader(&reader), ascHeader.tag == 0x05 else {
            return nil
        }
        return reader.bytes(ascHeader.length)
    }

    /// MPEG-4 descriptor header: a tag byte, then a length using the
    /// "expandable class" variable-length encoding (continuation bit
    /// `0x80`, up to 4 bytes).
    private static func readDescriptorHeader(
        _ reader: inout ByteReader
    ) -> (tag: UInt8, length: Int)? {
        guard let tag = reader.uint8(), let length = readDescriptorLength(&reader) else {
            return nil
        }
        return (tag, length)
    }

    private static func readDescriptorLength(_ reader: inout ByteReader) -> Int? {
        var result = 0
        for _ in 0..<4 {
            guard let byte = reader.uint8() else {
                return nil
            }
            result = (result << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                return result
            }
        }
        return result
    }

    /// `AudioSpecificConfig`'s first 16 bits: 5-bit object type, 4-bit
    /// sample-rate table index, 4-bit channel configuration.
    private static func audioStreamBasicDescription(asc: [UInt8]) -> AudioStreamBasicDescription? {
        guard asc.count >= 2 else {
            return nil
        }
        let bits = UInt16(asc[0]) << 8 | UInt16(asc[1])
        let objectType = (bits >> 11) & 0x1F
        let freqIndex = Int((bits >> 7) & 0x0F)
        let channelConfig = Int((bits >> 3) & 0x0F)
        guard
            objectType != 0,
            let sampleRate = aacSampleRate(forFreqIndex: freqIndex),
            let channels = aacChannelCount(forConfig: channelConfig)
        else {
            return nil
        }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// `samplingFrequencyIndex` table (`14496-3` 1.6.2.4); index `15` means
    /// an explicit 24-bit rate follows, which none of our sources use.
    private static func aacSampleRate(forFreqIndex index: Int) -> Double? {
        let table: [Double] = [
            96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
            16_000, 12_000, 11_025, 8_000, 7_350
        ]
        guard table.indices.contains(index) else {
            return nil
        }
        return table[index]
    }

    private static func aacChannelCount(forConfig config: Int) -> UInt32? {
        switch config {
        case 1...6:
            return UInt32(config)
        case 7:
            return 8
        default:
            return nil
        }
    }

    private static func createAudioFormatDescription(
        asbd: inout AudioStreamBasicDescription,
        magicCookie: [UInt8]
    ) -> CMAudioFormatDescription? {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: magicCookie.count,
            magicCookie: magicCookie,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }
}
