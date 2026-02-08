/**
 * @file DirettaProbe.h
 * @brief Lightweight audio path instrumentation for DirettaRendererUPnP
 *
 * Compile-time togglable via -DDIRETTA_PROBE (make PROBE=1).
 * When disabled, all macros compile to zero overhead.
 *
 * Pattern reused from LogRing (DirettaSync.h): lock-free SPSC ring buffer
 * with alignas(64) separated atomics and bitmask modulo.
 */

#ifndef DIRETTA_PROBE_H
#define DIRETTA_PROBE_H

#ifdef DIRETTA_PROBE

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>

//=============================================================================
// Probe Event Types
//=============================================================================

enum class ProbeEventType : uint16_t {
    // getNewStream() events (consumer / SDK callback)
    GET_STREAM          = 1,    // Normal pop from ring buffer
    GET_STREAM_UNDERRUN = 2,    // Underrun detected (silence inserted)
    GET_STREAM_SILENCE  = 3,    // Silence for other reasons

    // sendAudio() events (producer / audio thread)
    SEND_AUDIO          = 10,   // Normal push to ring buffer
    SEND_AUDIO_FULL     = 11,   // Ring full, returned 0

    // Format/session events
    FORMAT_CHANGE       = 20,   // Format transition detected
    PREFILL_DONE        = 21,   // Prefill target reached

    // Session lifecycle
    SESSION_START       = 30,   // Playback session started (open)
    SESSION_END         = 31,   // Playback session ended (stop)
};

// Silence reason flags (stored in ProbeEvent::flags for GET_STREAM_SILENCE)
enum class ProbeSilenceReason : uint16_t {
    SHUTDOWN        = 1,
    STOP_REQUESTED  = 2,
    PREFILL         = 3,
    STABILIZATION   = 4,
    RECONFIGURING   = 5,
};

//=============================================================================
// Probe Event (32 bytes, cache-line friendly)
//=============================================================================

struct ProbeEvent {
    uint64_t timestamp_ns;      // steady_clock nanoseconds since probe start
    uint16_t event_type;        // ProbeEventType
    uint16_t flags;             // Event-specific flags
    uint32_t duration_ns;       // Event duration (begin→end) for timed events
    uint32_t ring_level;        // Ring buffer bytes available at event time
    uint32_t ring_capacity;     // Ring buffer total size
    uint64_t payload;           // Context-dependent (bytes written, sample rate, etc.)
};
static_assert(sizeof(ProbeEvent) == 32, "ProbeEvent must be 32 bytes");

//=============================================================================
// Lock-free SPSC Probe Ring Buffer
//=============================================================================

class ProbeRing {
public:
    static constexpr size_t CAPACITY = 131072;  // 4MB at 32 bytes/event
    static constexpr size_t MASK = CAPACITY - 1;

    ProbeRing() : m_writePos(0), m_readPos(0), m_dropped(0) {
        m_startTime = std::chrono::steady_clock::now();
    }

    // Push a probe event (lock-free, drop-on-full)
    bool push(ProbeEventType type, uint16_t flags, uint32_t duration_ns,
              uint32_t ring_level, uint32_t ring_capacity, uint64_t payload) {
        size_t wp = m_writePos.load(std::memory_order_relaxed);
        size_t rp = m_readPos.load(std::memory_order_acquire);

        if (((wp + 1) & MASK) == rp) {
            m_dropped.fetch_add(1, std::memory_order_relaxed);
            return false;  // Full, drop event
        }

        auto now = std::chrono::steady_clock::now();
        m_events[wp].timestamp_ns = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                now - m_startTime).count());
        m_events[wp].event_type = static_cast<uint16_t>(type);
        m_events[wp].flags = flags;
        m_events[wp].duration_ns = duration_ns;
        m_events[wp].ring_level = ring_level;
        m_events[wp].ring_capacity = ring_capacity;
        m_events[wp].payload = payload;

        m_writePos.store((wp + 1) & MASK, std::memory_order_release);
        return true;
    }

    // Pop for drain thread (returns false if empty)
    bool pop(ProbeEvent& event) {
        size_t rp = m_readPos.load(std::memory_order_relaxed);
        size_t wp = m_writePos.load(std::memory_order_acquire);

        if (rp == wp) {
            return false;  // Empty
        }

        event = m_events[rp];
        m_readPos.store((rp + 1) & MASK, std::memory_order_release);
        return true;
    }

    bool empty() const {
        return m_readPos.load(std::memory_order_acquire) ==
               m_writePos.load(std::memory_order_acquire);
    }

    uint64_t dropped() const {
        return m_dropped.load(std::memory_order_relaxed);
    }

    std::chrono::steady_clock::time_point startTime() const {
        return m_startTime;
    }

private:
    ProbeEvent m_events[CAPACITY];
    alignas(64) std::atomic<size_t> m_writePos;
    alignas(64) std::atomic<size_t> m_readPos;
    std::atomic<uint64_t> m_dropped;
    std::chrono::steady_clock::time_point m_startTime;
};

//=============================================================================
// Global probe ring (initialized in main.cpp when --probe is used)
//=============================================================================

extern ProbeRing* g_probeRing;

//=============================================================================
// Instrumentation Macros
//=============================================================================

// Start timing a section
#define PROBE_BEGIN(var) \
    auto var = std::chrono::steady_clock::now()

// End timing and push event with duration
#define PROBE_END(type, begin_var, ring_level, ring_capacity, payload_val) \
    do { \
        if (g_probeRing) { \
            auto _probe_end = std::chrono::steady_clock::now(); \
            uint32_t _probe_dur = static_cast<uint32_t>( \
                std::chrono::duration_cast<std::chrono::nanoseconds>( \
                    _probe_end - (begin_var)).count()); \
            g_probeRing->push((type), 0, _probe_dur, \
                static_cast<uint32_t>(ring_level), \
                static_cast<uint32_t>(ring_capacity), \
                static_cast<uint64_t>(payload_val)); \
        } \
    } while (0)

// End timing with flags (for silence reason etc.)
#define PROBE_END_FLAGS(type, flags_val, begin_var, ring_level, ring_capacity, payload_val) \
    do { \
        if (g_probeRing) { \
            auto _probe_end = std::chrono::steady_clock::now(); \
            uint32_t _probe_dur = static_cast<uint32_t>( \
                std::chrono::duration_cast<std::chrono::nanoseconds>( \
                    _probe_end - (begin_var)).count()); \
            g_probeRing->push((type), static_cast<uint16_t>(flags_val), _probe_dur, \
                static_cast<uint32_t>(ring_level), \
                static_cast<uint32_t>(ring_capacity), \
                static_cast<uint64_t>(payload_val)); \
        } \
    } while (0)

// Single-point event (no duration measurement)
#define PROBE_EVENT(type, ring_level, ring_capacity, payload_val) \
    do { \
        if (g_probeRing) { \
            g_probeRing->push((type), 0, 0, \
                static_cast<uint32_t>(ring_level), \
                static_cast<uint32_t>(ring_capacity), \
                static_cast<uint64_t>(payload_val)); \
        } \
    } while (0)

#else  // !DIRETTA_PROBE

//=============================================================================
// No-op macros when probe is disabled (zero overhead)
//=============================================================================

#define PROBE_BEGIN(var)                                                  do {} while (0)
#define PROBE_END(type, begin_var, ring_level, ring_capacity, payload)    do {} while (0)
#define PROBE_END_FLAGS(type, flags, begin_var, rl, rc, payload)          do {} while (0)
#define PROBE_EVENT(type, ring_level, ring_capacity, payload)             do {} while (0)

#endif  // DIRETTA_PROBE

#endif  // DIRETTA_PROBE_H
