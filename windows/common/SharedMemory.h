#pragma once
#ifndef SHARED_MEMORY_H
#define SHARED_MEMORY_H

#include <stdint.h>

// Protocol Constants
#define SHARED_MEMORY_NAME "Local\\AntiGravityWebcamSource"
#define VIDEO_WIDTH 1280
#define VIDEO_HEIGHT 720
#define VIDEO_FPS 30

// Pixel Format: BGRA (32-bit)
// Size: 1280 * 720 * 4 = 3,686,400 bytes
#define FRAME_BUFFER_SIZE (VIDEO_WIDTH * VIDEO_HEIGHT * 4)

#pragma pack(1)
struct SharedMemoryLayout {
  uint32_t magic;   // 'WEBC' (0x43424557)
  uint32_t version; // Version 1

  // Writers increment this after writing data.
  // Readers poll this to detect new frames.
  volatile uint32_t write_sequence;

  uint32_t width;
  uint32_t height;

  // Timestamp in microseconds (useful for A/V sync later)
  uint64_t timestamp_us;

  // The raw pixel data (BGRA)
  uint8_t data[FRAME_BUFFER_SIZE];
};
#pragma pack() // Restore default alignment

// Verify structure size to ensure packing is working
static_assert(sizeof(struct SharedMemoryLayout) == (28 + FRAME_BUFFER_SIZE),
              "SharedMemoryLayout size mismatch");

#endif // SHARED_MEMORY_H
