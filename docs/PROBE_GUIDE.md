# DirettaProbe Guide

DirettaProbe is a lightweight instrumentation tool for measuring audio path latency and jitter in DirettaRendererUPnP. It captures timestamped events from the hot path (`sendAudio()` and `getNewStream()`) with ~100-150ns overhead per probe point, and writes structured CSV data for offline analysis.

When not enabled at compile time, all probe code is eliminated entirely---zero overhead.

---

## Quick Start

```bash
# 1. Build with probes enabled
make clean && make PROBE=1

# 2. Run with instrumentation
sudo ./bin/DirettaRendererUPnP --target 1 --probe

# 3. Play a few tracks, then Ctrl+C to stop
#    Output file is printed on shutdown:
#    [Probe] Wrote /tmp/diretta-probe-20260208-143022.csv

# 4. Analyse
python3 tools/probe-analyze.py /tmp/diretta-probe-20260208-143022.csv
```

---

## Building

DirettaProbe is controlled by a compile-time flag. It can be combined with other build flags:

```bash
# Probe only (with logging)
make PROBE=1

# Probe + production logging disabled
make PROBE=1 NOLOG=1

# Probe on a specific architecture
make PROBE=1 ARCH_NAME=aarch64-linux-15

# Normal build (no probe overhead at all)
make
```

When `PROBE=1` is not set, all probe macros expand to `do {} while(0)` and the compiler eliminates them completely. There is no runtime cost, no binary size increase, and no new symbols.

---

## Running

Two new command-line options are available in probe-enabled builds:

| Option | Description |
|--------|-------------|
| `--probe` | Enable probe data collection |
| `--probe-file <path>` | Set output file path (implies `--probe`) |

```bash
# Default output: /tmp/diretta-probe-YYYYMMDD-HHMMSS.csv
sudo ./bin/DirettaRendererUPnP --target 1 --probe

# Custom output path
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/baseline.csv
```

Probe data is flushed both on normal shutdown and on Ctrl+C (SIGINT/SIGTERM). The output file path is printed to stdout when the probe shuts down.

**Tip:** For consistent comparisons, play the same track or playlist in each run. A 2-3 minute session generates ~50,000-150,000 events depending on format and sample rate.

---

## Output Format

The CSV file begins with metadata headers (lines starting with `#`) followed by event rows:

```
# DPROBE1
# platform: x86_64
# kernel: 6.12.0-0.rc6.58.fc42.x86_64
# cpu_model: AMD Ryzen 9 7950X
# build_date: Feb  8 2026 14:30:00
# build_flags: NOLOG
# epoch_ns: 1738950600000000000
# version: 2.1-beta
#
timestamp_ns,event_type,flags,duration_ns,ring_level,ring_capacity,payload
100000000,SESSION_START,0,0,0,0,176400
200000000,SEND_AUDIO,0,2500,50000,262144,4096
220100000,GET_STREAM,0,1200,86000,262144,4096
```

### Metadata Fields

| Field | Description |
|-------|-------------|
| `platform` | CPU architecture (`x86_64`, `aarch64`) |
| `kernel` | Linux kernel version |
| `cpu_model` | CPU model name (from `/proc/cpuinfo`) |
| `build_date` | Compilation timestamp |
| `build_flags` | Build configuration (e.g., `NOLOG`) |
| `epoch_ns` | Wall-clock time at probe start (nanoseconds since Unix epoch) |
| `version` | Renderer version |

### Event Fields

| Field | Description |
|-------|-------------|
| `timestamp_ns` | Nanoseconds since probe start (monotonic `steady_clock`) |
| `event_type` | Event name (see table below) |
| `flags` | Event-specific flags (e.g., silence reason) |
| `duration_ns` | Time spent in the instrumented operation (0 for point events) |
| `ring_level` | Ring buffer bytes available at event time |
| `ring_capacity` | Ring buffer total size |
| `payload` | Context-dependent value (bytes written, sample rate, etc.) |

### Event Types

| Event | Where | Meaning |
|-------|-------|---------|
| `GET_STREAM` | `getNewStream()` | Normal pop from ring buffer. Duration = time to complete the call. |
| `GET_STREAM_UNDERRUN` | `getNewStream()` | Buffer empty, silence inserted. Payload = bytes needed. |
| `GET_STREAM_SILENCE` | `getNewStream()` | Silence sent for non-underrun reason. Flags encode the reason. |
| `SEND_AUDIO` | `sendAudio()` | Normal push to ring buffer. Payload = bytes written. |
| `SEND_AUDIO_FULL` | `sendAudio()` | Ring full or guard failed, returned 0. |
| `FORMAT_CHANGE` | Audio callback | Format transition detected. Payload = new sample rate. |
| `PREFILL_DONE` | `sendAudio()` | Prefill target reached. Payload = target bytes. |
| `SESSION_START` | `open()` | Playback session started. Payload = sample rate (bit 31 = DSD flag). |
| `SESSION_END` | `stopPlayback()` | Playback session ended. Payload = underrun count for the session. |

### Silence Reason Flags

When `event_type` is `GET_STREAM_SILENCE`, the `flags` field encodes the reason:

| Flag | Meaning |
|------|---------|
| 1 | Shutdown silence (post-stop flush) |
| 2 | Stop requested |
| 3 | Prefill not yet complete |
| 4 | Post-online stabilisation (DAC warmup) |
| 5 | Ring buffer reconfiguring |

---

## Analysis

The analysis script requires only Python 3 standard library (no pip dependencies). It works on headless systems over SSH.

### Single Run Summary

```bash
python3 tools/probe-analyze.py run.csv
```

Output includes:
- Platform metadata (CPU, kernel, build flags)
- `getNewStream()` latency: count, mean, stddev, P50/P90/P99/P99.9/max, histogram
- `getNewStream()` inter-call interval: mean, stddev, P99, max (measures SDK callback jitter)
- Underrun count
- Buffer fill level: mean, min, max (as percentage)
- `sendAudio()` latency: same statistics as getNewStream
- Session and format change counts
- Silence buffer breakdown by reason

### Comparing Two Runs

```bash
python3 tools/probe-analyze.py --compare baseline.csv experiment.csv
```

Prints side-by-side statistics with delta percentages. Use this to compare:
- **Tuning options:** Run with vs without CPU isolation
- **Kernel flavors:** RT-patched vs mainline
- **Hardware:** RPi vs Zen3 vs Zen4
- **SDK versions:** Link against v147 vs v148

### Filtering by Event Type

```bash
python3 tools/probe-analyze.py --filter GET_STREAM run.csv
python3 tools/probe-analyze.py --filter SEND_AUDIO run.csv
```

### JSON Export

```bash
python3 tools/probe-analyze.py --json run.csv > summary.json
```

Produces a structured JSON summary suitable for programmatic comparison or time-series tracking across builds.

---

## Common Workflows

### Comparing Two Kernel Flavors

```bash
# Boot kernel A, run measurement
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/kernel-rt.csv
# Play test playlist, Ctrl+C

# Reboot to kernel B, run measurement
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/kernel-mainline.csv
# Play same test playlist, Ctrl+C

# Compare
python3 tools/probe-analyze.py --compare kernel-rt.csv kernel-mainline.csv
```

### Comparing SDK Versions

```bash
# Build and run with SDK v147
make clean && make PROBE=1 DIRETTA_SDK_PATH=../DirettaHostSDK_147_19
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/sdk147.csv

# Build and run with SDK v148
make clean && make PROBE=1 DIRETTA_SDK_PATH=../DirettaHostSDK_148
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/sdk148.csv

# Compare
python3 tools/probe-analyze.py --compare sdk147.csv sdk148.csv
```

### Evaluating Tuner Script Impact

```bash
# Run WITHOUT tuner
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/no-tuner.csv

# Apply tuner and run again
sudo ./diretta-renderer-tuner-nosmt.sh
sudo ./bin/DirettaRendererUPnP --target 1 --probe-file /home/user/with-tuner.csv

# Compare
python3 tools/probe-analyze.py --compare no-tuner.csv with-tuner.csv
```

### Tracking Improvements Over Time

```bash
# After each build, capture a reference measurement
python3 tools/probe-analyze.py --json run.csv >> measurements.jsonl

# Each line is a self-contained JSON summary with platform metadata
```

---

## Reading the Results

### What Good Numbers Look Like

The key metrics to watch:

| Metric | What It Means | Healthy Range |
|--------|---------------|---------------|
| `getNewStream()` mean | Our code's per-call overhead | < 5 us |
| `getNewStream()` P99 | Worst-case overhead (excl. outliers) | < 20 us |
| Inter-call StdDev | SDK callback timing consistency | Low = good |
| Underruns | Buffer starved during playback | 0 |
| Buffer Level min | Lowest buffer fill observed | > 10% |
| `sendAudio()` mean | Producer push overhead | < 10 us |

### What to Investigate

- **P99 >> mean:** Occasional spikes, likely from scheduling interference. Check CPU isolation.
- **Underruns > 0:** Buffer too small, prefill too short, or producer too slow. Check buffer level min%.
- **Inter-call jitter high:** SDK callback timing inconsistent. May indicate network or OS scheduling issue.
- **Buffer level min < 10%:** Close to underrun. Consider increasing buffer size or prefill target.
- **Many SEND_AUDIO_FULL events:** Ring buffer too small for the producer rate, or consumer not keeping up.

### The Overhead Budget

At 44.1kHz stereo with 1500 MTU, the SDK calls `getNewStream()` approximately every 2620us. A 1.2us probe overhead represents 0.05% of the cycle. Even at DSD512, where cycles are shorter, the overhead remains well under 1%.

If probe overhead is ever a concern (e.g., on very slow ARM boards), build without `PROBE=1` for production use and with `PROBE=1` only for measurement sessions.

---

## Technical Details

### Architecture

```
Hot Path (audio thread / SDK thread)
    |
    +-- PROBE_BEGIN() --> steady_clock::now() (~20-50ns)
    |   ... existing code ...
    +-- PROBE_END()   --> compute duration, push to ProbeRing (~50ns)
    |
    v
ProbeRing (lock-free SPSC, 131072 entries, 4MB)
    |
    v
Drain Thread (wakes every 100ms, writes to file)
    |
    v
CSV File (/tmp/diretta-probe-*.csv)
    |
    v
probe-analyze.py (offline)
```

### Drop-on-Full Policy

The ProbeRing never blocks the hot path. If the ring is full (drain thread behind), events are silently dropped and a counter increments. The dropped count is written to the CSV footer on shutdown. In practice, with 131K entries and 100ms drain interval, drops should never occur during normal playback.

### Signal Safety

On Ctrl+C, the signal handler stops the renderer, then flushes remaining probe events to the file before exiting. This ensures the last events before shutdown are captured.
