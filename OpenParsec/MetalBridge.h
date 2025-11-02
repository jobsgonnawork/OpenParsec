#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "parsec.h"

static inline ParsecStatus ParsecMetalRenderWrapper(Parsec *ps, uint8_t stream, id<MTLCommandQueue> cq, id<MTLTexture> target, ParsecPreRenderCallback pre, const void *opaque, uint32_t timeout) {
    ParsecMetalCommandQueue *cqPtr = (ParsecMetalCommandQueue *)&cq;
    ParsecMetalTexture *tex = (ParsecMetalTexture *)target;
    ParsecMetalTexture **texPtr = &tex;
    return ParsecClientMetalRenderFrame(ps, stream, cqPtr, texPtr, pre, opaque, timeout);
}


