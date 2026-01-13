// CRITICAL: winsock2.h must be included BEFORE windows.h
#define WIN32_LEAN_AND_MEAN
#include "../common/SharedMemory.h"
#include <atomic>
#include <iostream>
#include <mutex>
#include <thread>
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

// UI & Threading globals
HWND hWindow = NULL;
std::mutex frameMutex;
std::atomic<bool> isRunning(true);
std::atomic<bool> isConnected(false);

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

  sws_ctx =
      sws_getContext(VIDEO_WIDTH, VIDEO_HEIGHT, AV_PIX_FMT_YUV420P, VIDEO_WIDTH,
                     VIDEO_HEIGHT, AV_PIX_FMT_BGRA, SWS_BICUBIC, NULL, NULL,
                     NULL); // BICUBIC for better quality
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

// Connection / Stream State
std::atomic<bool> hasSeenKeyframe(false);

// Decode function taking raw NAL buf (adds start code for FFmpeg)
void decode_frame(uint8_t *data, int size) {
  if (size <= 0)
    return;

  // Simple NAL Unit Type Check (first byte & 0x1F)
  int nalType = data[0] & 0x1F;

  // SPS (7), PPS (8), IDR (5) are critical for starting playback
  if (nalType == 7 || nalType == 8 || nalType == 5) {
    if (!hasSeenKeyframe) {
      std::cout << " [Keyframe/Header Found! Syncing Stream...] \n";
      hasSeenKeyframe = true;
    }
  }

  // If we haven't seen a keyframe yet, drop this packet to avoid artifacts
  if (!hasSeenKeyframe) {
    return;
  }

  // Create buffer with NAL start code prepended + Padding
  std::vector<uint8_t> nalWithStartCode(4 + size +
                                        AV_INPUT_BUFFER_PADDING_SIZE);
  memcpy(nalWithStartCode.data(), NAL_START_CODE, 4);
  memcpy(nalWithStartCode.data() + 4, data, size);
  // Zero out padding
  memset(nalWithStartCode.data() + 4 + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);

  uint8_t *outData = nullptr;
  int outSize = 0;

  // Use Parser to assemble frames from NALUs
  av_parser_parse2(parser, codecCtx, &outData, &outSize,
                   nalWithStartCode.data(), 4 + size, AV_NOPTS_VALUE,
                   AV_NOPTS_VALUE, 0);

  if (outSize > 0) {
    AVPacket *pkt = av_packet_alloc();
    pkt->data = outData;
    pkt->size = outSize;

    int sendResult = avcodec_send_packet(codecCtx, pkt);
    if (sendResult < 0) {
      char errBuf[256];
      av_strerror(sendResult, errBuf, sizeof(errBuf));
      std::cerr << "Decode Error: " << errBuf << "\n";
    } else {
      while (avcodec_receive_frame(codecCtx, pFrame) == 0) {
        // DEBUG: Print actual format from decoder (once)
        static bool formatPrinted = false;
        if (!formatPrinted) {
          std::cout << "Decoded frame format: "
                    << av_get_pix_fmt_name((AVPixelFormat)pFrame->format)
                    << " (" << pFrame->width << "x" << pFrame->height << ")\n";
          formatPrinted = true;
        }
        // Convert to RGB
        {
          std::lock_guard<std::mutex> lock(frameMutex);
          sws_scale(sws_ctx, (uint8_t const *const *)pFrame->data,
                    pFrame->linesize, 0, codecCtx->height, pFrameRGB->data,
                    pFrameRGB->linesize);

          // Write to Shared Memory inside the lock as well to be safe
          if (pSharedMem) {
            memcpy(pSharedMem->data, pFrameRGB->data[0], FRAME_BUFFER_SIZE);
            pSharedMem->write_sequence++;
          }
        } // mutex unlocks here

        // Request UI Repaint
        if (hWindow) {
          InvalidateRect(hWindow, NULL, FALSE);
        }
      }
    }
    av_packet_free(&pkt);
  }
}

void receiver_thread_func() {
  SOCKET ListenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  sockaddr_in service;
  service.sin_family = AF_INET;
  service.sin_addr.s_addr = INADDR_ANY;
  service.sin_port = htons(5000);

  if (bind(ListenSocket, (SOCKADDR *)&service, sizeof(service)) ==
      SOCKET_ERROR) {
    std::cerr << "Bind failed.\n";
    return;
  }

  if (listen(ListenSocket, 1) == SOCKET_ERROR) {
    std::cerr << "Listen failed.\n";
    return;
  }

  std::cout << "Waiting for connection on port 5000...\n";

  while (isRunning) {
    sockaddr_in clientAddr;
    int clientAddrLen = sizeof(clientAddr);
    SOCKET ClientSocket =
        accept(ListenSocket, (SOCKADDR *)&clientAddr, &clientAddrLen);

    if (ClientSocket == INVALID_SOCKET) {
      if (!isRunning)
        break;
      continue;
    }

    // New Connection: Reset Stream State
    hasSeenKeyframe = false;
    // Flush decoder to remove any old reference frames or stale state
    if (codecCtx) {
      avcodec_flush_buffers(codecCtx);
    }
    std::cout << "DEBUG: Waiting for Keyframe/SPS/PPS...\n";

    char *clientIP = inet_ntoa(clientAddr.sin_addr);
    int clientPort = ntohs(clientAddr.sin_port);
    std::cout << "Connected: " << clientIP << ":" << clientPort << "\n";
    isConnected = true;

    // Update Window Title to show status
    if (hWindow)
      SetWindowTextA(hWindow, "AntigravityCam Receiver - Connected");

    char lenBuf[4];
    while (isRunning) {
      int bytesReceived = recv(ClientSocket, lenBuf, 4, 0);
      if (bytesReceived <= 0)
        break;

      uint32_t netLen = *(uint32_t *)lenBuf;
      uint32_t len = ntohl(netLen);

      std::vector<uint8_t> buf(len);
      uint32_t totalRead = 0;
      bool connError = false;
      while (totalRead < len) {
        int r = recv(ClientSocket, (char *)buf.data() + totalRead,
                     len - totalRead, 0);
        if (r <= 0) {
          connError = true;
          break;
        }
        totalRead += r;
      }
      if (connError)
        break;

      decode_frame(buf.data(), len);
    }

    std::cout << "Disconnected.\n";
    isConnected = false;
    if (hWindow)
      SetWindowTextA(hWindow, "AntigravityCam Receiver - Waiting...");
    closesocket(ClientSocket);
  }

  closesocket(ListenSocket);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam,
                            LPARAM lParam) {
  switch (uMsg) {
  case WM_DESTROY:
    PostQuitMessage(0);
    return 0;

  case WM_PAINT: {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);

    // Draw the latest frame
    {
      std::lock_guard<std::mutex> lock(frameMutex);
      if (pFrameRGB && pFrameRGB->data[0]) {
        BITMAPINFO bmi = {0};
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = VIDEO_WIDTH;
        bmi.bmiHeader.biHeight = -VIDEO_HEIGHT; // Top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        SetDIBitsToDevice(hdc, 0, 0, VIDEO_WIDTH, VIDEO_HEIGHT, 0, 0, 0,
                          VIDEO_HEIGHT, pFrameRGB->data[0], &bmi,
                          DIB_RGB_COLORS);
      }
    }

    EndPaint(hwnd, &ps);
    return 0;
  }
  }
  return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

int main() {
  WSADATA wsaData;
  WSAStartup(MAKEWORD(2, 2), &wsaData);

  init_shared_memory();
  init_ffmpeg();

  // Create Window Class
  const wchar_t CLASS_NAME[] = L"AntigravityReceiverClass";
  WNDCLASSW wc = {};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = GetModuleHandle(NULL);
  wc.lpszClassName = CLASS_NAME;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);

  RegisterClassW(&wc);

  // Resize window to fit video content approximately (plus borders)
  RECT rect = {0, 0, VIDEO_WIDTH, VIDEO_HEIGHT};
  AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);

  hWindow = CreateWindowExW(
      0, CLASS_NAME, L"AntigravityCam Receiver - Waiting...",
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left,
      rect.bottom - rect.top, NULL, NULL, GetModuleHandle(NULL), NULL);

  if (hWindow == NULL) {
    return 0;
  }

  ShowWindow(hWindow, SW_SHOW);

  // Start Receiver Thread
  std::thread receiverThread(receiver_thread_func);

  // Message Loop
  MSG msg = {};
  while (GetMessage(&msg, NULL, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }

  isRunning = false;
  // receiverThread.join(); // May block if stuck in recv/accept, so we detach
  // or force close
  receiverThread.detach();

  cleanup();
  return 0;
}
