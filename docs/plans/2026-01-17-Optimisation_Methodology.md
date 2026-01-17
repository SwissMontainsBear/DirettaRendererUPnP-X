# Optimisation Methodology

**Date:** 2026-01-17
**Source:** Analysis of docs/plans/ design documents
**Context:** Collaboration with high-level expert on audio rendering quality

## Overview

This document captures the optimisation patterns identified in the DirettaRendererUPnP-X codebase improvements. Beyond the two primary techniques (hot path simplification and SIMD/hardware delegation), several additional patterns emerged that contribute to improved audio reproduction quality.

The underlying philosophy: **minimise variance in execution time, not just average execution time**. In audio rendering, jitter (timing variance) directly affects perceived quality.

---

## Pattern 1: Memory Allocation Elimination

**Principle:** Pre-allocate objects and reuse them across iterations rather than allocating per-call.

**Examples:**
- `m_packet` and `m_frame` allocated once in `AudioDecoder::open()`, reused for all reads
- Staging buffers allocated per-format at track open, reused for all conversions
- `m_pcmRemainder` vector pre-sized to avoid reallocation during playback

**Rationale:** Memory allocation involves syscalls and has highly variable latency. Pre-allocation moves this cost to the cold path (track open) rather than the hot path (per-sample processing).

---

## Pattern 2: Processing Layer Bypass

**Principle:** Skip entire processing stages when the data already matches the target format.

**Examples:**
- PCM bypass: skip `SwrContext` entirely when input/output formats match
- Raw PCM mode: bypass `avcodec_send_packet()`/`avcodec_receive_frame()` for uncompressed WAV files
- S24→S24_P32: request packed format from FFmpeg to avoid unnecessary unpacking/repacking

**Rationale:** The fastest code is code that doesn't run. Format-matching detection at track open allows entire processing stages to be skipped.

---

## Pattern 3: Decision Point Relocation

**Principle:** Move format decisions from per-sample (hot path) to per-track (cold path).

**Examples:**
- DSD conversion mode: determined once at track open, cached in `m_dsdConversionMode`
- S24 pack mode: detected at track open with metadata hint, not per-iteration detection
- Function pointer selection: choose specialised function once, call without branching

**Key Insight:** "The conversion mode is determined at track open and never changes during playback."

**Rationale:** Conditional branches have variable timing due to branch prediction. Moving decisions to track open eliminates per-sample branching entirely.

---

## Pattern 4: O(1) Data Structures

**Principle:** Replace O(n) operations with O(1) alternatives.

**Examples:**
- `AVAudioFifo` for circular buffer: O(1) read/write vs `memmove` O(n)
- Power-of-2 bitmask modulo: `& mask_` (1 cycle) vs `% size_` (20-100 cycles)
- Ring buffer with separate read/write positions vs shifting array

**Rationale:** O(n) operations have data-dependent timing. O(1) operations execute in constant time regardless of data size.

---

## Pattern 5: Timing Variance Reduction

**Principle:** Ensure code paths execute in predictable, consistent time.

**Examples:**
- Overlapping stores: write fixed iteration count regardless of actual data size
- Fixed staging buffer size: same cache footprint every iteration
- Consistent-timing memcpy: identical instruction sequence regardless of length
- Avoid early-exit optimisations that create timing differences

**Rationale:** Even if an optimisation reduces average time, if it increases variance, it may degrade audio quality. Predictable timing is preferred over faster-but-variable timing.

---

## Pattern 6: Cache Locality Optimisation

**Principle:** Keep frequently-accessed data in fast cache levels.

**Examples:**
- Staging buffers sized to fit L2 cache (~64KB)
- `alignas(64)` for cache-line separation of read/write positions (prevents false sharing)
- Single consolidated bit-reversal LUT vs 4 copies in different functions
- Zen 4-specific prefetch tuning for streaming data

**Rationale:** Cache misses have highly variable latency (L1: ~4 cycles, L2: ~12 cycles, L3: ~40 cycles, RAM: ~200+ cycles). Keeping hot data in cache reduces both latency and variance.

---

## Pattern 7: Flow Control Tuning

**Principle:** Adaptive scheduling based on buffer state.

**Examples:**
- Micro-sleep (500µs) when buffer is healthy vs 10ms blocking when nearly empty
- Early return on critical buffer levels
- Adaptive chunk sizing: smaller chunks when buffer is low, larger when healthy

**Rationale:** Aggressive sleeping saves CPU but risks underruns. Adaptive flow control maintains buffer health while minimising CPU usage during steady-state playback.

---

## Pattern 8: Direct Write APIs

**Principle:** Eliminate intermediate buffer copies by writing directly to destination.

**Examples:**
- `getWriteSpan()`/`commitWrite()`: expose ring buffer memory for zero-copy writes
- `swr_convert()` output directly to FIFO when sample counts align
- Target: reduce copies from 2-3 to 0-1 for 32-bit WAV playback

**Rationale:** Each memory copy adds latency and cache pressure. Direct writes eliminate intermediate buffers entirely.

---

## Pattern 9: Syscall Elimination

**Principle:** Remove kernel transitions from the audio path.

**Examples:**
- Replace mutex/condition variable with lock-free atomics
- Count underruns with atomic increment, log at session end (not in hot path)
- Spin-wait with `std::this_thread::yield()` vs `notify_all()` syscall
- Deferred I/O: accumulate statistics, write once at session end

**Rationale:** Syscalls involve context switches with highly variable latency (1-10µs typical, but can spike to milliseconds under load). Lock-free primitives keep execution entirely in userspace.

---

## Pattern Taxonomy

| Category | Pattern | Primary Benefit |
|----------|---------|-----------------|
| **Temporal** | Decision relocation | Eliminates per-sample branching |
| **Spatial** | Cache locality | Reduces memory access variance |
| **Structural** | Layer bypass | Eliminates unnecessary processing |
| **Algorithmic** | O(1) structures | Constant-time operations |
| **Timing** | Variance reduction | Predictable execution time |
| **System** | Syscall elimination | Avoids kernel transitions |
| **Memory** | Allocation elimination | Moves allocation to cold path |
| **Data Flow** | Direct write APIs | Reduces copy count |
| **Scheduling** | Flow control tuning | Balances latency vs CPU usage |

---

## Application Guidelines

### When to Apply Each Pattern

1. **Memory Allocation Elimination** - Apply to any object created per-iteration in the hot path
2. **Processing Layer Bypass** - Apply when format detection can identify no-op cases
3. **Decision Point Relocation** - Apply to any conditional that depends on track-level (not sample-level) data
4. **O(1) Data Structures** - Apply when data size varies and affects operation count
5. **Timing Variance Reduction** - Apply to innermost loops where consistency matters most
6. **Cache Locality Optimisation** - Apply to frequently-accessed data structures
7. **Flow Control Tuning** - Apply to producer/consumer boundaries
8. **Direct Write APIs** - Apply when intermediate buffers serve no transformation purpose
9. **Syscall Elimination** - Apply to any synchronisation or I/O in the hot path

### Measurement Approach

When evaluating optimisations, measure:
- **Mean latency** - Average execution time
- **P99 latency** - 99th percentile (captures variance)
- **Jitter** - Standard deviation of execution time
- **Cache miss rate** - Via hardware performance counters

An optimisation that reduces mean latency but increases P99 or jitter may degrade audio quality.

---

## References

- `docs/plans/2026-01-11-audio-memory-optimization-design.md` - Staging buffers, SIMD conversions
- `docs/plans/2026-01-12-PCM Latency and Jitter Optimization Design.md` - Allocation elimination, flow control
- `docs/plans/2026-01-14-resample-memcpy-optimization-design.md` - Direct write path, AVAudioFifo
- `docs/plans/2026-01-15-pcm-bypass-optimization-design.md` - PCM bypass, S24 detection
- `docs/plans/2026-01-15-dsd-conversion-optimization-design.md` - Function specialisation
- `docs/plans/2026-01-16-direct-pcm-fast-path-design.md` - Ring buffer direct write
- `docs/Hot Path Simplification Report.md` - Implementation summary
