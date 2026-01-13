cmake_minimum_required(VERSION 3.10)
project(AntigravityCam)

set(CMAKE_CXX_STANDARD 17)

# Path to "baseclasses" directory
set(BASECLASSES_DIR "${CMAKE_CURRENT_SOURCE_DIR}/baseclasses") 

include_directories(${BASECLASSES_DIR})
include_directories(../common)

# Gather BaseClasses sources
file(GLOB BASECLASSES_SOURCES "${BASECLASSES_DIR}/*.cpp")

# Create BaseClasses Static Library
add_library(BaseClasses STATIC ${BASECLASSES_SOURCES})
target_compile_definitions(BaseClasses PRIVATE _LIB WIN32 UNICODE _UNICODE)

# Virtual Camera Filter (Shared Library / DLL)
add_library(AntigravityCam SHARED 
    CaptureSource.cpp 
    CaptureSource.h 
    AntigravityCam.def
)

# Link against BaseClasses and System Libs
target_link_libraries(AntigravityCam 
    BaseClasses
    winmm.lib 
    msvcrt.lib
    strmiids.lib
)
