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
  uint32_t version; // Version 2 (added double-buffering)

  // Writers increment this after writing data.
  // Readers poll this to detect new frames.
  volatile uint32_t write_sequence;

  // Double-buffering: Active buffer index (0 or 1)
  // Writer updates this AFTER completing a frame write
  volatile uint32_t active_buffer;

  uint32_t width;
  uint32_t height;

  // Timestamp in microseconds (useful for A/V sync later)
  uint64_t timestamp_us;

  // Double-buffered frame data for race-free access
  // Reader reads from active_buffer, writer writes to (active_buffer ^ 1)
  uint8_t data[2][FRAME_BUFFER_SIZE];
};
#pragma pack() // Restore default alignment

// Verify structure size to ensure packing is working
// Header: 32 bytes + 2 buffers * 3,686,400 = 7,372,832 bytes
static_assert(sizeof(struct SharedMemoryLayout) == (32 + 2 * FRAME_BUFFER_SIZE),
              "SharedMemoryLayout size mismatch");

#endif // SHARED_MEMORY_H
