cmake_minimum_required(VERSION 4.0)

# gamesys tests

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/../../../../../scripts/cmake")
include(defold)

set(GS_TEST_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(GS_SRC_ROOT  "${CMAKE_CURRENT_LIST_DIR}/..")
set(GS_PROTO_DIR "${GS_SRC_ROOT}/../../proto/gamesys")

# When included from engine/gamesys, the 'gamesys' target is already defined.
# If configured standalone, callers must provide/link appropriate libs.

# ---------------------------------------------------------------------------
# Test content setup
# Copy the test content tree next to the test binaries for runtime access.
# The waf build uses content_root and copies resources; we mirror that here.
# ---------------------------------------------------------------------------
set(_GS_TEST_BIN_DIR "${CMAKE_CURRENT_BINARY_DIR}")
file(MAKE_DIRECTORY "${_GS_TEST_BIN_DIR}")

set(dirs
  "animationset/*"
  "atlas/*"
  "buffer/*"
  "camera/*"
  "collection_factory/*"
  "collection_proxy/*"
  "collision_object/**"
  "convex_shape/*"
  "display_profiles/*"
  "emitter/*"
  "factory/*"
  "font/*"
  "fragment_program/*"
  "gui/**"
  "image/*"
  "input/*"
  "label/*"
  "light/*"
  "lua/*"
  "material/*"
  "mesh/*"
  "meshset/*"
  "misc/**"
  "model/*"
  "particlefx/*"
  "render/*"
  "render_script/*"
  "render_target/*"
  "resource/*"
  "script/*"
  "shader/*"
  "sound/*"
  "sprite/**"
  "sys/**"
  "texture/*"
  "textureset/*"
  "tile/*"
  "tilegrid/*"
  "vertex_program/*"
  "window/*")

set(excl_pattern
  ".ttf"
  ".basis"
  ".psd"
  ".DS_Store")

glob_files(gamesys_content "${dirs}" "${excl_pattern}")

set(gamesys_content_outputs)
defold_content(gamesys_content_outputs ${gamesys_content}
  PYTHONPATH "${GAMESYS_PROTO_PY_DIR}"
  CONTENT_ROOT "${GS_TEST_ROOT}"
  OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}")

# ---------------------------------------------------------------------------
# Embed a few resources into headers (used by test_gamesys.cpp)
# Generates resource/<name>.embed.h with variables NAME[] and NAME_SIZE
# ---------------------------------------------------------------------------

set(_EMBED_HEADERS)
set(_EMBED_CPP)
set(_RES_DIR "${GS_TEST_ROOT}/resource")
defold_embed_to_header("${_RES_DIR}/layer_guitar_a.ogg" "${CMAKE_CURRENT_BINARY_DIR}/resource/layer_guitar_a.ogg.embed.h")
list(APPEND _EMBED_HEADERS "${CMAKE_CURRENT_BINARY_DIR}/resource/layer_guitar_a.ogg.embed.h")
list(APPEND _EMBED_CPP     "${CMAKE_CURRENT_BINARY_DIR}/resource/layer_guitar_a.ogg.embed.cpp")
defold_embed_to_header("${_RES_DIR}/booster_on_sfx.wav" "${CMAKE_CURRENT_BINARY_DIR}/resource/booster_on_sfx.wav.embed.h")
list(APPEND _EMBED_HEADERS "${CMAKE_CURRENT_BINARY_DIR}/resource/booster_on_sfx.wav.embed.h")
list(APPEND _EMBED_CPP     "${CMAKE_CURRENT_BINARY_DIR}/resource/booster_on_sfx.wav.embed.cpp")

# Ensure the generated Python protobuf modules are discoverable when proto_gamesys.py runs.
if(NOT GAMESYS_PROTO_PY_DIR)
  message(FATAL_ERROR "GAMESYS_PROTO_PY_DIR is not set; expected gamesys proto Python outputs to be generated")
endif()

# Make a phony target to expose content build step
add_custom_target(gamesys_test_content DEPENDS ${_EMBED_HEADERS} ${gamesys_content_outputs})
add_dependencies(gamesys_test_content gamesys gamesys_proto_py)

# ---------------------------------------------------------------------------
# Exported symbols helper (prevents stripping by linker and ensures adapters)
# ---------------------------------------------------------------------------
set(_COMMON_EXPORTED
  ComponentTypeAnim
  ComponentTypeGui
  ComponentTypeMesh
  ComponentTypeScript
  ComponentTypeSound
  ResourceProviderFile
  ResourceTypeAnim
  ResourceTypeAnimationSet
  ResourceTypeCollection
  ResourceTypeGameObject
  ResourceTypeGui
  ResourceTypeGuiScript
  ResourceTypeLua
  ResourceTypeOgg
  ResourceTypeOpus
  ResourceTypeScript
  ResourceTypeTTF
  ResourceTypeFont
  ResourceTypeWav
  GraphicsAdapterNull
  ScriptImageExt
  ScriptFont
  ScriptHttp)

# ---------------------------------------------------------------------------
# test_gamesys
# ---------------------------------------------------------------------------
set(TEST_GS_SOURCES
  "${GS_TEST_ROOT}/test_gamesys.cpp"
)

set(_TEST1_SYMBOLS ${_COMMON_EXPORTED};ScriptModelExt)
set(_TEST1_EXPORTED_CPP "${CMAKE_CURRENT_BINARY_DIR}/__exported_symbols_test_gamesys.cpp")
defold_create_exported_symbols_file("${_TEST1_EXPORTED_CPP}" "${_TEST1_SYMBOLS}")

defold_add_executable(test_gamesys ${TEST_GS_SOURCES} ${_TEST1_EXPORTED_CPP} ${_EMBED_HEADERS} ${_EMBED_CPP})
add_dependencies(test_gamesys gamesys_test_content)
target_include_directories(test_gamesys PRIVATE "${GS_SRC_ROOT}" "${GS_PROTO_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
set(_DEFOLD_TEST_LIBS
  testmain test_script dlib mbedtls zip ddf resource gameobject extension script input
  particle rig gui liveupdate graphics_null profile_null platform_null hid_null
  physics render render_font_default font sound_null box2d_defold)


target_link_libraries(test_gamesys PRIVATE gamesys gamesys_rig gamesys_model)
defold_target_link_libraries(test_gamesys ${TARGET_PLATFORM} ${_DEFOLD_TEST_LIBS})
defold_target_link_bullet3d(test_gamesys ${TARGET_PLATFORM})
defold_target_link_lua(test_gamesys ${TARGET_PLATFORM})
defold_target_link_glfw(test_gamesys ${TARGET_PLATFORM})
defold_target_link_platform(test_gamesys ${TARGET_PLATFORM})
defold_target_link_socket(test_gamesys ${TARGET_PLATFORM})
defold_target_link_graphics(test_gamesys ${TARGET_PLATFORM})
defold_target_link_app(test_gamesys ${TARGET_PLATFORM})
defold_register_test_target(test_gamesys ON "${CMAKE_CURRENT_BINARY_DIR}")

defold_target_link_libraries_web(test_gamesys ${TARGET_PLATFORM} SCOPE PRIVATE
  library_sys.js library_script.js library_render.js)

# ---------------------------------------------------------------------------
# test_gamesys_physics
# ---------------------------------------------------------------------------
set(TEST_GS_PHYS_SOURCES
  "${GS_TEST_ROOT}/test_gamesys_physics.cpp"
)
set(_TEST2_SYMBOLS ${_COMMON_EXPORTED};ScriptModelExt)
set(_TEST2_EXPORTED_CPP "${CMAKE_CURRENT_BINARY_DIR}/__exported_symbols_test_gamesys_physics.cpp")
defold_create_exported_symbols_file("${_TEST2_EXPORTED_CPP}" "${_TEST2_SYMBOLS}")

defold_add_executable(test_gamesys_physics ${TEST_GS_PHYS_SOURCES} ${_TEST2_EXPORTED_CPP} ${_EMBED_HEADERS} ${_EMBED_CPP})
add_dependencies(test_gamesys_physics gamesys_test_content)
target_include_directories(test_gamesys_physics PRIVATE "${GS_SRC_ROOT}" "${GS_PROTO_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(test_gamesys_physics PRIVATE gamesys gamesys_rig gamesys_model)
defold_target_link_libraries(test_gamesys_physics ${TARGET_PLATFORM} ${_DEFOLD_TEST_LIBS})
defold_target_link_bullet3d(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_lua(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_glfw(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_platform(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_socket(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_graphics(test_gamesys_physics ${TARGET_PLATFORM})
defold_target_link_app(test_gamesys_physics ${TARGET_PLATFORM})
defold_register_test_target(test_gamesys_physics ON "${CMAKE_CURRENT_BINARY_DIR}")

defold_target_link_libraries_web(test_gamesys_physics ${TARGET_PLATFORM} SCOPE PRIVATE
  library_sys.js library_script.js library_render.js)

# ---------------------------------------------------------------------------
# test_gamesys_http (not for web targets)
# ---------------------------------------------------------------------------
if(NOT TARGET_PLATFORM MATCHES "^(js-web|wasm-web|wasm_pthread-web)$")
  set(TEST_GS_HTTP_SOURCES "${GS_TEST_ROOT}/test_gamesys_http.cpp")
  set(_TEST3_SYMBOLS ${_COMMON_EXPORTED})
  set(_TEST3_EXPORTED_CPP "${CMAKE_CURRENT_BINARY_DIR}/__exported_symbols_test_gamesys_http.cpp")
  defold_create_exported_symbols_file("${_TEST3_EXPORTED_CPP}" "${_TEST3_SYMBOLS}")

  defold_add_executable(test_gamesys_http ${TEST_GS_HTTP_SOURCES} ${_TEST3_EXPORTED_CPP})
  add_dependencies(test_gamesys_http gamesys_test_content)
  target_include_directories(test_gamesys_http PRIVATE "${GS_SRC_ROOT}" "${GS_PROTO_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(test_gamesys_http PRIVATE gamesys gamesys_rig_null gamesys_model_null)
  defold_target_link_libraries(test_gamesys_http ${TARGET_PLATFORM} ${_DEFOLD_TEST_LIBS})
  defold_target_link_bullet3d(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_lua(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_glfw(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_platform(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_socket(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_graphics(test_gamesys_http ${TARGET_PLATFORM})
  defold_target_link_app(test_gamesys_http ${TARGET_PLATFORM})
  defold_register_test_target(test_gamesys_http ON "${CMAKE_CURRENT_BINARY_DIR}")
  defold_register_test_with_server(test_gamesys_http ${TARGET_PLATFORM} PORT 9001 WORKDIR "${CMAKE_CURRENT_BINARY_DIR}")
endif()
