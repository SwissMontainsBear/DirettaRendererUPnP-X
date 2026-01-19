# SDK 148 Alternative Implementation Options

**Date:** 2026-01-19
**Status:** Reference documentation (current implementation is working)

---

## Context

SDK 148 changed `getNewStream()` signature from `Stream&` to `diretta_stream&`. The SDK editor clarified:

> "The memory pointer passed to this method must be retained until Disconnect completes or the next getNewStream is called."

Our current implementation uses a persistent `m_streamData` buffer and directly sets `diretta_stream.Data.P`. This works correctly because we only resize at the start of `getNewStream()`, when the SDK is done with the previous pointer.

---

## Current Implementation (Working)

```cpp
// DirettaSync.h
std::vector<uint8_t> m_streamData;

// DirettaSync.cpp - getNewStream()
if (m_streamData.size() != currentBytesPerBuffer) {
    m_streamData.resize(currentBytesPerBuffer);
}
baseStream.Data.P = m_streamData.data();
baseStream.Size = currentBytesPerBuffer;
```

**Why it's correct:** Resize occurs at the start of `getNewStream()`, which is exactly when the previous pointer becomes invalid per SDK contract.

---

## Alternative A: Double-Buffer Pattern

If timing issues ever emerge, use two buffers and alternate:

```cpp
// Members:
std::vector<uint8_t> m_streamBuffers[2];
int m_activeBuffer = 0;

// In getNewStream():
m_activeBuffer = 1 - m_activeBuffer;
auto& buf = m_streamBuffers[m_activeBuffer];
if (buf.size() != currentBytesPerBuffer) {
    buf.resize(currentBytesPerBuffer);
}
baseStream.Data.P = buf.data();
baseStream.Size = currentBytesPerBuffer;
// Fill buf with audio data...
```

**Pros:** Guarantees previous pointer valid until next call
**Cons:** 2x memory usage

---

## Alternative B: Pre-allocate Maximum Size

Simplest approach - never reallocate:

```cpp
// Member:
static constexpr size_t MAX_STREAM_SIZE = 65536;  // 64KB
std::vector<uint8_t> m_streamData;

// In constructor or open():
m_streamData.resize(MAX_STREAM_SIZE);

// In getNewStream() - never resize:
baseStream.Data.P = m_streamData.data();  // Always same pointer
baseStream.Size = currentBytesPerBuffer;   // Only logical size varies
// Fill first currentBytesPerBuffer bytes...
```

**Pros:** Pointer never changes, zero reallocation risk
**Cons:** 64KB always allocated (negligible on modern systems)

---

## Alternative C: Resize Only When Disconnected

Conservative approach - only resize during format changes:

```cpp
// In getNewStream():
if (m_streamData.size() < currentBytesPerBuffer && !is_online()) {
    m_streamData.resize(currentBytesPerBuffer);
}
size_t usableSize = std::min(m_streamData.size(), (size_t)currentBytesPerBuffer);
baseStream.Data.P = m_streamData.data();
baseStream.Size = usableSize;
```

**Pros:** Minimal changes
**Cons:** May fail if larger buffer needed mid-stream

---

## Recommendation

**Keep current implementation** unless problems emerge. If crashes occur:

1. First try **Alternative B** (pre-allocate) - simplest fix
2. If memory constrained, try **Alternative A** (double-buffer)

---

## Related Files

- `src/DirettaSync.h` - `m_streamData` declaration
- `src/DirettaSync.cpp` - `getNewStream()` implementation
- `docs/SDK_148_MIGRATION_JOURNAL.md` - Full migration history
