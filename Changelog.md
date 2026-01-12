# Changelog 

## 2026-01-12 (thanks to @leeeanh)

### 1. Power-of-2 Bitmask Modulo

- Added `roundUpPow2()` helper function (lines 33-44)
- Added `mask_` member variable (line 295)
- `resize()` now rounds up to power-of-2 and sets `mask_ = size_ - 1`
- Replaced all `% size_` with `& mask_` throughout:
  - `getAvailable()` - line 69
  - `getFreeSpace()` - line 73 (simplified)
  - `push()` - line 106
  - `push24BitPacked()` - lines 138, 141-142, 145
  - `push16To32()` - lines 168, 172-174, 177
  - `pushDSDPlanar()` - lines 214, 232-234, 237-239, 244
  - `pop()` - line 268

### 2. Cache-Line Separation

- Added `alignas(64)` to `writePos_` (line 298)
- Added `alignas(64)` to `readPos_` (line 299)

### Performance Impact

| Operation     | Before                              | After                           |
| ------------- | ----------------------------------- | ------------------------------- |
| Modulo        | `% size_` (10-20 cycles)            | `& mask_` (1 cycle)             |
| False sharing | Possible between writePos_/readPos_ | Eliminated (64-byte separation) |

### Note

The buffer size will now be rounded up to the next power of 2. For example:
- Request 3MB → allocate 4MB
- Request 1.5MB → allocate 2MB

This wastes some memory but the tradeoff is worth it for the consistent fast-path performance.

---

## 2026-01-11 (thanks to @leeeanh)

### DirettaSync.h

- Removed `m_pushMutex`
- Added `m_reconfiguring` and `m_ringUsers` atomics for lock-free access
- Converted 11 format parameters to `std::atomic<>` (`m_sampleRate`, `m_channels`, `m_bytesPerSample`, etc.)
- Added `ReconfigureGuard` RAII class
- Added `beginReconfigure()` / `endReconfigure()` method declarations

### DirettaSync.cpp

- Added `RingAccessGuard` class for lock-free ring buffer access
- Added `beginReconfigure()` / `endReconfigure()` implementations
- Updated `sendAudio()` to use `RingAccessGuard` instead of mutex (lock-free hot path)
- Updated `configureRingPCM()`, `configureRingDSD()`, `fullReset()` to use `ReconfigureGuard`
- Updated all format parameter accesses to use atomic load/store with proper memory ordering

### DirettaRingBuffer.h

- Added `S24PackMode` enum (`Unknown`, `LsbAligned`, `MsbAligned`)
- Added `detectS24PackMode()` method that checks first 32 samples
- Updated `push24BitPacked()` to auto-detect and handle both S24 formats
- S24 detection resets on `clear()` and `resize()`

---

## Key Benefits

1. **Lock-free audio path** - `sendAudio()` no longer takes any mutex
2. **Safe reconfiguration** - `ReconfigureGuard` waits for active readers to drain
3. **S24 format flexibility** - Handles both LSB-aligned (FFmpeg S24_LE) and MSB-aligned formats automatically