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

#include <dlib/dstrings.h>
#include <dlib/profile.h>
#include <dlib/log.h>

#include "../graphics_private.h"
#include "../graphics_native.h"
#include "../graphics_adapter.h"

#include "graphics_metal_private.h"

DM_PROPERTY_EXTERN(rmtp_DrawCalls);
DM_PROPERTY_EXTERN(rmtp_DispatchCalls);

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

    template <typename T>
    static void DestroyResourceDeferred(MetalContext* context, T* resource)
    {
        if (resource == 0x0 || resource->m_Destroyed)
        {
            return;
        }

        ResourceToDestroy resource_to_destroy;
        resource_to_destroy.m_ResourceType = resource->GetType();

        switch(resource_to_destroy.m_ResourceType)
        {
            case RESOURCE_TYPE_DEVICE_BUFFER:
                resource_to_destroy.m_DeviceBuffer = ((MetalDeviceBuffer*) resource)->m_Buffer;

                // Nothing to destroy
                if (resource_to_destroy.m_DeviceBuffer == 0x0)
                {
                    return;
                }
                break;
            case RESOURCE_TYPE_TEXTURE:
            case RESOURCE_TYPE_PROGRAM:
            case RESOURCE_TYPE_RENDER_TARGET:
                break;
            default:
                assert(0);
                break;
        }

        MetalFrameResource& frame = context->m_FrameResources[context->m_CurrentFrameInFlight];

        if (frame.m_ResourcesToDestroy->Full())
        {
            frame.m_ResourcesToDestroy->OffsetCapacity(8);
        }

        frame.m_ResourcesToDestroy->Push(resource_to_destroy);
        resource->m_Destroyed = 1;
    }

    static void FlushResourcesToDestroy(MetalContext* context, ResourcesToDestroyList* resource_list)
    {
        if (resource_list->Size() > 0)
        {
            for (uint32_t i = 0; i < resource_list->Size(); ++i)
            {
                switch(resource_list->Begin()[i].m_ResourceType)
                {
                    case RESOURCE_TYPE_DEVICE_BUFFER:
                        resource_list->Begin()[i].m_DeviceBuffer->release();
                        break;
                    case RESOURCE_TYPE_TEXTURE:
                    case RESOURCE_TYPE_PROGRAM:
                    case RESOURCE_TYPE_RENDER_TARGET:
                        break;
                    default:


                        assert(0);
                        break;
                }
            }

            resource_list->SetSize(0);
        }
    }

    static inline MTL::ResourceOptions GetResourceOptions(MTL::StorageMode storageMode)
    {
        switch (storageMode)
        {
            case MTL::StorageModePrivate:
                return MTL::ResourceStorageModePrivate | MTL::ResourceCPUCacheModeDefaultCache;
            case MTL::StorageModeManaged:
                return MTL::ResourceStorageModeManaged | MTL::ResourceCPUCacheModeDefaultCache;
            case MTL::StorageModeShared:
            default:
                return MTL::ResourceStorageModeShared | MTL::ResourceCPUCacheModeDefaultCache;
        }
    }

    static void DeviceBufferUploadHelper(MetalContext* context, const void* data, uint32_t size, uint32_t offset, MetalDeviceBuffer* device_buffer)
    {
        if (size == 0)
            return;

        if (device_buffer->m_Destroyed || device_buffer->m_Buffer == 0x0)
        {
            device_buffer->m_Buffer = context->m_Device->newBuffer(size, GetResourceOptions(device_buffer->m_StorageMode));
            device_buffer->m_Size = size;
        }

        if (data == 0)
        {
            memset(device_buffer->m_Buffer->contents(), 0, (size_t) size);
        }
        else
        {
            memcpy(device_buffer->m_Buffer->contents(), data, size);
        }
    }

    static void ResizeConstantScratchBuffer(MetalContext* context, uint32_t new_size, MetalConstantScratchBuffer* scratch_buffer)
    {
        DestroyResourceDeferred(context, &scratch_buffer->m_DeviceBuffer);
        DeviceBufferUploadHelper(context, 0, new_size, 0, &scratch_buffer->m_DeviceBuffer);
        scratch_buffer->Rewind();
    }

    static void EnsureConstantScratchBufferSize(MetalContext* context, MetalConstantScratchBuffer* scratch_buffer, MetalProgram* program)
    {
        const uint32_t num_uniform_buffers = program->m_UniformBufferCount;

        if (!scratch_buffer->CanAllocate(program->m_UniformDataSizeAligned))
        {
            const uint32_t bytes_increase = 1024 * 8;
            ResizeConstantScratchBuffer(context, scratch_buffer->m_DeviceBuffer.m_Size + bytes_increase, scratch_buffer);
        }
    }

    static void SetupMainRenderTarget(MetalContext* context)
    {
        // Initialize the dummy rendertarget for the main framebuffer
        // The m_Framebuffer construct will be rotated sequentially
        // with the framebuffer objects created per swap chain.

        MetalRenderTarget* rt = GetAssetFromContainer<MetalRenderTarget>(context->m_AssetHandleContainer, context->m_MainRenderTarget);
        if (rt == 0x0)
        {
            rt                          = new MetalRenderTarget(DM_RENDERTARGET_BACKBUFFER_ID);
            context->m_MainRenderTarget = StoreAssetInContainer(context->m_AssetHandleContainer, rt, ASSET_TYPE_RENDER_TARGET);
        }

        rt->m_ColorFormat[0]       = MTL::PixelFormatBGRA8Unorm;
        rt->m_DepthStencilFormat   = MTL::PixelFormatDepth32Float_Stencil8;
        rt->m_ColorAttachmentCount = 1;
    }

    static bool MetalInitialize(HContext _context)
    {
        MetalContext* context        = (MetalContext*) _context;
        context->m_Device            = MTL::CreateSystemDefaultDevice();
        context->m_CommandQueue      = context->m_Device->newCommandQueue();
        context->m_NumFramesInFlight = MAX_FRAMES_IN_FLIGHT;

        SetupMainRenderTarget(context);
        context->m_CurrentRenderTarget = context->m_MainRenderTarget;

        context->m_PipelineCache.SetCapacity(32,64);

        uint32_t window_width = dmPlatform::GetWindowWidth(context->m_Window);
        uint32_t window_height = dmPlatform::GetWindowHeight(context->m_Window);

        // Create main resources-to-destroy lists, one for each command buffer
        for (uint32_t i = 0; i < context->m_NumFramesInFlight; ++i)
        {
            context->m_FrameResources[i].m_ResourcesToDestroy = new ResourcesToDestroyList;
            context->m_FrameResources[i].m_ResourcesToDestroy->SetCapacity(8);

            // This is just the starting point size for the constant scratch buffer,
            // the buffers can grow as needed.

            // Something is wrong here, I can't make larger buffer here?
            const uint32_t constant_buffer_size = 1024 * 8;
            context->m_FrameResources[i].m_ConstantScratchBuffer.m_DeviceBuffer.m_StorageMode = MTL::StorageModeShared;
            DeviceBufferUploadHelper(context, 0, constant_buffer_size, 0, &context->m_FrameResources[i].m_ConstantScratchBuffer.m_DeviceBuffer);
        }

        NSWindow* mative_window = (NSWindow*) dmGraphics::GetNativeOSXNSWindow();
        context->m_View         = [mative_window contentView];

        context->m_Layer               = [CAMetalLayer layer];
        context->m_Layer.device        = (__bridge id<MTLDevice>) context->m_Device;
        context->m_Layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        context->m_Layer.drawableSize  = CGSizeMake(window_width, window_height);

        [context->m_View setLayer:context->m_Layer];
        [context->m_View setWantsLayer:YES];

        MTL::TextureDescriptor* depthDesc = MTL::TextureDescriptor::texture2DDescriptor(
            MTL::PixelFormatDepth32Float_Stencil8,
            window_width,
            window_height,
            false
        );

        depthDesc->setStorageMode(MTL::StorageModePrivate);
        depthDesc->setUsage(MTL::TextureUsageRenderTarget);
        context->m_MainDepthStencilTexture = context->m_Device->newTexture(depthDesc);
        depthDesc->release();

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

        MetalFrameResource& frame       = context->m_FrameResources[context->m_CurrentFrameInFlight];
        context->m_AutoReleasePool      = NS::AutoreleasePool::alloc()->init();
        context->m_Drawable             = (__bridge CA::MetalDrawable*)[context->m_Layer nextDrawable];
        context->m_RenderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
        context->m_FrameBegun           = 1;

        frame.m_CommandBuffer = context->m_CommandQueue->commandBuffer();
        frame.m_ConstantScratchBuffer.Rewind();

        auto colorAttachment = context->m_RenderPassDescriptor->colorAttachments()->object(0);
        colorAttachment->setTexture(context->m_Drawable->texture());
        colorAttachment->setLoadAction(MTL::LoadActionClear);
        colorAttachment->setStoreAction(MTL::StoreActionStore);
        colorAttachment->setClearColor(MTL::ClearColor(0.1, 0.2, 0.4, 1.0));

        // Depth/stencil attachment
        auto depthAttachment = context->m_RenderPassDescriptor->depthAttachment();
        depthAttachment->setTexture(context->m_MainDepthStencilTexture);
        depthAttachment->setLoadAction(MTL::LoadActionClear);
        depthAttachment->setStoreAction(MTL::StoreActionDontCare);
        depthAttachment->setClearDepth(1.0);

        auto stencilAttachment = context->m_RenderPassDescriptor->stencilAttachment();
        stencilAttachment->setTexture(context->m_MainDepthStencilTexture);
        stencilAttachment->setLoadAction(MTL::LoadActionClear);
        stencilAttachment->setStoreAction(MTL::StoreActionDontCare);
        stencilAttachment->setClearStencil(0);

        context->m_RenderCommandEncoder = frame.m_CommandBuffer->renderCommandEncoder(context->m_RenderPassDescriptor);
    }

    static void MetalCommandBufferCompleted(MTL::CommandBuffer* cb, void* userData)
    {
        MetalFrameResource* frame = (MetalFrameResource*) userData;

        FlushResourcesToDestroy(g_MetalContext, frame->m_ResourcesToDestroy);
    }

    static void MetalFlip(HContext _context)
    {
        MetalContext* context = (MetalContext*) _context;

        context->m_RenderCommandEncoder->endEncoding();

        MetalFrameResource& frame = context->m_FrameResources[context->m_CurrentFrameInFlight];

        frame.m_CommandBuffer->presentDrawable(context->m_Drawable);

        // Register completion callback
        frame.m_CommandBuffer->addCompletedHandler(^void(MTL::CommandBuffer* cb) {
            MetalCommandBufferCompleted(cb, &frame);
        });

        frame.m_CommandBuffer->commit();

        context->m_AutoReleasePool->release();

        context->m_CurrentFrameInFlight = (context->m_CurrentFrameInFlight + 1) % context->m_NumFramesInFlight;
    }

    static void MetalClear(HContext _context, uint32_t flags, uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha, float depth, uint32_t stencil)
    {

    }

    static HVertexBuffer MetalNewVertexBuffer(HContext _context, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        MetalContext* context = (MetalContext*) _context;
        MetalDeviceBuffer* buffer = new MetalDeviceBuffer();

        /*
        switch (buffer_usage)
        {
            case BUFFER_USAGE_STATIC_DRAW:
                buffer->m_StorageMode = MTL::StorageModePrivate;
                break;
            case BUFFER_USAGE_DYNAMIC_DRAW:
                buffer->m_StorageMode = MTL::StorageModeShared;
                break;
            default:
                buffer->m_StorageMode = MTL::StorageModeShared;
                break;
        }
        */
        buffer->m_StorageMode = MTL::StorageModeShared;

        if (size > 0)
        {
            DeviceBufferUploadHelper(context, data, size, 0, buffer);
        }

        return (HVertexBuffer) buffer;
    }

    static void MetalDeleteVertexBuffer(HVertexBuffer _buffer)
    {
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;

        if (!buffer->m_Destroyed)
        {
            DestroyResourceDeferred(g_MetalContext, buffer);
        }
        delete buffer;
    }

    static void SetDeviceBuffer(MetalContext* context, MetalDeviceBuffer* buffer, uint32_t size, const void* data)
    {
        if (size == 0)
        {
            return;
        }
        if (size != buffer->m_Size)
        {
            DestroyResourceDeferred(context, buffer);
        }

        DeviceBufferUploadHelper(context, data, size, 0, buffer);
    }

    static void MetalSetVertexBufferData(HVertexBuffer buffer, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        DM_PROFILE(__FUNCTION__);
        SetDeviceBuffer(g_MetalContext, (MetalDeviceBuffer*) buffer, size, data);
    }

    static void MetalSetVertexBufferSubData(HVertexBuffer _buffer, uint32_t offset, uint32_t size, const void* data)
    {
        DM_PROFILE(__FUNCTION__);
        assert(size > 0);
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;
        assert(offset + size <= buffer->m_Size);
        DeviceBufferUploadHelper(g_MetalContext, data, size, offset, buffer);
    }

    static uint32_t MetalGetVertexBufferSize(HVertexBuffer _buffer)
    {
        if (!_buffer)
        {
            return 0;
        }
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;
        return buffer->m_Size;
    }

    static uint32_t MetalGetMaxElementsVertices(HContext _context)
    {
        return 65536;
    }

    static HIndexBuffer MetalNewIndexBuffer(HContext _context, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        MetalContext* context = (MetalContext*) _context;
        MetalDeviceBuffer* buffer = new MetalDeviceBuffer();

        /*
        switch (buffer_usage)
        {
            case BUFFER_USAGE_STATIC_DRAW:
                buffer->m_StorageMode = MTL::StorageModePrivate;
                break;
            case BUFFER_USAGE_DYNAMIC_DRAW:
                buffer->m_StorageMode = MTL::StorageModeShared;
                break;
            default:
                buffer->m_StorageMode = MTL::StorageModeShared;
                break;
        }
        */

        buffer->m_StorageMode = MTL::StorageModeShared;

        if (size > 0)
        {
            DeviceBufferUploadHelper(context, data, size, 0, buffer);
        }

        return (HIndexBuffer) buffer;
    }

    static void MetalDeleteIndexBuffer(HIndexBuffer _buffer)
    {
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;

        if (!buffer->m_Destroyed)
        {
            DestroyResourceDeferred(g_MetalContext, buffer);
        }
        delete buffer;
    }

    static void MetalSetIndexBufferData(HIndexBuffer buffer, uint32_t size, const void* data, BufferUsage buffer_usage)
    {
        DM_PROFILE(__FUNCTION__);
        SetDeviceBuffer(g_MetalContext, (MetalDeviceBuffer*) buffer, size, data);
    }

    static void MetalSetIndexBufferSubData(HIndexBuffer _buffer, uint32_t offset, uint32_t size, const void* data)
    {
        DM_PROFILE(__FUNCTION__);
        assert(size > 0);
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;
        assert(offset + size <= buffer->m_Size);
        DeviceBufferUploadHelper(g_MetalContext, data, size, offset, buffer);
    }

    static uint32_t MetalGetIndexBufferSize(HIndexBuffer _buffer)
    {
        if (!_buffer)
        {
            return 0;
        }
        MetalDeviceBuffer* buffer = (MetalDeviceBuffer*) _buffer;
        return buffer->m_Size;
    }

    static bool MetalIsIndexBufferFormatSupported(HContext _context, IndexBufferFormat format)
    {
        return true;
    }

    static uint32_t MetalGetMaxElementsIndices(HContext _context)
    {
        return -1;
    }

    static VertexDeclaration* CreateAndFillVertexDeclaration(HashState64* hash, HVertexStreamDeclaration stream_declaration)
    {
        VertexDeclaration* vd = new VertexDeclaration();
        memset(vd, 0, sizeof(VertexDeclaration));

        vd->m_StreamCount = stream_declaration->m_StreamCount;

        for (uint32_t i = 0; i < stream_declaration->m_StreamCount; ++i)
        {
            VertexStream& stream = stream_declaration->m_Streams[i];

            if (stream.m_Type == TYPE_UNSIGNED_BYTE && !stream.m_Normalize)
            {
                dmLogWarning("Using the type '%s' for stream '%s' with normalize: false is not supported for vertex declarations. Defaulting to TYPE_BYTE.", GetGraphicsTypeLiteral(stream.m_Type), dmHashReverseSafe64(stream.m_NameHash));
                stream.m_Type = TYPE_BYTE;
            }
            else if (stream.m_Type == TYPE_UNSIGNED_SHORT && !stream.m_Normalize)
            {
                dmLogWarning("Using the type '%s' for stream '%s' with normalize: false is not supported for vertex declarations. Defaulting to TYPE_SHORT.", GetGraphicsTypeLiteral(stream.m_Type), dmHashReverseSafe64(stream.m_NameHash));
                stream.m_Type = TYPE_SHORT;
            }

            vd->m_Streams[i].m_NameHash  = stream.m_NameHash;
            vd->m_Streams[i].m_Type      = stream.m_Type;
            vd->m_Streams[i].m_Size      = stream.m_Size;
            vd->m_Streams[i].m_Normalize = stream.m_Normalize;
            vd->m_Streams[i].m_Offset    = vd->m_Stride;
            vd->m_Streams[i].m_Location  = -1;
            vd->m_Stride                += stream.m_Size * GetTypeSize(stream.m_Type);

            dmHashUpdateBuffer64(hash, &stream.m_Size, sizeof(stream.m_Size));
            dmHashUpdateBuffer64(hash, &stream.m_Type, sizeof(stream.m_Type));
            dmHashUpdateBuffer64(hash, &vd->m_Streams[i].m_Type, sizeof(vd->m_Streams[i].m_Type));
        }

        vd->m_Stride       = DM_ALIGN(vd->m_Stride, 4);
        vd->m_StepFunction = stream_declaration->m_StepFunction;

        return vd;
    }

    static HVertexDeclaration MetalNewVertexDeclaration(HContext _context, HVertexStreamDeclaration stream_declaration)
    {
        DM_PROFILE(__FUNCTION__);
        HashState64 decl_hash_state;
        dmHashInit64(&decl_hash_state, false);
        VertexDeclaration* vd = CreateAndFillVertexDeclaration(&decl_hash_state, stream_declaration);
        dmHashUpdateBuffer64(&decl_hash_state, &vd->m_Stride, sizeof(vd->m_Stride));
        vd->m_PipelineHash = dmHashFinal64(&decl_hash_state);
        return vd;
    }

    static HVertexDeclaration MetalNewVertexDeclarationStride(HContext _context, HVertexStreamDeclaration stream_declaration, uint32_t stride)
    {
        HashState64 decl_hash_state;
        dmHashInit64(&decl_hash_state, false);
        VertexDeclaration* vd = CreateAndFillVertexDeclaration(&decl_hash_state, stream_declaration);
        dmHashUpdateBuffer64(&decl_hash_state, &stride, sizeof(stride));
        vd->m_Stride       = stride;
        vd->m_PipelineHash = dmHashFinal64(&decl_hash_state);
        return vd;
    }

    static void MetalEnableVertexDeclaration(HContext _context, HVertexDeclaration vertex_declaration, uint32_t binding_index, uint32_t base_offset, HProgram program)
    {
        MetalContext* context     = (MetalContext*) _context;
        MetalProgram* program_ptr = (MetalProgram*) program;

        context->m_MainVertexDeclaration[binding_index]                = {};
        context->m_MainVertexDeclaration[binding_index].m_Stride       = vertex_declaration->m_Stride;
        context->m_MainVertexDeclaration[binding_index].m_StepFunction = vertex_declaration->m_StepFunction;
        context->m_MainVertexDeclaration[binding_index].m_PipelineHash = vertex_declaration->m_PipelineHash;

        context->m_CurrentVertexDeclaration[binding_index]             = &context->m_MainVertexDeclaration[binding_index];
        context->m_CurrentVertexBufferOffset[binding_index]            = base_offset;

        uint32_t stream_ix = 0;
        uint32_t num_inputs = program_ptr->m_BaseProgram.m_ShaderMeta.m_Inputs.Size();

        for (int i = 0; i < vertex_declaration->m_StreamCount; ++i)
        {
            for (int j = 0; j < num_inputs; ++j)
            {
                ShaderResourceBinding& input = program_ptr->m_BaseProgram.m_ShaderMeta.m_Inputs[j];

                if (input.m_StageFlags & SHADER_STAGE_FLAG_VERTEX && input.m_NameHash == vertex_declaration->m_Streams[i].m_NameHash)
                {
                    VertexDeclaration::Stream& stream = context->m_MainVertexDeclaration[binding_index].m_Streams[stream_ix];
                    stream.m_NameHash  = input.m_NameHash;
                    stream.m_Location  = input.m_Binding;
                    stream.m_Type      = vertex_declaration->m_Streams[i].m_Type;
                    stream.m_Offset    = vertex_declaration->m_Streams[i].m_Offset;
                    stream.m_Size      = vertex_declaration->m_Streams[i].m_Size;
                    stream.m_Normalize = vertex_declaration->m_Streams[i].m_Normalize;
                    stream_ix++;

                    context->m_MainVertexDeclaration[binding_index].m_StreamCount++;
                    break;
                }
            }
        }
    }

    static void MetalDisableVertexDeclaration(HContext _context, HVertexDeclaration vertex_declaration)
    {
        MetalContext* context = (MetalContext*) _context;
        for (int i = 0; i < MAX_VERTEX_BUFFERS; ++i)
        {
            if (context->m_CurrentVertexDeclaration[i] == vertex_declaration)
            {
                context->m_CurrentVertexDeclaration[i]  = 0;
                context->m_CurrentVertexBufferOffset[i] = 0;
            }
        }
    }

    static void MetalEnableVertexBuffer(HContext _context, HVertexBuffer vertex_buffer, uint32_t binding_index)
    {
        MetalContext* context = (MetalContext*) _context;
        context->m_CurrentVertexBuffer[binding_index] = (MetalDeviceBuffer*) vertex_buffer;
    }

    static void MetalDisableVertexBuffer(HContext _context, HVertexBuffer vertex_buffer)
    {
        MetalContext* context = (MetalContext*) _context;
        for (int i = 0; i < MAX_VERTEX_BUFFERS; ++i)
        {
            if (context->m_CurrentVertexBuffer[i] == (MetalDeviceBuffer*) vertex_buffer)
            {
                context->m_CurrentVertexBuffer[i] = 0;
            }
        }
    }

    static inline MTL::VertexStepFunction ConvertStepFunction(VertexStepFunction step)
    {
        switch (step)
        {
            case VERTEX_STEP_FUNCTION_VERTEX:   return MTL::VertexStepFunctionPerVertex;
            case VERTEX_STEP_FUNCTION_INSTANCE: return MTL::VertexStepFunctionPerInstance;
            default:                            return MTL::VertexStepFunctionPerVertex;
        }
    }

    static inline MTL::VertexFormat ConvertVertexFormat(Type type, uint16_t size, bool normalized)
    {
        if (type == TYPE_FLOAT)
        {
            switch (size)
            {
                case 1:  return MTL::VertexFormatFloat;
                case 2:  return MTL::VertexFormatFloat2;
                case 3:  return MTL::VertexFormatFloat3;
                case 4:  return MTL::VertexFormatFloat4;
                case 9:  return MTL::VertexFormatFloat3;  // Mat3 fallback
                case 16: return MTL::VertexFormatFloat4;  // Mat4 fallback
                default: break;
            }
        }
        else if (type == TYPE_INT)
        {
            switch (size)
            {
                case 1:  return MTL::VertexFormatInt;
                case 2:  return MTL::VertexFormatInt2;
                case 3:  return MTL::VertexFormatInt3;
                case 4:  return MTL::VertexFormatInt4;
                case 9:  return MTL::VertexFormatInt3;
                case 16: return MTL::VertexFormatInt4;
                default: break;
            }
        }
        else if (type == TYPE_UNSIGNED_INT)
        {
            switch (size)
            {
                case 1:  return MTL::VertexFormatUInt;
                case 2:  return MTL::VertexFormatUInt2;
                case 3:  return MTL::VertexFormatUInt3;
                case 4:  return MTL::VertexFormatUInt4;
                case 9:  return MTL::VertexFormatUInt3;
                case 16: return MTL::VertexFormatUInt4;
                default: break;
            }
        }
        else if (type == TYPE_BYTE)
        {
            switch (size)
            {
                case 1:  return normalized ? MTL::VertexFormatCharNormalized   : MTL::VertexFormatChar;
                case 2:  return normalized ? MTL::VertexFormatChar2Normalized  : MTL::VertexFormatChar2;
                case 3:  return normalized ? MTL::VertexFormatChar3Normalized  : MTL::VertexFormatChar3;
                case 4:  return normalized ? MTL::VertexFormatChar4Normalized  : MTL::VertexFormatChar4;
                case 9:  return normalized ? MTL::VertexFormatChar3Normalized  : MTL::VertexFormatChar3;
                case 16: return normalized ? MTL::VertexFormatChar4Normalized  : MTL::VertexFormatChar4;
                default: break;
            }
        }
        else if (type == TYPE_UNSIGNED_BYTE)
        {
            switch (size)
            {
                case 1:  return normalized ? MTL::VertexFormatUCharNormalized   : MTL::VertexFormatUChar;
                case 2:  return normalized ? MTL::VertexFormatUChar2Normalized  : MTL::VertexFormatUChar2;
                case 3:  return normalized ? MTL::VertexFormatUChar3Normalized  : MTL::VertexFormatUChar3;
                case 4:  return normalized ? MTL::VertexFormatUChar4Normalized  : MTL::VertexFormatUChar4;
                case 9:  return normalized ? MTL::VertexFormatUChar3Normalized  : MTL::VertexFormatUChar3;
                case 16: return normalized ? MTL::VertexFormatUChar4Normalized  : MTL::VertexFormatUChar4;
                default: break;
            }
        }
        else if (type == TYPE_SHORT)
        {
            switch (size)
            {
                case 1:  return normalized ? MTL::VertexFormatShortNormalized   : MTL::VertexFormatShort;
                case 2:  return normalized ? MTL::VertexFormatShort2Normalized  : MTL::VertexFormatShort2;
                case 3:  return normalized ? MTL::VertexFormatShort3Normalized  : MTL::VertexFormatShort3;
                case 4:  return normalized ? MTL::VertexFormatShort4Normalized  : MTL::VertexFormatShort4;
                case 9:  return normalized ? MTL::VertexFormatShort3Normalized  : MTL::VertexFormatShort3;
                case 16: return normalized ? MTL::VertexFormatShort4Normalized  : MTL::VertexFormatShort4;
                default: break;
            }
        }
        else if (type == TYPE_UNSIGNED_SHORT)
        {
            switch (size)
            {
                case 1:  return normalized ? MTL::VertexFormatUShortNormalized   : MTL::VertexFormatUShort;
                case 2:  return normalized ? MTL::VertexFormatUShort2Normalized  : MTL::VertexFormatUShort2;
                case 3:  return normalized ? MTL::VertexFormatUShort3Normalized  : MTL::VertexFormatUShort3;
                case 4:  return normalized ? MTL::VertexFormatUShort4Normalized  : MTL::VertexFormatUShort4;
                case 9:  return normalized ? MTL::VertexFormatUShort3Normalized  : MTL::VertexFormatUShort3;
                case 16: return normalized ? MTL::VertexFormatUShort4Normalized  : MTL::VertexFormatUShort4;
                default: break;
            }
        }
        else if (type == TYPE_FLOAT_MAT4 || type == TYPE_FLOAT_MAT3 || type == TYPE_FLOAT_MAT2)
        {
            // Metal doesn't have matrix vertex formats.
            // Typically you expand these into multiple attributes.
            return MTL::VertexFormatFloat4;
        }
        else if (type == TYPE_FLOAT_VEC4)
        {
            return MTL::VertexFormatFloat4;
        }

        assert(0 && "Unable to deduce Metal vertex format from dmGraphics::Type");
        return MTL::VertexFormatInvalid;
    }

    static bool CreatePipeline(MetalContext* context, MetalRenderTarget* rt, const PipelineState pipeline_state,  MetalProgram* program, VertexDeclaration** vertexDeclaration, uint32_t vertexDeclarationCount, MetalPipeline* pipeline)
    {
        MTL::VertexDescriptor* vertex_desc = MTL::VertexDescriptor::alloc()->init();
        uint32_t attribute_index = 0;
        uint32_t vx_buffer_start_ix = program->m_BaseProgram.m_MaxBinding;

        for (uint32_t buffer_index = 0; buffer_index < vertexDeclarationCount; ++buffer_index)
        {
            VertexDeclaration* vd = vertexDeclaration[buffer_index];

            for (uint32_t s = 0; s < vd->m_StreamCount; ++s)
            {
                const VertexDeclaration::Stream& stream = vd->m_Streams[s];
                MTL::VertexAttributeDescriptor* attr = vertex_desc->attributes()->object(attribute_index);

                attr->setFormat(ConvertVertexFormat(stream.m_Type, stream.m_Size, stream.m_Normalize));
                attr->setOffset(stream.m_Offset);
                attr->setBufferIndex(buffer_index + vx_buffer_start_ix);

                ++attribute_index;
            }

            // One layout per vertex buffer
            MTL::VertexBufferLayoutDescriptor* layout = vertex_desc->layouts()->object(buffer_index + vx_buffer_start_ix);

            layout->setStride(vd->m_Stride);
            layout->setStepFunction(ConvertStepFunction(vd->m_StepFunction));
            layout->setStepRate(1);
        }

        MTL::RenderPipelineDescriptor* pipeline_desc = MTL::RenderPipelineDescriptor::alloc()->init();
        pipeline_desc->setVertexFunction(program->m_VertexModule->m_Function);
        pipeline_desc->setFragmentFunction(program->m_FragmentModule->m_Function);
        pipeline_desc->setVertexDescriptor(vertex_desc);

        for (uint32_t i = 0; i < rt->m_ColorAttachmentCount; ++i)
        {
            MTL::RenderPipelineColorAttachmentDescriptor* colorAttachment = pipeline_desc->colorAttachments()->object(i);
            colorAttachment->setPixelFormat(rt->m_ColorFormat[i]);
            colorAttachment->setBlendingEnabled(pipeline_state.m_BlendEnabled);
        }
        pipeline_desc->setDepthAttachmentPixelFormat(rt->m_DepthStencilFormat);
        pipeline_desc->setStencilAttachmentPixelFormat(rt->m_DepthStencilFormat);

        NS::Error* error = nullptr;
        pipeline->m_RenderPipelineState = context->m_Device->newRenderPipelineState(pipeline_desc, &error);

        if (!pipeline->m_RenderPipelineState)
        {
            dmLogError("Failed to create Metal pipeline: %s", error ? error->localizedDescription()->utf8String() : "Unknown error");
            pipeline_desc->release();
            vertex_desc->release();
            return false;
        }

        MTL::DepthStencilDescriptor* depthDesc = MTL::DepthStencilDescriptor::alloc()->init();
        depthDesc->setDepthCompareFunction(MTL::CompareFunctionLess);
        depthDesc->setDepthWriteEnabled(pipeline_state.m_WriteDepth);
        pipeline->m_DepthStencilState = context->m_Device->newDepthStencilState(depthDesc);
        depthDesc->release();

        pipeline_desc->release();
        vertex_desc->release();

        return true;
    }

    static MetalPipeline* GetOrCreatePipeline(MetalContext* context, const PipelineState pipeline_state, MetalProgram* program, MetalRenderTarget* rt, VertexDeclaration** vertexDeclaration, uint32_t vertexDeclarationCount)
    {
        HashState64 pipeline_hash_state;
        dmHashInit64(&pipeline_hash_state, false);
        dmHashUpdateBuffer64(&pipeline_hash_state, &program->m_Hash, sizeof(program->m_Hash));
        dmHashUpdateBuffer64(&pipeline_hash_state, &pipeline_state, sizeof(pipeline_state));
        dmHashUpdateBuffer64(&pipeline_hash_state, &rt->m_Id, sizeof(rt->m_Id));
        //dmHashUpdateBuffer64(&pipeline_hash_state, &vk_sample_count, sizeof(vk_sample_count));

        for (int i = 0; i < vertexDeclarationCount; ++i)
        {
            dmHashUpdateBuffer64(&pipeline_hash_state, &vertexDeclaration[i]->m_PipelineHash, sizeof(vertexDeclaration[i]->m_PipelineHash));
            dmHashUpdateBuffer64(&pipeline_hash_state, &vertexDeclaration[i]->m_StepFunction, sizeof(vertexDeclaration[i]->m_StepFunction));
        }

        uint64_t pipeline_hash = dmHashFinal64(&pipeline_hash_state);

        MetalPipeline* cached_pipeline = context->m_PipelineCache.Get(pipeline_hash);

        if (!cached_pipeline)
        {
            // Create the pipeline here!
            MetalPipeline new_pipeline = {};

            if (!CreatePipeline(context, rt, pipeline_state, program, vertexDeclaration, vertexDeclarationCount, &new_pipeline))
            {
                return 0;
            }

            if (context->m_PipelineCache.Full())
            {
                context->m_PipelineCache.SetCapacity(32, context->m_PipelineCache.Capacity() + 4);
            }

            context->m_PipelineCache.Put(pipeline_hash, new_pipeline);
            cached_pipeline = context->m_PipelineCache.Get(pipeline_hash);
        }

        return cached_pipeline;
    }

    static void PrepareProgram(MetalContext* context, MetalProgram* program)
    {
        if (program->m_ArgumentEncodersCreated)
        {
            return;
        }

        uint8_t set_stage_flags[MAX_SET_COUNT] = {0};

        for (int i = 0; i < program->m_BaseProgram.m_MaxSet; ++i)
        {
            for (int j = 0; j < program->m_BaseProgram.m_MaxBinding; ++j)
            {
                ProgramResourceBinding* res = &program->m_BaseProgram.m_ResourceBindings[i][j];

                if (res->m_Res)
                {
                    set_stage_flags[i] |= res->m_Res->m_StageFlags;
                }
            }

            if (set_stage_flags[i] == 0)
            {
                continue;
            }

            if (set_stage_flags[i] & SHADER_STAGE_FLAG_VERTEX)
            {
                program->m_ArgumentEncoders[i] = program->m_VertexModule->m_Function->newArgumentEncoder(i);
            }
            else if (set_stage_flags[i] & SHADER_STAGE_FLAG_FRAGMENT)
            {
                program->m_ArgumentEncoders[i] = program->m_FragmentModule->m_Function->newArgumentEncoder(i);
            }
            else if (set_stage_flags[i] & SHADER_STAGE_FLAG_COMPUTE)
            {
                program->m_ArgumentEncoders[i] = program->m_ComputeModule->m_Function->newArgumentEncoder(i);
            }

            uint32_t encode_length = program->m_ArgumentEncoders[i]->encodedLength();

            program->m_ArgumentBuffers[i] = context->m_Device->newBuffer(encode_length, MTL::ResourceStorageModeShared);
            program->m_ArgumentEncoders[i]->setArgumentBuffer(program->m_ArgumentBuffers[i], 0);
        }
        program->m_ArgumentEncodersCreated = true;
    }

    static void CommitUniforms(MetalContext* context, MTL::RenderCommandEncoder* encoder,
                           MetalConstantScratchBuffer* scratch_buffer, MetalProgram* program,
                           uint32_t alignment)
    {
        ProgramResourceBindingIterator it(&program->m_BaseProgram);
        const ProgramResourceBinding* next;
        while ((next = it.Next()))
        {
            ShaderResourceBinding* res = next->m_Res;
            MTL::ArgumentEncoder* arg_encoder = program->m_ArgumentEncoders[res->m_Set];
            assert(arg_encoder);

            uint32_t msl_index = program->m_ResourceToMslIndex[res->m_Set][res->m_Binding];

            switch (res->m_BindingFamily)
            {
                case ShaderResourceBinding::BINDING_FAMILY_UNIFORM_BUFFER:
                {
                    const uint32_t uniform_size = DM_ALIGN(res->m_BindingInfo.m_BlockSize, alignment);
                    uint32_t offset = DM_ALIGN(scratch_buffer->m_MappedDataCursor, alignment);

                    //copy data into scratch buffer
                    memcpy(reinterpret_cast<uint8_t*>(scratch_buffer->m_DeviceBuffer.m_Buffer->contents()) + offset,
                           &program->m_UniformData[next->m_DataOffset],
                           res->m_BindingInfo.m_BlockSize);

                    // Advance cursor in scratch
                    scratch_buffer->m_MappedDataCursor = offset + uniform_size;
                } break;

                default:
                    break;
            }
        }

    #if 0
        uint64_t arg_ptr = *(uint64_t*)program->m_ArgumentBuffers[0]->contents();
        printf("DBG: argbuf gpuAddr=0x%llx, arg_ptr_in_argbuf=0x%llx, scratch_gpu=0x%llx\n",
               (unsigned long long)program->m_ArgumentBuffers[0]->gpuAddress(),
               (unsigned long long)arg_ptr,
               (unsigned long long)scratch_buffer->m_DeviceBuffer.m_Buffer->gpuAddress());
    #endif
    }

    static void DrawSetup(MetalContext* context)
    {
        assert(context->m_RenderCommandEncoder);
        MTL::RenderCommandEncoder* encoder = context->m_RenderCommandEncoder;

        MetalRenderTarget* current_rt = GetAssetFromContainer<MetalRenderTarget>(context->m_AssetHandleContainer, context->m_CurrentRenderTarget);

        VertexDeclaration* vx_declarations[MAX_VERTEX_BUFFERS] = {};
        uint32_t num_vx_buffers = 0;
        uint32_t vx_buffer_start_ix = context->m_CurrentProgram->m_BaseProgram.m_MaxBinding;

        for (int i = 0; i < MAX_VERTEX_BUFFERS; ++i)
        {
            if (context->m_CurrentVertexBuffer[i] && context->m_CurrentVertexDeclaration[i])
            {
                vx_declarations[num_vx_buffers] = context->m_CurrentVertexDeclaration[i];

                encoder->setVertexBuffer(context->m_CurrentVertexBuffer[i]->m_Buffer, 0, num_vx_buffers + vx_buffer_start_ix);

                num_vx_buffers++;
            }
        }

        MetalFrameResource& frame = context->m_FrameResources[context->m_CurrentFrameInFlight];

        EnsureConstantScratchBufferSize(context, &frame.m_ConstantScratchBuffer, context->m_CurrentProgram);

        PipelineState pipeline_state_draw = context->m_PipelineState;

        // If the culling, or viewport has changed, make sure to flip the
        // culling flag if we are rendering to the backbuffer.
        // This is needed because we are rendering with a negative viewport
        // which means that the face direction is inverted.
        if (current_rt->m_Id != DM_RENDERTARGET_BACKBUFFER_ID)
        {
            if (pipeline_state_draw.m_CullFaceType == FACE_TYPE_BACK)
            {
                pipeline_state_draw.m_CullFaceType = FACE_TYPE_FRONT;
            }
            else if (pipeline_state_draw.m_CullFaceType == FACE_TYPE_FRONT)
            {
                pipeline_state_draw.m_CullFaceType = FACE_TYPE_BACK;
            }
        }

        MetalPipeline* pipeline = GetOrCreatePipeline(context, pipeline_state_draw,
            context->m_CurrentProgram, current_rt, vx_declarations, num_vx_buffers);
        assert(pipeline);

        encoder->setRenderPipelineState(pipeline->m_RenderPipelineState);
        if (pipeline->m_DepthStencilState)
        {
            encoder->setDepthStencilState(pipeline->m_DepthStencilState);
        }

        if (context->m_ViewportChanged)
        {
            MTL::Viewport metal_vp;
            metal_vp.originX = context->m_MainViewport.m_X;
            metal_vp.originY = context->m_MainViewport.m_Y;
            metal_vp.width   = context->m_MainViewport.m_W;
            metal_vp.height  = context->m_MainViewport.m_H;
            metal_vp.znear   = 0.0;
            metal_vp.zfar    = 1.0;
            encoder->setViewport(metal_vp);

            // MTL::ScissorRect scissor;
            // scissor.x      = current_rt->m_Scissor.offset.x;
            // scissor.y      = current_rt->m_Scissor.offset.y;
            // scissor.width  = current_rt->m_Scissor.extent.width;
            // scissor.height = current_rt->m_Scissor.extent.height;
            // encoder->setScissorRect(scissor);
        }

        PrepareProgram(context, context->m_CurrentProgram);
        CommitUniforms(context, encoder, &frame.m_ConstantScratchBuffer, context->m_CurrentProgram, UNIFORM_BUFFER_ALIGNMENT);

        context->m_CurrentProgram->m_ArgumentEncoders[0]->setArgumentBuffer(context->m_CurrentProgram->m_ArgumentBuffers[0], 0);

        context->m_CurrentProgram->m_ArgumentEncoders[0]->setBuffer(frame.m_ConstantScratchBuffer.m_DeviceBuffer.m_Buffer, 0, 0);

        encoder->setVertexBuffer(context->m_CurrentProgram->m_ArgumentBuffers[0], 0, 0);
    }

    static MTL::PrimitiveType ConvertPrimitiveType(PrimitiveType prim_type)
    {
        switch (prim_type)
        {
            case PRIMITIVE_TRIANGLES:      return MTL::PrimitiveTypeTriangle;
            case PRIMITIVE_TRIANGLE_STRIP: return MTL::PrimitiveTypeTriangleStrip;
            case PRIMITIVE_LINES:          return MTL::PrimitiveTypeLine;
            //case PRIMITIVE_LINE_STRIP:     return MTL::PrimitiveTypeLineStrip;
            //case PRIMITIVE_POINTS:         return MTL::PrimitiveTypePoint;
            default: break;
        }
        return MTL::PrimitiveTypeTriangle;
    }

    static void MetalDrawElements(HContext _context, PrimitiveType prim_type, uint32_t first, uint32_t count, Type type, HIndexBuffer index_buffer, uint32_t instance_count)
    {
        DM_PROFILE(__FUNCTION__);
        DM_PROPERTY_ADD_U32(rmtp_DrawCalls, 1);

        MetalContext* context = (MetalContext*)_context;
        assert(context->m_FrameBegun);

        DrawSetup(context);

        // Index buffer setup
        MetalDeviceBuffer* ib = (MetalDeviceBuffer*) index_buffer;
        assert(ib);
        assert(ib->m_Buffer);

        MTL::IndexType metal_index_type = (type == TYPE_UNSIGNED_INT)
            ? MTL::IndexTypeUInt32
            : MTL::IndexTypeUInt16;

        // The `first` value is a byte offset, similar to Vulkan’s.
        NSUInteger index_offset = first;

        MTL::PrimitiveType metal_prim_type = ConvertPrimitiveType(prim_type);

        // Perform the draw
        if (instance_count > 1)
        {
            context->m_RenderCommandEncoder->drawIndexedPrimitives(metal_prim_type, count, metal_index_type, ib->m_Buffer, index_offset, instance_count);
        }
        else
        {
            context->m_RenderCommandEncoder->drawIndexedPrimitives(metal_prim_type, count, metal_index_type, ib->m_Buffer, index_offset);
        }
    }

    static void MetalDraw(HContext _context, PrimitiveType prim_type, uint32_t first, uint32_t count, uint32_t instance_count)
    {
        DM_PROFILE(__FUNCTION__);
        DM_PROPERTY_ADD_U32(rmtp_DrawCalls, 1);

        MetalContext* context = (MetalContext*)_context;
        assert(context->m_FrameBegun);

        DrawSetup(context);

        MTL::PrimitiveType metal_prim_type = ConvertPrimitiveType(prim_type);

        if (instance_count > 1)
        {
            context->m_RenderCommandEncoder->drawPrimitives(metal_prim_type, first, count, instance_count);
        }
        else
        {
            context->m_RenderCommandEncoder->drawPrimitives(metal_prim_type, first, count);
        }
    }

    static void MetalDispatchCompute(HContext _context, uint32_t group_count_x, uint32_t group_count_y, uint32_t group_count_z)
    {

    }

    static MetalShaderModule* CreateShaderModule(MTL::Device* device, const char* src, char* error_buffer, uint32_t error_buffer_size)
    {
        NS::Error* error  = 0;
        MTL::Library* library = device->newLibrary(NS::String::string(src, NS::StringEncoding::UTF8StringEncoding), 0, &error);
        if (error)
        {
            dmSnPrintf(error_buffer, error_buffer_size, "%s", error->localizedDescription()->utf8String());
            return 0;
        }

        MetalShaderModule* module = new MetalShaderModule;
        module->m_Library = library;
        module->m_Function = library->newFunction(NS::String::string("main0", NS::StringEncoding::UTF8StringEncoding));

        dmLogInfo("-----------------");
        dmLogInfo("Shader: \n%s", src);
        dmLogInfo("-----------------");

        return module;
    }

    static void CreateProgramResourceBindings(MetalProgram* program, ResourceBindingDesc bindings[MAX_SET_COUNT][MAX_BINDINGS_PER_SET_COUNT], MetalShaderModule** shaders, ShaderDesc::Shader** ddf_shaders, uint32_t num_shaders)
    {
        ProgramResourceBindingsInfo binding_info = {};
        FillProgramResourceBindings(&program->m_BaseProgram, bindings, UNIFORM_BUFFER_ALIGNMENT, STORAGE_BUFFER_ALIGNMENT, binding_info);

        for (int i = 0; i < num_shaders; ++i)
        {
            ShaderDesc::Shader* ddf = ddf_shaders[i];

            for (int j = 0; j < ddf->m_MslResourceMapping.m_Count; ++j)
            {
                ShaderDesc::MSLResourceMapping* entry = &ddf->m_MslResourceMapping[j];
                program->m_ResourceToMslIndex[entry->m_Set][entry->m_Binding] = entry->m_MslIndex;
            }
        }

        program->m_UniformData = new uint8_t[binding_info.m_UniformDataSize];
        memset(program->m_UniformData, 0, binding_info.m_UniformDataSize);

        program->m_UniformDataSizeAligned   = binding_info.m_UniformDataSizeAligned;
        program->m_UniformBufferCount       = binding_info.m_UniformBufferCount;
        program->m_StorageBufferCount       = binding_info.m_StorageBufferCount;
        program->m_TextureSamplerCount      = binding_info.m_TextureCount;
        program->m_BaseProgram.m_MaxSet     = binding_info.m_MaxSet;
        program->m_BaseProgram.m_MaxBinding = binding_info.m_MaxBinding;

        BuildUniforms(&program->m_BaseProgram);
    }

    static HProgram MetalNewProgram(HContext _context, ShaderDesc* ddf, char* error_buffer, uint32_t error_buffer_size)
    {
        ShaderDesc::Shader* ddf_vp = 0x0;
        ShaderDesc::Shader* ddf_fp = 0x0;
        ShaderDesc::Shader* ddf_cp = 0x0;

        if (!GetShaderProgram(_context, ddf, &ddf_vp, &ddf_fp, &ddf_cp))
        {
            return 0;
        }

        MetalContext* context = (MetalContext*) _context;
        MetalProgram* program = new MetalProgram;
        memset(program, 0, sizeof(MetalProgram));

        CreateShaderMeta(&ddf->m_Reflection, &program->m_BaseProgram.m_ShaderMeta);

        MetalShaderModule* shaders[] = { 0x0, 0x0 };
        ShaderDesc::Shader* ddf_shaders[] = { 0x0, 0x0 };
        uint32_t num_shaders = 0;

        if (ddf_cp)
        {
            program->m_ComputeModule = CreateShaderModule(context->m_Device, (const char*) ddf_cp->m_Source.m_Data, error_buffer, error_buffer_size);

            if (!program->m_ComputeModule)
            {
                DeleteProgram(_context, (HProgram) program);
                return 0;
            }

            shaders[0]     = program->m_ComputeModule;
            ddf_shaders[0] = ddf_cp;
            num_shaders    = 1;
        }
        else
        {
            program->m_VertexModule = CreateShaderModule(context->m_Device, (const char*) ddf_vp->m_Source.m_Data, error_buffer, error_buffer_size);
            if (!program->m_VertexModule)
            {
                DeleteProgram(_context, (HProgram) program);
                return 0;
            }

            program->m_FragmentModule = CreateShaderModule(context->m_Device, (const char*) ddf_fp->m_Source.m_Data, error_buffer, error_buffer_size);
            if (!program->m_FragmentModule)
            {
                DeleteProgram(_context, (HProgram) program);
                return 0;
            }

            shaders[0]     = program->m_VertexModule;
            shaders[1]     = program->m_FragmentModule;
            ddf_shaders[0] = ddf_vp;
            ddf_shaders[1] = ddf_fp;
            num_shaders    = 2;
        }

        ResourceBindingDesc bindings[MAX_SET_COUNT][MAX_BINDINGS_PER_SET_COUNT] = {};
        CreateProgramResourceBindings(program, bindings, shaders, ddf_shaders, num_shaders);

        return (HProgram) program;
    }

    static void MetalDeleteProgram(HContext _context, HProgram _program)
    {
        MetalProgram* program = (MetalProgram*) _program;
        delete program;
    }

    static ShaderDesc::Language MetalGetProgramLanguage(HProgram _program)
    {
        return ShaderDesc::LANGUAGE_MSL_22;
    }

    static bool MetalIsShaderLanguageSupported(HContext _context, ShaderDesc::Language language, ShaderDesc::ShaderType shader_type)
    {
        return language == ShaderDesc::LANGUAGE_MSL_22;
    }

    static void MetalEnableProgram(HContext _context, HProgram program)
    {
        MetalContext* context = (MetalContext*)_context;
        context->m_CurrentProgram = (MetalProgram*) program;
    }

    static void MetalDisableProgram(HContext _context)
    {
        MetalContext* context = (MetalContext*)_context;
        context->m_CurrentProgram = 0;
    }

    static bool MetalReloadProgram(HContext _context, HProgram program, ShaderDesc* ddf)
    {
        return 0;
    }

    static uint32_t MetalGetAttributeCount(HProgram prog)
    {
        MetalProgram* program_ptr = (MetalProgram*) prog;
        uint32_t num_vx_inputs = 0;
        for (int i = 0; i < program_ptr->m_BaseProgram.m_ShaderMeta.m_Inputs.Size(); ++i)
        {
            if (program_ptr->m_BaseProgram.m_ShaderMeta.m_Inputs[i].m_StageFlags & SHADER_STAGE_FLAG_VERTEX)
            {
                num_vx_inputs++;
            }
        }
        return num_vx_inputs;
    }

    static void MetalGetAttribute(HProgram prog, uint32_t index, dmhash_t* name_hash, Type* type, uint32_t* element_count, uint32_t* num_values, int32_t* location)
    {
        MetalProgram* program = (MetalProgram*) prog;
        uint32_t input_ix = 0;
        for (int i = 0; i < program->m_BaseProgram.m_ShaderMeta.m_Inputs.Size(); ++i)
        {
            if (program->m_BaseProgram.m_ShaderMeta.m_Inputs[i].m_StageFlags & SHADER_STAGE_FLAG_VERTEX)
            {
                if (input_ix == index)
                {
                    ShaderResourceBinding& attr = program->m_BaseProgram.m_ShaderMeta.m_Inputs[i];
                    *name_hash                  = attr.m_NameHash;
                    *type                       = ShaderDataTypeToGraphicsType(attr.m_Type.m_ShaderType);
                    *num_values                 = 1;
                    *location                   = attr.m_Binding;
                    *element_count              = GetShaderTypeSize(attr.m_Type.m_ShaderType) / sizeof(float);
                }
                input_ix++;
            }
        }
    }

    static inline void WriteConstantData(uint32_t offset, uint8_t* uniform_data_ptr, uint8_t* data_ptr, uint32_t data_size)
    {
        memcpy(&uniform_data_ptr[offset], data_ptr, data_size);
    }

    static void MetalSetConstantV4(HContext _context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context->m_CurrentProgram);
        assert(base_location != INVALID_UNIFORM_LOCATION);

        MetalProgram* program_ptr = (MetalProgram*) context->m_CurrentProgram;
        uint32_t set               = UNIFORM_LOCATION_GET_OP0(base_location);
        uint32_t binding           = UNIFORM_LOCATION_GET_OP1(base_location);
        uint32_t buffer_offset     = UNIFORM_LOCATION_GET_OP2(base_location);
        assert(!(set == UNIFORM_LOCATION_MAX && binding == UNIFORM_LOCATION_MAX));

        ProgramResourceBinding& pgm_res = program_ptr->m_BaseProgram.m_ResourceBindings[set][binding];

        uint32_t offset = pgm_res.m_DataOffset + buffer_offset;
        WriteConstantData(offset, program_ptr->m_UniformData, (uint8_t*) data, sizeof(dmVMath::Vector4) * count);
    }

    static void MetalSetConstantM4(HContext _context, const dmVMath::Vector4* data, int count, HUniformLocation base_location)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context->m_CurrentProgram);
        assert(base_location != INVALID_UNIFORM_LOCATION);

        MetalProgram* program_ptr    = (MetalProgram*) context->m_CurrentProgram;
        uint32_t set            = UNIFORM_LOCATION_GET_OP0(base_location);
        uint32_t binding        = UNIFORM_LOCATION_GET_OP1(base_location);
        uint32_t buffer_offset  = UNIFORM_LOCATION_GET_OP2(base_location);
        assert(!(set == UNIFORM_LOCATION_MAX && binding == UNIFORM_LOCATION_MAX));

        ProgramResourceBinding& pgm_res = program_ptr->m_BaseProgram.m_ResourceBindings[set][binding];

        uint32_t offset = pgm_res.m_DataOffset + buffer_offset;
        WriteConstantData(offset, program_ptr->m_UniformData, (uint8_t*) data, sizeof(dmVMath::Vector4) * 4 * count);
    }

    static void MetalSetSampler(HContext _context, HUniformLocation location, int32_t unit)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context->m_CurrentProgram);
        assert(location != INVALID_UNIFORM_LOCATION);

        MetalProgram* program_ptr = (MetalProgram*) context->m_CurrentProgram;
        uint32_t set         = UNIFORM_LOCATION_GET_OP0(location);
        uint32_t binding     = UNIFORM_LOCATION_GET_OP1(location);
        assert(!(set == UNIFORM_LOCATION_MAX && binding == UNIFORM_LOCATION_MAX));

        assert(program_ptr->m_BaseProgram.m_ResourceBindings[set][binding].m_Res);
        program_ptr->m_BaseProgram.m_ResourceBindings[set][binding].m_TextureUnit = unit;
    }

    static void MetalSetViewport(HContext _context, int32_t x, int32_t y, int32_t width, int32_t height)
    {
        MetalContext* context = (MetalContext*)_context;
        // Defer the update to when we actually draw, since we *might* need to invert the viewport
        // depending on wether or not we have set a different rendertarget from when
        // this call was made.
        MetalViewport& viewport = context->m_MainViewport;
        viewport.m_X            = (uint16_t) x;
        viewport.m_Y            = (uint16_t) y;
        viewport.m_W            = (uint16_t) width;
        viewport.m_H            = (uint16_t) height;

        context->m_ViewportChanged = 1;
    }

    static void MetalEnableState(HContext _context, State state)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context);
        SetPipelineStateValue(context->m_PipelineState, state, 1);
    }

    static void MetalDisableState(HContext _context, State state)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context);
        SetPipelineStateValue(context->m_PipelineState, state, 0);
    }

    static void MetalSetBlendFunc(HContext _context, BlendFactor source_factor, BlendFactor destinaton_factor)
    {
        MetalContext* context = (MetalContext*) _context;
        assert(context);
        context->m_PipelineState.m_BlendSrcFactor = source_factor;
        context->m_PipelineState.m_BlendDstFactor = destinaton_factor;
    }

    static void MetalSetColorMask(HContext _context, bool red, bool green, bool blue, bool alpha)
    {
        MetalContext* context = (MetalContext*)_context;
        assert(context);
        uint8_t write_mask = red   ? DM_GRAPHICS_STATE_WRITE_R : 0;
        write_mask        |= green ? DM_GRAPHICS_STATE_WRITE_G : 0;
        write_mask        |= blue  ? DM_GRAPHICS_STATE_WRITE_B : 0;
        write_mask        |= alpha ? DM_GRAPHICS_STATE_WRITE_A : 0;

        context->m_PipelineState.m_WriteColorMask = write_mask;
    }

    static void MetalSetDepthMask(HContext _context, bool enable_mask)
    {
        MetalContext* context = (MetalContext*)_context;
        context->m_PipelineState.m_WriteDepth = enable_mask;
    }

    static void MetalSetDepthFunc(HContext _context, CompareFunc func)
    {
        MetalContext* context = (MetalContext*)_context;
        context->m_PipelineState.m_DepthTestFunc = func;
    }

    static void MetalSetScissor(HContext _context, int32_t x, int32_t y, int32_t width, int32_t height)
    {

    }

    static void MetalSetStencilMask(HContext _context, uint32_t mask)
    {
        MetalContext* context = (MetalContext*)_context;
        context->m_PipelineState.m_StencilWriteMask = mask;
    }

    static void MetalSetStencilFunc(HContext _context, CompareFunc func, uint32_t ref, uint32_t mask)
    {
        MetalContext* context = (MetalContext*)_context;
        assert(context);
        context->m_PipelineState.m_StencilFrontTestFunc = (uint8_t) func;
        context->m_PipelineState.m_StencilBackTestFunc  = (uint8_t) func;
        context->m_PipelineState.m_StencilReference     = (uint8_t) ref;
        context->m_PipelineState.m_StencilCompareMask   = (uint8_t) mask;
    }

    static void MetalSetStencilFuncSeparate(HContext _context, FaceType face_type, CompareFunc func, uint32_t ref, uint32_t mask)
    {
        MetalContext* context = (MetalContext*)_context;
        assert(context);
        if (face_type == FACE_TYPE_BACK)
        {
            context->m_PipelineState.m_StencilBackTestFunc  = (uint8_t) func;
        }
        else
        {
            context->m_PipelineState.m_StencilFrontTestFunc = (uint8_t) func;
        }
        context->m_PipelineState.m_StencilReference     = (uint8_t) ref;
        context->m_PipelineState.m_StencilCompareMask   = (uint8_t) mask;
    }

    static void MetalSetStencilOp(HContext _context, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {
        MetalContext* context = (MetalContext*)_context;
        assert(context);
        context->m_PipelineState.m_StencilFrontOpFail      = sfail;
        context->m_PipelineState.m_StencilFrontOpDepthFail = dpfail;
        context->m_PipelineState.m_StencilFrontOpPass      = dppass;
        context->m_PipelineState.m_StencilBackOpFail       = sfail;
        context->m_PipelineState.m_StencilBackOpDepthFail  = dpfail;
        context->m_PipelineState.m_StencilBackOpPass       = dppass;
    }

    static void MetalSetStencilOpSeparate(HContext _context, FaceType face_type, StencilOp sfail, StencilOp dpfail, StencilOp dppass)
    {
        MetalContext* context = (MetalContext*)_context;
        if (face_type == FACE_TYPE_BACK)
        {
            context->m_PipelineState.m_StencilBackOpFail       = sfail;
            context->m_PipelineState.m_StencilBackOpDepthFail  = dpfail;
            context->m_PipelineState.m_StencilBackOpPass       = dppass;
        }
        else
        {
            context->m_PipelineState.m_StencilFrontOpFail      = sfail;
            context->m_PipelineState.m_StencilFrontOpDepthFail = dpfail;
            context->m_PipelineState.m_StencilFrontOpPass      = dppass;
        }
    }

    static void MetalSetCullFace(HContext _context, FaceType face_type)
    {
        MetalContext* context = (MetalContext*)_context;
        assert(context);
        context->m_PipelineState.m_CullFaceType = face_type;
        context->m_CullFaceChanged              = true;
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
        return true;
    }

    static PipelineState MetalGetPipelineState(HContext _context)
    {
        MetalContext* context = (MetalContext*)_context;
        return context->m_PipelineState;
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
        MetalContext* context = (MetalContext*)_context;
        const MetalViewport& viewport = context->m_MainViewport;
        *x = viewport.m_X, *y = viewport.m_Y, *width = viewport.m_W, *height = viewport.m_H;
    }

    static GraphicsAdapterFunctionTable MetalRegisterFunctionTable()
    {
        GraphicsAdapterFunctionTable fn_table = {};
        DM_REGISTER_GRAPHICS_FUNCTION_TABLE(fn_table, Metal);
        return fn_table;
    }
}
