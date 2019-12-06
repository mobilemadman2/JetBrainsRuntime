/*
 * Copyright (c) 2019, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#ifndef HEADLESS

#include <jni.h>
#include <jlong.h>

#include "SurfaceData.h"
#include "MTLBlitLoops.h"
#include "MTLRenderQueue.h"
#include "MTLSurfaceData.h"
#include "MTLUtils.h"
#include "GraphicsPrimitiveMgr.h"

#include <stdlib.h> // malloc
#include <string.h> // memcpy
#include "IntArgbPre.h"

#import <Accelerate/Accelerate.h>

typedef struct {
    MTLPixelFormat   format;
    jboolean hasAlpha;
    jboolean isPremult;
    const uint8_t * permuteMap;
} MTLRasterFormatInfo;

// 0 denotes the alpha channel, 1 the red channel, 2 the green channel, and 3 the blue channel.
const uint8_t permuteMap_rgbx[4] = { 1, 2, 3, 0 };
const uint8_t permuteMap_bgrx[4] = { 3, 2, 1, 0 };

static uint8_t revertPerm(const uint8_t * perm, uint8_t pos) {
    for (int c = 0; c < 4; ++c) {
        if (perm[c] == pos)
            return c;
    }
    return -1;
}

#define uint2swizzle(channel) (channel == 0 ? MTLTextureSwizzleAlpha : (channel == 1 ? MTLTextureSwizzleRed : (channel == 2 ? MTLTextureSwizzleGreen : (channel == 3 ? MTLTextureSwizzleBlue : MTLTextureSwizzleZero))))

/**
 * This table contains the "pixel formats" for all system memory surfaces
 * that Metal is capable of handling, indexed by the "PF_" constants defined
 * in MTLLSurfaceData.java.  These pixel formats contain information that is
 * passed to Metal when copying from a system memory ("Sw") surface to
 * an Metal surface
 */
MTLRasterFormatInfo RasterFormatInfos[] = {
        { MTLPixelFormatBGRA8Unorm, 1, 0, NULL }, /* 0 - IntArgb      */ // Argb (in java notation)
        { MTLPixelFormatBGRA8Unorm, 1, 1, NULL }, /* 1 - IntArgbPre   */
        { MTLPixelFormatBGRA8Unorm, 0, 1, NULL }, /* 2 - IntRgb       */ // xrgb
        { MTLPixelFormatBGRA8Unorm, 0, 1, permuteMap_rgbx }, /* 3 - IntRgbx      */
        { MTLPixelFormatRGBA8Unorm, 0, 1, NULL }, /* 4 - IntBgr       */ // xbgr
        { MTLPixelFormatBGRA8Unorm, 0, 1, permuteMap_bgrx }, /* 5 - IntBgrx      */

//        TODO: support 2-byte formats
//        { GL_BGRA, GL_UNSIGNED_SHORT_1_5_5_5_REV,
//                2, 0, 1,                                     }, /* 7 - Ushort555Rgb */
//        { GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1,
//                2, 0, 1,                                     }, /* 8 - Ushort555Rgbx*/
//        { GL_LUMINANCE, GL_UNSIGNED_BYTE,
//                1, 0, 1,                                     }, /* 9 - ByteGray     */
//        { GL_LUMINANCE, GL_UNSIGNED_SHORT,
//                2, 0, 1,                                     }, /*10 - UshortGray   */
//        { GL_BGR,  GL_UNSIGNED_BYTE,
//                1, 0, 1,                                     }, /*11 - ThreeByteBgr */
};

extern void J2dTraceImpl(int level, jboolean cr, const char *string, ...);

void fillTxQuad(
        struct TxtVertex * txQuadVerts,
        jint sx1, jint sy1, jint sx2, jint sy2, jint sw, jint sh,
        jdouble dx1, jdouble dy1, jdouble dx2, jdouble dy2, jdouble dw, jdouble dh
) {
    const float nsx1 = sx1/(float)sw;
    const float nsy1 = sy1/(float)sh;
    const float nsx2 = sx2/(float)sw;
    const float nsy2 = sy2/(float)sh;

    txQuadVerts[0].position[0] = dx1;
    txQuadVerts[0].position[1] = dy1;
    txQuadVerts[0].txtpos[0]   = nsx1;
    txQuadVerts[0].txtpos[1]   = nsy1;

    txQuadVerts[1].position[0] = dx2;
    txQuadVerts[1].position[1] = dy1;
    txQuadVerts[1].txtpos[0]   = nsx2;
    txQuadVerts[1].txtpos[1]   = nsy1;

    txQuadVerts[2].position[0] = dx2;
    txQuadVerts[2].position[1] = dy2;
    txQuadVerts[2].txtpos[0]   = nsx2;
    txQuadVerts[2].txtpos[1]   = nsy2;

    txQuadVerts[3].position[0] = dx2;
    txQuadVerts[3].position[1] = dy2;
    txQuadVerts[3].txtpos[0]   = nsx2;
    txQuadVerts[3].txtpos[1]   = nsy2;

    txQuadVerts[4].position[0] = dx1;
    txQuadVerts[4].position[1] = dy2;
    txQuadVerts[4].txtpos[0]   = nsx1;
    txQuadVerts[4].txtpos[1]   = nsy2;

    txQuadVerts[5].position[0] = dx1;
    txQuadVerts[5].position[1] = dy1;
    txQuadVerts[5].txtpos[0]   = nsx1;
    txQuadVerts[5].txtpos[1]   = nsy1;
}

//#define TRACE_drawTex2Tex

static void drawTex2Tex(MTLContext *mtlc,
                        id<MTLTexture> src, id<MTLTexture> dst,
                        jboolean isSrcOpaque, jboolean isDstOpaque,
                        jint sx1, jint sy1, jint sx2, jint sy2,
                        jdouble dx1, jdouble dy1, jdouble dx2, jdouble dy2)
{
    if (mtlc == NULL || src == nil || dst == nil)
        return;

#ifdef TRACE_drawTex2Tex
    J2dRlsTraceLn2(J2D_TRACE_VERBOSE, "drawTex2Tex: src tex=%p, dst tex=%p", src, dst);
    J2dRlsTraceLn4(J2D_TRACE_VERBOSE, "  sw=%d sh=%d dw=%d dh=%d", src.width, src.height, dst.width, dst.height);
    J2dRlsTraceLn4(J2D_TRACE_VERBOSE, "  sx1=%d sy1=%d sx2=%d sy2=%d", sx1, sy1, sx2, sy2);
    J2dRlsTraceLn4(J2D_TRACE_VERBOSE, "  dx1=%f dy1=%f dx2=%f dy2=%f", dx1, dy1, dx2, dy2);
#endif //TRACE_drawTex2Tex

    id<MTLRenderCommandEncoder> encoder = [mtlc createCommonSamplingEncoderForDest:
                                               dst
                                               isSrcOpaque:isSrcOpaque
                                               isDstOpaque:isDstOpaque];

    struct TxtVertex quadTxVerticesBuffer[6];
    fillTxQuad(quadTxVerticesBuffer, sx1, sy1, sx2, sy2, src.width, src.height, dx1, dy1, dx2, dy2, dst.width, dst.height);

    [encoder setVertexBytes:quadTxVerticesBuffer length:sizeof(quadTxVerticesBuffer) atIndex:MeshVertexBuffer];
    [encoder setFragmentTexture:src atIndex: 0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

static
id<MTLTexture> replaceTextureRegion(id<MTLTexture> dest, const SurfaceDataRasInfo * srcInfo, const MTLRasterFormatInfo * rfi, int dx1, int dy1, int dx2, int dy2) {
    const int dw = dx2 - dx1;
    const int dh = dy2 - dy1;

    const void * raster = srcInfo->rasBase;
    id<MTLTexture> result = nil;
    if (rfi->permuteMap != NULL) {
#if defined(__MAC_10_15) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_10_15
        if (@available(macOS 10.15, *)) {
            @autoreleasepool {
                const uint8_t swzRed = revertPerm(rfi->permuteMap, 1);
                const uint8_t swzGreen = revertPerm(rfi->permuteMap, 2);
                const uint8_t swzBlue = revertPerm(rfi->permuteMap, 3);
                const uint8_t swzAlpha = revertPerm(rfi->permuteMap, 0);
                MTLTextureSwizzleChannels swizzle = MTLTextureSwizzleChannelsMake(
                        uint2swizzle(swzRed),
                        uint2swizzle(swzGreen),
                        uint2swizzle(swzBlue),
                        rfi->hasAlpha ? uint2swizzle(swzAlpha) : MTLTextureSwizzleOne
                );
                result = [dest
                        newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm
                        textureType:MTLTextureType2D
                        levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)
                        swizzle:swizzle];
                J2dTraceLn5(J2D_TRACE_VERBOSE, "replaceTextureRegion [use swizzle for pooled]: %d, %d, %d, %d, hasA=%d",
                            swizzle.red, swizzle.green, swizzle.blue, swizzle.alpha, rfi->hasAlpha);
            }
        } else
#endif // __MAC_10_15 && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_10_15
        {
            // perform raster conversion
            // invoked only from rq-thread, so use static buffers
            // but it's better to use thread-local buffers (or special buffer manager)
            const int destRasterSize = dw*dh*4;

            static int bufferSize = 0;
            static void * buffer = NULL;
            if (buffer == NULL || bufferSize < destRasterSize) {
                bufferSize = destRasterSize;
                buffer = realloc(buffer, bufferSize);
            }
            if (buffer == NULL) {
                J2dTraceLn1(J2D_TRACE_ERROR, "replaceTextureRegion: can't alloc buffer for raster conversion, size=%d", bufferSize);
                bufferSize = 0;
                return nil;
            }
            vImage_Buffer srcBuf;
            srcBuf.height = dw;
            srcBuf.width = dh;
            srcBuf.rowBytes = srcInfo->scanStride;
            srcBuf.data = srcInfo->rasBase;

            vImage_Buffer destBuf;
            destBuf.height = dw;
            destBuf.width = dh;
            destBuf.rowBytes = dw*4;
            destBuf.data = buffer;

            vImagePermuteChannels_ARGB8888(&srcBuf, &destBuf, rfi->permuteMap, kvImageNoFlags);
            raster = buffer;

            J2dTraceLn5(J2D_TRACE_VERBOSE, "replaceTextureRegion [use conversion]: %d, %d, %d, %d, hasA=%d",
                        rfi->permuteMap[0], rfi->permuteMap[1], rfi->permuteMap[2], rfi->permuteMap[3], rfi->hasAlpha);
        }
    }

    MTLRegion region = MTLRegionMake2D(dx1, dy1, dw, dh);
    if (result != nil)
        dest = result;
    [dest replaceRegion:region mipmapLevel:0 withBytes:raster bytesPerRow:srcInfo->scanStride];
    return result;
}

/**
 * Inner loop used for copying a source system memory ("Sw") surface to a
 * destination MTL "Surface".  This method is invoked from
 * MTLBlitLoops_Blit().
 */

static void
MTLBlitSwToTextureViaPooledTexture(MTLContext *ctx, SurfaceDataRasInfo *srcInfo, BMTLSDOps * bmtlsdOps,
                   MTLRasterFormatInfo * rfi,
                   jdouble dx1, jdouble dy1, jdouble dx2, jdouble dy2)
{
    if (bmtlsdOps == NULL || bmtlsdOps->pTexture == NULL) {
        J2dTraceLn(J2D_TRACE_ERROR, "MTLBlitSwToSurfaceViaTexture: dest is null");
        return;
    }

    const int sw = srcInfo->bounds.x2 - srcInfo->bounds.x1;
    const int sh = srcInfo->bounds.y2 - srcInfo->bounds.y1;
    id<MTLTexture> dest = bmtlsdOps->pTexture;

    MTLPooledTextureHandle * texHandle = [ctx.texturePool getTexture:sw height:sh format:rfi->format];
    if (texHandle == nil) {
        J2dTraceLn(J2D_TRACE_ERROR, "MTLBlitSwToTextureViaPooledTexture: can't obtain temporary texture object from pool");
        return;
    }
    [[ctx getCommandBufferWrapper] registerPooledTexture:texHandle];

    id<MTLTexture> texBuff = texHandle.texture;
    id<MTLTexture> swizzledTexture = replaceTextureRegion(texBuff, srcInfo, rfi, 0, 0, sw, sh);
    drawTex2Tex(ctx, swizzledTexture != nil ? swizzledTexture : texBuff, dest, !rfi->hasAlpha, bmtlsdOps->isOpaque, 0, 0, sw, sh, dx1, dy1, dx2, dy2);
    if (swizzledTexture != nil) {
        [swizzledTexture release];
    }
}

//#define TRACE_ISOBLIT

/**
 * General blit method for copying a native MTL surface to another MTL "Surface".
 * Parameter texture == true only in SwToTextureBlit (straight copy from sw to texture), dest coordinates will always be integers.
 * Parameter xform == true only when AffineTransform is used (invoked only from TransformBlit, dest coordinates will always be integers).
 * Parameter scaled == true only when invoked from ScaledBlit (it is the single case when dest coordinates can be double).
 */
void
MTLBlitLoops_IsoBlit(JNIEnv *env,
                     MTLContext *mtlc, jlong pSrcOps, jlong pDstOps,
                     jboolean xform, jint hint,
                     jboolean texture, jboolean rtt,
                     jint sx1, jint sy1, jint sx2, jint sy2,
                     jdouble dx1, jdouble dy1, jdouble dx2, jdouble dy2)
{
    BMTLSDOps *srcOps = (BMTLSDOps *)jlong_to_ptr(pSrcOps);
    BMTLSDOps *dstOps = (BMTLSDOps *)jlong_to_ptr(pDstOps);

    RETURN_IF_NULL(srcOps);
    RETURN_IF_NULL(dstOps);

    id<MTLTexture> srcTex = srcOps->pTexture;
    id<MTLTexture> dstTex = dstOps->pTexture;
    if (mtlc == NULL || srcTex == nil || srcTex == nil) {
        J2dTraceLn2(J2D_TRACE_ERROR, "MTLBlitLoops_IsoBlit: surface is null (stex=%p, dtex=%p)", srcTex, dstTex);
        return;
    }

    const jint sw    = sx2 - sx1;
    const jint sh    = sy2 - sy1;
    const jdouble dw = dx2 - dx1;
    const jdouble dh = dy2 - dy1;

    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) {
        J2dTraceLn4(J2D_TRACE_WARNING, "MTLBlitLoops_IsoBlit: invalid dimensions: sw=%d, sh%d, dw=%d, dh=%d", sw, sh, dw, dh);
        return;
    }

    SurfaceDataRasInfo srcInfo;
    srcInfo.bounds.x1 = sx1;
    srcInfo.bounds.y1 = sy1;
    srcInfo.bounds.x2 = sx2;
    srcInfo.bounds.y2 = sy2;
    SurfaceData_IntersectBoundsXYXY(&srcInfo.bounds, 0, 0, srcOps->width, srcOps->height);

    if (srcInfo.bounds.x2 <= srcInfo.bounds.x1 || srcInfo.bounds.y2 <= srcInfo.bounds.y1) {
        J2dTraceLn(J2D_TRACE_VERBOSE, "MTLBlitLoops_IsoBlit: source rectangle doesn't intersect with source surface bounds");
        J2dTraceLn6(J2D_TRACE_VERBOSE, "  sx1=%d sy1=%d sx2=%d sy2=%d sw=%d sh=%d", sx1, sy1, sx2, sy2, srcOps->width, srcOps->height);
        J2dTraceLn4(J2D_TRACE_VERBOSE, "  dx1=%f dy1=%f dx2=%f dy2=%f", dx1, dy1, dx2, dy2);
        return;
    }

    if (srcInfo.bounds.x1 != sx1) {
        dx1 += (srcInfo.bounds.x1 - sx1) * (dw / sw);
        sx1 = srcInfo.bounds.x1;
    }
    if (srcInfo.bounds.y1 != sy1) {
        dy1 += (srcInfo.bounds.y1 - sy1) * (dh / sh);
        sy1 = srcInfo.bounds.y1;
    }
    if (srcInfo.bounds.x2 != sx2) {
        dx2 += (srcInfo.bounds.x2 - sx2) * (dw / sw);
        sx2 = srcInfo.bounds.x2;
    }
    if (srcInfo.bounds.y2 != sy2) {
        dy2 += (srcInfo.bounds.y2 - sy2) * (dh / sh);
        sy2 = srcInfo.bounds.y2;
    }

#ifdef TRACE_ISOBLIT
    J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_FALSE,
         "MTLBlitLoops_IsoBlit [AC=%s]: src=%s, dst=%s | (%d, %d, %d, %d)->(%1.2f, %1.2f, %1.2f, %1.2f)",
         [mtlc getAlphaCompositeRuleString].cString, getSurfaceDescription(srcOps).cString, getSurfaceDescription(dstOps).cString,
         sx1, sy1, sx2, sy2, dx1, dy1, dx2, dy2);
#endif //TRACE_ISOBLIT

    const jboolean useBlitEncoder =
            mtlc.isBlendingDisabled
            && fabs(dx2 - dx1 - sx2 + sx1) < 0.001f && fabs(dy2 - dy1 - sy2 + sy1) < 0.001f // dimensions are equal (TODO: check that dx1,dy1 is integer)
            && !mtlc.useTransform; // TODO: check whether transform is simple translate (and use blitEncoder in this case)
    if (useBlitEncoder) {
#ifdef TRACE_ISOBLIT
        J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_TRUE," [via blitEncoder]");
#endif //TRACE_ISOBLIT
        [mtlc endCommonRenderEncoder];

        id <MTLBlitCommandEncoder> blitEncoder = [mtlc createBlitEncoder];
        [blitEncoder copyFromTexture:srcTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx1, sy1, 0) sourceSize:MTLSizeMake(mtlc.clipRect.width, mtlc.clipRect.height, 1) toTexture:dstTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(dx1, dy1, 0)];
        [blitEncoder endEncoding];
    } else {
        // TODO: support other flags

#ifdef TRACE_ISOBLIT
        J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_TRUE," [via sampling]");
#endif //TRACE_ISOBLIT

        drawTex2Tex(mtlc, srcTex, dstTex, srcOps->isOpaque, dstOps->isOpaque, sx1, sy1, sx2, sy2, dx1, dy1, dx2, dy2);
    }
}

static
void trimRectangles(
        jdouble * x1, jdouble * y1, jdouble * x2, jdouble * y2,
        jint w, jint h,
        SurfaceDataBounds * associatedRect
) {
    if (*x1 < 0) {
        associatedRect->x1 += (int)*x1;
        *x1 = 0;
    }
    if (*x2 > w) {
        associatedRect->x2 -= (int)*x2 - w;
        *x2 = w;
    }
    if (*y1 < 0) {
        associatedRect->y1 += (int)*y1;
        *y1 = 0;
    }
    if (*y2 > h) {
        associatedRect->y2 -= (int)*y2 - h;
        *y2 = h;
    }
}

static
void trimRectanglesScaled(
        jdouble * x1, jdouble * y1, jdouble * x2, jdouble * y2,
        jint w, jint h, jdouble scaleX, jdouble scaleY,
        SurfaceDataBounds * associatedRect
) {
    if (*x1 < 0) {
        associatedRect->x1 += (int)(*x1 * scaleX);
        *x1 = 0;
    }
    if (*x2 > w) {
        associatedRect->x2 -= (int)((*x2 - w) * scaleX);
        *x2 = w;
    }
    if (*y1 < 0) {
        associatedRect->y1 += (int)(*y1 * scaleY);
        *y1 = 0;
    }
    if (*y2 > h) {
        associatedRect->y2 -= (int)((*y2 - h) * scaleY);
        *y2 = h;
    }
}

//#define DEBUG_BLIT
//#define TRACE_BLIT

/**
 * General blit method for copying a system memory ("Sw") surface to a native MTL surface.
 * Parameter texture == true only in SwToTextureBlit (straight copy from sw to texture), dest coordinates will always be integers.
 * Parameter xform == true only when AffineTransform is used (invoked only from TransformBlit, dest coordinates will always be integers).
 * Parameter scaled == true only when invoked from ScaledBlit (it is the single case when dest coordinates can be double).
 */
void
MTLBlitLoops_Blit(JNIEnv *env,
                  MTLContext *mtlc, jlong pSrcOps, jlong pDstOps,
                  jboolean xform, jboolean scaled, jint hint,
                  jint srctype, jboolean texture,
                  jint sx1, jint sy1, jint sx2, jint sy2,
                  jdouble dx1, jdouble dy1, jdouble dx2, jdouble dy2)
{
    RETURN_IF_NULL(jlong_to_ptr(pSrcOps));
    RETURN_IF_NULL(jlong_to_ptr(pDstOps));

    SurfaceDataOps *srcOps = (SurfaceDataOps *)jlong_to_ptr(pSrcOps);
    BMTLSDOps *dstOps = (BMTLSDOps *)jlong_to_ptr(pDstOps);
    id<MTLTexture> dest = dstOps->pTexture;

    if (dest == NULL) {
        J2dTraceLn(J2D_TRACE_ERROR, "MTLBlitLoops_Blit: dest is null");
        return;
    }
    if (srctype < 0 || srctype >= sizeof(RasterFormatInfos)/ sizeof(MTLRasterFormatInfo)) {
        J2dTraceLn1(J2D_TRACE_ERROR, "MTLBlitLoops_Blit: source pixel format %d isn't supported", srctype);
        return;
    }
    const jint sw    = sx2 - sx1;
    const jint sh    = sy2 - sy1;
    const jdouble dw = dx2 - dx1;
    const jdouble dh = dy2 - dy1;

    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) {
        J2dTraceLn(J2D_TRACE_ERROR, "MTLBlitLoops_Blit: invalid dimensions");
        return;
    }

#ifdef DEBUG_BLIT
    jboolean traceDest = JNI_FALSE;
    if (
        (xform == JNI_TRUE) != (mtlc.useTransform == JNI_TRUE)
        || (xform && texture)
        || (xform && scaled)
        || (scaled && texture)
    ) {
        J2dTraceImpl(J2D_TRACE_ERROR, JNI_TRUE,
                "MTLBlitLoops_Blit state error: xform=%d, mtlc.useTransform=%d, texture=%d, scaled=%d",
                xform, mtlc.useTransform, texture, scaled);
        traceDest = JNI_TRUE;
    }
    if (xform || texture || !scaled) {
        // check that dx1,dy1 is integer and destSize equals srcSize
        const double epsilon = 0.001f;
        if (fabs(dx1 - (int)dx1) > epsilon || fabs(dy1 - (int)dy1) > epsilon) {
            J2dTraceImpl(J2D_TRACE_ERROR, JNI_TRUE, "MTLBlitLoops_Blit: dest coords must be integers");
            traceDest = JNI_TRUE;
        }
        if (fabs(dx2 - dx1 - sx2 + sx1) > epsilon || fabs(dy2 - dy1 - sy2 + sy1) > epsilon) {
            J2dTraceImpl(J2D_TRACE_ERROR, JNI_TRUE, "MTLBlitLoops_Blit: src and dst dimensions must be equal");
            traceDest = JNI_TRUE;
        }
    }
    if (traceDest) {
        J2dTraceImpl(J2D_TRACE_ERROR, JNI_TRUE,
                "\tbdst=%p [tex=%p] %dx%d | src (%d, %d, %d, %d) -> dst (%1.2f, %1.2f, %1.2f, %1.2f)",
                dstOps, dest, dest.width, dest.height, sx1, sy1, sx2, sy2, dx1, dy1, dx2, dy2);
    }
#endif // DEBUG_BLIT

    SurfaceDataBounds srect = {sx1, sy1, sx2, sy2 };

    // Trim destination rect by dest.bounds (to decrease size of raster requested from source)
    if (scaled) {
        trimRectanglesScaled(&dx1, &dy1, &dx2, &dy2, dest.width, dest.height, sw/dw, sh/dh, &srect);
    } else {
        trimRectangles(&dx1, &dy1, &dx2, &dy2, dest.width, dest.height, &srect);
    }

    SurfaceDataRasInfo srcInfo;
    srcInfo.bounds = srect;

    // NOTE: This function will modify the contents of the bounds field to represent the maximum available raster data.
    if (srcOps->Lock(env, srcOps, &srcInfo, SD_LOCK_READ) != SD_SUCCESS) {
        J2dTraceLn(J2D_TRACE_WARNING, "MTLBlitLoops_Blit: could not acquire lock");
        return;
    }

#ifdef TRACE_BLIT
    J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_FALSE,
        "MTLBlitLoops_Blit [AC=%s]: bdst=%s, src=%p (%dx%d) O=%d premul=%d | (%d, %d, %d, %d)->(%1.2f, %1.2f, %1.2f, %1.2f)",
        [mtlc getAlphaCompositeRuleString].cString, getSurfaceDescription(dstOps).cString, srcOps,
        srcInfo.bounds.x2 - srcInfo.bounds.x1, srcInfo.bounds.y2 - srcInfo.bounds.y1,
        RasterFormatInfos[srctype].hasAlpha ? 0 : 1, RasterFormatInfos[srctype].isPremult ? 1 : 0,
        srcInfo.bounds.x1, srcInfo.bounds.y1, srcInfo.bounds.x2, srcInfo.bounds.y2,
        dx1, dy1, dx2, dy2);
#endif //TRACE_BLIT

    if (srcInfo.bounds.x2 > srcInfo.bounds.x1 && srcInfo.bounds.y2 > srcInfo.bounds.y1) {
        srcOps->GetRasInfo(env, srcOps, &srcInfo);
        if (srcInfo.rasBase) {
            if (srcInfo.bounds.x1 != srect.x1) {
                const int dx = srcInfo.bounds.x1 - srect.x1;
                dx1 += scaled ? dx * (dw / sw) : dx;
            }
            if (srcInfo.bounds.y1 != srect.y1) {
                const int dy = srcInfo.bounds.y1 - srect.y1;
                dy1 += scaled ? dy * (dh / sh) : dy;
            }
            if (srcInfo.bounds.x2 != sx2) {
                const int dx = srcInfo.bounds.x2 - srect.x2;
                dx2 += scaled ? dx * (dw / sw) : dx;
            }
            if (srcInfo.bounds.y2 != sy2) {
                const int dy = srcInfo.bounds.y2 - srect.y2;
                dy2 += scaled ? dy * (dh / sh) : dy;
            }

            MTLRasterFormatInfo rfi = RasterFormatInfos[srctype];
            const int ndx1 = (int)dx1, ndy1 = (int)dy1, ndx2 = (int)dx2, ndy2 = (int)dy2;
            const bool wholeDest = ndx1 == 0 && ndy1 == 0 && ndx2 == dest.width && ndy2 == dest.height;
            const jboolean useReplaceRegion = texture ||
                    (mtlc.isBlendingDisabled
                    && !scaled
                    && !xform // Possible optimization: check whether transform is simple translate (and use replaceRegion in this case)
                    && (dstOps->isOpaque || rfi.hasAlpha || wholeDest)); // can't use replaceRegion when dest has alpha and source hasn't alpha (and blit is partial)

            if (useReplaceRegion) {
#ifdef TRACE_BLIT
                J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_TRUE," [replaceTextureRegion]");
#endif //TRACE_BLIT
                replaceTextureRegion(dest, &srcInfo, &rfi, ndx1, ndy1, ndx2, ndy2);
                if (wholeDest) {
                    // J2dTraceLn2(J2D_TRACE_VERBOSE, "\t change opaque-flag: %d -> %d", dstOps->isOpaque, !rfi.hasAlpha);
                    dstOps->isOpaque = !rfi.hasAlpha;
                }
            } else { // !useReplaceRegion
#ifdef TRACE_BLIT
                J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_TRUE," [via pooled texture]");
#endif //TRACE_BLIT
                MTLBlitSwToTextureViaPooledTexture(mtlc, &srcInfo, dstOps, &rfi, dx1, dy1, dx2, dy2);
            }
        }
        SurfaceData_InvokeRelease(env, srcOps, &srcInfo);
    }
    SurfaceData_InvokeUnlock(env, srcOps, &srcInfo);
}

/**
 * Specialized blit method for copying a native MTL "Surface" (pbuffer,
 * window, etc.) to a system memory ("Sw") surface.
 */
void
MTLBlitLoops_SurfaceToSwBlit(JNIEnv *env, MTLContext *mtlc,
                             jlong pSrcOps, jlong pDstOps, jint dsttype,
                             jint srcx, jint srcy, jint dstx, jint dsty,
                             jint width, jint height)
{
    //TODO
    J2dTraceLn(J2D_TRACE_ERROR, "MTLBlitLoops_SurfaceToSwBlit -- :TODO");
}

void
MTLBlitLoops_CopyArea(JNIEnv *env,
                      MTLContext *mtlc, BMTLSDOps *dstOps,
                      jint x, jint y, jint width, jint height,
                      jint dx, jint dy)
{
#ifdef DEBUG
    J2dTraceImpl(J2D_TRACE_VERBOSE, JNI_TRUE, "MTLBlitLoops_CopyArea: bdst=%p [tex=%p] %dx%d | src (%d, %d), %dx%d -> dst (%d, %d)",
            dstOps, dstOps->pTexture, ((id<MTLTexture>)dstOps->pTexture).width, ((id<MTLTexture>)dstOps->pTexture).height, x, y, width, height, dx, dy);
#endif //DEBUG
    [mtlc endCommonRenderEncoder];
    id <MTLBlitCommandEncoder> blitEncoder = [mtlc createBlitEncoder];
    [blitEncoder
            copyFromTexture:dstOps->pTexture
            sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(width, height, 1)
            toTexture:dstOps->pTexture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x + dx, y + dy, 0)];
    [blitEncoder endEncoding];
}

#endif /* !HEADLESS */
