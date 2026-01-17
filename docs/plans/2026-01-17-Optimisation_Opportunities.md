# Optimisation Opportunities

**Date:** 2026-01-17
**Scope:** Consolidated codebase review and action plan
**Status:** Analysis complete - ready for implementation planning

---

## Executive Summary

This document consolidates findings from:
1. **Technical Review (Second Pass)** - Hot path analysis with execution frequency mapping
2. **Pattern-Based Review** - Application of 9 optimisation patterns from Optimisation_Methodology.md

### Implementation Status

| Category | Total Issues | Implemented | Remaining |
|----------|--------------|-------------|-----------|
| Critical (Hot Path) | 8 | 5 | 3 |
| Secondary (Track Init) | 5 | 2 | 3 |
| New Opportunities | 4 | 0 | 4 |

---

## Execution Path Analysis

```
┌─ Audio Thread ─────────────────────────────────────────────────────┐
│                                                                    │
│  AudioEngine::process()                                            │
│      └─► AudioDecoder::readSamples()                               │
│              └─► Audio callback (DirettaRenderer.cpp:154-311)      │
│                      ├─► m_shutdownRequested check  ✓ FIXED        │
│                      ├─► Atomic guard (no syscall)  ✓ FIXED        │
│                      ├─► Format comparison (6 checks) ← REMAINING  │
│                      └─► DirettaSync::sendAudio()                  │
│                              ├─► RingAccessGuard (2 atomics)       │
│                              ├─► 5 atomic loads     ← REMAINING    │
│                              └─► DirettaRingBuffer::push*()        │
│                                      └─► writeToRing() ✓ FIXED     │
└────────────────────────────────────────────────────────────────────┘

┌─ SDK Thread (Diretta callback) ────────────────────────────────────┐
│                                                                    │
│  DirettaSync::getNewStream()                                       │
│      ├─► RingAccessGuard (2 atomics)                               │
│      ├─► Underrun counter (no I/O)  ✓ FIXED                        │
│      └─► DirettaRingBuffer::pop()                                  │
└────────────────────────────────────────────────────────────────────┘
```

---

## IMPLEMENTED: Hot Path Simplifications

These items from the Technical Review have been completed (see `Hot Path Simplification Report.md`):

| ID | Issue | Fix Applied |
|----|-------|-------------|
| C0 | Mutex + notify_all in callback | Replaced with lock-free atomics |
| C1 | Modulo in writeToRing | Changed `% size` to `& mask_` |
| C4 | Dual memcpy dispatch | Unified to single `memcpy_audio_fixed` |
| C6 | I/O on underrun | Deferred to atomic counter + session-end log |
| C7 | Bit-reversal LUT duplication | Consolidated to `kBitReverseLUT` |
| S1 | Disabled code blocks | Removed ~75 lines |
| S2 | Legacy pushDSDPlanar | Replaced with `pushDSDPlanarOptimized` |

---

## REMAINING: Critical Hot Path Issues

### R1: Cache Atomic Loads in sendAudio (was C2)

**Pattern:** #3 (Decision Point Relocation)
**Location:** `DirettaSync.cpp` sendAudio()
**Frequency:** Every audio frame

**Issue:** 5 atomic loads for values that never change during playback:
```cpp
bool dsdMode = m_isDsdMode.load(std::memory_order_acquire);
bool pack24bit = m_need24BitPack.load(std::memory_order_acquire);
bool upsample16to32 = m_need16To32Upsample.load(std::memory_order_acquire);
int numChannels = m_channels.load(std::memory_order_acquire);
int bytesPerSample = m_bytesPerSample.load(std::memory_order_acquire);
```

**Impact:** 5 memory barriers × thousands of frames/sec

**Fix:** Cache in struct at track open (see Appendix A.3)

**Effort:** Medium | **Risk:** Low | **Impact:** High

---

### R2: Format Comparison Every Frame (was C3)

**Pattern:** #3 (Decision Point Relocation)
**Location:** `DirettaRenderer.cpp:213-216`
**Frequency:** Every audio frame

**Issue:** 4 comparisons on every frame:
```cpp
bool formatChanged = (currentSyncFormat.sampleRate != format.sampleRate ||
                     currentSyncFormat.bitDepth != format.bitDepth ||
                     currentSyncFormat.channels != format.channels ||
                     currentSyncFormat.isDSD != format.isDSD);
```

**Fix:** Use format generation counter - single integer comparison

**Effort:** Medium | **Risk:** Low | **Impact:** Medium

---

### R3: RingAccessGuard Atomic Operations (was C5)

**Pattern:** #9 (Syscall Elimination) - partial
**Location:** `DirettaSync.cpp:16-27`
**Frequency:** Every sendAudio() and getNewStream() call

**Issue:** Two `fetch_add`/`fetch_sub` with `acq_rel` barriers per function:
```cpp
users_.fetch_add(1, std::memory_order_acq_rel);  // Entry
users_.fetch_sub(1, std::memory_order_acq_rel);  // Exit
```

**Impact:** Full memory barriers even though reconfiguration is rare.

**Fix:** Consider relaxed memory ordering for statistics, or thread-local counters.

**Effort:** High | **Risk:** High | **Impact:** Medium

---

## NEW: Additional Opportunities

### N1: Direct Write API for Ring Buffer

**Pattern:** #8 (Direct Write APIs)
**Location:** `DirettaRingBuffer.h`
**Status:** Designed in `2026-01-16-direct-pcm-fast-path-design.md`, not implemented

**Proposed API:**
```cpp
struct WriteSpan {
    uint8_t* ptr;
    size_t maxBytes;
};

WriteSpan getWriteSpan() const;
void commitWrite(size_t bytes);
```

**Benefit:** Zero-copy writes for 32-bit PCM when contiguous space available.

| Input Format | Current | With Direct Write |
|--------------|---------|-------------------|
| S32LE WAV | 1 copy | 0 copies |
| S16LE | 1 copy | 0 copies |

**Effort:** Medium | **Impact:** High for WAV playback

---

### N2: Raw PCM Fast Path (FFmpeg Bypass)

**Pattern:** #2 (Processing Layer Bypass)
**Location:** `AudioEngine.cpp`
**Status:** Designed in `2026-01-16-direct-pcm-fast-path-design.md`, not implemented

For uncompressed WAV (PCM_S16LE, PCM_S24LE, PCM_S32LE), bypass FFmpeg decode:

**Current:**
```
av_read_frame() → avcodec_send_packet() → avcodec_receive_frame() → AudioBuffer
```

**Proposed:**
```
av_read_frame() → packet.data direct → AudioBuffer
```

**Benefit:** Eliminates 2 FFmpeg API calls + 1 memcpy per frame for WAV.

**Effort:** High | **Impact:** High for WAV playback

---

### N3: Consolidate Duplicate Bit Reversal LUT in AudioEngine

**Pattern:** #6 (Cache Locality)
**Location:** `AudioEngine.cpp:711-728`

AudioEngine has its own 256-byte bit reversal table, identical to `DirettaRingBuffer::kBitReverseLUT`.

**Fix:** Reference shared LUT:
```cpp
const uint8_t* rev = DirettaRingBuffer::kBitReverseLUT;
```

**Effort:** Trivial | **Impact:** Low (code size, cache)

---

### N4: SIMD Memcpy for Fixed Sizes

**Pattern:** #5 (Timing Variance Reduction)
**Location:** `DirettaRingBuffer.h` writeToRing

The ~176-byte buffer copies (stereo 44.1kHz) could use explicit SIMD for consistent timing:

```cpp
// For 176-byte stereo frames (11 × 16 bytes)
inline void memcpy_176(uint8_t* dst, const uint8_t* src) {
    __m128i* d = reinterpret_cast<__m128i*>(dst);
    const __m128i* s = reinterpret_cast<const __m128i*>(src);
    for (int i = 0; i < 11; i++) {
        _mm_store_si128(d + i, _mm_load_si128(s + i));
    }
}
```

**Effort:** Medium | **Impact:** Low-Medium

---

## REMAINING: Secondary (Track Initialization)

### S3: Consolidate Format Transition Logic

**Location:** `DirettaSync.cpp:335-534`

~200 lines of nested conditionals in `open()`. Could be refactored for clarity.

**Effort:** High | **Impact:** Maintainability only

---

### S4: Consolidate Retry Constants

**Location:** `DirettaSync.cpp` scattered

Magic numbers for retry counts and delays should be named constants.

**Effort:** Low | **Impact:** Maintainability only

---

### S5: Remove DSD Diagnostic Code

**Location:** `AudioEngine.cpp:348-390, 666-707`

Packet diagnostics with allocations at track open. Consider compile-time flag.

**Effort:** Low | **Impact:** Cold path only

---

## Implementation Roadmap

### Phase 1: Quick Wins (Trivial/Low effort)

| Item | Effort | Files |
|------|--------|-------|
| N3: Consolidate AudioEngine LUT | Trivial | AudioEngine.cpp |
| S4: Retry constants | Low | DirettaSync.cpp |
| S5: DSD diagnostics flag | Low | AudioEngine.cpp |

### Phase 2: Moderate Effort

| Item | Effort | Files |
|------|--------|-------|
| R1: Cache atomic loads | Medium | DirettaSync.h/cpp |
| R2: Format generation counter | Medium | DirettaRenderer.cpp, DirettaSync.h |

### Phase 3: Significant Effort

| Item | Effort | Files |
|------|--------|-------|
| N1: Direct Write API | Medium | DirettaRingBuffer.h, DirettaSync.cpp |
| N2: Raw PCM Fast Path | High | AudioEngine.cpp/h |
| N4: SIMD memcpy | Medium | DirettaRingBuffer.h |
| R3: RingAccessGuard | High | DirettaSync.cpp |

---

## Appendix A: Implementation Details

### A.3 R1: Cache Atomic Config Values in sendAudio

**File:** `src/DirettaSync.h`

ADD after other member variables:
```cpp
    // Cached playback config (set in open(), read in sendAudio())
    struct PlaybackConfig {
        bool dsdMode = false;
        bool pack24bit = false;
        bool upsample16to32 = false;
        int numChannels = 2;
        int bytesPerSample = 4;
    };
    PlaybackConfig m_playbackConfig;
    std::atomic<bool> m_configValid{false};
```

**File:** `src/DirettaSync.cpp`

In `open()`, after setting atomics:
```cpp
    // Cache config for hot path
    m_playbackConfig.dsdMode = m_isDsdMode.load(std::memory_order_relaxed);
    m_playbackConfig.pack24bit = m_need24BitPack.load(std::memory_order_relaxed);
    m_playbackConfig.upsample16to32 = m_need16To32Upsample.load(std::memory_order_relaxed);
    m_playbackConfig.numChannels = m_channels.load(std::memory_order_relaxed);
    m_playbackConfig.bytesPerSample = m_bytesPerSample.load(std::memory_order_relaxed);
    m_configValid.store(true, std::memory_order_release);
```

In `sendAudio()`, REPLACE 5 atomic loads WITH:
```cpp
    if (!m_configValid.load(std::memory_order_acquire)) return 0;
    const auto& cfg = m_playbackConfig;
    bool dsdMode = cfg.dsdMode;
    bool pack24bit = cfg.pack24bit;
    bool upsample16to32 = cfg.upsample16to32;
    int numChannels = cfg.numChannels;
    int bytesPerSample = cfg.bytesPerSample;
```

In `close()` or `stopPlayback()`:
```cpp
    m_configValid.store(false, std::memory_order_release);
```

---

### A.4 R2: Format Generation Counter

**File:** `src/DirettaSync.h`

ADD:
```cpp
    std::atomic<uint32_t> m_formatGeneration{0};
```

**File:** `src/DirettaSync.cpp`

In `open()`, after format is configured:
```cpp
    m_formatGeneration.fetch_add(1, std::memory_order_release);
```

**File:** `src/DirettaRenderer.cpp`

ADD member:
```cpp
    uint32_t m_lastFormatGeneration{0};
```

In callback, REPLACE format comparison WITH:
```cpp
    uint32_t currentGen = m_direttaSync->getFormatGeneration();
    bool formatChanged = (m_lastFormatGeneration != currentGen);
    if (formatChanged) {
        m_lastFormatGeneration = currentGen;
        // Handle format change...
    }
```

---

### A.5 N3: Consolidate AudioEngine LUT

**File:** `src/AudioEngine.cpp`

REPLACE lines 711-728:
```cpp
static const uint8_t rev[256] = { ... };
```

WITH:
```cpp
// Use shared LUT from ring buffer
const uint8_t* rev = DirettaRingBuffer::kBitReverseLUT;
```

ADD include if needed:
```cpp
#include "DirettaRingBuffer.h"
```

---

### A.11 R3: RingAccessGuard Relaxation (High Risk)

**File:** `src/DirettaSync.cpp`

**Current implementation (lines 16-27):**
```cpp
class RingAccessGuard {
public:
    explicit RingAccessGuard(std::atomic<int>& users, std::atomic<bool>& reconfiguring)
        : users_(users), reconfiguring_(reconfiguring) {
        users_.fetch_add(1, std::memory_order_acq_rel);  // Full barrier
    }
    ~RingAccessGuard() {
        users_.fetch_sub(1, std::memory_order_acq_rel);  // Full barrier
    }
    bool isReconfiguring() const {
        return reconfiguring_.load(std::memory_order_acquire);
    }
private:
    std::atomic<int>& users_;
    std::atomic<bool>& reconfiguring_;
};
```

**Option 1: Relaxed entry, release exit (Lower risk)**

The entry barrier is only needed to see prior reconfiguration state. The exit barrier ensures reconfiguration sees completed work.

```cpp
explicit RingAccessGuard(std::atomic<int>& users, std::atomic<bool>& reconfiguring)
    : users_(users), reconfiguring_(reconfiguring) {
    users_.fetch_add(1, std::memory_order_acquire);  // See prior reconfig
}
~RingAccessGuard() {
    users_.fetch_sub(1, std::memory_order_release);  // Make work visible
}
```

**Option 2: Thread-local tracking (Higher complexity)**

Track per-thread access, aggregate only during reconfiguration:
```cpp
thread_local bool t_inRingAccess = false;

class RingAccessGuard {
public:
    explicit RingAccessGuard(DirettaSync& sync) : sync_(sync) {
        t_inRingAccess = true;
        std::atomic_thread_fence(std::memory_order_seq_cst);
    }
    ~RingAccessGuard() {
        std::atomic_thread_fence(std::memory_order_seq_cst);
        t_inRingAccess = false;
    }
    // ...
};

// In beginReconfigure():
void DirettaSync::beginReconfigure() {
    m_reconfiguring.store(true, std::memory_order_seq_cst);
    // Spin until no thread is in access
    while (anyThreadInAccess()) {
        std::this_thread::yield();
    }
}
```

**Recommendation:** Start with Option 1 (lower risk). Only pursue Option 2 if profiling shows Option 1 insufficient.

**Testing required:** Stress test format transitions (DSD↔PCM) while playing to verify no corruption.

---

### A.6 N1: Direct Write API for Ring Buffer

**File:** `src/DirettaRingBuffer.h`

ADD struct and methods (around line 100, in public section):
```cpp
public:
    /**
     * @brief Contiguous write region for zero-copy writes
     */
    struct WriteSpan {
        uint8_t* ptr;       // Pointer to write location (nullptr if no space)
        size_t maxBytes;    // Contiguous bytes available (up to wrap point)
    };

    /**
     * @brief Get contiguous writable region without wrap-around
     *
     * Returns a span where the caller can write directly. The span ends
     * at either the buffer wrap point or the read position, whichever is closer.
     * After writing, call commitWrite() to advance the write pointer.
     */
    WriteSpan getWriteSpan() const {
        if (size_ == 0) return { nullptr, 0 };

        size_t wp = writePos_.load(std::memory_order_acquire);
        size_t rp = readPos_.load(std::memory_order_acquire);

        // Total free space (leave 1 byte to distinguish full from empty)
        size_t totalFree = (rp - wp - 1) & mask_;
        if (totalFree == 0) return { nullptr, 0 };

        // Contiguous space from write position to end of buffer
        size_t toEnd = size_ - wp;

        // Return the smaller of contiguous space or total free space
        size_t contiguous = std::min(toEnd, totalFree);

        return { buffer_.data() + wp, contiguous };
    }

    /**
     * @brief Commit bytes after direct write
     *
     * Call this after writing to the span returned by getWriteSpan().
     * Only call with bytes <= the maxBytes returned by getWriteSpan().
     */
    void commitWrite(size_t bytes) {
        if (bytes == 0) return;
        size_t wp = writePos_.load(std::memory_order_relaxed);
        writePos_.store((wp + bytes) & mask_, std::memory_order_release);
    }
```

**File:** `src/DirettaSync.cpp`

In `sendAudio()`, ADD fast path before existing conversion logic:
```cpp
size_t DirettaSync::sendAudio(const uint8_t* data, size_t numSamples) {
    // ... existing entry checks ...

    // Fast path: 32-bit PCM with no conversion needed
    if (!cfg.dsdMode && !cfg.pack24bit && !cfg.upsample16to32) {
        size_t inputBytes = numSamples * cfg.bytesPerSample * cfg.numChannels;

        auto span = m_ringBuffer.getWriteSpan();
        if (span.maxBytes > 0) {
            size_t toCopy = std::min(inputBytes, span.maxBytes);
            // Align to frame boundary
            size_t frameSize = cfg.bytesPerSample * cfg.numChannels;
            toCopy = (toCopy / frameSize) * frameSize;

            if (toCopy > 0) {
                memcpy_audio_fixed(span.ptr, data, toCopy);
                m_ringBuffer.commitWrite(toCopy);
                return toCopy;
            }
        }

        // Fall back to push() if contiguous space unavailable
        return m_ringBuffer.push(data, inputBytes);
    }

    // ... existing conversion paths ...
}
```

---

### A.7 N2: Raw PCM Fast Path (FFmpeg Bypass)

**Note:** Full implementation is in `docs/plans/2026-01-16-direct-pcm-fast-path-design.md`

**File:** `src/AudioEngine.h` (in AudioDecoder class)

ADD member variables:
```cpp
private:
    // Raw PCM mode (WAV direct read without FFmpeg decode)
    bool m_rawPCM = false;
    int m_pcmPackedBits = 0;              // 24 if S24LE (3-byte packed), else 0
    std::vector<uint8_t> m_pcmRemainder;  // Partial packet buffer
    size_t m_pcmRemainderCount = 0;
```

**File:** `src/AudioEngine.cpp`

In `AudioDecoder::open()`, ADD detection before codec open:
```cpp
    // Detect raw PCM codecs - bypass FFmpeg decode
    bool isRawPCM = (
        codecpar->codec_id == AV_CODEC_ID_PCM_S16LE ||
        codecpar->codec_id == AV_CODEC_ID_PCM_S24LE ||
        codecpar->codec_id == AV_CODEC_ID_PCM_S32LE
    );

    if (isRawPCM) {
        m_rawPCM = true;
        m_pcmPackedBits = (codecpar->codec_id == AV_CODEC_ID_PCM_S24LE) ? 24 : 0;

        // Extract format info from codecpar (don't need codec context)
        m_trackInfo.sampleRate = codecpar->sample_rate;
        m_trackInfo.channels = codecpar->ch_layout.nb_channels;
        m_trackInfo.bitDepth = (codecpar->codec_id == AV_CODEC_ID_PCM_S16LE) ? 16 :
                               (codecpar->codec_id == AV_CODEC_ID_PCM_S24LE) ? 24 : 32;

        DEBUG_LOG("[AudioDecoder] Raw PCM mode: " << m_trackInfo.bitDepth << "-bit LE");
        return true;  // Skip codec open
    }
```

In `AudioDecoder::readSamples()`, ADD at start:
```cpp
    if (m_rawPCM) {
        return readSamplesRawPCM(buffer, numSamples);  // New method
    }
```

ADD helper for S24 expansion:
```cpp
// Expand packed 24-bit (3 bytes) to S32 (4 bytes, sign-extended)
void AudioDecoder::expand24To32(uint8_t* dst, const uint8_t* src, size_t numSamples) {
    for (size_t i = 0; i < numSamples; i++) {
        dst[i * 4 + 0] = src[i * 3 + 0];  // LSB
        dst[i * 4 + 1] = src[i * 3 + 1];
        dst[i * 4 + 2] = src[i * 3 + 2];  // MSB of 24-bit
        // Sign extend: replicate bit 23 into the top byte
        dst[i * 4 + 3] = (src[i * 3 + 2] & 0x80) ? 0xFF : 0x00;
    }
}
```

In `AudioDecoder::seek()`, ADD:
```cpp
    if (m_rawPCM) {
        m_pcmRemainderCount = 0;
        m_eof = false;
    }
```

---

### A.8 N4: SIMD Memcpy for Fixed Sizes

**File:** `src/DirettaRingBuffer.h`

ADD specialised functions (near memcpy_audio_fixed):
```cpp
// Fixed-size SIMD copies for common audio frame sizes
// These eliminate memcpy's internal size branching

#ifdef __AVX2__
// 176 bytes = stereo 44.1kHz frame (11 × 16 bytes, fits in 3 AVX registers with overlap)
inline void memcpy_176_avx(uint8_t* __restrict dst, const uint8_t* __restrict src) {
    __m256i v0 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src));
    __m256i v1 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src + 32));
    __m256i v2 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src + 64));
    __m256i v3 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src + 96));
    __m256i v4 = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src + 128));
    // Last 16 bytes (176 - 160 = 16)
    __m128i v5 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + 160));

    _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst), v0);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst + 32), v1);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst + 64), v2);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst + 96), v3);
    _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst + 128), v4);
    _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + 160), v5);
}

// 384 bytes = stereo 96kHz frame (12 × 32 bytes)
inline void memcpy_384_avx(uint8_t* __restrict dst, const uint8_t* __restrict src) {
    for (size_t i = 0; i < 384; i += 32) {
        __m256i v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(src + i));
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(dst + i), v);
    }
}
#endif

// Dispatch based on known sizes
inline void memcpy_audio_sized(uint8_t* dst, const uint8_t* src, size_t len) {
#ifdef __AVX2__
    if (len == 176) { memcpy_176_avx(dst, src); return; }
    if (len == 384) { memcpy_384_avx(dst, src); return; }
#endif
    memcpy_audio_fixed(dst, src, len);
}
```

In `writeToRing()`, REPLACE memcpy calls:
```cpp
    if (firstChunk > 0) {
        memcpy_audio_sized(ring + writePos, staged, firstChunk);
    }
    if (secondChunk > 0) {
        memcpy_audio_sized(ring, staged + firstChunk, secondChunk);
    }
```

---

### A.9 S4: Consolidate Retry Constants

**File:** `src/DirettaSync.h`

ADD namespace after DirettaBuffer namespace:
```cpp
namespace DirettaRetry {
    // Connection establishment
    constexpr int ONLINE_WAIT_RETRIES = 20;
    constexpr int ONLINE_WAIT_DELAY_MS = 100;

    // Format switching
    constexpr int FORMAT_SWITCH_RETRIES = 10;
    constexpr int FORMAT_SWITCH_DELAY_MS = 50;

    // Playback start
    constexpr int START_PLAYBACK_RETRIES = 50;
    constexpr int START_PLAYBACK_DELAY_MS = 10;

    // Audio send
    constexpr int SEND_AUDIO_RETRIES = 100;
    constexpr int SEND_AUDIO_DELAY_MS = 5;
}
```

**File:** `src/DirettaSync.cpp`

REPLACE magic numbers with constants:
```cpp
// BEFORE
for (int i = 0; i < 20; i++) { ... std::this_thread::sleep_for(std::chrono::milliseconds(100)); }

// AFTER
for (int i = 0; i < DirettaRetry::ONLINE_WAIT_RETRIES; i++) {
    std::this_thread::sleep_for(std::chrono::milliseconds(DirettaRetry::ONLINE_WAIT_DELAY_MS));
}
```

---

### A.10 S5: DSD Diagnostic Code Compile Flag

**File:** `src/AudioEngine.cpp`

WRAP diagnostic code in compile-time flag:
```cpp
#ifdef DIRETTA_DSD_DIAGNOSTICS
    // Packet diagnostics (lines 348-390)
    if (m_trackInfo.isDSD) {
        DEBUG_LOG("[DSD] First packet analysis:");
        // ... existing diagnostic code ...
    }
#endif
```

**File:** `Makefile`

ADD optional flag:
```makefile
# Enable DSD packet diagnostics (debug builds only)
ifdef DSD_DIAG
    CXXFLAGS += -DDIRETTA_DSD_DIAGNOSTICS
endif
```

Usage: `make DSD_DIAG=1`

---

## Appendix B: Testing Checklist

### Basic Playback
- [ ] PCM 16-bit/44.1kHz (CD quality)
- [ ] PCM 24-bit/96kHz (high-res)
- [ ] PCM 24-bit/192kHz
- [ ] PCM 32-bit/384kHz
- [ ] DSD64
- [ ] DSD128

### Format Transitions
- [ ] PCM → PCM (same rate)
- [ ] PCM → PCM (different rate)
- [ ] PCM → DSD
- [ ] DSD → PCM
- [ ] DSD → DSD (different rate)

### Control
- [ ] Stop during playback
- [ ] Pause/Resume
- [ ] Seek during playback
- [ ] Rapid play/stop cycles
- [ ] Clean shutdown (no hangs)

### Stress Tests
- [ ] Long playback (1+ hour)
- [ ] Gapless playback (multiple tracks)
- [ ] Check underrun count at session end

---

## Appendix C: Measurement Recommendations

Before implementing, establish baselines:

1. **Callback timing variance:** Measure P99 latency of audio callback
2. **CPU usage:** Profile sendAudio() and readSamples()
3. **Cache miss rate:** Use perf counters for L1/L2/L3 misses
4. **Underrun count:** Track m_underrunCount across test runs

After each optimisation, re-measure to validate impact.

---

## Patterns Already Well-Applied

| Pattern | Where Applied |
|---------|---------------|
| Memory Allocation Elimination | m_packet, m_frame reuse |
| Processing Layer Bypass | PCM bypass in AudioDecoder |
| O(1) Data Structures | AVAudioFifo, power-of-2 ring buffer |
| Cache Locality | alignas(64) on ring positions |
| Syscall Elimination | Lock-free callback sync |
| Flow Control Tuning | 500µs micro-sleep |
| Function Specialisation | DSD conversion modes |

---

**End of Report**
