//
//  Dav1dShim.c
//  See Dav1dShim.h. dav1d is linked device-only; the simulator gets stubs.
//

#include "Dav1dShim.h"
#include <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR

#include <dav1d/dav1d.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

const char *dav1d_shim_version(void) {
    return dav1d_version();
}

void *dav1d_shim_create(void) {
    Dav1dSettings settings;
    dav1d_default_settings(&settings);

    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores < 1) {
        cores = 1;
    }
    // Bound the thread pool: single-stream 1080p/4K decode doesn't benefit
    // much past a handful of tile threads, and we don't want to compete with
    // the rest of the app for cores.
    int threads = (int)(cores < 4 ? cores : 4);
    settings.n_threads = threads;
    // Disable frame-level lookahead/threading: with max_frame_delay = 1,
    // dav1d_send_data()+dav1d_get_picture() for one temporal unit fully
    // completes that frame's decode (tile threads still run, but the frame
    // is synchronized before the picture is handed back) before returning.
    // This is what lets dav1d_shim_decode() treat the caller's OBU buffer as
    // valid only for the duration of that single call — see its doc comment.
    settings.max_frame_delay = 1;

    Dav1dContext *context = NULL;
    if (dav1d_open(&context, &settings) < 0) {
        return NULL;
    }
    return context;
}

void dav1d_shim_destroy(void *ctx) {
    if (ctx == NULL) {
        return;
    }
    Dav1dContext *context = (Dav1dContext *)ctx;
    dav1d_close(&context);
}

void dav1d_shim_flush(void *ctx) {
    if (ctx == NULL) {
        return;
    }
    dav1d_flush((Dav1dContext *)ctx);
}

static void dav1d_shim_noop_free(const uint8_t *buf, void *cookie) {
    (void)buf;
    (void)cookie;
    // No-op: `buf` belongs to the caller of dav1d_shim_decode() (backed by a
    // Swift Data/segment buffer) for the lifetime of that call only. Because
    // the decoder is opened with max_frame_delay = 1 (see dav1d_shim_create),
    // dav1d has fully finished reading `buf` by the time send+get returns for
    // this temporal unit, so there is nothing for us to free here and no
    // risk of a background thread touching `buf` after we return.
}

/// Builds a retained CFDictionary of the form
/// { kCVPixelBufferIOSurfacePropertiesKey: {} } so the created pixel buffer
/// is IOSurface-backed (required to enqueue on AVSampleBufferDisplayLayer).
static CFDictionaryRef dav1d_shim_iosurface_backed_attrs(void) {
    CFDictionaryRef emptyProps = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    const void *keys[1] = { kCVPixelBufferIOSurfacePropertiesKey };
    const void *values[1] = { emptyProps };
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(emptyProps);
    return attrs;
}

static void dav1d_shim_attach_color(CVPixelBufferRef pixelBuffer) {
    // BT.709 is a reasonable default for HD SDR content. Deriving exact
    // primaries/transfer/matrix from pic.seq_hdr's color_description is a
    // nice-to-have left for later; many 4K AV1 streams are 10-bit HDR
    // (BT.2020/PQ or HLG) and will look off with this default — tracked as a
    // known limitation of the v1 decode path, not fixed here.
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

/// Converts an 8-bit 4:2:0 Dav1dPicture into a triplanar I420 CVPixelBuffer.
static CVPixelBufferRef dav1d_shim_convert_8bit_i420(const Dav1dPicture *pic) {
    CFDictionaryRef attrs = dav1d_shim_iosurface_backed_attrs();
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)pic->p.w, (size_t)pic->p.h,
                                          kCVPixelFormatType_420YpCbCr8Planar,
                                          attrs, &pixelBuffer);
    CFRelease(attrs);
    if (status != kCVReturnSuccess || pixelBuffer == NULL) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Planes: 0 = Y, 1 = U/Cb, 2 = V/Cr. dav1d shares one chroma stride
    // between U and V (stride[1]); Y uses stride[0].
    const int widths[3]  = { pic->p.w, (pic->p.w + 1) / 2, (pic->p.w + 1) / 2 };
    const int heights[3] = { pic->p.h, (pic->p.h + 1) / 2, (pic->p.h + 1) / 2 };
    const ptrdiff_t srcStrides[3] = { pic->stride[0], pic->stride[1], pic->stride[1] };

    for (int plane = 0; plane < 3; plane++) {
        const uint8_t *src = (const uint8_t *)pic->data[plane];
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, (size_t)plane);
        size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, (size_t)plane);
        size_t copyWidth = (size_t)widths[plane];
        if (dstStride < copyWidth) {
            copyWidth = dstStride;
        }
        for (int row = 0; row < heights[plane]; row++) {
            memcpy(dst + (size_t)row * dstStride,
                  src + (size_t)row * srcStrides[plane],
                  copyWidth);
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

/// Converts a 10-bit 4:2:0 Dav1dPicture into a biplanar P010 CVPixelBuffer.
/// dav1d always hands back 3 separate planes (Y/U/V) regardless of bit
/// depth, so this interleaves U/V into one plane and left-shifts each 10-bit
/// sample (stored in the low bits of a 16-bit word) into P010's high-bit
/// packing.
static CVPixelBufferRef dav1d_shim_convert_10bit_p010(const Dav1dPicture *pic) {
    CFDictionaryRef attrs = dav1d_shim_iosurface_backed_attrs();
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)pic->p.w, (size_t)pic->p.h,
                                          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                          attrs, &pixelBuffer);
    CFRelease(attrs);
    if (status != kCVReturnSuccess || pixelBuffer == NULL) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Plane 0: Y, 16-bit samples with the 10-bit value in the low bits.
    {
        uint16_t *dstY = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        ptrdiff_t srcStride = pic->stride[0];
        for (int row = 0; row < pic->p.h; row++) {
            const uint16_t *srcRow =
                (const uint16_t *)((const uint8_t *)pic->data[0] + (size_t)row * srcStride);
            uint16_t *dstRow = (uint16_t *)((uint8_t *)dstY + (size_t)row * dstStride);
            for (int col = 0; col < pic->p.w; col++) {
                dstRow[col] = (uint16_t)(srcRow[col] << 6);
            }
        }
    }

    // Plane 1: interleaved UV (NV12-style), each sample left-shifted the
    // same way as luma.
    {
        uint16_t *dstUV = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        ptrdiff_t srcStride = pic->stride[1];
        int chromaWidth = (pic->p.w + 1) / 2;
        int chromaHeight = (pic->p.h + 1) / 2;
        for (int row = 0; row < chromaHeight; row++) {
            const uint16_t *srcURow =
                (const uint16_t *)((const uint8_t *)pic->data[1] + (size_t)row * srcStride);
            const uint16_t *srcVRow =
                (const uint16_t *)((const uint8_t *)pic->data[2] + (size_t)row * srcStride);
            uint16_t *dstRow = (uint16_t *)((uint8_t *)dstUV + (size_t)row * dstStride);
            for (int col = 0; col < chromaWidth; col++) {
                dstRow[2 * col] = (uint16_t)(srcURow[col] << 6);
                dstRow[2 * col + 1] = (uint16_t)(srcVRow[col] << 6);
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

CVPixelBufferRef dav1d_shim_decode(
    void *ctx, const uint8_t *obu, size_t len, dav1d_shim_decode_result_t *outResult) {
    outResult->status = DAV1D_SHIM_STATUS_INVALID_ARGS;
    outResult->errorCode = 0;
    outResult->width = 0;
    outResult->height = 0;
    outResult->bitDepth = 0;

    if (ctx == NULL || obu == NULL || len == 0) {
        return NULL;
    }
    Dav1dContext *context = (Dav1dContext *)ctx;

    Dav1dData data;
    memset(&data, 0, sizeof(data));
    int wrapResult = dav1d_data_wrap(&data, obu, len, dav1d_shim_noop_free, NULL);
    if (wrapResult < 0) {
        outResult->status = DAV1D_SHIM_STATUS_SEND_ERROR;
        outResult->errorCode = wrapResult;
        return NULL;
    }

    // Feed the sample to the decoder. dav1d_send_data() returns:
    //  - 0: the whole buffer was consumed and ownership of the reference
    //       passed to dav1d (our local `data` is zeroed by the library).
    //  - EAGAIN: internal buffers are full; drain a picture (discarding it —
    //       with max_frame_delay = 1 this is not expected in steady state,
    //       but if the decoder is warming up on the first temporal unit it's
    //       possible) and retry the send.
    //  - another negative value: a real error; the reference remains ours.
    int sendError = 0;
    for (;;) {
        int sendResult = dav1d_send_data(context, &data);
        if (sendResult == 0) {
            break;
        }
        if (sendResult == DAV1D_ERR(EAGAIN)) {
            Dav1dPicture drained;
            memset(&drained, 0, sizeof(drained));
            if (dav1d_get_picture(context, &drained) == 0) {
                dav1d_picture_unref(&drained);
            }
            continue;
        }
        sendError = 1;
        outResult->errorCode = sendResult;
        break;
    }

    // Always safe: dav1d_data_unref() is a documented no-op once the
    // reference has already been transferred to the library on a successful
    // send, so this never double-frees.
    dav1d_data_unref(&data);

    if (sendError) {
        outResult->status = DAV1D_SHIM_STATUS_SEND_ERROR;
        return NULL;
    }

    Dav1dPicture picture;
    memset(&picture, 0, sizeof(picture));
    int getResult = dav1d_get_picture(context, &picture);
    if (getResult != 0) {
        if (getResult == DAV1D_ERR(EAGAIN)) {
            outResult->status = DAV1D_SHIM_STATUS_NO_PICTURE_YET;
        } else {
            outResult->status = DAV1D_SHIM_STATUS_GET_PICTURE_ERROR;
            outResult->errorCode = getResult;
        }
        return NULL;
    }

    outResult->width = picture.p.w;
    outResult->height = picture.p.h;
    outResult->bitDepth = picture.p.bpc;

    int layoutSupported =
        (picture.p.bpc == 8 || picture.p.bpc == 10) && picture.p.layout == DAV1D_PIXEL_LAYOUT_I420;
    if (!layoutSupported) {
        // Other layouts (4:2:2, 4:4:4, monochrome) aren't handled.
        dav1d_picture_unref(&picture);
        outResult->status = DAV1D_SHIM_STATUS_UNSUPPORTED_LAYOUT;
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = picture.p.bpc == 8
        ? dav1d_shim_convert_8bit_i420(&picture)
        : dav1d_shim_convert_10bit_p010(&picture);
    dav1d_picture_unref(&picture);

    if (pixelBuffer == NULL) {
        // Layout was supported, so the only way convert_* returns NULL is
        // CVPixelBufferCreate() failing — most likely memory pressure at
        // large (4K) frame sizes on constrained devices.
        outResult->status = DAV1D_SHIM_STATUS_ALLOC_FAILED;
        return NULL;
    }

    dav1d_shim_attach_color(pixelBuffer);
    outResult->status = DAV1D_SHIM_STATUS_OK;
    return pixelBuffer;
}

#else

void *dav1d_shim_create(void) {
    return 0;
}

void dav1d_shim_destroy(void *ctx) {
    (void)ctx;
}

CVPixelBufferRef dav1d_shim_decode(
    void *ctx, const uint8_t *obu, size_t len, dav1d_shim_decode_result_t *outResult) {
    (void)ctx;
    (void)obu;
    (void)len;
    outResult->status = DAV1D_SHIM_STATUS_INVALID_ARGS;
    outResult->errorCode = 0;
    outResult->width = 0;
    outResult->height = 0;
    outResult->bitDepth = 0;
    return 0;
}

void dav1d_shim_flush(void *ctx) {
    (void)ctx;
}

const char *dav1d_shim_version(void) {
    return 0;
}

#endif
