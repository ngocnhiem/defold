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

#ifndef DMGRAPHICS_GRAPHICS_DEVICE_METAL_H
#define DMGRAPHICS_GRAPHICS_DEVICE_METAL_H

#include <Metal.hpp>

#include <dlib/hashtable.h>
#include <dlib/opaque_handle_container.h>

namespace dmGraphics
{
    struct ResourceToDestroy;
    struct MetalPipeline;

    typedef dmHashTable64<MetalPipeline> PipelineCache;
    typedef dmArray<ResourceToDestroy>   ResourcesToDestroyList;

    const static uint8_t MAX_FRAMES_IN_FLIGHT = 2; // In flight frames - number of concurrent frames being processed

    enum MetalResourceType
    {
        RESOURCE_TYPE_DEVICE_BUFFER  = 0,
        RESOURCE_TYPE_TEXTURE        = 1,
        RESOURCE_TYPE_PROGRAM        = 2,
        RESOURCE_TYPE_RENDER_TARGET  = 3,
        RESOURCE_TYPE_COMMAND_BUFFER = 4,
    };

    struct MetalViewport
    {
        uint16_t m_X;
        uint16_t m_Y;
        uint16_t m_W;
        uint16_t m_H;
    };

    struct MetalPipeline
    {
        MTL::RenderPipelineState* m_RenderPipelineState;
        MTL::DepthStencilState*   m_DepthStencilState;
    };

    struct ResourceToDestroy
    {
        union
        {
            MTL::Buffer* m_DeviceBuffer;
        };
        MetalResourceType m_ResourceType;
    };

    struct MetalDeviceBuffer
    {
        MTL::Buffer*     m_Buffer;
        MTL::StorageMode m_StorageMode;
        uint32_t         m_Size;
        uint8_t          m_Destroyed;

        const static MetalResourceType GetType()
        {
            return RESOURCE_TYPE_DEVICE_BUFFER;
        }
    };

    struct MetalRenderTarget
    {
        const uint16_t m_Id;
    };

    struct MetalStorageBufferBinding
    {
        HStorageBuffer m_Buffer;
        uint32_t       m_BufferOffset;
    };

    struct MetalShaderModule
    {
        MTL::Function* m_Function;
        MTL::Library*  m_Library;
    };

    struct MetalProgram
    {
        Program            m_BaseProgram;
        MetalShaderModule* m_VertexModule;
        MetalShaderModule* m_FragmentModule;
        MetalShaderModule* m_ComputeModule;
        uint64_t           m_Hash;
    };

    struct MetalFrameResource
    {
        MTL::CommandBuffer*     m_CommandBuffer;
        ResourcesToDestroyList* m_ResourcesToDestroy;
    };

    struct MetalContext
    {
        MetalContext(const ContextParams& params);

        dmPlatform::HWindow        m_Window;

        NSView*                    m_View;
        CAMetalLayer*              m_Layer;
        MetalFrameResource         m_FrameResources[MAX_FRAMES_IN_FLIGHT];
        MTL::Device*               m_Device;
        MTL::CommandQueue*         m_CommandQueue;
        PipelineState              m_PipelineState;
        PipelineCache              m_PipelineCache;
        VertexDeclaration          m_MainVertexDeclaration[MAX_VERTEX_BUFFERS];
        MetalViewport              m_MainViewport;

        // Per-frame metal resources
        CA::MetalDrawable*         m_Drawable;
        NS::AutoreleasePool*       m_AutoReleasePool;
        MTL::RenderPassDescriptor* m_RenderPassDescriptor;
        MTL::RenderCommandEncoder* m_RenderCommandEncoder;

        // Per-frame render state
        MetalDeviceBuffer*         m_CurrentVertexBuffer[MAX_VERTEX_BUFFERS];
        VertexDeclaration*         m_CurrentVertexDeclaration[MAX_VERTEX_BUFFERS];
        uint32_t                   m_CurrentVertexBufferOffset[MAX_VERTEX_BUFFERS];
        MetalStorageBufferBinding  m_CurrentStorageBuffers[MAX_STORAGE_BUFFERS];
        MetalProgram*              m_CurrentProgram;
        MetalPipeline*             m_CurrentPipeline;

        TextureFilter              m_DefaultTextureMinFilter;
        TextureFilter              m_DefaultTextureMagFilter;
        uint32_t                   m_Width;
        uint32_t                   m_Height;

        uint32_t                   m_CurrentFrameInFlight : 2;
        uint32_t                   m_NumFramesInFlight    : 2;
        uint32_t                   m_ViewportChanged      : 1;
        uint32_t                   m_CullFaceChanged      : 1;
    };
}

#endif // DMGRAPHICS_GRAPHICS_DEVICE_METAL_H
