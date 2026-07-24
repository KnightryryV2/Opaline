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
///  - 8-bit 4:2:0 streams  -> kCVPixelFormatType_420YpCbCr8Planar (I420)
///  - 10-bit 4:2:0 streams -> kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (P010)
///  - anything else (4:2:2, 4:4:4, monochrome) -> NULL; caller must fall back.
/// Color attachments are set to BT.709 primaries/transfer/matrix as a
/// reasonable default for HD content (deriving exact values from the AV1
/// sequence header is a nice-to-have left for later).
///
/// CF_RETURNS_RETAINED: this really does hand back a +1 reference (the C
/// implementation CVPixelBufferCreate()s a fresh buffer per call and never
/// releases it). Without this annotation Swift imports the return type as
/// an unmanaged pointer, and callers going through `.takeUnretainedValue()`
/// would leak every frame; with it, Swift imports a plain `CVPixelBuffer?`
/// that ARC balances correctly on scope exit.
CF_RETURNS_RETAINED CVPixelBufferRef dav1d_shim_decode(void *ctx, const uint8_t *obu, size_t len);

#endif /* DAV1D_SHIM_H */
