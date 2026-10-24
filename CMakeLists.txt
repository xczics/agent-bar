cmake_minimum_required(VERSION 3.20)
project(agent-bar VERSION 0.0.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(AGENTBAR_BUILD_TESTS "Build unit tests" ON)
option(AGENTBAR_BUILD_BAR "Build the agent-bar floating window" ON)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# nlohmann/json, pinned. Set FETCHCONTENT_SOURCE_DIR_JSON to build offline.
include(FetchContent)
FetchContent_Declare(json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(json)

if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_compile_options(/W4 /utf-8)
else()
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# ---- core: platform-independent logic + POSIX/Win32 file store ----
add_library(agentbar_core STATIC
  core/src/status.cpp
  core/src/adapter.cpp
  core/src/placement.cpp
  core/src/config.cpp
  core/src/settings.cpp
  core/src/store.cpp)
target_include_directories(agentbar_core PUBLIC core/include)
target_link_libraries(agentbar_core PUBLIC nlohmann_json::nlohmann_json)
target_compile_definitions(agentbar_core PUBLIC AGENTBAR_VERSION="${PROJECT_VERSION}")

# ---- agent-status-hook ----
add_executable(agent-status-hook hook/main.cpp)
target_link_libraries(agent-status-hook PRIVATE agentbar_core)

# ---- agent-bar ----
if(AGENTBAR_BUILD_BAR AND APPLE)
  enable_language(OBJCXX)
  add_executable(agent-bar platform/mac/main.mm)
  target_link_libraries(agent-bar PRIVATE agentbar_core
    "-framework Cocoa" "-framework CoreServices" "-framework QuartzCore")
  target_compile_options(agent-bar PRIVATE -fobjc-arc)
endif()

# ---- tests ----
if(AGENTBAR_BUILD_TESTS)
  enable_testing()
  add_executable(core_tests tests/test_core.cpp)
  target_link_libraries(core_tests PRIVATE agentbar_core)
  add_test(NAME core_tests COMMAND core_tests)
endif()
