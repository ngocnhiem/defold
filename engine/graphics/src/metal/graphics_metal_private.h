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

namespace dmGraphics
{
    struct MetalProgram
    {
        Program                   m_BaseProgram;
        MTL::RenderPipelineState* m_PipelineState;
        MTL::Function*            m_VertexFunction;
        MTL::Function*            m_FragmentFunction;
        MTL::Library*             m_Library;
    };

    struct MetalContext
    {
        MetalContext(const ContextParams& params);

        dmPlatform::HWindow m_Window;

        NSView*                    m_View;
        CAMetalLayer*              m_Layer;

        MTL::Device*               m_Device;
        MTL::CommandQueue*         m_CommandQueue;

        // Per-frame resources
        CA::MetalDrawable*         m_Drawable;
        NS::AutoreleasePool*       m_AutoReleasePool;
        MTL::CommandBuffer*        m_CommandBuffer;
        MTL::RenderPassDescriptor* m_RenderPassDescriptor;
        MTL::RenderCommandEncoder* m_RenderCommandEncoder;

        TextureFilter              m_DefaultTextureMinFilter;
        TextureFilter              m_DefaultTextureMagFilter;
        uint32_t                   m_Width;
        uint32_t                   m_Height;
    };
}

#endif // DMGRAPHICS_GRAPHICS_DEVICE_METAL_H
