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

#include <dlib/math.h>
#include <dlib/dstrings.h>
#include <dlib/profile.h>
#include <dlib/log.h>
#include <dlib/thread.h>

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

    static int16_t       CreateTextureSampler(MetalContext* context, TextureFilter minFilter, TextureFilter magFilter, TextureWrap uWrap, TextureWrap vWrap, uint8_t maxLod, float maxAnisotropy);
    static MetalTexture* MetalNewTextureInternal(const TextureCreationParams& params);
    static void          MetalSetTextureInternal(MetalContext* context, MetalTexture* texture, const TextureParams& params);

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
        m_JobThread               = params.m_JobThread;
        // m_UseValidationLayers     = params.m_UseValidationLayers;

        assert(dmPlatform::GetWindowStateParam(m_Window, dmPlatform::WINDOW_STATE_OPENED));

        if (m_DefaultTextureMinFilter == TEXTURE_FILTER_DEFAULT)
            m_DefaultTextureMinFilter = TEXTURE_FILTER_LINEAR;
        if (m_DefaultTextureMagFilter == TEXTURE_FILTER_DEFAULT)
            m_DefaultTextureMagFilter = TEXTURE_FILTER_LINEAR;

        DM_STATIC_ASSERT(sizeof(m_TextureFormatSupport) * 8 >= TEXTURE_FORMAT_COUNT, Invalid_Struct_Size );
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

    void MetalConstantScratchBuffer::EnsureSize(const MetalContext* context, uint32_t size)
    {
        if (!CanAllocate(size))
        {
            const uint32_t SIZE_INCREASE = 1024 * 8;
            DestroyResourceDeferred((MetalContext*) context, &m_DeviceBuffer);
            DeviceBufferUploadHelper((MetalContext*) context, 0, m_DeviceBuffer.m_Size + SIZE_INCREASE, 0, &m_DeviceBuffer);
            Rewind();
        }
    }

    void MetalArgumentBufferPool::Initialize(const MetalContext* context, uint32_t size_per_buffer)
    {
        m_ScratchBufferIndex = 0;
        m_SizePerBuffer      = size_per_buffer;

        AddBuffer(context);
    }

    void MetalArgumentBufferPool::AddBuffer(const MetalContext* context)
    {
        MetalConstantScratchBuffer buffer = {};
        buffer.m_DeviceBuffer.m_StorageMode = MTL::StorageModeShared;
        buffer.EnsureSize(context, m_SizePerBuffer);
        m_ScratchBufferPool.OffsetCapacity(1);
        m_ScratchBufferPool.Push(buffer);
    }

    MetalConstantScratchBuffer* MetalArgumentBufferPool::Allocate(const MetalContext* context, uint32_t size)
    {
        MetalConstantScratchBuffer* current = Get();

        if (!current->CanAllocate(size))
        {
            m_ScratchBufferIndex++;
            if (m_ScratchBufferIndex >= m_ScratchBufferPool.Size())
            {
                AddBuffer(context);
            }
            current = Get();
        }

        assert(current->CanAllocate(size));
        return current;
    }

    MetalArgumentBinding MetalArgumentBufferPool::Bind(const MetalContext* context, MTL::ArgumentEncoder* encoder)
    {
        uint32_t encode_size_aligned = DM_ALIGN(encoder->encodedLength(), 16);
        assert(encode_size_aligned > 0);

        MetalConstantScratchBuffer* current = Allocate(context, encode_size_aligned);

        MetalArgumentBinding arg_binding = {};
        arg_binding.m_Buffer = current->m_DeviceBuffer.m_Buffer;
        arg_binding.m_Offset = current->m_MappedDataCursor;

        encoder->setArgumentBuffer(current->m_DeviceBuffer.m_Buffer, current->m_MappedDataCursor);
        current->Advance(encoder->encodedLength());

        return arg_binding;
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

    static void SetupSupportedTextureFormats(MetalContext* context)
    {
        // PVRTC is always supported on Apple GPUs
        context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGB_PVRTC_2BPPV1);
        context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGB_PVRTC_4BPPV1);
        context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGBA_PVRTC_2BPPV1);
        context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGBA_PVRTC_4BPPV1);

        // ETC2 support
        if (context->m_Device->supportsFamily(MTL::GPUFamilyApple3))  // A8+ class
        {
            context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGB_ETC1);
            context->m_TextureFormatSupport |= (1 << TEXTURE_FORMAT_RGBA_ETC2);
        }

        // ASTC support
        if (context->m_Device->supportsFamily(MTL::GPUFamilyApple3))
        {
            context->m_ASTCSupport = 1;
            context->m_ASTCArrayTextureSupport = 1;
        }

        // Common uncompressed formats
        TextureFormat base_formats[] = {
            TEXTURE_FORMAT_RGBA,
            TEXTURE_FORMAT_RGBA16F,
            TEXTURE_FORMAT_RGBA32F,
            TEXTURE_FORMAT_R16F,
            TEXTURE_FORMAT_R32F,
            TEXTURE_FORMAT_RG16F,
            TEXTURE_FORMAT_RG32F,
            TEXTURE_FORMAT_RGBA32UI,
            TEXTURE_FORMAT_R32UI,
        };

        for (uint32_t i = 0; i < DM_ARRAY_SIZE(base_formats); ++i)
        {
            context->m_TextureFormatSupport |= 1 << base_formats[i];
        }

        // RGB isn't supported as a texture format, but we still need to supply it to the engine
        // Later in the vulkan pipeline when the texture is created, we will convert it internally to RGBA
        context->m_TextureFormatSupport |= 1 << TEXTURE_FORMAT_RGB;
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

        SetupSupportedTextureFormats(context);

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

            // This is a fixed size per buffer in the pool
            const uint32_t argument_buffer_size = 1024 * 4;
            context->m_FrameResources[i].m_ArgumentBufferPool.Initialize(context, argument_buffer_size);
        }

        context->m_AsyncProcessingSupport = context->m_JobThread != 0x0 && dmThread::PlatformHasThreadSupport();
        if (context->m_AsyncProcessingSupport)
        {
            InitializeSetTextureAsyncState(context->m_SetTextureAsyncState);
            context->m_AssetHandleContainerMutex = dmMutex::New();
        }

        // Create default texture sampler
        CreateTextureSampler(context, TEXTURE_FILTER_LINEAR, TEXTURE_FILTER_LINEAR, TEXTURE_WRAP_REPEAT, TEXTURE_WRAP_REPEAT, 1, 1.0f);

        // Create default dummy texture
        TextureCreationParams default_texture_creation_params;
        default_texture_creation_params.m_Width          = 1;
        default_texture_creation_params.m_Height         = 1;
        default_texture_creation_params.m_LayerCount     = 1;
        default_texture_creation_params.m_OriginalWidth  = default_texture_creation_params.m_Width;
        default_texture_creation_params.m_OriginalHeight = default_texture_creation_params.m_Height;

        const uint8_t default_texture_data[4 * 6] = {}; // RGBA * 6 (for cubemap)

        TextureParams default_texture_params;
        default_texture_params.m_Width      = 1;
        default_texture_params.m_Height     = 1;
        default_texture_params.m_LayerCount = 1;
        default_texture_params.m_Data       = default_texture_data;
        default_texture_params.m_Format     = TEXTURE_FORMAT_RGBA;

        context->m_DefaultTexture2D = MetalNewTextureInternal(default_texture_creation_params);
        MetalSetTextureInternal(context, context->m_DefaultTexture2D, default_texture_params);

        default_texture_params.m_Format = TEXTURE_FORMAT_RGBA32UI;
        context->m_DefaultTexture2D32UI = MetalNewTextureInternal(default_texture_creation_params);
        MetalSetTextureInternal(context, context->m_DefaultTexture2D32UI, default_texture_params);

        default_texture_params.m_Format                 = TEXTURE_FORMAT_RGBA;
        default_texture_creation_params.m_LayerCount    = 1;
        default_texture_creation_params.m_Type          = TEXTURE_TYPE_IMAGE_2D;
        default_texture_creation_params.m_UsageHintBits = TEXTURE_USAGE_FLAG_STORAGE | TEXTURE_USAGE_FLAG_SAMPLE;
        context->m_DefaultStorageImage2D                = MetalNewTextureInternal(default_texture_creation_params);
        MetalSetTextureInternal(context, context->m_DefaultStorageImage2D, default_texture_params);

        default_texture_creation_params.m_UsageHintBits = TEXTURE_USAGE_FLAG_SAMPLE;
        default_texture_creation_params.m_Type          = TEXTURE_TYPE_2D_ARRAY;
        default_texture_creation_params.m_LayerCount    = 1;
        context->m_DefaultTexture2DArray                = MetalNewTextureInternal(default_texture_creation_params);
        MetalSetTextureInternal(context, context->m_DefaultTexture2DArray, default_texture_params);

        default_texture_creation_params.m_Type          = TEXTURE_TYPE_CUBE_MAP;
        default_texture_creation_params.m_Depth         = 1;
        default_texture_creation_params.m_LayerCount    = 6;
        context->m_DefaultTextureCubeMap = MetalNewTextureInternal(default_texture_creation_params);
        MetalSetTextureInternal(context, context->m_DefaultTextureCubeMap, default_texture_params);

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
        frame.m_ArgumentBufferPool.Rewind();

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

    static inline MetalTexture* GetDefaultTexture(MetalContext* context, ShaderDesc::ShaderDataType type)
    {
        switch(type)
        {
            case ShaderDesc::SHADER_TYPE_RENDER_PASS_INPUT:
            case ShaderDesc::SHADER_TYPE_TEXTURE2D:
            case ShaderDesc::SHADER_TYPE_SAMPLER:
            case ShaderDesc::SHADER_TYPE_SAMPLER2D:       return context->m_DefaultTexture2D;
            case ShaderDesc::SHADER_TYPE_SAMPLER2D_ARRAY: return context->m_DefaultTexture2DArray;
            case ShaderDesc::SHADER_TYPE_SAMPLER_CUBE:    return context->m_DefaultTextureCubeMap;
            case ShaderDesc::SHADER_TYPE_UTEXTURE2D:      return context->m_DefaultTexture2D32UI;
            case ShaderDesc::SHADER_TYPE_IMAGE2D:
            case ShaderDesc::SHADER_TYPE_UIMAGE2D:        return context->m_DefaultStorageImage2D;
            default:break;
        }
        return 0x0;
    }

    static void CommitUniforms(MetalContext* context, MTL::RenderCommandEncoder* encoder,
                           MetalConstantScratchBuffer* scratch_buffer, MetalArgumentBufferPool* argument_buffer_pool,
                           MetalProgram* program, uint32_t alignment)
    {
        for (int i = 0; i < program->m_BaseProgram.m_MaxSet; ++i)
        {
            if (program->m_ArgumentEncoders[i])
            {
                program->m_ArgumentBufferBindings[i] = argument_buffer_pool->Bind(context, program->m_ArgumentEncoders[i]);
            }
        }

        ProgramResourceBindingIterator it(&program->m_BaseProgram);
        const ProgramResourceBinding* next;
        while ((next = it.Next()))
        {
            ShaderResourceBinding* res        = next->m_Res;
            MTL::ArgumentEncoder* arg_encoder = program->m_ArgumentEncoders[res->m_Set];

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

                    // encode the pointer for this binding (msl_index is the index inside the argument encoder,
                    // i.e. the [[id(N)]] for the field inside the argument struct)
                    arg_encoder->setBuffer(scratch_buffer->m_DeviceBuffer.m_Buffer, (NSUInteger) offset, (NSUInteger) msl_index);

                    // Advance cursor in scratch
                    scratch_buffer->m_MappedDataCursor = offset + uniform_size;
                } break;

                case ShaderResourceBinding::BINDING_FAMILY_TEXTURE:
                {
                    MetalTexture* texture = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, context->m_TextureUnits[next->m_TextureUnit]);

                    if (texture == 0x0)
                    {
                        texture = GetDefaultTexture(context, res->m_Type.m_ShaderType);
                    }

                    MetalTextureSampler* sampler = &context->m_TextureSamplers[texture->m_TextureSamplerIndex];

                    arg_encoder->setTexture(texture->m_Texture, msl_index);
                    arg_encoder->setSamplerState(sampler->m_Sampler, msl_index + 1);

                    encoder->useResource(texture->m_Texture, MTL::ResourceUsageRead);

                    // TODO: separate samplers
                } break;

                case ShaderResourceBinding::BINDING_FAMILY_STORAGE_BUFFER:
                    // TODO
                    break;
                case ShaderResourceBinding::BINDING_FAMILY_GENERIC:
                    break;

                default:
                    break;
            }
        }

        // Maybe move this call to a "prepare scratch buffer" function or something?
        encoder->useResource(scratch_buffer->m_DeviceBuffer.m_Buffer, MTL::ResourceUsageRead);

        for (uint32_t set = 0; set < context->m_CurrentProgram->m_BaseProgram.m_MaxSet; ++set)
        {
            if (context->m_CurrentProgram->m_ArgumentEncoders[set])
            {
                MetalArgumentBinding& arg_binding = context->m_CurrentProgram->m_ArgumentBufferBindings[set];

                encoder->useResource(arg_binding.m_Buffer, MTL::ResourceUsageRead);

                // TODO: Support binding for both stages based on stage flags?
                if (set == 0)
                {
                    encoder->setVertexBuffer(arg_binding.m_Buffer, arg_binding.m_Offset, set);
                }
                if (set == 1)
                {
                    encoder->setFragmentBuffer(arg_binding.m_Buffer, arg_binding.m_Offset, set);
                }
            }
        }
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

        frame.m_ConstantScratchBuffer.EnsureSize(context, context->m_CurrentProgram->m_UniformDataSizeAligned);

        // EnsureConstantScratchBufferSize(context, &frame.m_ConstantScratchBuffer, context->m_CurrentProgram);

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

        CommitUniforms(context, encoder, &frame.m_ConstantScratchBuffer, &frame.m_ArgumentBufferPool, context->m_CurrentProgram, UNIFORM_BUFFER_ALIGNMENT);
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

    static MetalShaderModule* CreateShaderModule(MTL::Device* device, const char* src, uint32_t src_size, char* error_buffer, uint32_t error_buffer_size)
    {
        char* null_terminated_buffer = new char[src_size + 1];
        memcpy(null_terminated_buffer, src, src_size);
        null_terminated_buffer[src_size] = 0;

        NS::Error* error  = 0;
        MTL::Library* library = device->newLibrary(NS::String::string(null_terminated_buffer, NS::StringEncoding::UTF8StringEncoding), 0, &error);

        delete[] null_terminated_buffer;

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

    static void CreateArgumentBuffers(MetalContext* context, MetalProgram* program)
    {
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

            // uint32_t encode_length = program->m_ArgumentEncoders[i]->encodedLength();
            // program->m_ArgumentBuffers[i] = context->m_Device->newBuffer(encode_length, MTL::ResourceStorageModeShared);
            // program->m_NumArgumentBuffers++;
        }
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
            program->m_ComputeModule = CreateShaderModule(context->m_Device, (const char*) ddf_cp->m_Source.m_Data, ddf_cp->m_Source.m_Count, error_buffer, error_buffer_size);

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
            program->m_VertexModule = CreateShaderModule(context->m_Device, (const char*) ddf_vp->m_Source.m_Data, ddf_vp->m_Source.m_Count, error_buffer, error_buffer_size);
            if (!program->m_VertexModule)
            {
                DeleteProgram(_context, (HProgram) program);
                return 0;
            }

            program->m_FragmentModule = CreateShaderModule(context->m_Device, (const char*) ddf_fp->m_Source.m_Data, ddf_fp->m_Source.m_Count, error_buffer, error_buffer_size);
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

        CreateArgumentBuffers(context, program);

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
        MetalContext* context = (MetalContext*) _context;
        return (context->m_TextureFormatSupport & (1 << format)) != 0 || (context->m_ASTCSupport && IsTextureFormatASTC(format));
    }

    static inline void InitializeMetalTexture(MetalTexture* t)
    {
        memset(t, 0, sizeof(MetalTexture));
        t->m_Type           = TEXTURE_TYPE_2D;
        t->m_GraphicsFormat = TEXTURE_FORMAT_RGBA;
        //t->m_Format         = VK_FORMAT_UNDEFINED;
    }

    static MetalTexture* MetalNewTextureInternal(const TextureCreationParams& params)
    {
        MetalTexture* tex = new MetalTexture;
        InitializeMetalTexture(tex);

        tex->m_Type           = params.m_Type;
        tex->m_Width          = params.m_Width;
        tex->m_Height         = params.m_Height;
        tex->m_Depth          = dmMath::Max((uint16_t)1, params.m_Depth);
        tex->m_LayerCount     = dmMath::Max((uint8_t)1, params.m_LayerCount);
        tex->m_MipMapCount    = params.m_MipMapCount;
        tex->m_UsageHintFlags = params.m_UsageHintBits;
        tex->m_PageCount      = params.m_LayerCount;
        tex->m_DataState      = 0;

        // TODO
        // tex->m_PendingUpload  = INVALID_OPAQUE_HANDLE;
        // tex->m_UsageFlags     = GetMetalUsageFromHints(params.m_UsageHintBits);

        if (params.m_OriginalWidth == 0)
        {
            tex->m_OriginalWidth  = params.m_Width;
            tex->m_OriginalHeight = params.m_Height;
            tex->m_OriginalDepth  = params.m_Depth;
        }
        else
        {
            tex->m_OriginalWidth  = params.m_OriginalWidth;
            tex->m_OriginalHeight = params.m_OriginalHeight;
            tex->m_OriginalDepth  = params.m_OriginalDepth;
        }
        return tex;
    }

    static HTexture MetalNewTexture(HContext _context, const TextureCreationParams& params)
    {
        MetalContext* context = (MetalContext*) _context;
        MetalTexture* texture = MetalNewTextureInternal(params);
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        return StoreAssetInContainer(context->m_AssetHandleContainer, texture, ASSET_TYPE_TEXTURE);
    }

    static void MetalDeleteTextureInternal(MetalContext* context, MetalTexture* texture)
    {
        DestroyResourceDeferred(context, texture);
        delete texture;
    }

    static void MetalDeleteTexture(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalDeleteTextureInternal(context, GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture));
        context->m_AssetHandleContainer.Release(texture);
    }

    static MTL::PixelFormat GetMetalPixelFormat(TextureFormat format)
    {
        switch (format)
        {
            case TEXTURE_FORMAT_LUMINANCE:         return MTL::PixelFormatR8Unorm;
            case TEXTURE_FORMAT_LUMINANCE_ALPHA:   return MTL::PixelFormatRG8Unorm;
            case TEXTURE_FORMAT_RGB:               return MTL::PixelFormatRGBA8Unorm; // expand RGB to RGBA
            case TEXTURE_FORMAT_RGBA:              return MTL::PixelFormatRGBA8Unorm;
            case TEXTURE_FORMAT_RGB_16BPP:         return MTL::PixelFormatB5G6R5Unorm; // closest 16-bit
            //case TEXTURE_FORMAT_RGBA_16BPP:        return MTL::PixelFormatRGBA4Unorm;
            case TEXTURE_FORMAT_DEPTH:             return MTL::PixelFormatInvalid;
            case TEXTURE_FORMAT_STENCIL:           return MTL::PixelFormatInvalid;

            // PVRTC
            case TEXTURE_FORMAT_RGB_PVRTC_2BPPV1:  return MTL::PixelFormatPVRTC_RGB_2BPP;
            case TEXTURE_FORMAT_RGB_PVRTC_4BPPV1:  return MTL::PixelFormatPVRTC_RGB_4BPP;
            case TEXTURE_FORMAT_RGBA_PVRTC_2BPPV1: return MTL::PixelFormatPVRTC_RGBA_2BPP;
            case TEXTURE_FORMAT_RGBA_PVRTC_4BPPV1: return MTL::PixelFormatPVRTC_RGBA_4BPP;

            // ETC2
            case TEXTURE_FORMAT_RGB_ETC1:          return MTL::PixelFormatETC2_RGB8;
            //case TEXTURE_FORMAT_RGBA_ETC2:         return MTL::PixelFormatETC2_RGBA8;

            // BC / DXT (macOS only)
            case TEXTURE_FORMAT_RGB_BC1:           return MTL::PixelFormatBC1_RGBA;
            case TEXTURE_FORMAT_RGBA_BC3:          return MTL::PixelFormatBC3_RGBA;
            //case TEXTURE_FORMAT_RGBA_BC7:          return MTL::PixelFormatBC7_RGBA;
            case TEXTURE_FORMAT_R_BC4:             return MTL::PixelFormatBC4_RUnorm;
            case TEXTURE_FORMAT_RG_BC5:            return MTL::PixelFormatBC5_RGUnorm;

            // Floating point
            case TEXTURE_FORMAT_RGB16F:            return MTL::PixelFormatRGBA16Float; // expand RGB -> RGBA
            case TEXTURE_FORMAT_RGB32F:            return MTL::PixelFormatRGBA32Float; // expand RGB -> RGBA
            case TEXTURE_FORMAT_RGBA16F:           return MTL::PixelFormatRGBA16Float;
            case TEXTURE_FORMAT_RGBA32F:           return MTL::PixelFormatRGBA32Float;
            case TEXTURE_FORMAT_R16F:              return MTL::PixelFormatR16Float;
            case TEXTURE_FORMAT_RG16F:             return MTL::PixelFormatRG16Float;
            case TEXTURE_FORMAT_R32F:              return MTL::PixelFormatR32Float;
            case TEXTURE_FORMAT_RG32F:             return MTL::PixelFormatRG32Float;

            // Unsigned integer
            case TEXTURE_FORMAT_RGBA32UI:          return MTL::PixelFormatRGBA32Uint;
            case TEXTURE_FORMAT_R32UI:             return MTL::PixelFormatR32Uint;
            case TEXTURE_FORMAT_BGRA8U:            return MTL::PixelFormatBGRA8Unorm;

            // ASTC
            case TEXTURE_FORMAT_RGBA_ASTC_4X4:    return MTL::PixelFormatASTC_4x4_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_5X4:    return MTL::PixelFormatASTC_5x4_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_5X5:    return MTL::PixelFormatASTC_5x5_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_6X5:    return MTL::PixelFormatASTC_6x5_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_6X6:    return MTL::PixelFormatASTC_6x6_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_8X5:    return MTL::PixelFormatASTC_8x5_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_8X6:    return MTL::PixelFormatASTC_8x6_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_8X8:    return MTL::PixelFormatASTC_8x8_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_10X5:   return MTL::PixelFormatASTC_10x5_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_10X6:   return MTL::PixelFormatASTC_10x6_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_10X8:   return MTL::PixelFormatASTC_10x8_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_10X10:  return MTL::PixelFormatASTC_10x10_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_12X10:  return MTL::PixelFormatASTC_12x10_LDR;
            case TEXTURE_FORMAT_RGBA_ASTC_12X12:  return MTL::PixelFormatASTC_12x12_LDR;

            default: return MTL::PixelFormatInvalid;
        }
    }

    static void MetalCopyToTexture(MetalContext* context,
                                   const TextureParams& params,
                                   uint32_t tex_data_size,
                                   void* tex_data_ptr,
                                   MetalTexture* texture)
    {
        MTL::Device* device = context->m_Device;

        uint32_t width  = params.m_Width;
        uint32_t height = params.m_Height;
        uint32_t depth  = dmMath::Max((uint16_t)1u, params.m_Depth);
        uint8_t  bpp    = GetTextureFormatBitsPerPixel(params.m_Format);

        uint32_t bytesPerRow   = (bpp / 8) * width;
        uint32_t bytesPerImage = bytesPerRow * height;

        // Create staging (upload) buffer
        MTL::Buffer* stagingBuffer = device->newBuffer(tex_data_size, MTL::ResourceStorageModeShared);
        memcpy(stagingBuffer->contents(), tex_data_ptr, tex_data_size);

        // Command buffer + blit encoder
        MTL::CommandBuffer* commandBuffer = context->m_CommandQueue->commandBuffer();
        MTL::BlitCommandEncoder* blitEncoder = commandBuffer->blitCommandEncoder();

        // Compute copy region
        MTL::Origin origin = { params.m_X, params.m_Y, params.m_Z };
        MTL::Size   size   = { width, height, depth };

        for (uint32_t layer = 0; layer < texture->m_LayerCount; ++layer)
        {
            // Source offset — each layer data follows the previous one
            uint32_t srcOffset = layer * bytesPerImage;

            blitEncoder->copyFromBuffer(
                stagingBuffer,
                srcOffset,
                bytesPerRow,
                bytesPerImage,
                size,
                texture->m_Texture,
                params.m_Slice + layer,     // destination array slice
                params.m_MipMap,            // destination mip level
                origin                      // subregion offset
            );
        }

        blitEncoder->endEncoding();
        commandBuffer->commit();
        commandBuffer->waitUntilCompleted();

        stagingBuffer->release();
    }

    static void MetalSetTextureInternal(MetalContext* context, MetalTexture* texture, const TextureParams& params)
    {
        // Reject unsupported formats
        if (params.m_Format == TEXTURE_FORMAT_DEPTH || params.m_Format == TEXTURE_FORMAT_STENCIL)
        {
            dmLogError("Unable to upload texture data, unsupported type (%s).", GetTextureFormatLiteral(params.m_Format));
            return;
        }

        // Clamp size to Metal limits
        uint32_t maxSize = GetMaxTextureSize(context);
        assert(params.m_Width  <= maxSize);
        assert(params.m_Height <= maxSize);

        // Compute layer count, depth, and bits per pixel
        uint8_t tex_layer_count = dmMath::Max(texture->m_LayerCount, params.m_LayerCount);
        uint16_t tex_depth      = dmMath::Max(texture->m_Depth, params.m_Depth);
        uint8_t tex_bpp         = GetTextureFormatBitsPerPixel(params.m_Format);
        size_t tex_data_size    = params.m_DataSize * tex_layer_count * 8; // bits
        void* tex_data_ptr      = (void*)params.m_Data;

        // Expand RGB to RGBA if needed
        TextureFormat format_orig = params.m_Format;
        if (format_orig == TEXTURE_FORMAT_RGB)
        {
            uint32_t pixel_count = params.m_Width * params.m_Height * tex_layer_count;
            uint8_t* data_new = new uint8_t[pixel_count * 4]; // RGBA
            RepackRGBToRGBA(pixel_count, (uint8_t*)tex_data_ptr, data_new);
            tex_data_ptr = data_new;
            tex_bpp = 32;
        }

        // Compute tex_data_size in bytes
        tex_data_size = tex_bpp / 8 * params.m_Width * params.m_Height * tex_depth * tex_layer_count;

        // Recreate texture if needed
        bool needsRecreate = !texture->m_Texture ||
                             texture->m_Width  != params.m_Width ||
                             texture->m_Height != params.m_Height ||
                             texture->m_Depth  != params.m_Depth ||
                             texture->m_GraphicsFormat != params.m_Format;

        if (params.m_SubUpdate)
        {
            // Same as vulkan
            tex_data_size = params.m_Width * params.m_Height * tex_bpp * tex_layer_count;
        }
        else if (needsRecreate)
        {
            assert(!params.m_SubUpdate);

            MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();

            // Set type
            if (tex_depth > 1)
                desc->setTextureType(MTL::TextureType3D);
            else if (tex_layer_count > 1)
                desc->setTextureType(MTL::TextureType2DArray);
            else
                desc->setTextureType(MTL::TextureType2D);

            // Set pixel format
            desc->setPixelFormat(GetMetalPixelFormat(params.m_Format));

            // Set dimensions
            desc->setWidth(params.m_Width);
            desc->setHeight(params.m_Height);
            desc->setDepth(tex_depth);
            desc->setArrayLength(tex_layer_count);
            desc->setMipmapLevelCount(params.m_MipMap + 1);
            desc->setSampleCount(1);
            desc->setStorageMode(MTL::StorageModePrivate);
            desc->setUsage(MTL::TextureUsageShaderRead); // | MTL::TextureUsageShaderWrite);

            // Create Metal texture
            if (texture->m_Texture)
                texture->m_Texture->release();
            texture->m_Texture = context->m_Device->newTexture(desc);
            desc->release();

            texture->m_Width  = params.m_Width;
            texture->m_Height = params.m_Height;
            texture->m_Depth  = params.m_Depth;
            texture->m_LayerCount = tex_layer_count;
            texture->m_GraphicsFormat = params.m_Format;
            texture->m_MipMapCount = params.m_MipMap + 1;
        }

        if (tex_data_ptr && tex_data_size > 0)
        {
            MetalCopyToTexture(context, params, tex_data_size, tex_data_ptr, texture);
        }

        // Clean up temporary RGB->RGBA conversion
        if (format_orig == TEXTURE_FORMAT_RGB)
        {
            delete[] (uint8_t*)tex_data_ptr;
        }
    }

    static void MetalSetTexture(HContext _context, HTexture texture, const TextureParams& params)
    {
        DM_PROFILE(__FUNCTION__);
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        MetalSetTextureInternal(context, tex, params);
    }

    static int16_t GetTextureSamplerIndex(MetalContext* context, TextureFilter minfilter, TextureFilter magfilter, TextureWrap uwrap, TextureWrap vwrap, uint8_t maxLod, float max_anisotropy)
    {
        if (minfilter == TEXTURE_FILTER_DEFAULT)
        {
            minfilter = context->m_DefaultTextureMinFilter;
        }
        if (magfilter == TEXTURE_FILTER_DEFAULT)
        {
            magfilter = context->m_DefaultTextureMagFilter;
        }

        for (uint32_t i=0; i < context->m_TextureSamplers.Size(); i++)
        {
            const MetalTextureSampler& sampler = context->m_TextureSamplers[i];
            if (sampler.m_MagFilter     == magfilter &&
                sampler.m_MinFilter     == minfilter &&
                sampler.m_AddressModeU  == uwrap     &&
                sampler.m_AddressModeV  == vwrap     &&
                sampler.m_MaxLod        == maxLod    &&
                sampler.m_MaxAnisotropy == max_anisotropy)
            {
                return (uint8_t) i;
            }
        }

        return -1;
    }

    static inline float GetMaxAnisotrophyClamped(float requested)
    {
        // Metal does not expose a device query for this, but all Apple GPUs
        // and modern discrete GPUs support at least 16x anisotropy.
        const float MAX_SUPPORTED_ANISOTROPY = 16.0f;
        return (requested < MAX_SUPPORTED_ANISOTROPY) ? requested : MAX_SUPPORTED_ANISOTROPY;
    }

    static inline MTL::SamplerAddressMode GetMetalSamplerAddressMode(TextureWrap wrap)
    {
        switch (wrap)
        {
            case TEXTURE_WRAP_REPEAT:          return MTL::SamplerAddressModeRepeat;
            case TEXTURE_WRAP_MIRRORED_REPEAT: return MTL::SamplerAddressModeMirrorRepeat;
            case TEXTURE_WRAP_CLAMP_TO_EDGE:   return MTL::SamplerAddressModeClampToEdge;
            default:                           return MTL::SamplerAddressModeClampToEdge;
        }
    }

    static inline MTL::SamplerMinMagFilter GetMetalFilter(TextureFilter filter)
    {
        switch (filter)
        {
            case TEXTURE_FILTER_NEAREST: return MTL::SamplerMinMagFilterNearest;
            case TEXTURE_FILTER_LINEAR:  return MTL::SamplerMinMagFilterLinear;
            default:                     return MTL::SamplerMinMagFilterNearest;
        }
    }

    static MTL::SamplerState* CreateMetalTextureSampler(
        MTL::Device* device,
        MTL::SamplerMinMagFilter minFilter,
        MTL::SamplerMinMagFilter magFilter,
        MTL::SamplerMipFilter mipFilter,
        MTL::SamplerAddressMode wrapU,
        MTL::SamplerAddressMode wrapV,
        float minLod,
        float maxLod,
        float maxAnisotropy)
    {
        using namespace MTL;

        // Create and configure the sampler descriptor
        SamplerDescriptor* desc = SamplerDescriptor::alloc()->init();
        desc->setMinFilter(minFilter);
        desc->setMagFilter(magFilter);
        desc->setMipFilter(mipFilter);

        desc->setSAddressMode(wrapU);
        desc->setTAddressMode(wrapV);
        desc->setRAddressMode(wrapU); // Metal allows 3D address mode too

        desc->setLodMinClamp(minLod);
        desc->setLodMaxClamp(maxLod);
        desc->setSupportArgumentBuffers(true);

        if (maxAnisotropy > 1.0f)
            desc->setMaxAnisotropy(maxAnisotropy);

        // Metal always normalizes texture coordinates
        // (no unnormalizedCoordinates option like Vulkan)

        // Metal doesn't support border color — it clamps or repeats instead
        // so you must pick the appropriate address mode for that

        // Create the sampler state
        SamplerState* sampler = device->newSamplerState(desc);
        desc->release();

        return sampler;
    }

    static int16_t CreateTextureSampler(MetalContext* context, TextureFilter minFilter, TextureFilter magFilter, TextureWrap uWrap, TextureWrap vWrap, uint8_t maxLod, float maxAnisotropy)
    {
        // Resolve default filters
        if (magFilter == TEXTURE_FILTER_DEFAULT)
        {
            magFilter = context->m_DefaultTextureMagFilter;
        }
        if (minFilter == TEXTURE_FILTER_DEFAULT)
        {
            minFilter = context->m_DefaultTextureMinFilter;
        }

        // Convert filters to Metal types
        MTL::SamplerMinMagFilter metalMagFilter = GetMetalFilter(magFilter);
        MTL::SamplerMinMagFilter metalMinFilter = GetMetalFilter(minFilter);
        MTL::SamplerMipFilter metalMipFilter = MTL::SamplerMipFilterNearest;

        float maxLodFloat = static_cast<float>(maxLod);

        // Match Vulkan-like logic for mip filtering
        switch (minFilter)
        {
            case TEXTURE_FILTER_NEAREST_MIPMAP_LINEAR:
            case TEXTURE_FILTER_LINEAR_MIPMAP_LINEAR:
                metalMipFilter = MTL::SamplerMipFilterLinear;
                break;
            default:
                metalMipFilter = MTL::SamplerMipFilterNearest;
                break;
        }

        // Convert address modes
        MTL::SamplerAddressMode wrapU = GetMetalSamplerAddressMode(uWrap);
        MTL::SamplerAddressMode wrapV = GetMetalSamplerAddressMode(vWrap);

        // Construct sampler struct
        MetalTextureSampler newSampler = {};
        newSampler.m_MinFilter     = minFilter;
        newSampler.m_MagFilter     = magFilter;
        newSampler.m_AddressModeU  = uWrap;
        newSampler.m_AddressModeV  = vWrap;
        newSampler.m_MaxLod        = maxLod;
        newSampler.m_MaxAnisotropy = maxAnisotropy;

        uint32_t samplerIndex = context->m_TextureSamplers.Size();
        if (context->m_TextureSamplers.Full())
        {
            context->m_TextureSamplers.OffsetCapacity(1);
        }

        // Create the Metal sampler
        newSampler.m_Sampler = CreateMetalTextureSampler(
            context->m_Device,
            metalMinFilter,
            metalMagFilter,
            metalMipFilter,
            wrapU,
            wrapV,
            0.0f,
            maxLodFloat,
            maxAnisotropy
        );

        context->m_TextureSamplers.Push(newSampler);
        return static_cast<int16_t>(samplerIndex);
    }

    static void MetalSetTextureParamsInternal(MetalContext* context, MetalTexture* texture, TextureFilter minfilter, TextureFilter magfilter, TextureWrap uwrap, TextureWrap vwrap, float max_anisotropy)
    {
        const MetalTextureSampler& sampler = context->m_TextureSamplers[texture->m_TextureSamplerIndex];
        float anisotropy_clamped = GetMaxAnisotrophyClamped(max_anisotropy);

        if (sampler.m_MinFilter     != minfilter              ||
            sampler.m_MagFilter     != magfilter              ||
            sampler.m_AddressModeU  != uwrap                  ||
            sampler.m_AddressModeV  != vwrap                  ||
            sampler.m_MaxLod        != texture->m_MipMapCount ||
            sampler.m_MaxAnisotropy != anisotropy_clamped)
        {
            int16_t sampler_index = GetTextureSamplerIndex(context, minfilter, magfilter, uwrap, vwrap, texture->m_MipMapCount, anisotropy_clamped);
            if (sampler_index < 0)
            {
                sampler_index = CreateTextureSampler(context, minfilter, magfilter, uwrap, vwrap, texture->m_MipMapCount, anisotropy_clamped);
            }
            texture->m_TextureSamplerIndex = sampler_index;
        }
    }

    static void MetalSetTextureAsync(HContext _context, HTexture texture, const TextureParams& params, SetTextureAsyncCallback callback, void* user_data)
    {
        // TODO
        SetTexture(_context, texture, params);
        if (callback)
        {
            callback(texture, user_data);
        }
    }

    static void MetalSetTextureParams(HContext _context, HTexture texture, TextureFilter minfilter, TextureFilter magfilter, TextureWrap uwrap, TextureWrap vwrap, float max_anisotropy)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        MetalSetTextureParamsInternal(context, tex, minfilter, magfilter, uwrap, vwrap, max_anisotropy);
    }

    static uint32_t MetalGetTextureResourceSize(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        if (!tex)
        {
            return 0;
        }
        uint32_t size_total = 0;
        uint32_t size = tex->m_Width * tex->m_Height * dmMath::Max(1U, GetTextureFormatBitsPerPixel(tex->m_GraphicsFormat)/8);
        for(uint32_t i = 0; i < tex->m_MipMapCount; ++i)
        {
            size_total += size;
            size >>= 2;
        }
        if (tex->m_Type == TEXTURE_TYPE_CUBE_MAP)
        {
            size_total *= 6;
        }
        return size_total + sizeof(MetalTexture);
    }

    static uint16_t MetalGetTextureWidth(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_Width : 0;
    }

    static uint16_t MetalGetTextureHeight(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_Height : 0;
    }

    static uint16_t MetalGetTextureDepth(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_Depth : 0;
    }

    static uint16_t MetalGetOriginalTextureWidth(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_OriginalWidth : 0;
    }

    static uint16_t MetalGetOriginalTextureHeight(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_OriginalHeight : 0;
    }

    static uint8_t MetalGetTextureMipmapCount(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_MipMapCount : 0;
    }

    static TextureType MetalGetTextureType(HContext _context, HTexture texture)
    {
        MetalContext* context = (MetalContext*)_context;
        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, texture);
        return tex ? tex->m_Type : TEXTURE_TYPE_2D;
    }

    static void MetalEnableTexture(HContext _context, uint32_t unit, uint8_t id_index, HTexture texture)
    {
        assert(unit < DM_MAX_TEXTURE_UNITS);
        ((MetalContext*)_context)->m_TextureUnits[unit] = texture;
    }

    static void MetalDisableTexture(HContext _context, uint32_t unit, HTexture texture)
    {
        assert(unit < DM_MAX_TEXTURE_UNITS);
        ((MetalContext*)_context)->m_TextureUnits[unit] = 0;
    }

    static uint32_t MetalGetMaxTextureSize(HContext _context)
    {
        MetalContext* context = (MetalContext*)_context;
        if (context->m_Device->supportsFamily(MTL::GPUFamilyApple5) ||
            context->m_Device->supportsFamily(MTL::GPUFamilyMac1))
        {
            return 16384;
        }
        return 8192;
    }

    static uint32_t MetalGetTextureStatusFlags(HContext _context, HTexture texture)
    {
        return TEXTURE_STATUS_OK;
    }

    static void MetalReadPixels(HContext _context, int32_t x, int32_t y, uint32_t width, uint32_t height, void* buffer, uint32_t buffer_size)
    {

    }

    static void MetalRunApplicationLoop(void* user_data, WindowStepMethod step_method, WindowIsRunning is_running)
    {

    }

    static HandleResult MetalGetTextureHandle(HTexture texture, void** out_handle)
    {
        return HANDLE_RESULT_OK;
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
        return 1;
    }

    static uint32_t MetalGetTextureUsageHintFlags(HContext _context, HTexture texture)
    {
        return 0;
    }

    static uint8_t MetalGetTexturePageCount(HTexture texture)
    {
        DM_MUTEX_SCOPED_LOCK(g_MetalContext->m_AssetHandleContainerMutex);
        MetalTexture* tex = GetAssetFromContainer<MetalTexture>(g_MetalContext->m_AssetHandleContainer, texture);
        return tex ? tex->m_PageCount : 0;
    }

    static bool MetalIsAssetHandleValid(HContext _context, HAssetHandle asset_handle)
    {
        if (asset_handle == 0)
        {
            return false;
        }

        MetalContext* context = (MetalContext*) _context;
        AssetType type         = GetAssetType(asset_handle);

        DM_MUTEX_SCOPED_LOCK(context->m_AssetHandleContainerMutex);
        if (type == ASSET_TYPE_TEXTURE)
        {
            return GetAssetFromContainer<MetalTexture>(context->m_AssetHandleContainer, asset_handle) != 0;
        }
        else if (type == ASSET_TYPE_RENDER_TARGET)
        {
            return GetAssetFromContainer<MetalRenderTarget>(context->m_AssetHandleContainer, asset_handle) != 0;
        }
        return false;
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
