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
        // m_DefaultTextureMinFilter = params.m_DefaultTextureMinFilter;
        // m_DefaultTextureMagFilter = params.m_DefaultTextureMagFilter;
        // m_VerifyGraphicsCalls     = params.m_VerifyGraphicsCalls;
        // m_PrintDeviceInfo         = params.m_PrintDeviceInfo;
        // m_Window                  = params.m_Window;
        // m_Width                   = params.m_Width;
        // m_Height                  = params.m_Height;
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
        return true;
    }

    static void MetalCloseWindow(HContext context)
    {

    }

    static void MetalFinalize()
    {

    }

    static dmPlatform::HWindow MetalGetWindow(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;
        return context->m_Window;
    }

    static uint32_t MetalGetDisplayDpi(HContext context)
    {
        return 0;
    }

    static uint32_t MetalGetWidth(HContext context)
    {
        return 0;
    }

    static uint32_t MetalGetHeight(HContext context)
    {
        return 0;
    }

    static void MetalSetWindowSize(HContext context, uint32_t width, uint32_t height)
    {

    }

    static void MetalResizeWindow(HContext context, uint32_t width, uint32_t height)
    {

    }

    static void MetalGetDefaultTextureFilters(HContext context, TextureFilter& out_min_filter, TextureFilter& out_mag_filter)
    {

    }

    static void MetalBeginFrame(HContext context)
    {

    }

    static void MetalFlip(HContext context)
    {

    }

    static void MetalClear(HContext context, uint32_t flags, uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha, float depth, uint32_t stencil)
    {

    }

    static HVertexBuffer MetalNewVertexBuffer(HContext context, uint32_t size, const void* data, BufferUsage buffer_usage)
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

    static uint32_t MetalGetMaxElementsVertices(HContext context)
    {
        return 0;
    }

    static HIndexBuffer MetalNewIndexBuffer(HContext context, uint32_t size, const void* data, BufferUsage buffer_usage)
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

    static bool MetalIsIndexBufferFormatSupported(HContext context, IndexBufferFormat format)
    {
        return 0;
    }

    static uint32_t MetalGetMaxElementsIndices(HContext context)
    {
        return 0;
    }

    static HVertexDeclaration MetalNewVertexDeclaration(HContext context, HVertexStreamDeclaration stream_declaration)
    {
        return 0;
    }

    static HVertexDeclaration MetalNewVertexDeclarationStride(HContext context, HVertexStreamDeclaration stream_declaration, uint32_t stride)
    {
        return 0;
    }

    static void MetalEnableVertexDeclaration(HContext context, HVertexDeclaration vertex_declaration, uint32_t binding_index, uint32_t base_offset, HProgram program)
    {

    }

    static void MetalDisableVertexDeclaration(HContext context, HVertexDeclaration vertex_declaration)
    {

    }

    static void MetalEnableVertexBuffer(HContext context, HVertexBuffer vertex_buffer, uint32_t binding_index)
    {

    }

    static void MetalDisableVertexBuffer(HContext context, HVertexBuffer vertex_buffer)
    {

    }

    static void MetalDrawElements(HContext context, PrimitiveType prim_type, uint32_t first, uint32_t count, Type type, HIndexBuffer index_buffer, uint32_t instance_count)
    {

    }

    static void MetalDraw(HContext context, PrimitiveType prim_type, uint32_t first, uint32_t count, uint32_t instance_count)
    {

    }

    static void MetalDispatchCompute(HContext context, uint32_t group_count_x, uint32_t group_count_y, uint32_t group_count_z)
    {

    }

    static HProgram MetalNewProgram(HContext context, ShaderDesc* ddf, char* error_buffer, uint32_t error_buffer_size)
    {
        return 0;
    }

    static void MetalDeleteProgram(HContext context, HProgram program)
    {

    }

    static ShaderDesc::Language MetalGetProgramLanguage(HProgram program)
    {
        return (ShaderDesc::Language) 0;
    }

    static bool MetalIsShaderLanguageSupported(HContext context, ShaderDesc::Language language, ShaderDesc::ShaderType shader_type)
    {
        return 0;
    }

    static void MetalEnableProgram(HContext context, HProgram program)
    {

    }

    static void MetalDisableProgram(HContext context)
    {

    }

    static bool MetalReloadProgram(HContext context, HProgram program, ShaderDesc* ddf)
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

    static void MetalSetConstantV4(HContext context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {

    }

    static void MetalSetConstantM4(HContext context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {

    }

    static void MetalSetSampler(HContext context, HUniformLocation location, int32_t unit)
    {

    }

    static void MetalSetViewport(HContext context, int32_t x, int32_t y, int32_t width, int32_t height)
    {

    }

    static void MetalEnableState(HContext context, State state)
    {

    }

    static void MetalDisableState(HContext context, State state)
    {

    }

    static void MetalSetBlendFunc(HContext context, BlendFactor source_factor, BlendFactor destinaton_factor)
    {

    }

    static void MetalSetColorMask(HContext context, bool red, bool green, bool blue, bool alpha)
    {

    }

    static void MetalSetDepthMask(HContext context, bool enable_mask)
    {

    }

    static void MetalSetDepthFunc(HContext context, CompareFunc func)
    {

    }

    static void MetalSetScissor(HContext context, int32_t x, int32_t y, int32_t width, int32_t height)
    {

    }

    static void MetalSetStencilMask(HContext context, uint32_t mask)
    {

    }

    static void MetalSetStencilFunc(HContext context, CompareFunc func, uint32_t ref, uint32_t mask)
    {

    }

    static void MetalSetStencilFuncSeparate(HContext context, FaceType face_type, CompareFunc func, uint32_t ref, uint32_t mask)
    {

    }

    static void MetalSetStencilOp(HContext context, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {

    }

    static void MetalSetStencilOpSeparate(HContext context, FaceType face_type, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {

    }

    static void MetalSetCullFace(HContext context, FaceType face_type)
    {

    }

    static void MetalSetFaceWinding(HContext context, FaceWinding face_winding)
    {

    }

    static void MetalSetPolygonOffset(HContext context, float factor, float units)
    {

    }

    static HRenderTarget MetalNewRenderTarget(HContext context, uint32_t buffer_type_flags, const RenderTargetCreationParams params)
    {
        return 0;
    }

    static void MetalDeleteRenderTarget(HContext context, HRenderTarget render_target)
    {

    }

    static void MetalSetRenderTarget(HContext context, HRenderTarget render_target, uint32_t transient_buffer_types)
    {

    }

    static HTexture MetalGetRenderTargetTexture(HContext context, HRenderTarget render_target, BufferType buffer_type)
    {
        return 0;
    }

    static void MetalGetRenderTargetSize(HContext context, HRenderTarget render_target, BufferType buffer_type, uint32_t& width, uint32_t& height)
    {

    }

    static void MetalSetRenderTargetSize(HContext context, HRenderTarget render_target, uint32_t width, uint32_t height)
    {

    }

    static bool MetalIsTextureFormatSupported(HContext context, TextureFormat format)
    {
        return 0;
    }

    static HTexture MetalNewTexture(HContext context, const TextureCreationParams& params)
    {
        return 0;
    }

    static void MetalDeleteTexture(HContext context, HTexture t)
    {

    }

    static void MetalSetTexture(HContext context, HTexture texture, const TextureParams& params)
    {

    }

    static void MetalSetTextureAsync(HContext context, HTexture texture, const TextureParams& params, SetTextureAsyncCallback callback, void* user_data)
    {

    }

    static void MetalSetTextureParams(HContext context, HTexture texture, TextureFilter minfilter, TextureFilter magfilter, TextureWrap uwrap, TextureWrap vwrap, float max_anisotropy)
    {

    }

    static uint32_t MetalGetTextureResourceSize(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureWidth(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureHeight(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetTextureDepth(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetOriginalTextureWidth(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint16_t MetalGetOriginalTextureHeight(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint8_t MetalGetTextureMipmapCount(HContext context, HTexture texture)
    {
        return 0;
    }

    static TextureType MetalGetTextureType(HContext context, HTexture texture)
    {
        return (TextureType) 0;
    }

    static void MetalEnableTexture(HContext context, uint32_t unit, uint8_t id_index, HTexture texture)
    {

    }

    static void MetalDisableTexture(HContext context, uint32_t unit, HTexture texture)
    {

    }

    static uint32_t MetalGetMaxTextureSize(HContext context)
    {
        return 0;
    }

    static uint32_t MetalGetTextureStatusFlags(HContext context, HTexture texture)
    {
        return 0;
    }

    static void MetalReadPixels(HContext context, int32_t x, int32_t y, uint32_t width, uint32_t height, void* buffer, uint32_t buffer_size)
    {

    }

    static void MetalRunApplicationLoop(void* user_data, WindowStepMethod step_method, WindowIsRunning is_running)
    {

    }

    static HandleResult MetalGetTextureHandle(HTexture texture, void** out_handle)
    {
        return (HandleResult) 0;
    }

    static bool MetalIsExtensionSupported(HContext context, const char* extension)
    {
        return 0;
    }

    static uint32_t MetalGetNumSupportedExtensions(HContext context)
    {
        return 0;
    }

    static const char* MetalGetSupportedExtension(HContext context, uint32_t index)
    {
        return 0;
    }

    static bool MetalIsContextFeatureSupported(HContext context, ContextFeature feature)
    {
        return 0;
    }

    static PipelineState MetalGetPipelineState(HContext context)
    {
        return {};
    }

    static uint8_t MetalGetNumTextureHandles(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint32_t MetalGetTextureUsageHintFlags(HContext context, HTexture texture)
    {
        return 0;
    }

    static uint8_t MetalGetTexturePageCount(HTexture texture)
    {
        return 0;
    }

    static bool MetalIsAssetHandleValid(HContext context, HAssetHandle asset_handle)
    {
        return 0;
    }

    static void MetalInvalidateGraphicsHandles(HContext context)
    {

    }

    static void MetalGetViewport(HContext context, int32_t* x, int32_t* y, uint32_t* width, uint32_t* height)
    {

    }


    static GraphicsAdapterFunctionTable MetalRegisterFunctionTable()
    {
        GraphicsAdapterFunctionTable fn_table = {};
        DM_REGISTER_GRAPHICS_FUNCTION_TABLE(fn_table, Metal);
        return fn_table;
    }
}
