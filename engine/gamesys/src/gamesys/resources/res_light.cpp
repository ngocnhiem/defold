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

#include "res_light.h"

#include <gamesys/gamesys_ddf.h>

namespace dmGameSystem
{
    dmResource::Result ResLightCreate(const dmResource::ResourceCreateParams* params)
    {
        LightResource* light_resource = new LightResource();
        memset(light_resource, 0, sizeof(LightResource));

        light_resource->m_DDF = (dmGameSystemDDF::LightDesc*) params->m_PreloadData;

        dmResource::SetResource(params->m_Resource, light_resource);

        return dmResource::RESULT_OK;
    }

    static inline void ReleaseResources(dmResource::HFactory factory, LightResource* resource)
    {
        if (resource->m_DDF != 0x0)
            dmDDF::FreeMessage(resource->m_DDF);
    }

    dmResource::Result ResLightDestroy(const dmResource::ResourceDestroyParams* params)
    {
        LightResource* light_resource = (LightResource*) dmResource::GetResource(params->m_Resource);
        ReleaseResources(params->m_Factory, light_resource);
        delete light_resource;
        return dmResource::RESULT_OK;
    }

    dmResource::Result ResLightPreload(const dmResource::ResourcePreloadParams* params)
    {
        dmGameSystemDDF::LightDesc *ddf;
        dmDDF::Result e = dmDDF::LoadMessage(params->m_Buffer, params->m_BufferSize, &ddf);
        if ( e != dmDDF::RESULT_OK )
        {
            return dmResource::RESULT_FORMAT_ERROR;
        }

        *params->m_PreloadData = ddf;
        return dmResource::RESULT_OK;
    }

    dmResource::Result ResLightRecreate(const dmResource::ResourceRecreateParams* params)
    {
        LightResource tmp_light_resource = {};

        dmDDF::Result e = dmDDF::LoadMessage(params->m_Buffer, params->m_BufferSize, &tmp_light_resource.m_DDF);
        if ( e != dmDDF::RESULT_OK )
        {
            return dmResource::RESULT_FORMAT_ERROR;
        }

        LightResource* light_resource = (LightResource*) dmResource::GetResource(params->m_Resource);
        ReleaseResources(params->m_Factory, light_resource);
        *light_resource = tmp_light_resource;

        return dmResource::RESULT_OK;
    }
}
