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

#ifndef DMSDK_SOUND_SOUND_H
#define DMSDK_SOUND_SOUND_H

/*# Sound API documentation
 *
 * Functions for controlling the engine sound mixer from native extensions.
 *
 * @document
 * @name Sound
 * @namespace dmSound
 * @language C++
 */

namespace dmSound
{
    // Forward declaration supplied by the runtime.
    enum Result : int;

    /*# Set master mute state
     * Mute or unmute the master mixer group.
     *
     * @name SetMasterMute
     * @param mute [type:bool] `true` to mute, `false` to restore audio
     * @return result [type:Result] RESULT_OK on success
     */
    Result SetMasterMute(bool mute);

    /*# Toggle master mute
     * Toggle the master mixer group mute state.
     *
     * @name ToggleMasterMute
     * @return result [type:Result] RESULT_OK on success
     */
    Result ToggleMasterMute();

    /*# Query master mute state
     * @name IsMasterMuted
     * @return muted [type:bool] `true` if the mixer master group is muted
     */
    bool IsMasterMuted();
}

#endif // DMSDK_SOUND_SOUND_H
