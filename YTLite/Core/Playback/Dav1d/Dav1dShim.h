//
//  Dav1dShim.h
//  Thin C wrapper over dav1d (VideoLAN's AV1 decoder). Swift talks only to
//  this shim, never to dav1d's headers directly.
//
//  dav1d ships as a device-arm64-only static library (Vendor/dav1d.xcframework
//  has no simulator slice), so on the simulator every function here is a stub
//  returning NULL/0 — callers must treat a NULL result as "AV1 decode
//  unavailable" and fall back.
//

#ifndef DAV1D_SHIM_H
#define DAV1D_SHIM_H

#import <CoreVideo/CoreVideo.h>

/// Why a `dav1d_shim_decode()` call produced no picture (or why it did,
/// distinguishing the ordinary success case) — see that function's doc
/// comment for what to do with each value.
typedef enum {
    /// A picture was produced; the returned `CVPixelBufferRef` is non-NULL.
    DAV1D_SHIM_STATUS_OK = 0,
    /// Bad arguments (NULL ctx/obu or zero len) — a caller bug, not a stream
    /// or device condition.
    DAV1D_SHIM_STATUS_INVALID_ARGS,
    /// `dav1d_send_data()` returned a hard error; `errorCode` is dav1d's
    /// negative errno.
    DAV1D_SHIM_STATUS_SEND_ERROR,
    /// The sample was consumed but no picture is ready yet (dav1d signaled
    /// EAGAIN from `dav1d_get_picture()`). Not a failure — expected on
    /// decoder warm-up.
    DAV1D_SHIM_STATUS_NO_PICTURE_YET,
    /// `dav1d_get_picture()` returned a hard (non-EAGAIN) error; `errorCode`
    /// is dav1d's negative errno.
    DAV1D_SHIM_STATUS_GET_PICTURE_ERROR,
    /// A picture decoded successfully but its chroma layout/bit depth isn't
    /// one this shim converts (only 8-bit and 10-bit 4:2:0 are handled).
    /// `width`/`height`/`bitDepth` describe the picture that was dropped.
    DAV1D_SHIM_STATUS_UNSUPPORTED_LAYOUT,
    /// A picture decoded successfully but `CVPixelBufferCreate()` failed —
    /// most likely memory pressure at large frame sizes. `width`/`height`
    /// describe the allocation that failed.
    DAV1D_SHIM_STATUS_ALLOC_FAILED
} dav1d_shim_status_t;

/// Out-parameter for `dav1d_shim_decode()`, filled in on every call
/// regardless of outcome.
typedef struct {
    dav1d_shim_status_t status;
    /// dav1d's negative errno for `*_ERROR` statuses, 0 otherwise.
    int errorCode;
    /// Picture dimensions, valid for `OK`/`UNSUPPORTED_LAYOUT`/`ALLOC_FAILED`
    /// (0 otherwise — no picture was decoded to measure).
    int width;
    int height;
    /// dav1d's `Dav1dPicture.p.bpc`, valid for the same statuses as
    /// width/height.
    int bitDepth;
    /// Raw AV1/CICP color description resolved for this picture (dav1d's
    /// Dav1dColorPrimaries / Dav1dTransferCharacteristics /
    /// Dav1dMatrixCoefficients enum values — see dav1d/headers.h), valid only
    /// for `OK`. When the picture carries no sequence header these read back
    /// as the CICP "unspecified" codepoint (2), which the shim's color
    /// mapping resolves to BT.709 — i.e. today's default.
    uint8_t colorPrimaries;
    uint8_t transferCharacteristics;
    uint8_t matrixCoefficients;
    /// 1 if the picture uses full-range (JPEG) sample values, 0 for
    /// video/limited range (MPEG) — dav1d's `Dav1dSequenceHeader.color_range`.
    /// Valid only for `OK`.
    uint8_t colorRangeFull;
} dav1d_shim_decode_result_t;

/// dav1d's API version string (e.g. "1.5.1"), or NULL when dav1d is not linked
/// (simulator). Referencing this from Swift also anchors the static library
/// into the link.
const char *dav1d_shim_version(void);

/// Creates and opens a dav1d decoder context configured for synchronous,
/// per-sample decode (see dav1d_shim_decode). Returns an opaque pointer to
/// pass to dav1d_shim_decode()/dav1d_shim_destroy(), or NULL on failure
/// (including on the simulator, where dav1d isn't linked).
void *dav1d_shim_create(void);

/// Closes and frees a decoder created by dav1d_shim_create(). Safe to call
/// with NULL (no-op).
void dav1d_shim_destroy(void *ctx);

/// Decodes ONE temporal unit — the raw OBU bytes of a single fMP4 av01
/// sample — and returns a retained CVPixelBufferRef the caller must
/// CFRelease, or NULL if no picture was produced this call (e.g. the decoder
/// is still buffering) or on error.
///
/// `obu`/`len` describe one sample's bytes and only need to stay valid for
/// the duration of this call: the decoder context is configured with
/// max_frame_delay = 1 (no frame-level lookahead), so send+get fully
/// completes this temporal unit's decode before dav1d_shim_decode returns —
/// there is no background thread holding a reference to `obu` afterwards.
///
/// Pixel format of the returned buffer:
///  - 8-bit 4:2:0 streams  -> kCVPixelFormatType_420YpCbCr8Planar(FullRange) (I420)
///  - 10-bit 4:2:0 streams -> kCVPixelFormatType_420YpCbCr10BiPlanar(Video|Full)Range (P010)
///  - anything else (4:2:2, 4:4:4, monochrome) -> NULL; caller must fall back.
/// The Video/FullRange variant is chosen from the picture's sequence header
/// color_range. Color primaries/transfer/matrix attachments are derived from
/// the same sequence header's CICP color description (BT.709 SDR, BT.2020
/// SDR, PQ, HLG, sRGB — see Dav1dShim.c); unknown/unrecognized values fall
/// back to BT.709, matching the old fixed default.
///
/// CF_RETURNS_RETAINED: this really does hand back a +1 reference (the C
/// implementation CVPixelBufferCreate()s a fresh buffer per call and never
/// releases it). Without this annotation Swift imports the return type as
/// an unmanaged pointer, and callers going through `.takeUnretainedValue()`
/// would leak every frame; with it, Swift imports a plain `CVPixelBuffer?`
/// that ARC balances correctly on scope exit.
///
/// `outResult` must be non-NULL; it's filled in unconditionally so the
/// caller can log *why* a NULL return happened (see `dav1d_shim_status_t`).
CF_RETURNS_RETAINED CVPixelBufferRef dav1d_shim_decode(
    void *ctx, const uint8_t *obu, size_t len, dav1d_shim_decode_result_t *outResult);

/// Drops the decoder's internal picture queue and reference frames. Call
/// this on a seek/discontinuity — after one, the next OBU sample fed to
/// dav1d_shim_decode() no longer follows the previously-decoded stream
/// position, and without a flush dav1d_get_picture() can hand back a
/// picture decoded from the pre-seek position. Safe to call with NULL
/// (no-op).
void dav1d_shim_flush(void *ctx);

#endif /* DAV1D_SHIM_H */
