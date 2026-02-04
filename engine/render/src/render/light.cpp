// Copyright 2020-2026 The Defold Foundation
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

#include "render.h"
#include "render_private.h"

namespace dmRender
{
    LightParams::LightParams()
    : m_Type(LIGHT_TYPE_POINT)
    , m_Color(1.0f, 1.0f, 1.0f, 1.0f)
    , m_Direction(0.0f, 0.0f, -1.0f)
    , m_Intensity(1.0f)
    , m_Range(10.0f)
    , m_InnerConeAngle(0.0f)
    , m_OuterConeAngle(3.1415926535f / 4.0f)
    {
    }

    HLight NewLight(HRenderContext render_context, const LightParams& params)
    {
        switch(params.m_Type)
        {
        case LIGHT_TYPE_DIRECTIONAL:
            {
                DirectionalLight* dr = new DirectionalLight;
                dr->m_BaseLight.m_Type = params.m_Type;
                dr->m_BaseLight.m_Color = params.m_Color;
                dr->m_BaseLight.m_Intensity = params.m_Intensity;
                dr->m_Direction = params.m_Direction;
                return (HLight) dr;
            } break;
        case LIGHT_TYPE_POINT:
            {
                PointLight* pl = new PointLight;
                pl->m_BaseLight.m_Type = params.m_Type;
                pl->m_BaseLight.m_Color = params.m_Color;
                pl->m_BaseLight.m_Intensity = params.m_Intensity;
                pl->m_Range = params.m_Range;
                return (HLight) pl;
            } break;
        case LIGHT_TYPE_SPOT:
            {
                SpotLight* sl = new SpotLight;
                sl->m_BaseLight.m_Type = params.m_Type;
                sl->m_BaseLight.m_Color = params.m_Color;
                sl->m_BaseLight.m_Intensity = params.m_Intensity;
                sl->m_Range = params.m_Range;
                sl->m_InnerConeAngle = params.m_InnerConeAngle;
                sl->m_OuterConeAngle = params.m_OuterConeAngle;
                return (HLight) sl;
            } break;
        }

        return 0;
    }

    void DeleteLight(HRenderContext render_context, HLight light)
    {
        delete light;
    }

    HLightInstance NewLightInstance(HRenderContext render_context, HLight light_prototype)
    {
        if (render_context->m_RenderLights.Full())
        {
            render_context->m_RenderLights.Allocate(4);
        }

        LightInstance* light_instance    = new LightInstance;
        light_instance->m_Position       = dmVMath::Point3();
        light_instance->m_LightPrototype = light_prototype;

        return render_context->m_RenderLights.Put(light_instance);
    }

    void DeleteLightInstance(HRenderContext render_context, HLightInstance instance)
    {
        LightInstance* light_instance = render_context->m_RenderLights.Get(instance);
        if (light_instance)
        {
            delete light_instance;
            render_context->m_RenderLights.Release(instance);
        }
    }

    void SetLightInstance(HRenderContext render_context, HLightInstance instance, dmVMath::Point3 position, dmVMath::Quat rotation)
    {
        LightInstance* light_instance = render_context->m_RenderLights.Get(instance);
        if (!light_instance)
            return;
        light_instance->m_Position = position;
        light_instance->m_Rotation = rotation;
    }
}
