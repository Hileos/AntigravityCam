cmake_minimum_required(VERSION 3.10)
project(AntigravityCam)

set(CMAKE_CXX_STANDARD 17)

# Path to "baseclasses" directory from Windows SDK Samples or internal copy
set(BASECLASSES_DIR "${CMAKE_SOURCE_DIR}/baseclasses") 

include_directories(${BASECLASSES_DIR})
include_directories(../common)

add_library(AntigravityCam SHARED 
    CaptureSource.cpp 
    CaptureSource.h 
    AntigravityCam.def
)

link_directories(${BASECLASSES_DIR}/x64/Release) # Adjust based on build

target_link_libraries(AntigravityCam 
    strmbase.lib 
    winmm.lib 
    msvcrt.lib
)
