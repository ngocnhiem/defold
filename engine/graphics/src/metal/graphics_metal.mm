// Copyright 2020-2025 The Defold Foundation
// Copyright 2014-2020 King
// Copyright 2009-2014 Ragnar Svensson, Christian Murray
// Licensed under the Defold License version 1.0 (the "License"); you may not use
// this file except in compliance with the License.
//
// You may obtain a copy of the License, together with FAQs at
// https://www.defold.com/license
//
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

#include <type_traits>

#define NS_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Foundation/Foundation.h>
// Metal.hpp is Taken from https://github.com/bkaradzic/metal-cpp/blob/metal-cpp_macOS15.2_iOS18.2/SingleHeader/Metal.hpp
#include <Metal.hpp>
#include <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>

#include "../graphics_private.h"
#include "../graphics_native.h"
#include "../graphics_adapter.h"

#include "graphics_metal_private.h"

namespace dmGraphics
{
    static GraphicsAdapterFunctionTable MetalRegisterFunctionTable();
    static bool                         MetalIsSupported();
    static HContext                     MetalGetContext();
    static bool                         MetalInitialize(HContext _context);
    static GraphicsAdapter g_Metal_adapter(ADAPTER_FAMILY_METAL);
    static MetalContext*   g_MetalContext = 0x0;

    DM_REGISTER_GRAPHICS_ADAPTER(GraphicsAdapterMetal, &g_Metal_adapter, MetalIsSupported, MetalRegisterFunctionTable, MetalGetContext, ADAPTER_FAMILY_PRIORITY_METAL);

    MetalContext::MetalContext(const ContextParams& params)
    {
        memset(this, 0, sizeof(*this));

        // m_NumFramesInFlight       = MAX_FRAMES_IN_FLIGHT;
        m_DefaultTextureMinFilter = params.m_DefaultTextureMinFilter;
        m_DefaultTextureMagFilter = params.m_DefaultTextureMagFilter;
        // m_VerifyGraphicsCalls     = params.m_VerifyGraphicsCalls;
        // m_PrintDeviceInfo         = params.m_PrintDeviceInfo;
        m_Window                  = params.m_Window;
        m_Width                   = params.m_Width;
        m_Height                  = params.m_Height;
        // m_UseValidationLayers     = params.m_UseValidationLayers;

        assert(dmPlatform::GetWindowStateParam(m_Window, dmPlatform::WINDOW_STATE_OPENED));
    }

    static HContext MetalNewContext(const ContextParams& params)
    {
        if (!g_MetalContext)
        {
            g_MetalContext = new MetalContext(params);

            if (MetalInitialize(g_MetalContext))
            {
                return g_MetalContext;
            }

            DeleteContext(g_MetalContext);
        }
        return 0x0;
    }

    static void MetalDeleteContext(HContext _context)
    {
        assert(_context);
        if (g_MetalContext)
        {
            MetalContext* context = (MetalContext*) _context;

            context->m_Device->release();
            context->m_CommandQueue->release();

            // for (uint8_t i=0; i < DM_ARRAY_SIZE(context->m_FrameResources); i++)
            // {
            //     FlushResourcesToDestroy(context->m_FrameResources[i]);
            // }

            delete (MetalContext*) context;
            g_MetalContext = 0x0;
        }
    }

    static HContext MetalGetContext()
    {
        return g_MetalContext;
    }

    static bool MetalIsSupported()
    {
        return true;
    }

    static bool MetalInitialize(HContext _context)
    {
        MetalContext* context   = (MetalContext*) _context;
        context->m_Device       = MTL::CreateSystemDefaultDevice();
        context->m_CommandQueue = context->m_Device->newCommandQueue();

        NSWindow* mative_window = (NSWindow*) dmGraphics::GetNativeOSXNSWindow();
        context->m_View         = [mative_window contentView];

        context->m_Layer               = [CAMetalLayer layer];
        context->m_Layer.device        = (__bridge id<MTLDevice>) context->m_Device;
        context->m_Layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        context->m_Layer.drawableSize  = CGSizeMake(context->m_Width, context->m_Height);

        [context->m_View setLayer:context->m_Layer];
        [context->m_View setWantsLayer:YES];

        return true;
    }

    static void MetalCloseWindow(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;

        if (dmPlatform::GetWindowStateParam(context->m_Window, dmPlatform::WINDOW_STATE_OPENED))
        {
        }
    }

    static void MetalFinalize()
    {

    }

    static dmPlatform::HWindow MetalGetWindow(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;
        return context->m_Window;
    }

    static uint32_t MetalGetDisplayDpi(HContext _context)
    {
        return 0;
    }

    static uint32_t MetalGetWidth(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;
        return context->m_Width;
    }

    static uint32_t MetalGetHeight(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;
        return context->m_Height;
    }

    static void MetalSetWindowSize(HContext _context, uint32_t width, uint32_t height)
    {
        assert(_context);
        MetalContext* context = (MetalContext*) _context;
        if (dmPlatform::GetWindowStateParam(context->m_Window, dmPlatform::WINDOW_STATE_OPENED))
        {
            dmPlatform::SetWindowSize(context->m_Window, width, height);
        }
    }

    static void MetalResizeWindow(HContext _context, uint32_t width, uint32_t height)
    {
        assert(_context);
        MetalContext* context = (MetalContext*) _context;
        if (dmPlatform::GetWindowStateParam(context->m_Window, dmPlatform::WINDOW_STATE_OPENED))
        {
            dmPlatform::SetWindowSize(context->m_Window, width, height);
        }
    }

    static void MetalGetDefaultTextureFilters(HContext _context, TextureFilter& out_min_filter, TextureFilter& out_mag_filter)
    {
        MetalContext* context = (MetalContext*) _context;
        out_min_filter = context->m_DefaultTextureMinFilter;
        out_mag_filter = context->m_DefaultTextureMagFilter;
    }

    static void MetalBeginFrame(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;

        context->m_Drawable = (__bridge CA::MetalDrawable*)[context->m_Layer nextDrawable];

        context->m_AutoReleasePool = NS::AutoreleasePool::alloc()->init();
        context->m_CommandBuffer = context->m_CommandQueue->commandBuffer();

        context->m_RenderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();

        auto colorAttachment = context->m_RenderPassDescriptor->colorAttachments()->object(0);
        colorAttachment->setTexture(context->m_Drawable->texture());
        colorAttachment->setLoadAction(MTL::LoadActionClear);
        colorAttachment->setStoreAction(MTL::StoreActionStore);
        colorAttachment->setClearColor(MTL::ClearColor(0.1, 0.2, 0.4, 1.0));

        context->m_RenderCommandEncoder = context->m_CommandBuffer->renderCommandEncoder( context->m_RenderPassDescriptor );
    }

    static void MetalFlip(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;

        context->m_RenderCommandEncoder->endEncoding();

        context->m_CommandBuffer->presentDrawable(context->m_Drawable);
        context->m_CommandBuffer->commit();

        context->m_AutoReleasePool->release();
    }

    static void MetalClear(HContext _context, uint32_t flags, uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha, float depth, uint32_t stencil)
    {

    }

    static HVertexBuffer MetalNewVertexBuffer(HContext _context, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        return 0;
    }

    static void MetalDeleteVertexBuffer(HVertexBuffer buffer)
    {

    }

    static void MetalSetVertexBufferData(HVertexBuffer buffer, uint32_t size, const void* data, BufferUsage buffer_usage)
    {

    }

    static void MetalSetVertexBufferSubData(HVertexBuffer buffer, uint32_t offset, uint32_t size, const void* data)
    {

    }

    static uint32_t MetalGetVertexBufferSize(HVertexBuffer buffer)
    {
        return 0;
    }

    static uint32_t MetalGetMaxElementsVertices(HContext _context)
    {
        return 0;
    }

    static HIndexBuffer MetalNewIndexBuffer(HContext _context, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        return 0;
    }

    static void MetalDeleteIndexBuffer(HIndexBuffer buffer)
    {

    }

    static void MetalSetIndexBufferData(HIndexBuffer buffer, uint32_t size, const void* data, BufferUsage buffer_usage)
    {

    }

    static void MetalSetIndexBufferSubData(HIndexBuffer buffer, uint32_t offset, uint32_t size, const void* data)
    {

    }

    static uint32_t MetalGetIndexBufferSize(HIndexBuffer buffer)
    {
        return 0;
    }

    static bool MetalIsIndexBufferFormatSupported(HContext _context, IndexBufferFormat format)
    {
        return 0;
    }

    static uint32_t MetalGetMaxElementsIndices(HContext _context)
    {
        return 0;
    }

    static HVertexDeclaration MetalNewVertexDeclaration(HContext _context, HVertexStreamDeclaration stream_declaration)
    {
        return 0;
    }

    static HVertexDeclaration MetalNewVertexDeclarationStride(HContext _context, HVertexStreamDeclaration stream_declaration, uint32_t stride)
    {
        return 0;
    }

    static void MetalEnableVertexDeclaration(HContext _context, HVertexDeclaration vertex_declaration, uint32_t binding_index, uint32_t base_offset, HProgram program)
    {

    }

    static void MetalDisableVertexDeclaration(HContext _context, HVertexDeclaration vertex_declaration)
    {

    }

    static void MetalEnableVertexBuffer(HContext _context, HVertexBuffer vertex_buffer, uint32_t binding_index)
    {

    }

    static void MetalDisableVertexBuffer(HContext _context, HVertexBuffer vertex_buffer)
    {

    }

    static void MetalDrawElements(HContext _context, PrimitiveType prim_type, uint32_t first, uint32_t count, Type type, HIndexBuffer index_buffer, uint32_t instance_count)
    {

    }

    static void MetalDraw(HContext _context, PrimitiveType prim_type, uint32_t first, uint32_t count, uint32_t instance_count)
    {

    }

    static void MetalDispatchCompute(HContext _context, uint32_t group_count_x, uint32_t group_count_y, uint32_t group_count_z)
    {

    }

    static HProgram MetalNewProgram(HContext _context, ShaderDesc* ddf, char* error_buffer, uint32_t error_buffer_size)
    {
        MetalProgram* program = new MetalProgram();

        return (HProgram) program;
    }

    static void MetalDeleteProgram(HContext _context, HProgram _program)
    {
        MetalProgram* program = (MetalProgram*) _program;
        delete program;
    }

    static ShaderDesc::Language MetalGetProgramLanguage(HProgram program)
    {
        return (ShaderDesc::Language) 0;
    }

    static bool MetalIsShaderLanguageSupported(HContext _context, ShaderDesc::Language language, ShaderDesc::ShaderType shader_type)
    {
        return true;
    }

    static void MetalEnableProgram(HContext _context, HProgram program)
    {

    }

    static void MetalDisableProgram(HContext _context)
    {

    }

    static bool MetalReloadProgram(HContext _context, HProgram program, ShaderDesc* ddf)
    {
        return 0;
    }

    static uint32_t MetalGetAttributeCount(HProgram prog)
    {
        return 0;
    }

    static void MetalGetAttribute(HProgram prog, uint32_t index, dmhash_t* name_hash, Type* type, uint32_t* element_count, uint32_t* num_values, int32_t* location)
    {

    }

    static void MetalSetConstantV4(HContext _context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {

    }

    static void MetalSetConstantM4(HContext _context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {

    }

    static void MetalSetSampler(HContext _context, HUniformLocation location, int32_t unit)
    {

    }

    static void MetalSetViewport(HContext _context, int32_t x, int32_t y, int32_t width, int32_t height)
    {

    }

    static void MetalEnableState(HContext _context, State state)
    {

    }

    static void MetalDisableState(HContext _context, State state)
    {

    }

    static void MetalSetBlendFunc(HContext _context, BlendFactor source_factor, BlendFactor destinaton_factor)
    {

    }

    static void MetalSetColorMask(HContext _context, bool red, bool green, bool blue, bool alpha)
    {

    }

    static void MetalSetDepthMask(HContext _context, bool enable_mask)
    {

    }

    static void MetalSetDepthFunc(HContext _context, CompareFunc func)
    {

    }

    static void MetalSetScissor(HContext _context, int32_t x, int32_t y, int32_t width, int32_t height)
    {

    }

    static void MetalSetStencilMask(HContext _context, uint32_t mask)
    {

    }

    static void MetalSetStencilFunc(HContext _context, CompareFunc func, uint32_t ref, uint32_t mask)
    {

    }

    static void MetalSetStencilFuncSeparate(HContext _context, FaceType face_type, CompareFunc func, uint32_t ref, uint32_t mask)
    {

    }

    static void MetalSetStencilOp(HContext _context, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {

    }

    static void MetalSetStencilOpSeparate(HContext _context, FaceType face_type, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {

    }

    static void MetalSetCullFace(HContext _context, FaceType face_type)
    {

    }

    static void MetalSetFaceWinding(HContext _context, FaceWinding face_winding)
    {

    }

    static void MetalSetPolygonOffset(HContext _context, float factor, float units)
    {

    }

    static HRenderTarget MetalNewRenderTarget(HContext _context, uint32_t buffer_type_flags, const RenderTargetCreationParams params)
    {
        return 0;
    }

    static void MetalDeleteRenderTarget(HContext _context, HRenderTarget render_target)
    {

    }

    static void MetalSetRenderTarget(HContext _context, HRenderTarget render_target, uint32_t transient_buffer_types)
    {

    }

    static HTexture MetalGetRenderTargetTexture(HContext _context, HRenderTarget render_target, BufferType buffer_type)
    {
        return 0;
    }

    static void MetalGetRenderTargetSize(HContext _context, HRenderTarget render_target, BufferType buffer_type, uint32_t& width, uint32_t& height)
    {

    }

    static void MetalSetRenderTargetSize(HContext _context, HRenderTarget render_target, uint32_t width, uint32_t height)
    {

    }

    static bool MetalIsTextureFormatSupported(HContext _context, TextureFormat format)
    {
        return 0;
    }

    static HTexture MetalNewTexture(HContext _context, const TextureCreationParams& params)
    {
        return 0;
    }

    static void MetalDeleteTexture(HContext _context, HTexture t)
    {

    }

    static void MetalSetTexture(HContext _context, HTexture texture, const TextureParams& params)
    {

    }

    static void MetalSetTextureAsync(HContext _context, HTexture texture, const TextureParams& params, SetTextureAsyncCallback callback, void* user_data)
    {

    }

    static void MetalSetTextureParams(HContext _context, HTexture texture, TextureFilter minfilter, TextureFilter magfilter, TextureWrap uwrap, TextureWrap vwrap, float max_anisotropy)
    {

    }

    static uint32_t MetalGetTextureResourceSize(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureWidth(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureHeight(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureDepth(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetOriginalTextureWidth(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetOriginalTextureHeight(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint8_t MetalGetTextureMipmapCount(HContext _context, HTexture texture)
    {
        return 0;
    }

    static TextureType MetalGetTextureType(HContext _context, HTexture texture)
    {
        return (TextureType) 0;
    }

    static void MetalEnableTexture(HContext _context, uint32_t unit, uint8_t id_index, HTexture texture)
    {

    }

    static void MetalDisableTexture(HContext _context, uint32_t unit, HTexture texture)
    {

    }

    static uint32_t MetalGetMaxTextureSize(HContext _context)
    {
        return 0;
    }

    static uint32_t MetalGetTextureStatusFlags(HContext _context, HTexture texture)
    {
        return 0;
    }

    static void MetalReadPixels(HContext _context, int32_t x, int32_t y, uint32_t width, uint32_t height, void* buffer, uint32_t buffer_size)
    {

    }

    static void MetalRunApplicationLoop(void* user_data, WindowStepMethod step_method, WindowIsRunning is_running)
    {

    }

    static HandleResult MetalGetTextureHandle(HTexture texture, void** out_handle)
    {
        return (HandleResult) 0;
    }

    static bool MetalIsExtensionSupported(HContext _context, const char* extension)
    {
        return 0;
    }

    static uint32_t MetalGetNumSupportedExtensions(HContext _context)
    {
        return 0;
    }

    static const char* MetalGetSupportedExtension(HContext _context, uint32_t index)
    {
        return 0;
    }

    static bool MetalIsContextFeatureSupported(HContext _context, ContextFeature feature)
    {
        return 0;
    }

    static PipelineState MetalGetPipelineState(HContext _context)
    {
        return {};
    }

    static uint8_t MetalGetNumTextureHandles(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint32_t MetalGetTextureUsageHintFlags(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint8_t MetalGetTexturePageCount(HTexture texture)
    {
        return 0;
    }

    static bool MetalIsAssetHandleValid(HContext _context, HAssetHandle asset_handle)
    {
        return 0;
    }

    static void MetalInvalidateGraphicsHandles(HContext _context)
    {

    }

    static void MetalGetViewport(HContext _context, int32_t* x, int32_t* y, uint32_t* width, uint32_t* height)
    {

    }


    static GraphicsAdapterFunctionTable MetalRegisterFunctionTable()
    {
        GraphicsAdapterFunctionTable fn_table = {};
        DM_REGISTER_GRAPHICS_FUNCTION_TABLE(fn_table, Metal);
        return fn_table;
    }
}
