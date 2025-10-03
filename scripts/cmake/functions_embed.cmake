defold_log("functions_embed.cmake:")

# Script-mode entry point to generate header content without creating
# temporary generator files. When invoked with -P on this file and with
# DEFOLD_EMBED_GENERATE=ON, it will read INPUT and write OUTPUT.
if(DEFINED DEFOLD_EMBED_GENERATE)
  if(NOT DEFINED INPUT OR NOT DEFINED OUTPUT OR NOT DEFINED SYM)
    message(FATAL_ERROR "functions_embed: Missing vars (INPUT/OUTPUT/SYM)")
  endif()
  # Ensure output directory exists
  get_filename_component(_outdir "${OUTPUT}" DIRECTORY)
  if(_outdir)
    file(MAKE_DIRECTORY "${_outdir}")
  endif()
  # Read input as hex and assemble header
  file(READ "${INPUT}" _data HEX)
  string(REGEX REPLACE "(..)" "0x\\1, " _hex_list "${_data}")
  file(WRITE "${OUTPUT}" "#pragma once\n")
  file(APPEND "${OUTPUT}" "#include <stdint.h>\n")
  file(APPEND "${OUTPUT}" "static const unsigned char ${SYM}[] = { ${_hex_list} };\n")
  file(SIZE "${INPUT}" _sz)
  file(APPEND "${OUTPUT}" "static const unsigned int ${SYM}_SIZE = (unsigned int)${_sz};\n")
  return()
endif()

# Generate embedded C sources for a binary file.
# Usage: defold_embed_to_header(<input_file> <output_header>)
# - Produces the given header and a sibling .cpp file (same name with .cpp).
function(defold_embed_to_header)
  # Keyword-style API with backwards compatibility for positional args.
  # Usage (preferred):
  #   defold_embed_to_header(INPUT <file> OUTPUT_HEADER <path> [OUTPUT_CPP <path>] [SYMBOL <name>]
  #                         [OUT_HEADER_VAR var] [OUT_CPP_VAR var])
  # Legacy positional still supported:
  #   defold_embed_to_header(<input_file> <output_header>)

  set(options)
  set(oneValueArgs INPUT OUTPUT_HEADER OUTPUT_CPP SYMBOL OUT_HEADER_VAR OUT_CPP_VAR)
  set(multiValueArgs)
  cmake_parse_arguments(EM "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(_in "")
  set(_out_h "")
  set(_out_cpp "")
  set(_sym "")

  if(EM_INPUT)
    set(_in "${EM_INPUT}")
    if(EM_OUTPUT_HEADER)
      set(_out_h "${EM_OUTPUT_HEADER}")
    endif()
    if(EM_OUTPUT_CPP)
      set(_out_cpp "${EM_OUTPUT_CPP}")
    endif()
    if(EM_SYMBOL)
      set(_sym "${EM_SYMBOL}")
    endif()
  else()
    # Positional fallback
    if(ARGC LESS 2)
      message(FATAL_ERROR "defold_embed_to_header: expected INPUT/OUTPUT_HEADER or two positional arguments")
    endif()
    list(GET ARGV 0 _in)
    list(GET ARGV 1 _out_h)
  endif()

  if(NOT _in)
    message(FATAL_ERROR "defold_embed_to_header: missing INPUT")
  endif()

  # Derive header path if not given: <binary dir>/<BASENAME>.embed.h
  if(NOT _out_h)
    get_filename_component(_in_base "${_in}" NAME)
    set(_out_h "${CMAKE_CURRENT_BINARY_DIR}/${_in_base}.embed.h")
  endif()

  # Derive symbol similar to waf embed_build
  if(NOT _sym)
    get_filename_component(_base "${_in}" NAME)
    string(TOUPPER "${_base}" _sym)
    string(REPLACE "." "_" _sym "${_sym}")
    string(REPLACE "-" "_" _sym "${_sym}")
    string(REPLACE "@" "at" _sym "${_sym}")
  endif()

  # Derive cpp path: replace .h with .cpp, else append .cpp
  if(NOT _out_cpp)
    set(_out_cpp "${_out_h}")
    if(_out_cpp MATCHES "\\.h(pp)?$")
      string(REGEX REPLACE "\\.h(pp)?$" ".cpp" _out_cpp "${_out_cpp}")
    else()
      set(_out_cpp "${_out_cpp}.cpp")
    endif()
  endif()

  # Locate python and the helper script
  find_program(_PY3 NAMES python3 python REQUIRED)
  # Use the directory of this module for robust pathing regardless of CWD
  set(_THIS_DIR "${CMAKE_CURRENT_LIST_DIR}")
  set(_BIN2CPP "${_THIS_DIR}/bin2cpp.py")
  if(NOT EXISTS "${_BIN2CPP}")
    # Fallback: try to resolve via module path search
    find_file(_BIN2CPP_ALT NAMES bin2cpp.py HINTS "${CMAKE_CURRENT_LIST_DIR}" ${CMAKE_MODULE_PATH})
    if(_BIN2CPP_ALT)
      set(_BIN2CPP "${_BIN2CPP_ALT}")
    endif()
  endif()
  if(NOT EXISTS "${_BIN2CPP}")
    message(FATAL_ERROR "functions_embed: Missing bin2cpp.py at ${_BIN2CPP}")
  endif()

  add_custom_command(
    OUTPUT "${_out_h}" "${_out_cpp}"
    COMMAND "${_PY3}" "${_BIN2CPP}" --input "${_in}" --out-h "${_out_h}" --out-cpp "${_out_cpp}" --symbol "${_sym}"
    DEPENDS "${_in}" "${_BIN2CPP}"
    VERBATIM)

  # Expose generated paths to caller if requested
  if(EM_OUT_HEADER_VAR)
    set(${EM_OUT_HEADER_VAR} "${_out_h}" PARENT_SCOPE)
  endif()
  if(EM_OUT_CPP_VAR)
    set(${EM_OUT_CPP_VAR} "${_out_cpp}" PARENT_SCOPE)
  endif()
endfunction()
