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

#include "comp_light.h"
#include "resources/res_light.h"
#include <gamesys/gamesys_ddf.h>
#include <gamesys/gamesys.h>
#include <gamesys/gamesys_private.h>

#include <dlib/array.h>
#include <dlib/log.h>
#include <dlib/hash.h>
#include <dlib/message.h>
#include <dlib/dstrings.h>
#include <render/render.h>
#include <gameobject/gameobject.h>
#include <dmsdk/dlib/vmath.h>

namespace dmGameSystem
{
    using namespace dmVMath;

    struct LightComponent
    {
        dmGameObject::HInstance m_Instance;
        LightResource*          m_LightResource;
        uint16_t                m_AddedToUpdate : 1;
        uint16_t                m_Padding : 15;
    };

    struct LightWorld
    {
        dmArray<LightComponent*> m_Components;
    };

    dmGameObject::CreateResult CompLightNewWorld(const dmGameObject::ComponentNewWorldParams& params)
    {
        LightContext* light_context = (LightContext*) params.m_Context;
        LightWorld* world = new LightWorld;

        uint32_t comp_count = dmMath::Min(params.m_MaxComponentInstances, light_context->m_MaxLightCount);
        world->m_Components.SetCapacity(comp_count);

        *params.m_World = world;

        return dmGameObject::CREATE_RESULT_OK;
    }

    dmGameObject::CreateResult CompLightDeleteWorld(const dmGameObject::ComponentDeleteWorldParams& params)
    {
        LightWorld* light_world = (LightWorld*) params.m_World;
        delete light_world;
        return dmGameObject::CREATE_RESULT_OK;
    }

    dmGameObject::CreateResult CompLightCreate(const dmGameObject::ComponentCreateParams& params)
    {
        LightWorld* world = (LightWorld*) params.m_World;

        if (world->m_Components.Full())
        {
            ShowFullBufferError("Light", "light.max_count", world->m_Components.Capacity());
            return dmGameObject::CREATE_RESULT_UNKNOWN_ERROR;
        }

        LightComponent* light  = new LightComponent;
        memset(light, 0, sizeof(LightComponent));

        light->m_Instance      = params.m_Instance;
        light->m_LightResource = (LightResource*) params.m_Resource;

        world->m_Components.Push(light);
        *params.m_UserData = (uintptr_t) light;

        return dmGameObject::CREATE_RESULT_OK;
    }

    void* CompLightGetComponent(const dmGameObject::ComponentGetParams& params)
    {
        return (void*)params.m_UserData;
    }

    dmGameObject::CreateResult CompLightDestroy(const dmGameObject::ComponentDestroyParams& params)
    {
        LightComponent* light = (LightComponent*) *params.m_UserData;
        LightWorld* light_world = (LightWorld*) params.m_World;

        for (uint32_t i = 0; i < light_world->m_Components.Size(); ++i)
        {
            if (light_world->m_Components[i] == light)
            {
                light_world->m_Components.EraseSwap(i);
                delete light;
                return dmGameObject::CREATE_RESULT_OK;
            }
        }
        assert(false);
        return dmGameObject::CREATE_RESULT_OK;
    }

    dmGameObject::CreateResult CompLightAddToUpdate(const dmGameObject::ComponentAddToUpdateParams& params) {
        LightComponent* light = (LightComponent*) *params.m_UserData;
        light->m_AddedToUpdate = true;
        return dmGameObject::CREATE_RESULT_OK;
    }

    dmGameObject::UpdateResult CompLightLateUpdate(const dmGameObject::ComponentsUpdateParams& params, dmGameObject::ComponentsUpdateResult& update_result)
    {
        LightWorld* light_world = (LightWorld*) params.m_World;
        uint32_t num_components = light_world->m_Components.Size();

        for (uint32_t i = 0; i < num_components; ++i)
        {
            LightComponent* light = light_world->m_Components[i];
            if (!light->m_AddedToUpdate)
            {
                continue;
            }
        }

        /*
        for (uint32_t i = 0; i < light_world->m_Lights.Size(); ++i)
        {
            Light* light = light_world->m_Lights[i];
            if (!light->m_AddedToUpdate) {
                continue;
            }
            Point3 position = dmGameObject::GetPosition(light->m_Instance);
            Quat rotation = dmGameObject::GetRotation(light->m_Instance);

            dmGameSystemDDF::LightDesc* light_desc = *light->m_LightResource;
            dmSnPrintf(buf + sizeof(dmGameSystemDDF::SetLight), 9, "%X", dmHashString32(light_desc->m_Id));
            set_light->m_Light.m_Id = (const char*) sizeof(dmGameSystemDDF::SetLight);
            set_light->m_Light.m_Type = light_desc->m_Type;
            set_light->m_Light.m_Intensity = light_desc->m_Intensity;
            set_light->m_Light.m_Color = light_desc->m_Color;
            set_light->m_Light.m_Range = light_desc->m_Range;
            set_light->m_Light.m_Decay = light_desc->m_Decay;
            set_light->m_Light.m_ConeAngle = light_desc->m_ConeAngle;
            set_light->m_Light.m_PenumbraAngle = light_desc->m_PenumbraAngle;
            set_light->m_Light.m_DropOff = light_desc->m_DropOff;
            set_light->m_Position = position;
            set_light->m_Rotation = rotation;
        }
        */

        return dmGameObject::UPDATE_RESULT_OK;
    }

    dmGameObject::UpdateResult CompLightOnMessage(const dmGameObject::ComponentOnMessageParams& params)
    {
        return dmGameObject::UPDATE_RESULT_OK;
    }
}
