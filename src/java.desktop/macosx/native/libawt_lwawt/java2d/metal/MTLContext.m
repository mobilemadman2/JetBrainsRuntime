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

#include <stdlib.h>
#include <string.h>

#include "sun_java2d_SunGraphics2D.h"

#include "jlong.h"
#include "jni_util.h"
#import "MTLContext.h"
#include "MTLRenderQueue.h"
#include "MTLSurfaceDataBase.h"
#include "GraphicsPrimitiveMgr.h"
#include "Region.h"
#include "common.h"

#include "jvm.h"

extern jboolean MTLSD_InitMTLWindow(JNIEnv *env, MTLSDOps *mtlsdo);
extern MTLContext *MTLSD_MakeMTLContextCurrent(JNIEnv *env,
                                               MTLSDOps *srcOps,
                                               MTLSDOps *dstOps);
NSString *getAlphaCompositeString(jint rule, jfloat extraAlpha);

static id<MTLRenderCommandEncoder> commonRenderEncoder = NULL;
static id<MTLTexture> commonRenderEncoderDest = NULL;

#define RGBA_TO_V4(c)              \
{                                  \
    (((c) >> 16) & (0xFF))/255.0f, \
    (((c) >> 8) & 0xFF)/255.0f,    \
    ((c) & 0xFF)/255.0f,           \
    (((c) >> 24) & 0xFF)/255.0f    \
}

/**
 * This table contains the standard blending rules (or Porter-Duff compositing
 * factors) used in glBlendFunc(), indexed by the rule constants from the
 * AlphaComposite class.
 */
MTLBlendRule MTStdBlendRules[] = {
};

static struct TxtVertex verts[PGRAM_VERTEX_COUNT] = {
        {{-1.0, 1.0}, {0.0, 0.0}},
        {{1.0, 1.0}, {1.0, 0.0}},
        {{1.0, -1.0}, {1.0, 1.0}},
        {{1.0, -1.0}, {1.0, 1.0}},
        {{-1.0, -1.0}, {0.0, 1.0}},
        {{-1.0, 1.0}, {0.0, 0.0}}
};


static void _traceMatrix(simd_float4x4 * mtx) {
    for (int row = 0; row < 4; ++row) {
        J2dTraceLn4(J2D_TRACE_VERBOSE, "  [%lf %lf %lf %lf]",
                    mtx->columns[0][row], mtx->columns[1][row], mtx->columns[2][row], mtx->columns[3][row]);
    }
}

MTLRenderPassDescriptor* createRenderPassDesc(id<MTLTexture> dest) {
    MTLRenderPassDescriptor * result = [MTLRenderPassDescriptor renderPassDescriptor];
    if (result == nil)
        return nil;

    if (dest == nil) {
        J2dTraceLn(J2D_TRACE_ERROR, "_createRenderPassDesc: destination texture is null");
        return nil;
    }

    MTLRenderPassColorAttachmentDescriptor * ca = result.colorAttachments[0];
    ca.texture = dest;
    ca.loadAction = MTLLoadActionLoad;
    ca.clearColor = MTLClearColorMake(0.0f, 0.9f, 0.0f, 1.0f);
    ca.storeAction = MTLStoreActionStore;
    return result;
}

@implementation MTLCommandBufferWrapper {
    id<MTLCommandBuffer> _commandBuffer;
    NSMutableArray * _pooledTextures;
}

- (id) initWithCommandBuffer:(id<MTLCommandBuffer>)cmdBuf {
    self = [super init];
    if (self) {
        _commandBuffer = [cmdBuf retain];
        _pooledTextures = [[NSMutableArray alloc] init];
    }
    return self;
}

- (id<MTLCommandBuffer>) getCommandBuffer {
    return _commandBuffer;
}

- (void) onComplete { // invoked from completion handler in some pooled thread
    for (int c = 0; c < [_pooledTextures count]; ++c)
        [[_pooledTextures objectAtIndex:c] releaseTexture];
    [_pooledTextures removeAllObjects];
}

- (void) registerPooledTexture:(MTLPooledTextureHandle *)handle {
    [_pooledTextures addObject:handle];
}

- (void) dealloc {
    [self onComplete];

    [self->_pooledTextures release];
    [self->_commandBuffer release];
    [super dealloc];
}

@end


@implementation MTLContext {
    MTLCommandBufferWrapper * _commandBufferWrapper;
}

@synthesize compState, extraAlpha, alphaCompositeRule, xorPixel, pixel, p0,
            p1, p3, cyclic, pixel1, pixel2, r, g, b, a, paintState, useMask,
            useTransform, transform4x4, blitTextureID, textureFunction,
            vertexCacheEnabled, device, library, pipelineState, pipelineStateStorage,
            commandQueue, vertexBuffer,
            color, clipRect, useClip, texturePool;


 - (MTLCommandBufferWrapper *) getCommandBufferWrapper {
    if (_commandBufferWrapper == nil) {
        J2dTraceLn(J2D_TRACE_VERBOSE, "MTLContext : commandBuffer is NULL");
        // NOTE: Command queues are thread-safe and allow multiple outstanding command buffers to be encoded simultaneously.
        _commandBufferWrapper = [[MTLCommandBufferWrapper alloc] initWithCommandBuffer:[self.commandQueue commandBuffer]];// released in [layer blitTexture]
    }
    return _commandBufferWrapper;
}

- (MTLCommandBufferWrapper *) pullCommandBufferWrapper {
    MTLCommandBufferWrapper * result = _commandBufferWrapper;
    _commandBufferWrapper = nil;
    return result;
}

+ (MTLContext*) setSurfacesEnv:(JNIEnv*)env src:(jlong)pSrc dst:(jlong)pDst {
    BMTLSDOps *srcOps = (BMTLSDOps *)jlong_to_ptr(pSrc);
    BMTLSDOps *dstOps = (BMTLSDOps *)jlong_to_ptr(pDst);
    MTLContext *mtlc = NULL;

    if (srcOps == NULL || dstOps == NULL) {
        J2dRlsTraceLn(J2D_TRACE_ERROR, "MTLContext_SetSurfaces: ops are null");
        return NULL;
    }

    J2dTraceLn6(J2D_TRACE_VERBOSE, "MTLContext_SetSurfaces: bsrc=%p (tex=%p type=%d), bdst=%p (tex=%p type=%d)", srcOps, srcOps->pTexture, srcOps->drawableType, dstOps, dstOps->pTexture, dstOps->drawableType);

    if (dstOps->drawableType == MTLSD_TEXTURE) {
        J2dRlsTraceLn(J2D_TRACE_ERROR,
                      "MTLContext_SetSurfaces: texture cannot be used as destination");
        return NULL;
    }

    if (dstOps->drawableType == MTLSD_UNDEFINED) {
        // initialize the surface as an OGLSD_WINDOW
        if (!MTLSD_InitMTLWindow(env, dstOps)) {
            J2dRlsTraceLn(J2D_TRACE_ERROR,
                          "MTLContext_SetSurfaces: could not init OGL window");
            return NULL;
        }
    }

    // make the context current
    MTLSDOps *dstCGLOps = (MTLSDOps *)dstOps->privOps;
    mtlc = dstCGLOps->configInfo->context;

    if (mtlc == NULL) {
        J2dRlsTraceLn(J2D_TRACE_ERROR,
                      "MTLContext_SetSurfaces: could not make context current");
        return NULL;
    }

    // perform additional one-time initialization, if necessary
    if (dstOps->needsInit) {
        if (dstOps->isOpaque) {
            // in this case we are treating the destination as opaque, but
            // to do so, first we need to ensure that the alpha channel
            // is filled with fully opaque values (see 6319663)
            //MTLContext_InitAlphaChannel();
        }
        dstOps->needsInit = JNI_FALSE;
    }

    return mtlc;
}

- (id)initWithDevice:(id<MTLDevice>)d shadersLib:(NSString*)shadersLib {
    self = [super init];
    if (self) {
        // Initialization code here.
        device = d;

        texturePool = [[MTLTexturePool alloc] initWithDevice:device];
        pipelineStateStorage = [[MTLPipelineStatesStorage alloc] initWithDevice:device shaderLibPath:shadersLib];

        vertexBuffer = [device newBufferWithBytes:verts
                                           length:sizeof(verts)
                                          options:MTLResourceCPUCacheModeDefaultCache];

        NSError *error = nil;

        library = [device newLibraryWithFile:shadersLib error:&error];
        if (!library) {
            NSLog(@"Failed to load library. error %@", error);
            exit(0);
        }

        _commandBufferWrapper = nil;

        // Create command queue
        commandQueue = [device newCommandQueue];
    }
    return self;
}

- (void)resetClip {
    //TODO
    J2dTraceLn(J2D_TRACE_INFO, "MTLContext.resetClip");
    useClip = JNI_FALSE;
}

- (void)setClipRectX1:(jint)x1 Y1:(jint)y1 X2:(jint)x2 Y2:(jint)y2 {
    //TODO
    jint width = x2 - x1;
    jint height = y2 - y1;

    J2dTraceLn4(J2D_TRACE_INFO, "MTLContext.setClipRect: x=%d y=%d w=%d h=%d", x1, y1, width, height);

    clipRect.x = x1;
    clipRect.y = y1;
    clipRect.width = width;
    clipRect.height = height;
    useClip = JNI_TRUE;
}

- (void)beginShapeClip {
    //TODO
    J2dTraceLn(J2D_TRACE_ERROR, "MTLContext.beginShapeClip -- :TODO");
}

- (void)endShapeClip {
    //TODO
    J2dTraceLn(J2D_TRACE_ERROR, "MTLContext.endShapeClip  -- :TODO");
}

- (void)resetComposite {
    //TODO
    J2dTraceLn(J2D_TRACE_ERROR, "MTLContext_ResetComposite  -- :TODO");
}

- (void)setAlphaCompositeRule:(jint)rule extraAlpha:(jfloat)_extraAlpha
                        flags:(jint)flags {
    J2dTraceLn3(J2D_TRACE_INFO, "MTLContext_SetAlphaComposite: rule=%d, extraAlpha=%1.2f, flags=%d", rule, extraAlpha, flags);

    extraAlpha = _extraAlpha;
    alphaCompositeRule = rule;
}

- (NSString*)getAlphaCompositeRuleString {
    return getAlphaCompositeString(alphaCompositeRule, extraAlpha);
}

- (void)setXorComposite:(jint)xp {
    //TODO
    J2dTraceLn1(J2D_TRACE_ERROR,
                "MTLContext.setXorComposite: xorPixel=%08x -- :TODO", xp);
}

- (jboolean)isBlendingDisabled {
    // TODO: hold case mtlc->alphaCompositeRule == RULE_SrcOver && sun_java2d_pipe_BufferedContext_SRC_IS_OPAQUE
    return alphaCompositeRule == RULE_Src && (extraAlpha - 1.0f < 0.001f);
}


- (void)resetTransform {
    J2dTraceLn(J2D_TRACE_INFO, "MTLContext_ResetTransform");
    useTransform = JNI_FALSE;
}

- (void)setTransformM00:(jdouble) m00 M10:(jdouble) m10
                    M01:(jdouble) m01 M11:(jdouble) m11
                    M02:(jdouble) m02 M12:(jdouble) m12 {


    J2dTraceLn(J2D_TRACE_INFO, "MTLContext_SetTransform");

    memset(&(transform4x4), 0, sizeof(transform4x4));
    transform4x4.columns[0][0] = m00;
    transform4x4.columns[0][1] = m10;
    transform4x4.columns[1][0] = m01;
    transform4x4.columns[1][1] = m11;
    transform4x4.columns[3][0] = m02;
    transform4x4.columns[3][1] = m12;
    transform4x4.columns[3][3] = 1.0;
    useTransform = JNI_TRUE;
}

- (jboolean)initBlitTileTexture {
    //TODO
    J2dTraceLn(J2D_TRACE_INFO, "MTLContext_InitBlitTileTexture -- :TODO");

    return JNI_TRUE;
}

- (jint)createBlitTextureFormat:(jint)internalFormat pixelFormat:(jint)pixelFormat
                          width:(jint)width height:(jint)height {
    J2dTraceLn(J2D_TRACE_INFO, "MTLContext_InitBlitTileTexture -- :TODO");

    //TODO
    return 0;
}


- (void)setColorR:(int)_r G:(int)_g B:(int)_b A:(int)_a {
    color = 0;
    color |= (_r & (0xFF)) << 16;
    color |= (_g & (0xFF)) << 8;
    color |= _b & (0xFF);
    color |= (_a & (0xFF)) << 24;
    J2dTraceLn4(J2D_TRACE_INFO, "MTLContext.setColor (%d, %d, %d) %d", r,g,b,a);
}

- (void)setColorInt:(int)_pixel {
    color = _pixel;
    J2dTraceLn5(J2D_TRACE_INFO, "MTLContext.setColorInt: pixel=%08x [r=%d g=%d b=%d a=%d]", color, (color >> 16) & (0xFF), (color >> 8) & 0xFF, (color) & 0xFF, (color >> 24) & 0xFF);
}

- (id<MTLRenderCommandEncoder>) createEncoderForDest:(id<MTLTexture>) dest {
    MTLCommandBufferWrapper * cbw = [self getCommandBufferWrapper];
    if (cbw == nil)
        return nil;

    MTLRenderPassDescriptor * rpd = createRenderPassDesc(dest);
    if (rpd == nil)
        return nil;

    // J2dTraceLn1(J2D_TRACE_VERBOSE, "MTLContext: created render encoder to draw on tex=%p", dest);
    id <MTLRenderCommandEncoder> encoder = [[cbw getCommandBuffer] renderCommandEncoderWithDescriptor:rpd];
    [rpd release];
    return encoder;
}

- (void) setEncoderTransform:(id<MTLRenderCommandEncoder>) encoder dest:(id<MTLTexture>) dest {
    simd_float4x4 normalize;
    memset(&normalize, 0, sizeof(normalize));
    normalize.columns[0][0] = 2/(double)dest.width;
    normalize.columns[1][1] = -2/(double)dest.height;
    normalize.columns[3][0] = -1.f;
    normalize.columns[3][1] = 1.f;
    normalize.columns[3][3] = 1.0;

    if (useTransform) {
        simd_float4x4 vertexMatrix = simd_mul(normalize, transform4x4);
        [encoder setVertexBytes:&(vertexMatrix) length:sizeof(vertexMatrix) atIndex:MatrixBuffer];
    } else {
        [encoder setVertexBytes:&(normalize) length:sizeof(normalize) atIndex:MatrixBuffer];
    }
}

- (void) updateRenderEncoderProperties:(id<MTLRenderCommandEncoder>) encoder dest:(id<MTLTexture>) dest {
    if (useClip)
        [encoder setScissorRect:clipRect];

    if (compState == sun_java2d_SunGraphics2D_PAINT_ALPHACOLOR) {
        // set pipeline state
        if (((color >> 24) & 0xFF) < 255) {
            //J2dRlsTraceLn(J2D_TRACE_INFO, "use AC render state");
            [encoder setRenderPipelineState:[self.pipelineStateStorage getRenderPipelineState:NO isSourcePremultiplied:YES isDestPremultiplied:YES isSrcOpaque:NO isDstOpaque:NO compositeRule:RULE_SrcOver]];
        } else {
            //J2dRlsTraceLn(J2D_TRACE_INFO, "use non-AC render state");
            [encoder setRenderPipelineState:[self.pipelineStateStorage getRenderPipelineState:NO]];
        }
        struct FrameUniforms uf = {RGBA_TO_V4(color)};
        [encoder setVertexBytes:&uf length:sizeof(uf) atIndex:FrameUniformBuffer];
    } else if (compState == sun_java2d_SunGraphics2D_PAINT_GRADIENT) {
        // set viewport and pipeline state
        //[mtlEncoder setRenderPipelineState:gradPipelineState];
        [encoder setRenderPipelineState:[self.pipelineStateStorage getRenderPipelineState:YES]];

        struct GradFrameUniforms uf = {
                {p0, p1, p3},
                RGBA_TO_V4(pixel1),
                RGBA_TO_V4(pixel2)};

        [encoder setFragmentBytes: &uf length:sizeof(uf) atIndex:0];
    } else {
        // set pipeline state
        if (((color >> 24) & 0xFF) < 255) {
            //J2dRlsTraceLn(J2D_TRACE_INFO, "use AC render state (comp is UNKNOWN)");
            [encoder setRenderPipelineState:[self.pipelineStateStorage getRenderPipelineState:NO isSourcePremultiplied:YES isDestPremultiplied:YES isSrcOpaque:NO isDstOpaque:NO compositeRule:RULE_SrcOver]];
        } else {
            //J2dRlsTraceLn(J2D_TRACE_INFO, "use non-AC render state (comp is UNKNOWN)");
            [encoder setRenderPipelineState:[self.pipelineStateStorage getRenderPipelineState:NO]];
        }
        struct FrameUniforms uf = {RGBA_TO_V4(color)};
        [encoder setVertexBytes:&uf length:sizeof(uf) atIndex:FrameUniformBuffer];
    }
    [self setEncoderTransform:encoder dest:dest];
}

- (void) updateSamplingEncoderProperties:
     (id<MTLRenderCommandEncoder>) encoder
     dest:(id<MTLTexture>) dest
     isSrcOpaque:(bool)isSrcOpaque
     isDstOpaque:(bool)isDstOpaque
{
    if (compState == sun_java2d_SunGraphics2D_PAINT_ALPHACOLOR) {
        struct TxtFrameUniforms uf = {RGBA_TO_V4(color), 1, isSrcOpaque, isDstOpaque };
        [encoder setFragmentBytes:&uf length:sizeof(uf) atIndex:FrameUniformBuffer];
    } else {
        struct TxtFrameUniforms uf = {RGBA_TO_V4(0), 0, isSrcOpaque, isDstOpaque };
        [encoder setFragmentBytes:&uf length:sizeof(uf) atIndex:FrameUniformBuffer];
    }
    [encoder setRenderPipelineState:[pipelineStateStorage getTexturePipelineState:YES
          isDestPremultiplied:YES
          isSrcOpaque:isSrcOpaque
          isDstOpaque:isDstOpaque
          compositeRule:alphaCompositeRule]];
    [self setEncoderTransform:encoder dest:dest];
}

- (id<MTLBlitCommandEncoder>)createBlitEncoder {
    [self endCommonRenderEncoder];
    return [[[self getCommandBufferWrapper] getCommandBuffer] blitCommandEncoder];
}

- (id<MTLRenderCommandEncoder>) createCommonRenderEncoderForDest:(id<MTLTexture>) dest {
    if (commonRenderEncoderDest != dest && commonRenderEncoder != nil) {
        J2dTraceLn2(J2D_TRACE_VERBOSE, "endCommonRenderEncoder because of dest change: %p -> %p", commonRenderEncoderDest, dest);
        [self endCommonRenderEncoder];
    }
    if (commonRenderEncoder == nil) {
        commonRenderEncoder = [self createEncoderForDest: dest];
        commonRenderEncoderDest = dest;
    }
    [self updateRenderEncoderProperties:commonRenderEncoder dest:dest];
    return commonRenderEncoder;
}

- (id<MTLRenderCommandEncoder>)createCommonSamplingEncoderForDest:(id<MTLTexture>)dest isSrcOpaque:(bool)isSrcOpaque isDstOpaque:(bool)isDstOpaque {
    if (commonRenderEncoderDest != dest && commonRenderEncoder != nil) {
        J2dTraceLn2(J2D_TRACE_VERBOSE, "endCommonRenderEncoder(Sampling) because of dest change: %p -> %p", commonRenderEncoderDest, dest);
        [self endCommonRenderEncoder];
    }
    if (commonRenderEncoder == nil) {
        commonRenderEncoder = [self createEncoderForDest: dest];
        commonRenderEncoderDest = dest;
    }
    [self updateRenderEncoderProperties:commonRenderEncoder dest:dest];
    [self updateSamplingEncoderProperties:commonRenderEncoder
            dest:dest
            isSrcOpaque:isSrcOpaque
            isDstOpaque:isDstOpaque];

    return commonRenderEncoder;
}

- (void) endCommonRenderEncoder {
    if (commonRenderEncoder != nil) {
        [commonRenderEncoder endEncoding];
        [commonRenderEncoder release];
        commonRenderEncoder = nil;
        commonRenderEncoderDest = nil;
    }
}

- (id<MTLCommandBuffer>)createBlitCommandBuffer {
    return [self.commandQueue commandBuffer];
}
- (void)dealloc {
    J2dTraceLn(J2D_TRACE_INFO, "MTLContext.dealloc");

    self.texturePool = nil;
    self.library = nil;
    self.vertexBuffer = nil;
    self.commandQueue = nil;
    self.pipelineState = nil;
    self.pipelineStateStorage = nil;
    [super dealloc];
}

- (void)setGradientPaintUseMask:(jboolean)_useMask cyclic:(jboolean)_cyclic p0:(jdouble) _p0 p1:(jdouble)_p1
                             p3:(jdouble)_p3 pixel1:(jint)_pixel1 pixel2:(jint)_pixel2 {

    //TODO Resolve gradient distribution problem
    //TODO Implement useMask
    //TODO Implement cyclic
    //fprintf(stderr,
    //        "MTLPaints_SetGradientPaint useMask=%d cyclic=%d "
    //        "p0=%f p1=%f p3=%f pix1=%d pix2=%d\n", useMask, cyclic,
    //        p0, p1, p3, pixel1, pixel2);

    compState = sun_java2d_SunGraphics2D_PAINT_GRADIENT;
    useMask = _useMask;
    pixel1 = _pixel1;
    pixel2 = _pixel2;
    p0 = _p0;
    p1 = _p1;
    p3 = _p3;
    cyclic = _cyclic;
 }

- (NSString *)getPaintStateString {
    if (compState == sun_java2d_SunGraphics2D_PAINT_ALPHACOLOR) {
        return [NSString stringWithFormat:@"[r=%d g=%d b=%d a=%d]", (color >> 16) & (0xFF), (color >> 8) & 0xFF, (color) & 0xFF, (color >> 24) & 0xFF];
    }
    return @"non-color-paint";
 }

@end

/*
 * Class:     sun_java2d_metal_MTLContext
 * Method:    getMTLIdString
 * Signature: ()Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_sun_java2d_metal_MTLContext_getMTLIdString
  (JNIEnv *env, jclass mtlcc)
{
    char *vendor, *renderer, *version;
    char *pAdapterId;
    jobject ret = NULL;
    int len;

    return NULL;
}

NSString * getAlphaCompositeString(jint rule, jfloat extraAlpha) {
    const char * result = "";
    switch (rule) {
        case java_awt_AlphaComposite_CLEAR:
        {
            result = "CLEAR";
        }
            break;
        case java_awt_AlphaComposite_SRC:
        {
            result = "SRC";
        }
            break;
        case java_awt_AlphaComposite_DST:
        {
            result = "DST";
        }
            break;
        case java_awt_AlphaComposite_SRC_OVER:
        {
            result = "SRC_OVER";
        }
            break;
        case java_awt_AlphaComposite_DST_OVER:
        {
            result = "DST_OVER";
        }
            break;
        case java_awt_AlphaComposite_SRC_IN:
        {
            result = "SRC_IN";
        }
            break;
        case java_awt_AlphaComposite_DST_IN:
        {
            result = "DST_IN";
        }
            break;
        case java_awt_AlphaComposite_SRC_OUT:
        {
            result = "SRC_OUT";
        }
            break;
        case java_awt_AlphaComposite_DST_OUT:
        {
            result = "DST_OUT";
        }
            break;
        case java_awt_AlphaComposite_SRC_ATOP:
        {
            result = "SRC_ATOP";
        }
            break;
        case java_awt_AlphaComposite_DST_ATOP:
        {
            result = "DST_ATOP";
        }
            break;
        case java_awt_AlphaComposite_XOR:
        {
            result = "XOR";
        }
            break;
        default:
            result = "UNKNOWN";
            break;
    }
    const double epsilon = 0.001f;
    if (fabs(extraAlpha - 1.f) > epsilon) {
        return [NSString stringWithFormat:@"%s [%1.2f]", result, extraAlpha];
    }
    return [NSString stringWithFormat:@"%s", result];
}

#endif /* !HEADLESS */
