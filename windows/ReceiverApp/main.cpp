// CRITICAL: winsock2.h must be included BEFORE windows.h
#define WIN32_LEAN_AND_MEAN
#include "../common/SharedMemory.h"
#include <iostream>
#include <vector>
#include <windows.h>
#include <winsock2.h>


// Link against Ws2_32.lib
#pragma comment(lib, "Ws2_32.lib")

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

}

// Global AV variables
AVCodecContext *codecCtx = nullptr;
AVCodecParserContext *parser = nullptr;
AVFrame *pFrame = nullptr;
AVFrame *pFrameRGB = nullptr;
SwsContext *sws_ctx = nullptr;
HANDLE hMapFile = NULL;
SharedMemoryLayout *pSharedMem = nullptr;

void cleanup() {
  if (pFrame)
    av_frame_free(&pFrame);
  if (pFrameRGB)
    av_frame_free(&pFrameRGB);
  if (codecCtx)
    avcodec_free_context(&codecCtx);
  if (parser)
    av_parser_close(parser);
  if (pSharedMem)
    UnmapViewOfFile(pSharedMem);
  if (hMapFile)
    CloseHandle(hMapFile);
  WSACleanup();
}

void init_ffmpeg() {
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
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
  int numBytes =
      av_image_get_buffer_size(AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);
  uint8_t *buffer = (uint8_t *)av_malloc(numBytes * sizeof(uint8_t));
  av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, buffer,
                       AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);

  sws_ctx = sws_getContext(VIDEO_WIDTH, VIDEO_HEIGHT, AV_PIX_FMT_YUV420P,
                           VIDEO_WIDTH, VIDEO_HEIGHT, AV_PIX_FMT_BGRA,
                           SWS_BILINEAR, NULL, NULL, NULL);
}

void init_shared_memory() {
  hMapFile = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                sizeof(SharedMemoryLayout), SHARED_MEMORY_NAME);

  if (hMapFile == NULL) {
    std::cerr << "Could not create file mapping object (" << GetLastError()
              << ").\n";
    exit(1);
  }

  pSharedMem = (SharedMemoryLayout *)MapViewOfFile(
      hMapFile, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedMemoryLayout));

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

// NAL start code for Annex B format (required by FFmpeg H.264 decoder)
static const uint8_t NAL_START_CODE[] = {0x00, 0x00, 0x00, 0x01};

// Decode function taking raw NAL buf (adds start code for FFmpeg)
void decode_frame(uint8_t *data, int size) {
  // Create buffer with NAL start code prepended
  std::vector<uint8_t> nalWithStartCode(4 + size);
  memcpy(nalWithStartCode.data(), NAL_START_CODE, 4);
  memcpy(nalWithStartCode.data() + 4, data, size);

  uint8_t *outData = nullptr;
  int outSize = 0;

  // Use Parser to assemble frames from NALUs
  av_parser_parse2(parser, codecCtx, &outData, &outSize,
                   nalWithStartCode.data(), nalWithStartCode.size(),
                   AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);

  if (outSize > 0) {
    AVPacket *pkt = av_packet_alloc();
    pkt->data = outData;
    pkt->size = outSize;

    if (avcodec_send_packet(codecCtx, pkt) == 0) {
      while (avcodec_receive_frame(codecCtx, pFrame) == 0) {
        // Convert to RGB
        sws_scale(sws_ctx, (uint8_t const *const *)pFrame->data,
                  pFrame->linesize, 0, codecCtx->height, pFrameRGB->data,
                  pFrameRGB->linesize);

        // Write to Shared Memory
        if (pSharedMem) {
          memcpy(pSharedMem->data, pFrameRGB->data[0], FRAME_BUFFER_SIZE);
          pSharedMem->write_sequence++;
          // Use \r to overwrite line
          std::cout << "Frame Decoded: " << pSharedMem->write_sequence << "\r"
                    << std::flush;
        }
      }
    }
    av_packet_free(&pkt);
  }
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

  bind(ListenSocket, (SOCKADDR *)&service, sizeof(service));
  listen(ListenSocket, 1);

  std::cout << "========================================\n";
  std::cout << "   AntigravityCam Windows Receiver\n";
  std::cout << "========================================\n";
  std::cout << "Status: WAITING\n";
  std::cout << "Listening on port 5000...\n\n";

  // Accept connection and get client IP
  sockaddr_in clientAddr;
  int clientAddrLen = sizeof(clientAddr);
  SOCKET ClientSocket =
      accept(ListenSocket, (SOCKADDR *)&clientAddr, &clientAddrLen);

  // Get client IP address
  char *clientIP = inet_ntoa(clientAddr.sin_addr);
  int clientPort = ntohs(clientAddr.sin_port);

  std::cout << "========================================\n";
  std::cout << "Status: CONNECTED\n";
  std::cout << "iPhone IP: " << clientIP << ":" << clientPort << "\n";
  std::cout << "========================================\n\n";
  // Receiving Loop
  // Protocol: [4 byte length][data]

  char lenBuf[4];
  while (true) {
    // Read Length
    int bytesReceived = recv(ClientSocket, lenBuf, 4, 0);
    if (bytesReceived <= 0)
      break;

    uint32_t netLen = *(uint32_t *)lenBuf;
    uint32_t len = ntohl(netLen);

    // DEBUG: Print received size to confirm data flow
    // std::cout << "Received " << len << " bytes" << "\r" << std::flush;

    // Read Data
    std::vector<uint8_t> buf(len);
    uint32_t totalRead = 0;
    while (totalRead < len) {
      int r = recv(ClientSocket, (char *)buf.data() + totalRead,
                   len - totalRead, 0);
      if (r <= 0)
        goto end_conn;
      totalRead += r;
    }

    decode_frame(buf.data(), len);
  }

end_conn:
  std::cout << "\n========================================\n";
  std::cout << "Status: DISCONNECTED\n";
  std::cout << "========================================\n";
  cleanup();
  return 0;
}
