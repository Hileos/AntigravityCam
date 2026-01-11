#include <iostream>
#include <vector>
#include <winsock2.h>
#include <windows.h>
#include "../common/SharedMemory.h"

// Link against Ws2_32.lib
#pragma comment(lib, "Ws2_32.lib")

extern "C" {
    #include <libavcodec/avcodec.h>
    #include <libavformat/avformat.h>
    #include <libswscale/swscale.h>
    #include <libavutil/imgutils.h>
}

// Global AV variables
AVCodecContext* codecCtx = nullptr;
AVCodecParserContext* parser = nullptr;
AVFrame* pFrame = nullptr;
AVFrame* pFrameRGB = nullptr;
SwsContext* sws_ctx = nullptr;
HANDLE hMapFile = NULL;
SharedMemoryLayout* pSharedMem = nullptr;

void cleanup() {
    if (pFrame) av_frame_free(&pFrame);
    if (pFrameRGB) av_frame_free(&pFrameRGB);
    if (codecCtx) avcodec_free_context(&codecCtx);
    if (parser) av_parser_close(parser);
    if (pSharedMem) UnmapViewOfFile(pSharedMem);
    if (hMapFile) CloseHandle(hMapFile);
    WSACleanup();
}

void init_ffmpeg() {
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) {
        std::cerr << "Codec not found\n";
        exit(1);
    }

    parser = av_parser_init(codec->id);
    codecCtx = avcodec_alloc_context3(codec);
    
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        std::cerr << "Could not open codec\n";
        exit(1);
    }

    pFrame = av_frame_alloc();
    pFrameRGB = av_frame_alloc();

    // Prepare RGB Frame buffer
    int numBytes = av_image_get_buffer_size(AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);
    uint8_t* buffer = (uint8_t*)av_malloc(numBytes * sizeof(uint8_t));
    av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, buffer, AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);
    
    sws_ctx = sws_getContext(VIDEO_WIDTH, VIDEO_HEIGHT, AV_PIX_FMT_YUV420P,
                             VIDEO_WIDTH, VIDEO_HEIGHT, AV_PIX_FMT_BGRA,
                             SWS_BILINEAR, NULL, NULL, NULL);
}

void init_shared_memory() {
    hMapFile = CreateFileMappingA(
        INVALID_HANDLE_VALUE,
        NULL,
        PAGE_READWRITE,
        0,
        sizeof(SharedMemoryLayout),
        SHARED_MEMORY_NAME
    );

    if (hMapFile == NULL) {
        std::cerr << "Could not create file mapping object (" << GetLastError() << ").\n";
        exit(1);
    }

    pSharedMem = (SharedMemoryLayout*)MapViewOfFile(hMapFile, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedMemoryLayout));
    
    if (pSharedMem == NULL) {
        std::cerr << "Could not map view of file (" << GetLastError() << ").\n";
        CloseHandle(hMapFile);
        exit(1);
    }

    // Init Header
    pSharedMem->magic = 0x43424557; // 'WEBC'
    pSharedMem->version = 1;
    pSharedMem->width = VIDEO_WIDTH;
    pSharedMem->height = VIDEO_HEIGHT;
    pSharedMem->write_sequence = 0;
}



// Simpler decode function taking raw NAL buf
void decode_frame(uint8_t* data, int size) {
    AVPacket* pkt = av_packet_alloc();
    pkt->data = data;
    pkt->size = size;

    if (avcodec_send_packet(codecCtx, pkt) == 0) {
        while (avcodec_receive_frame(codecCtx, pFrame) == 0) {
            // Convert to RGB
            sws_scale(sws_ctx, (uint8_t const * const *)pFrame->data,
                      pFrame->linesize, 0, codecCtx->height,
                      pFrameRGB->data, pFrameRGB->linesize);

            // Write to Shared Memory
            if (pSharedMem) {
                // Copy line by line to handle potential padding differences (though with predefined size it might be contiguous)
                // For simplicity assuming packed:
                memcpy(pSharedMem->data, pFrameRGB->data[0], FRAME_BUFFER_SIZE);
                pSharedMem->write_sequence++;
                // std::cout << "Frame Decoded & Written: " << pSharedMem->write_sequence << "\r";
            }
        }
    }
    av_packet_free(&pkt);
}

int main() {
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);

    init_shared_memory();
    init_ffmpeg();

    SOCKET ListenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in service;
    service.sin_family = AF_INET;
    service.sin_addr.s_addr = INADDR_ANY;
    service.sin_port = htons(5000);

    bind(ListenSocket, (SOCKADDR*)&service, sizeof(service));
    listen(ListenSocket, 1);

    std::cout << "Waiting for iPhone on port 5000...\n";

    SOCKET ClientSocket = accept(ListenSocket, NULL, NULL);
    std::cout << "iPhone Connected!\n";

    // Receiving Loop
    // Protocol: [4 byte length][data]
    
    char lenBuf[4];
    while (true) {
        // Read Length
        int bytesReceived = recv(ClientSocket, lenBuf, 4, 0);
        if (bytesReceived <= 0) break;
        
        uint32_t netLen = *(uint32_t*)lenBuf;
        uint32_t len = ntohl(netLen);
        
        // Read Data
        std::vector<uint8_t> buf(len);
        uint32_t totalRead = 0;
        while (totalRead < len) {
            int r = recv(ClientSocket, (char*)buf.data() + totalRead, len - totalRead, 0);
            if (r <= 0) goto end_conn;
            totalRead += r;
        }

        decode_frame(buf.data(), len);
    }

end_conn:
    std::cout << "Connection closed.\n";
    cleanup();
    return 0;
}
