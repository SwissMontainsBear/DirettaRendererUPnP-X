#!/usr/bin/env python3
"""
DirettaProbe Analysis Tool

Analyzes CSV output from DirettaRendererUPnP instrumentation probes.
No external dependencies (stdlib only - works on RPi without pip install).

Usage:
    python3 probe-analyze.py run.csv                          # Single run summary
    python3 probe-analyze.py --compare baseline.csv test.csv  # Compare two runs
    python3 probe-analyze.py --filter GET_STREAM run.csv      # Filter by event type
    python3 probe-analyze.py --json run.csv                   # JSON output
"""

import csv
import sys
import os
import json
import math
import argparse
from collections import defaultdict


# ═══════════════════════════════════════════════════════════════
# Data Structures
# ═══════════════════════════════════════════════════════════════

class ProbeData:
    """Parsed probe CSV file with metadata and events."""

    def __init__(self, filepath):
        self.filepath = filepath
        self.metadata = {}
        self.events = []
        self._parse()

    def _parse(self):
        with open(self.filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if line.startswith('# ') and ':' in line:
                    key_val = line[2:]
                    colon = key_val.index(':')
                    key = key_val[:colon].strip()
                    val = key_val[colon + 1:].strip()
                    self.metadata[key] = val
                elif line.startswith('#'):
                    continue
                elif line.startswith('timestamp_ns'):
                    continue  # header row
                else:
                    parts = line.split(',')
                    if len(parts) >= 7:
                        self.events.append({
                            'timestamp_ns': int(parts[0]),
                            'event_type': parts[1],
                            'flags': int(parts[2]),
                            'duration_ns': int(parts[3]),
                            'ring_level': int(parts[4]),
                            'ring_capacity': int(parts[5]),
                            'payload': int(parts[6]),
                        })

    @property
    def duration_s(self):
        if not self.events:
            return 0
        return (self.events[-1]['timestamp_ns'] - self.events[0]['timestamp_ns']) / 1e9

    def events_of_type(self, *types):
        return [e for e in self.events if e['event_type'] in types]


# ═══════════════════════════════════════════════════════════════
# Statistics
# ═══════════════════════════════════════════════════════════════

def compute_stats(values):
    """Compute statistical summary of a list of numeric values."""
    if not values:
        return None

    n = len(values)
    sorted_vals = sorted(values)
    mean = sum(values) / n

    if n > 1:
        variance = sum((x - mean) ** 2 for x in values) / (n - 1)
        stddev = math.sqrt(variance)
    else:
        stddev = 0.0

    return {
        'count': n,
        'mean': mean,
        'stddev': stddev,
        'min': sorted_vals[0],
        'max': sorted_vals[-1],
        'p50': sorted_vals[int(n * 0.50)],
        'p90': sorted_vals[int(n * 0.90)] if n >= 10 else sorted_vals[-1],
        'p99': sorted_vals[int(n * 0.99)] if n >= 100 else sorted_vals[-1],
        'p999': sorted_vals[int(n * 0.999)] if n >= 1000 else sorted_vals[-1],
    }


def compute_interval_jitter(events):
    """Compute inter-call interval statistics from timestamped events."""
    if len(events) < 2:
        return None

    intervals = []
    for i in range(1, len(events)):
        dt = (events[i]['timestamp_ns'] - events[i - 1]['timestamp_ns']) / 1000.0  # ns -> us
        intervals.append(dt)

    return compute_stats(intervals)


# ═══════════════════════════════════════════════════════════════
# Text Histogram
# ═══════════════════════════════════════════════════════════════

def text_histogram(values, bins=None, width=35, unit="us"):
    """Generate a text histogram string."""
    if not values:
        return "  (no data)\n"

    if bins is None:
        # Auto-generate bins based on data distribution
        p99 = sorted(values)[int(len(values) * 0.99)] if len(values) >= 100 else max(values)
        if p99 <= 5:
            bins = [0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
        elif p99 <= 20:
            bins = [0, 1, 2, 3, 5, 10, 20]
        elif p99 <= 100:
            bins = [0, 5, 10, 20, 50, 100]
        elif p99 <= 1000:
            bins = [0, 10, 50, 100, 200, 500, 1000]
        else:
            bins = [0, 100, 500, 1000, 2000, 5000]

    # Count values in each bin
    counts = [0] * len(bins)
    overflow = 0
    for v in values:
        placed = False
        for i in range(len(bins) - 1):
            if bins[i] <= v < bins[i + 1]:
                counts[i] += 1
                placed = True
                break
        if not placed:
            overflow += 1

    max_count = max(max(counts), overflow) if counts else overflow
    total = len(values)

    # Determine label format: use decimals if any bin edge has a fractional part
    use_decimals = any(b != int(b) for b in bins)
    fmt = '.1f' if use_decimals else '.0f'

    lines = []
    for i in range(len(bins) - 1):
        label = f"  {bins[i]:{fmt}}-{bins[i+1]:{fmt}}"
        bar_len = int(counts[i] / max_count * width) if max_count > 0 else 0
        bar = "\u2588" * bar_len
        pct = 100.0 * counts[i] / total if total > 0 else 0
        lines.append(f"{label:>12} {unit} |{bar:<{width}}| {counts[i]:>7,}  ({pct:5.1f}%)")

    if overflow > 0:
        label = f"  {bins[-1]:{fmt}}+"
        bar_len = int(overflow / max_count * width) if max_count > 0 else 0
        bar = "\u2588" * bar_len
        pct = 100.0 * overflow / total if total > 0 else 0
        lines.append(f"{label:>12} {unit} |{bar:<{width}}| {overflow:>7,}  ({pct:5.1f}%)")

    return '\n'.join(lines) + '\n'


# ═══════════════════════════════════════════════════════════════
# Report Generation
# ═══════════════════════════════════════════════════════════════

def format_stat_line(label, stats, key, unit="us", decimals=1):
    """Format a single statistics line."""
    val = stats[key]
    return f"  {label:<10} {val:>{8}.{decimals}f} {unit}"


def print_stats_block(label, stats, show_histogram=True, values=None):
    """Print a complete statistics block."""
    if stats is None:
        print(f"\n{label}")
        print("  (no data)")
        return

    print(f"\n{label}")
    print(f"  Count:   {stats['count']:>10,}")
    print(f"  Mean:    {stats['mean']:>10.1f} us")
    print(f"  StdDev:  {stats['stddev']:>10.1f} us")
    print(f"  P50:     {stats['p50']:>10.1f}    "
          f"P90: {stats['p90']:.1f}    "
          f"P99: {stats['p99']:.1f}    "
          f"P99.9: {stats['p999']:.1f}    "
          f"Max: {stats['max']:.1f}")

    if show_histogram and values:
        print()
        print(text_histogram(values))


def generate_report(data, event_filter=None):
    """Generate a full single-run report."""
    platform = data.metadata.get('platform', 'unknown')
    cpu = data.metadata.get('cpu_model', 'unknown')
    kernel = data.metadata.get('kernel', 'unknown')
    version = data.metadata.get('version', 'unknown')

    print("DirettaProbe Analysis")
    print("\u2550" * 55)
    print(f"  Platform:  {platform} / {cpu}")
    print(f"  Kernel:    {kernel}")
    print(f"  Version:   {version}")
    print(f"  Build:     {data.metadata.get('build_date', 'unknown')}")
    print(f"  Flags:     {data.metadata.get('build_flags', 'unknown')}")
    print(f"  Duration:  {data.duration_s:.1f}s")
    print(f"  Events:    {len(data.events):,}")
    print("\u2550" * 55)

    # --- getNewStream() latency ---
    get_stream_events = data.events_of_type('GET_STREAM')
    if event_filter is None or 'GET_STREAM' in event_filter:
        durations_us = [e['duration_ns'] / 1000.0 for e in get_stream_events]
        stats = compute_stats(durations_us)
        print_stats_block("getNewStream() Latency (us)", stats,
                          show_histogram=True, values=durations_us)

    # --- getNewStream() inter-call jitter ---
    all_consumer_events = data.events_of_type('GET_STREAM', 'GET_STREAM_UNDERRUN', 'GET_STREAM_SILENCE')
    if event_filter is None or 'GET_STREAM' in event_filter:
        jitter_stats = compute_interval_jitter(all_consumer_events)
        if jitter_stats:
            print(f"\ngetNewStream() Inter-call Interval (us)")
            print(f"  Mean:    {jitter_stats['mean']:>10.1f} us")
            print(f"  StdDev:  {jitter_stats['stddev']:>10.1f} us")
            print(f"  P99:     {jitter_stats['p99']:>10.1f} us")
            print(f"  Max:     {jitter_stats['max']:>10.1f} us")

    # --- Underruns ---
    underrun_events = data.events_of_type('GET_STREAM_UNDERRUN')
    if event_filter is None:
        print(f"\nUnderruns: {len(underrun_events)}")

    # --- Buffer level ---
    if event_filter is None or 'GET_STREAM' in event_filter:
        buffer_pcts = []
        for e in get_stream_events:
            if e['ring_capacity'] > 0:
                buffer_pcts.append(100.0 * e['ring_level'] / e['ring_capacity'])
        if buffer_pcts:
            bstats = compute_stats(buffer_pcts)
            print(f"\nBuffer Level: mean={bstats['mean']:.1f}%  "
                  f"min={bstats['min']:.1f}%  max={bstats['max']:.1f}%")

    # --- sendAudio() latency ---
    send_events = data.events_of_type('SEND_AUDIO')
    if event_filter is None or 'SEND_AUDIO' in event_filter:
        durations_us = [e['duration_ns'] / 1000.0 for e in send_events]
        stats = compute_stats(durations_us)
        print_stats_block("sendAudio() Latency (us)", stats,
                          show_histogram=True, values=durations_us)

    # --- Session events ---
    session_starts = data.events_of_type('SESSION_START')
    session_ends = data.events_of_type('SESSION_END')
    format_changes = data.events_of_type('FORMAT_CHANGE')
    if event_filter is None:
        print(f"\nSessions: {len(session_starts)} started, {len(session_ends)} ended")
        if format_changes:
            print(f"Format changes: {len(format_changes)}")

    # --- Silence breakdown ---
    silence_events = data.events_of_type('GET_STREAM_SILENCE')
    if event_filter is None and silence_events:
        reasons = defaultdict(int)
        reason_names = {1: 'shutdown', 2: 'stop', 3: 'prefill', 4: 'stabilization', 5: 'reconfiguring'}
        for e in silence_events:
            name = reason_names.get(e['flags'], f'unknown({e["flags"]})')
            reasons[name] += 1
        print(f"\nSilence buffers sent: {len(silence_events)}")
        for reason, count in sorted(reasons.items(), key=lambda x: -x[1]):
            print(f"  {reason}: {count:,}")

    print()


def generate_comparison(data_a, data_b):
    """Generate a comparison report between two runs."""
    print("DirettaProbe Comparison")
    print("\u2550" * 60)
    print(f"{'':30} {'Baseline':>12}  {'Experiment':>12}")
    print(f"  Platform:{'':19} "
          f"{data_a.metadata.get('platform', '?'):>12}  "
          f"{data_b.metadata.get('platform', '?'):>12}")
    print(f"  Kernel:{'':21} "
          f"{data_a.metadata.get('kernel', '?')[:12]:>12}  "
          f"{data_b.metadata.get('kernel', '?')[:12]:>12}")
    print(f"  Duration:{'':19} "
          f"{data_a.duration_s:>11.1f}s  "
          f"{data_b.duration_s:>11.1f}s")
    print("\u2550" * 60)

    def compare_stats(label, stats_a, stats_b, keys=None):
        if keys is None:
            keys = [('mean', 'Mean'), ('p99', 'P99'), ('p999', 'P99.9'), ('max', 'Max')]

        print(f"\n{label}")
        print(f"{'':30} {'Baseline':>12}  {'Experiment':>12}  {'Delta':>8}")

        for key, name in keys:
            va = stats_a[key] if stats_a else 0
            vb = stats_b[key] if stats_b else 0
            if va > 0:
                delta_pct = ((vb - va) / va) * 100
                delta_str = f"{delta_pct:+.1f}%"
            else:
                delta_str = "n/a"
            print(f"  {name:<28} {va:>12.1f}  {vb:>12.1f}  {delta_str:>8}")

    # getNewStream() latency comparison
    gs_a = [e['duration_ns'] / 1000.0 for e in data_a.events_of_type('GET_STREAM')]
    gs_b = [e['duration_ns'] / 1000.0 for e in data_b.events_of_type('GET_STREAM')]
    compare_stats("getNewStream() Latency (us)",
                  compute_stats(gs_a), compute_stats(gs_b))

    # Inter-call jitter comparison
    all_a = data_a.events_of_type('GET_STREAM', 'GET_STREAM_UNDERRUN', 'GET_STREAM_SILENCE')
    all_b = data_b.events_of_type('GET_STREAM', 'GET_STREAM_UNDERRUN', 'GET_STREAM_SILENCE')
    jitter_a = compute_interval_jitter(all_a)
    jitter_b = compute_interval_jitter(all_b)
    compare_stats("Inter-call Jitter (us)", jitter_a, jitter_b,
                  keys=[('stddev', 'StdDev'), ('p99', 'P99'), ('max', 'Max')])

    # sendAudio() latency comparison
    sa_a = [e['duration_ns'] / 1000.0 for e in data_a.events_of_type('SEND_AUDIO')]
    sa_b = [e['duration_ns'] / 1000.0 for e in data_b.events_of_type('SEND_AUDIO')]
    compare_stats("sendAudio() Latency (us)",
                  compute_stats(sa_a), compute_stats(sa_b))

    # Underruns
    ur_a = len(data_a.events_of_type('GET_STREAM_UNDERRUN'))
    ur_b = len(data_b.events_of_type('GET_STREAM_UNDERRUN'))
    check = "\u2713" if ur_b <= ur_a else "\u2717"
    print(f"\nUnderruns:{'':20} {ur_a:>12}  {ur_b:>12}  {check}")

    print()


def generate_json(data):
    """Generate JSON summary for programmatic use."""
    gs_events = data.events_of_type('GET_STREAM')
    sa_events = data.events_of_type('SEND_AUDIO')
    all_consumer = data.events_of_type('GET_STREAM', 'GET_STREAM_UNDERRUN', 'GET_STREAM_SILENCE')

    gs_durations = [e['duration_ns'] / 1000.0 for e in gs_events]
    sa_durations = [e['duration_ns'] / 1000.0 for e in sa_events]

    result = {
        'metadata': data.metadata,
        'duration_s': data.duration_s,
        'total_events': len(data.events),
        'getNewStream': compute_stats(gs_durations),
        'getNewStream_jitter': compute_interval_jitter(all_consumer),
        'sendAudio': compute_stats(sa_durations),
        'underruns': len(data.events_of_type('GET_STREAM_UNDERRUN')),
        'sessions': len(data.events_of_type('SESSION_START')),
        'format_changes': len(data.events_of_type('FORMAT_CHANGE')),
    }

    # Buffer level stats
    buffer_pcts = []
    for e in gs_events:
        if e['ring_capacity'] > 0:
            buffer_pcts.append(100.0 * e['ring_level'] / e['ring_capacity'])
    if buffer_pcts:
        result['buffer_level'] = compute_stats(buffer_pcts)

    print(json.dumps(result, indent=2, default=str))


# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description='DirettaProbe Analysis Tool',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s run.csv                          Single run analysis
  %(prog)s --compare baseline.csv test.csv  Compare two runs
  %(prog)s --filter GET_STREAM run.csv      Filter by event type
  %(prog)s --json run.csv                   JSON output for scripting
""")
    parser.add_argument('files', nargs='*', help='Probe CSV file(s)')
    parser.add_argument('--compare', action='store_true',
                        help='Compare two runs (requires exactly 2 files)')
    parser.add_argument('--filter', type=str, default=None,
                        help='Filter by event type (e.g., GET_STREAM, SEND_AUDIO)')
    parser.add_argument('--json', action='store_true',
                        help='Output summary as JSON')

    args = parser.parse_args()

    if not args.files:
        parser.print_help()
        sys.exit(1)

    if args.compare:
        if len(args.files) != 2:
            print("Error: --compare requires exactly 2 CSV files", file=sys.stderr)
            sys.exit(1)
        data_a = ProbeData(args.files[0])
        data_b = ProbeData(args.files[1])
        generate_comparison(data_a, data_b)
    elif args.json:
        data = ProbeData(args.files[0])
        generate_json(data)
    else:
        data = ProbeData(args.files[0])
        event_filter = args.filter.split(',') if args.filter else None
        generate_report(data, event_filter)


if __name__ == '__main__':
    main()
