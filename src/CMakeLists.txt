# ============================================================================
#  Builds the wasmtime C API as a shared library for `package:webassembly`.
#
#  Everything platform specific already lives in wasmtime's own CMake project
#  (`wasmtime/crates/c-api/CMakeLists.txt`): locating cargo, resolving the Rust
#  target triple, choosing the build profile, naming the artifact, generating
#  `wasmtime/conf.h` and installing the result.  This file selects the features
#  we want, makes sure cargo can find its toolchain, and asks for a shared
#  library.
#
#  `hook/build.dart` drives it through package:native_toolchain_cmake on every
#  Flutter/Dart build.
# ============================================================================
cmake_minimum_required(VERSION 3.20)
project(webassembly_wasmtime LANGUAGES C)

# ---------------------------------------------------------------------------
# Rust toolchain environment
#
# `cargo` and `rustc` are normally rustup shims, and rustup needs RUSTUP_HOME to
# find its toolchains and CARGO_HOME to find the crate registry.  The hook
# runners of the Dart and Flutter SDKs invoke build hooks with a reduced
# environment that contains neither, so the shims would fail with
# "rustup could not choose a version of rustc to run, because one wasn't
# specified explicitly, and no default is configured".
#
# Cargo already has to be located here, so work the homes out from its location
# and hand them to the cargo invocation that wasmtime's CMakeLists builds
# (`cmake -E env ${WASMTIME_BUILD_ENV} cargo build ...`).  Both are left alone
# when they are already in the environment or when cargo is not a rustup shim
# (in which case nothing has to be forwarded).
# ---------------------------------------------------------------------------
find_program(WEBASSEMBLY_CARGO
  NAMES cargo cargo.exe
  HINTS "$ENV{CARGO_HOME}/bin" "$ENV{USERPROFILE}/.cargo/bin" "$ENV{HOME}/.cargo/bin"
  DOC "cargo executable used to build the wasmtime crates")
if(NOT WEBASSEMBLY_CARGO)
  message(FATAL_ERROR
    "cargo was not found on PATH. Install Rust (https://rustup.rs) or pass "
    "-DWEBASSEMBLY_CARGO=/path/to/cargo.")
endif()
get_filename_component(_cargo_bin_dir "${WEBASSEMBLY_CARGO}" DIRECTORY)
get_filename_component(_cargo_home "${_cargo_bin_dir}" DIRECTORY)

# <CARGO_HOME>/bin/cargo is the shim, and a used cargo home has a registry.
set(WEBASSEMBLY_CARGO_HOME "$ENV{CARGO_HOME}")
if(WEBASSEMBLY_CARGO_HOME STREQUAL "" AND
   (IS_DIRECTORY "${_cargo_home}/registry" OR EXISTS "${_cargo_home}/config.toml"))
  set(WEBASSEMBLY_CARGO_HOME "${_cargo_home}")
endif()

# rustup keeps its data beside CARGO_HOME, or in the user profile by default.
# Only a home that has both a configured default toolchain (`settings.toml`) and
# that toolchain actually installed is accepted: rustup also creates empty
# skeleton homes, and a `$HOME/.rustup` can hold toolchains that no profile
# selects (`rustc` then reports "no default is configured").
set(WEBASSEMBLY_RUSTUP_HOME "$ENV{RUSTUP_HOME}")
if(WEBASSEMBLY_RUSTUP_HOME STREQUAL "")
  # `*` does not match dot files, so the usual `~/.rustup` has to be named -
  # which is where CI runners and most Linux and macOS machines keep it.
  file(GLOB _rustup_candidates
       LIST_DIRECTORIES true
       "${_cargo_home}" "${_cargo_home}/.." "${_cargo_home}/../*"
       "${_cargo_home}/../.rustup" "${_cargo_home}/../.cargo"
       "$ENV{USERPROFILE}/.rustup" "$ENV{HOME}/.rustup")
  foreach(_candidate IN LISTS _rustup_candidates)
    file(GLOB _installed_toolchains LIST_DIRECTORIES true "${_candidate}/toolchains/*")
    if(EXISTS "${_candidate}/settings.toml" AND _installed_toolchains)
      set(WEBASSEMBLY_RUSTUP_HOME "${_candidate}")
      break()
    endif()
  endforeach()
endif()

foreach(_var CARGO_HOME RUSTUP_HOME)
  if(WEBASSEMBLY_${_var})
    message(STATUS "webassembly: ${_var} = ${WEBASSEMBLY_${_var}}")
    list(APPEND WASMTIME_BUILD_ENV "${_var}=${WEBASSEMBLY_${_var}}")
  endif()
endforeach()

# Upstream probes `rustc -vV` for the host triple, which needs the same
# environment.  Provide WASMTIME_TARGET up front so that probe is skipped; if
# this fails (no rustup involved) upstream's own probe runs instead.
if(NOT WASMTIME_TARGET AND WEBASSEMBLY_RUSTUP_HOME)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "RUSTUP_HOME=${WEBASSEMBLY_RUSTUP_HOME}" rustc -vV
    OUTPUT_VARIABLE _rustc_version
    ERROR_QUIET
    RESULT_VARIABLE _rustc_status)
  if(_rustc_status EQUAL 0 AND _rustc_version MATCHES "host: ([A-Za-z0-9_.-]+)")
    set(WASMTIME_TARGET "${CMAKE_MATCH_1}" CACHE STRING "" FORCE)
    message(STATUS "webassembly: rust target = ${WASMTIME_TARGET}")
  endif()
endif()

# ---------------------------------------------------------------------------
# wasmtime features
# ---------------------------------------------------------------------------

# Build cargo's cdylib (`wasmtime.dll` / `libwasmtime.so` / `libwasmtime.dylib`).
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)

# Start from "no features at all" and switch on exactly what we need instead of
# inheriting the generous defaults of `cmake/features.cmake`.
set(WASMTIME_DISABLE_ALL_FEATURES ON CACHE BOOL "" FORCE)
foreach(feature
    cranelift threads async
    component-model component-model-async
    cache parallel-compilation pooling-allocator
    gc gc-drc gc-null
    demangle addr2line coredump)
  string(TOUPPER "${feature}" wasmtime_feature)
  string(REPLACE "-" "_" wasmtime_feature "${wasmtime_feature}")
  set(WASMTIME_FEATURE_${wasmtime_feature} ON CACHE BOOL "" FORCE)
endforeach()

# `gc-copying` exists in `wasmtime/crates/c-api/Cargo.toml` but has no
# WASMTIME_FEATURE_* switch in `cmake/features.cmake` yet, so it goes straight
# to cargo.
set(WASMTIME_USER_CARGO_BUILD_OPTIONS "--features=gc-copying" CACHE STRING "" FORCE)

# ---------------------------------------------------------------------------
# Where the wasmtime sources are
#
# They are not part of this package: the build hook resolves a checkout - the
# submodule of the source repository while developing, a pinned download from
# the user level cache otherwise - and passes it in.  A hand-run configure falls
# back to the submodule next to this file.
# ---------------------------------------------------------------------------
set(WASMTIME_URL "https://github.com/bytecodealliance/wasmtime"
    CACHE STRING "where the sources come from")
set(WASMTIME_REVISION "5af334209f6a230c167f836bcbfdef5fa8cbad01"
    CACHE STRING "the revision built here")
set(WASMTIME_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../wasmtime"
    CACHE PATH "checkout of ${WASMTIME_URL} at ${WASMTIME_REVISION}")
if(NOT EXISTS "${WASMTIME_SOURCE_DIR}/crates/c-api/CMakeLists.txt")
  message(FATAL_ERROR
    "WASMTIME_SOURCE_DIR (${WASMTIME_SOURCE_DIR}) does not contain the wasmtime "
    "C API. Use the wasmtime submodule, or clone ${WASMTIME_URL} at "
    "${WASMTIME_REVISION} and pass -DWASMTIME_SOURCE_DIR=<checkout>.")
endif()

add_subdirectory("${WASMTIME_SOURCE_DIR}/crates/c-api"
                 "${CMAKE_CURRENT_BINARY_DIR}/wasmtime-c-api")

# ---------------------------------------------------------------------------
# Expose the generated `wasmtime/conf.h`
#
# `wasmtime.h` includes <wasmtime/conf.h>, which selects the parts of the C API
# that are compiled in.  Keep a copy at a stable path inside the build directory
# so `dart run ffigen --config ffigen.yaml` (whose `compiler-opts` adds
# `-Ibuild/ffigen/include`) sees exactly the feature set selected above,
# whatever build directory CMake was pointed at.
# ---------------------------------------------------------------------------
file(MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../build/ffigen/include/wasmtime")
configure_file(
  "${CMAKE_CURRENT_BINARY_DIR}/wasmtime-c-api/include/wasmtime/conf.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../build/ffigen/include/wasmtime/conf.h"
  COPYONLY)
