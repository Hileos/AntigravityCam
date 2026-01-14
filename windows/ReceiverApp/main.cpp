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

#include <ctime>
#include <fstream>
#include <iomanip>
#include <sstream>

std::ofstream debugFile;

void init_debug_log() {
  CreateDirectoryA("C:\\Users\\Hamza\\Documents\\Antigravity\\IOS Camrea "
                   "Potato Stream\\debug",
                   NULL);

  // Generate unique filename
  auto t = std::time(nullptr);
  auto tm = *std::localtime(&t);
  std::ostringstream oss;
  oss << "C:\\Users\\Hamza\\Documents\\Antigravity\\IOS Camrea Potato "
         "Stream\\debug\\log_"
      << std::put_time(&tm, "%Y%m%d_%H%M%S") << ".txt";

  debugFile.open(oss.str(), std::ios::out | std::ios::trunc);
  if (debugFile.is_open()) {
    debugFile << "Frame,Time,R,G,B\n";
    std::cout << "Debug Log: " << oss.str() << "\n";
  }
}

template <typename T> void log_msg(const T &msg) {
  std::cout << msg;
  if (debugFile.is_open()) {
    debugFile << "# " << msg;
    debugFile.flush();
  }
}

template <typename T> void log_err(const T &msg) {
  std::cerr << msg;
  if (debugFile.is_open()) {
    debugFile << "ERROR: " << msg;
    debugFile.flush();
  }
}

// Global AV variables
AVCodecContext *codecCtx = nullptr;
AVCodecParserContext *parser = nullptr;
AVFrame *pFrame = nullptr;
AVFrame *pFrameRGB = nullptr;
SwsContext *sws_ctx = nullptr;
uint8_t *pFrameRGBBuffer = nullptr; // Track RGB buffer for cleanup

// Decoding State
const AVCodec *codec = nullptr;

// Socket timeout in milliseconds (5 seconds)
const int SOCKET_TIMEOUT_MS = 5000;

HANDLE hMapFile = NULL;
SharedMemoryLayout *pSharedMem = nullptr;

// UI & Threading globals
HWND hWindow = NULL;
std::mutex frameMutex;
std::atomic<bool> isRunning(true);
std::atomic<bool> isConnected(false);

// FFmpeg Log Callback
void ffmpeg_log_callback(void *ptr, int level, const char *fmt, va_list vl) {
  if (level > AV_LOG_WARNING)
    return; // Only log warnings and above

  // Format the message
  char line[1024];
  vsnprintf(line, sizeof(line), fmt, vl);

  // Write to our log file
  log_msg(std::string("[FFMPEG] ") + line);
}

void cleanup() {
  if (debugFile.is_open())
    debugFile.close();
  if (sws_ctx)
    sws_freeContext(sws_ctx);
  if (pFrame)
    av_frame_free(&pFrame);
  if (pFrameRGB)
    av_frame_free(&pFrameRGB);
  if (pFrameRGBBuffer)
    av_free(pFrameRGBBuffer);
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

// NAL start code for Annex B format (required by FFmpeg H.264 decoder)
static const uint8_t NAL_START_CODE[] = {0x00, 0x00, 0x00, 0x01};

// Core initialization of decoder context (Software Only)
bool setup_decoder(const std::vector<uint8_t> &sps = {},
                   const std::vector<uint8_t> &pps = {}) {
  if (codecCtx) {
    avcodec_free_context(&codecCtx);
  }

  codecCtx = avcodec_alloc_context3(codec);
  if (!codecCtx) {
    std::cerr << "Could not allocate video codec context\n";
    return false;
  }

  // Set Extradata if provided
  if (!sps.empty() && !pps.empty()) {
    size_t extraSize = sps.size() + pps.size() + 8; // +8 for start codes
    codecCtx->extradata =
        (uint8_t *)av_malloc(extraSize + AV_INPUT_BUFFER_PADDING_SIZE);
    codecCtx->extradata_size = extraSize;

    uint8_t *ptr = codecCtx->extradata;
    memcpy(ptr, NAL_START_CODE, 4);
    ptr += 4;
    memcpy(ptr, sps.data(), sps.size());
    ptr += sps.size();
    memcpy(ptr, NAL_START_CODE, 4);
    ptr += 4;
    memcpy(ptr, pps.data(), pps.size());
    ptr += pps.size();

    memset(ptr, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    log_msg("Decoder configured with Extradata (SPS+PPS)\n");
  }

  // Software decoding configuration
  log_msg("Decoder Configured for SOFTWARE decoding\n");
  codecCtx->thread_count = 0; // Auto-detect optimal thread count

  if (avcodec_open2(codecCtx, codec, NULL) < 0) {
    std::cerr << "Could not open codec\n";
    return false;
  }
  return true;
}

void init_ffmpeg() {
  // Setup Logging
  av_log_set_callback(ffmpeg_log_callback);
  av_log_set_level(AV_LOG_WARNING);

  codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  if (!codec) {
    std::cerr << "Codec not found\n";
    exit(1);
  }

  log_msg("Using H.264 software decoder\n");

  setup_decoder();

  pFrame = av_frame_alloc();
  pFrameRGB = av_frame_alloc();

  // Prepare RGB Frame buffer
  int numBytes =
      av_image_get_buffer_size(AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);
  pFrameRGBBuffer = (uint8_t *)av_malloc(numBytes * sizeof(uint8_t));
  av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, pFrameRGBBuffer,
                       AV_PIX_FMT_BGRA, VIDEO_WIDTH, VIDEO_HEIGHT, 1);

  sws_ctx = NULL;
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
  pSharedMem->version = 2;        // Version 2: double-buffered
  pSharedMem->width = VIDEO_WIDTH;
  pSharedMem->height = VIDEO_HEIGHT;
  pSharedMem->write_sequence = 0;
  pSharedMem->active_buffer = 0;
}

// Connection / Stream State
std::atomic<bool> hasSeenKeyframe(false);
bool isDecoderConfiguredWithHeaders = false;

// SPS/PPS Cache for bundling with IDR
std::vector<uint8_t> sps_cache;
std::vector<uint8_t> pps_cache;
static int send_packet_err_count = 0;

// Decode function taking raw NAL buf (adds start code for FFmpeg)
void decode_frame(uint8_t *data, int size) {
  if (size <= 0)
    return;

  // Simple NAL Unit Type Check (first byte & 0x1F)
  int nalType = data[0] & 0x1F;

  if (nalType == 7)
    log_msg("NAL: SPS (7) found\n");
  else if (nalType == 8)
    log_msg("NAL: PPS (8) found\n");
  else if (nalType == 5)
    log_msg("NAL: IDR (5) found\n");

  // SPS (7), PPS (8), IDR (5) are critical for starting playback
  if (nalType == 7 || nalType == 8 || nalType == 5) {
    if (!hasSeenKeyframe) {
      log_msg(" [Keyframe/Header Found! Syncing Stream...] \n");
      hasSeenKeyframe = true;
    }
  }

  // If we haven't seen a keyframe yet, drop this packet to avoid artifacts
  if (!hasSeenKeyframe) {
    return;
  }

  // Handle SPS/PPS Caching
  if (nalType == 7) {
    sps_cache.assign(data, data + size);
    return; // Wait for IDR to bundle
  }
  if (nalType == 8) {
    pps_cache.assign(data, data + size);
    return; // Wait for IDR to bundle
  }

  // Prepare Payload
  std::vector<uint8_t> payload;
  payload.reserve(size + 1024);

  // If IDR, prepend SPS/PPS if available
  if (nalType == 5) {
    // LAZY INIT: If we have SPS/PPS but haven't configured decoder with
    // them yet, do it now.
    if (!isDecoderConfiguredWithHeaders && !sps_cache.empty() &&
        !pps_cache.empty()) {
      log_msg("Re-initializing Decoder with SPS/PPS Extradata...\n");
      setup_decoder(sps_cache, pps_cache);
      isDecoderConfiguredWithHeaders = true;
    }

    if (!sps_cache.empty()) {
      payload.insert(payload.end(), NAL_START_CODE, NAL_START_CODE + 4);
      payload.insert(payload.end(), sps_cache.begin(), sps_cache.end());
    }
    if (!pps_cache.empty()) {
      payload.insert(payload.end(), NAL_START_CODE, NAL_START_CODE + 4);
      payload.insert(payload.end(), pps_cache.begin(), pps_cache.end());
    }
  }

  // Add Start Code + Current NAL
  payload.insert(payload.end(), NAL_START_CODE, NAL_START_CODE + 4);
  payload.insert(payload.end(), data, data + size);

  // Actual data size without padding
  size_t actualSize = payload.size();

  // Direct Send to Decoder
  AVPacket *pkt = av_packet_alloc();
  if (!pkt) {
    std::cerr << "OOM: Could not allocate packet struct\n";
    return;
  }

  if (av_new_packet(pkt, actualSize) < 0) {
    std::cerr << "OOM: Could not allocate packet buffer\n";
    av_packet_free(&pkt);
    return;
  }

  memcpy(pkt->data, payload.data(), actualSize);
  memset(pkt->data + actualSize, 0, AV_INPUT_BUFFER_PADDING_SIZE);

  // Set Flags
  if (nalType == 5) {
    pkt->flags |= AV_PKT_FLAG_KEY;
  }

  int sendRes = avcodec_send_packet(codecCtx, pkt);
  if (sendRes < 0) {
    send_packet_err_count++;
    if (send_packet_err_count % 100 == 1) {
      char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
      av_strerror(sendRes, errbuf, AV_ERROR_MAX_STRING_SIZE);
      std::string errmsg =
          "Error sending packet: " + std::string(errbuf) + "\n";
      log_err(errmsg);
    }
  } else {
    int recvRes = 0;
    while (true) {
      recvRes = avcodec_receive_frame(codecCtx, pFrame);
      if (recvRes == AVERROR(EAGAIN) || recvRes == AVERROR_EOF) {
        break;
      }
      if (recvRes < 0) {
        char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(recvRes, errbuf, AV_ERROR_MAX_STRING_SIZE);
        static int recv_err_count = 0;
        recv_err_count++;
        if (recv_err_count % 100 == 1) {
          log_err("Error receiving frame: " + std::string(errbuf) + "\n");
        }
        break;
      }

      // Convert to RGB
      {
        std::lock_guard<std::mutex> lock(frameMutex);

        // Re-initialize scaler if format/size changes
        static int cached_format = -1;
        static int cached_w = -1;
        static int cached_h = -1;

        if (cached_format != pFrame->format || cached_w != pFrame->width ||
            cached_h != pFrame->height) {
          if (sws_ctx)
            sws_freeContext(sws_ctx);
          sws_ctx = sws_getContext(VIDEO_WIDTH, VIDEO_HEIGHT,
                                   (AVPixelFormat)pFrame->format, VIDEO_WIDTH,
                                   VIDEO_HEIGHT, AV_PIX_FMT_BGRA, SWS_BILINEAR,
                                   NULL, NULL, NULL);
          cached_format = pFrame->format;
          cached_w = pFrame->width;
          cached_h = pFrame->height;
        }

        if (sws_ctx) {
          sws_scale(sws_ctx, (uint8_t const *const *)pFrame->data,
                    pFrame->linesize, 0, codecCtx->height, pFrameRGB->data,
                    pFrameRGB->linesize);
        }

        // DEBUG: Sample Pixel (32, 32)
        static int debugFrameCount = 0;
        static uint8_t lastR = 0, lastG = 0, lastB = 0;
        debugFrameCount++;

        if (pFrameRGB->data[0]) {
          int x = 32;
          int y = 32;
          int linesize = pFrameRGB->linesize[0];
          // BGRA format: B, G, R, A
          uint8_t *ptr = pFrameRGB->data[0] + (y * linesize) + (x * 4);
          uint8_t b = ptr[0];
          uint8_t g = ptr[1];
          uint8_t r = ptr[2];

          bool changed = (abs(r - lastR) > 10 || abs(g - lastG) > 10 ||
                          abs(b - lastB) > 10);

          if (changed || (debugFrameCount % 30 == 0)) {
            if (changed)
              std::cout << "[Pattern Change] ";
            std::cout << "Pixel(32,32): RGB(" << (int)r << "," << (int)g << ","
                      << (int)b << ")\n";

            // Log to file
            if (debugFile.is_open()) {
              debugFile << debugFrameCount << "," << (int)r << "," << (int)g
                        << "," << (int)b << "\n";
              debugFile.flush();
            }

            lastR = r;
            lastG = g;
            lastB = b;
          }
        }

        // Write to Shared Memory (double-buffered)
        if (pSharedMem) {
          // Write to inactive buffer
          uint32_t writeBuffer = pSharedMem->active_buffer ^ 1;
          memcpy(pSharedMem->data[writeBuffer], pFrameRGB->data[0],
                 FRAME_BUFFER_SIZE);

          // Memory barrier to ensure write completes before updating index
          _ReadWriteBarrier();

          // Atomically switch to new buffer
          pSharedMem->active_buffer = writeBuffer;
          pSharedMem->write_sequence++;
        }
      }

      // Request UI Repaint
      if (hWindow) {
        InvalidateRect(hWindow, NULL, FALSE);
      }
    }
  }
  av_packet_free(&pkt);
}

// Helper to receive exact amount of data
bool recv_all(SOCKET s, void *buf, int len) {
  char *ptr = (char *)buf;
  int total = 0;
  while (total < len) {
    int r = recv(s, ptr + total, len - total, 0);
    if (r <= 0) {
      return false;
    }
    total += r;
  }
  return true;
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

    // Set socket receive timeout to detect dead connections
    setsockopt(ClientSocket, SOL_SOCKET, SO_RCVTIMEO,
               (const char *)&SOCKET_TIMEOUT_MS, sizeof(SOCKET_TIMEOUT_MS));

    // New Connection: Reset Stream State
    hasSeenKeyframe = false;
    isDecoderConfiguredWithHeaders = false;
    // Flush decoder to remove any old reference frames
    if (codecCtx) {
      avcodec_flush_buffers(codecCtx);
    }
    std::cout << "DEBUG: Waiting for Keyframe/SPS/PPS...\n";

    char *clientIP = inet_ntoa(clientAddr.sin_addr);
    int clientPort = ntohs(clientAddr.sin_port);
    std::cout << "Connected: " << clientIP << ":" << clientPort << "\n";
    isConnected = true;

    // Update Window Title
    if (hWindow)
      SetWindowTextA(hWindow, "AntigravityCam Receiver - Connected");

    while (isRunning) {
      // 1. Read Length Header (4 bytes)
      uint32_t netLen = 0;
      if (!recv_all(ClientSocket, &netLen, 4)) {
        break;
      }

      uint32_t len = ntohl(netLen);

      // Sanity check
      if (len > 1000000) {
        std::cerr << "Oversized packet (" << len
                  << " bytes). Dropping connection.\n";
        break;
      }

      // 2. Read Payload
      std::vector<uint8_t> buf(len);
      if (!recv_all(ClientSocket, buf.data(), len)) {
        break;
      }

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

// Active Discovery Thread: Broadcasts PING, Listens for PONG
void beacon_listener_thread_func() {
  SOCKET udpSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (udpSock == INVALID_SOCKET) {
    log_msg("[Discovery] Error: Socket creation failed\n");
    return;
  }

  // 1. Enable Broadcast
  BOOL broadcast = TRUE;
  if (setsockopt(udpSock, SOL_SOCKET, SO_BROADCAST, (char *)&broadcast,
                 sizeof(broadcast)) < 0) {
    log_msg("[Discovery] Error: Could not enable broadcast.\n");
    closesocket(udpSock);
    return;
  }

  // 2. Bind to 5001
  sockaddr_in local;
  local.sin_family = AF_INET;
  local.sin_addr.s_addr = INADDR_ANY;
  local.sin_port = htons(5001);
  bind(udpSock, (SOCKADDR *)&local, sizeof(local));

  // 3. Set Timeout
  DWORD timeout = 200;
  setsockopt(udpSock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout,
             sizeof(timeout));

  // 4. Setup Broadcast Destination
  sockaddr_in broadcastAddr;
  broadcastAddr.sin_family = AF_INET;
  broadcastAddr.sin_port = htons(5001);
  broadcastAddr.sin_addr.s_addr = INADDR_BROADCAST;

  log_msg(
      "[Discovery] Starting Active Discovery (Broadcasting PING on 5001)...\n");
  std::cout << "Device Not Found\n";

  auto lastBeaconTime = std::chrono::steady_clock::now();
  auto lastPingTime = std::chrono::steady_clock::now();
  bool deviceAvailable = false;

  enum DiscoveryState { STATE_WAITING, STATE_AVAILABLE, STATE_CONNECTED };
  DiscoveryState lastConsoleState = STATE_WAITING;

  const char PING_PACKET[] = {0x41, 0x47, 0x43, 0x4D, 0x01, 1};

  while (isRunning) {
    auto now = std::chrono::steady_clock::now();

    long long elapsedPing =
        std::chrono::duration_cast<std::chrono::milliseconds>(now -
                                                              lastPingTime)
            .count();
    if (elapsedPing >= 1000) {
      sendto(udpSock, PING_PACKET, sizeof(PING_PACKET), 0,
             (sockaddr *)&broadcastAddr, sizeof(broadcastAddr));
      lastPingTime = now;
    }

    char buf[1024];
    sockaddr_in sender;
    int senderLen = sizeof(sender);

    int len =
        recvfrom(udpSock, buf, sizeof(buf), 0, (sockaddr *)&sender, &senderLen);

    if (len > 0) {
      if (len >= 39 && buf[0] == 0x41 && buf[1] == 0x47 && buf[2] == 0x43 &&
          buf[3] == 0x4D && buf[4] == 0x02) {

        char name[33] = {0};
        memcpy(name, &buf[7], 32);

        lastBeaconTime = now;
        deviceAvailable = true;

        // UI Update Logic (Console Only, No Window Title)
        if (!isConnected) {
          if (lastConsoleState != STATE_AVAILABLE) {
            std::cout << "Device Found: " << name << "\n";
            log_msg("[Discovery] Device Found: " + std::string(name) + "\n");
            lastConsoleState = STATE_AVAILABLE;
          }
        } else {
          if (lastConsoleState != STATE_CONNECTED) {
            lastConsoleState = STATE_CONNECTED;
          }
        }
      }
    }

    if (deviceAvailable) {
      long long elapsed =
          std::chrono::duration_cast<std::chrono::seconds>(now - lastBeaconTime)
              .count();
      if (elapsed > 3) {
        deviceAvailable = false;

        if (lastConsoleState != STATE_WAITING) {
          if (!isConnected) {
            std::cout << "Device Not Found\n";
            log_msg("[Discovery] Device Lost (Timeout)\n");
          }
          lastConsoleState = STATE_WAITING;
        }
      }
    } else {
      if (!deviceAvailable && !isConnected &&
          lastConsoleState != STATE_WAITING) {
        std::cout << "Device Not Found\n";
        lastConsoleState = STATE_WAITING;
      }
    }
  }

  closesocket(udpSock);
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
  int wsaResult = WSAStartup(MAKEWORD(2, 2), &wsaData);
  if (wsaResult != 0) {
    std::cerr << "WSAStartup failed with error: " << wsaResult << "\n";
    return 1;
  }

  init_debug_log();
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

  // Resize window to fit video content (plus borders)
  RECT rect = {0, 0, VIDEO_WIDTH, VIDEO_HEIGHT};
  AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);

  hWindow = CreateWindowExW(0, CLASS_NAME, L"AntigravityCam Receiver",
                            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                            rect.right - rect.left, rect.bottom - rect.top,
                            NULL, NULL, GetModuleHandle(NULL), NULL);

  if (hWindow == NULL) {
    return 0;
  }

  ShowWindow(hWindow, SW_SHOW);

  // Start Receiver Thread
  std::thread receiverThread(receiver_thread_func);
  std::thread beaconThread(beacon_listener_thread_func);

  // Message Loop
  MSG msg = {};
  while (GetMessage(&msg, NULL, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }

  isRunning = false;
  if (receiverThread.joinable())
    receiverThread.join();
  if (beaconThread.joinable())
    beaconThread.join();

  cleanup();
  return 0;
}
