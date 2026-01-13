cmake_minimum_required(VERSION 3.15)
project(ReceiverApp)

set(CMAKE_CXX_STANDARD 17)

# Relative path to avoid space issues in absolute paths
set(FFMPEG_ROOT "../../ffmpeg")

message(STATUS "ReceiverApp FFMPEG_ROOT: ${FFMPEG_ROOT}")

include_directories("${FFMPEG_ROOT}/include")
include_directories("../common")

link_directories("${FFMPEG_ROOT}/lib")

add_executable(ReceiverApp main.cpp)

target_link_libraries(ReceiverApp 
    ws2_32 
    avcodec 
    avformat 
    avutil 
    swscale
)

# Auto-copy DLLs
add_custom_command(TARGET ReceiverApp POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${FFMPEG_ROOT}/bin
    $<TARGET_FILE_DIR:ReceiverApp>
    COMMENT "Copying FFmpeg DLLs to output directory..."
)
