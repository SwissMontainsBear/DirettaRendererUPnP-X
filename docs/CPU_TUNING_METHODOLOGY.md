# CPU Tuning for Diretta Renderer

This document describes the CPU isolation and tuning strategy for optimal audio performance.

## Overview

The tuning script `diretta-renderer-tuner-nosmt.sh` implements three layers of optimization:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| 1 | `nosmt` kernel parameter | Disable SMT/Hyper-Threading |
| 2 | `isolcpus` + systemd slice | Isolate CPUs 1-7 for audio |
| 3 | Thread distribution script | Spread threads across isolated cores |

## CPU Layout (Ryzen 7 7700X)

With nosmt enabled, the system has 8 physical cores (0-7):

```
CPU 0: Housekeeping (IRQs, kernel tasks, system processes)
CPU 1-7: Audio processing (isolated, no IRQs, no timer ticks)
```

## Why Each Layer?

### Layer 1: Disable SMT (nosmt)

SMT (Simultaneous Multi-Threading) / Hyper-Threading shares execution resources between logical cores:
- Shared ALUs, cache, branch predictors
- Can cause micro-stalls and unpredictable latency
- Disabling gives dedicated physical cores

**Result**: 8 dedicated physical cores instead of 16 shared logical cores.

### Layer 2: CPU Isolation (isolcpus)

Kernel parameters prevent the scheduler from using isolated cores for general tasks:

| Parameter | Effect |
|-----------|--------|
| `isolcpus=1-7` | Scheduler won't place tasks on CPUs 1-7 |
| `nohz_full=1-7` | Disable timer ticks on isolated cores |
| `rcu_nocbs=1-7` | Offload RCU callbacks |
| `irqaffinity=0` | Route all IRQs to CPU 0 |

The systemd slice `audio-isolated.slice` explicitly places the renderer on isolated CPUs.

**Result**: CPUs 1-7 are "quiet" - no interrupts, no kernel work, no other processes.

### Layer 3: Thread Distribution

With `isolcpus`, threads are restricted to allowed CPUs but not distributed - they all pile onto CPU 1. The distribution script uses `taskset` to spread threads round-robin across CPUs 1-7.

**Result**: 10-12 threads spread across 7 CPUs instead of all on one.

## Quick Start

```bash
# 1. Apply configuration
sudo ./diretta-renderer-tuner-nosmt.sh apply

# 2. Reboot for kernel parameters
sudo reboot

# 3. Start service and verify
sudo systemctl restart diretta-renderer.service
sudo ./diretta-renderer-tuner-nosmt.sh verify
```

## Commands

| Command | Description |
|---------|-------------|
| `apply` | Apply all configuration (requires reboot) |
| `verify` | Check all three layers are working |
| `distribute` | Manually redistribute threads |
| `status` | Quick status check |
| `revert` | Remove all configuration (requires reboot) |

## Verification

After reboot, `verify` should show:

```
Layer 1: SMT Status
-------------------
[OK] nosmt in kernel cmdline
[OK] SMT disabled (smt/active = 0)
[OK] Expected 8 CPUs with nosmt

Layer 2: CPU Isolation
----------------------
[OK] isolcpus=1-7
[OK] irqaffinity=0
[INFO] Kernel isolated CPUs: 1-7
[OK] Systemd slice exists
[OK] Service override exists

Layer 3: Thread Distribution
----------------------------
[OK] Distribution script exists
[OK] Service running (PID: xxx)

Thread layout:
  TID      CPU
  -------  ---
  786      1
  790      2
  791      3
  ...

Threads per CPU:
  CPU 1: 2 thread(s)
  CPU 2: 2 thread(s)
  CPU 3: 2 thread(s)
  CPU 4: 1 thread(s)
  CPU 5: 1 thread(s)
  CPU 6: 1 thread(s)
  CPU 7: 1 thread(s)
```

## Troubleshooting

### Threads on CPU 0

If any threads appear on CPU 0 after starting the service:

```bash
sudo ./diretta-renderer-tuner-nosmt.sh distribute
```

This re-runs the distribution. The automatic distribution runs 2 seconds after service start, which should catch all threads, but manual redistribution may be needed if threads spawn later.

### nproc still shows 16

The `nosmt` parameter didn't take effect. Check:

```bash
# Verify nosmt is in GRUB config
grep nosmt /etc/default/grub

# Verify GRUB was updated
grep nosmt /boot/grub/grub.cfg   # Debian/Ubuntu
grep nosmt /boot/grub2/grub.cfg  # Fedora/RHEL

# Reboot if changes were made
sudo reboot
```

### Threads concentrated on one CPU

The distribution script didn't run or failed. Check:

```bash
# Check the log
cat /var/log/diretta-thread-distribution.log

# Run manually
sudo ./diretta-renderer-tuner-nosmt.sh distribute
```

### Service won't start after applying

Check for systemd configuration errors:

```bash
systemctl status diretta-renderer.service
journalctl -u diretta-renderer.service
```

If the slice or override is misconfigured:

```bash
# Temporarily remove override
sudo rm -rf /etc/systemd/system/diretta-renderer.service.d
sudo systemctl daemon-reload
sudo systemctl restart diretta-renderer.service
```

## Reverting

To remove all tuning:

```bash
sudo ./diretta-renderer-tuner-nosmt.sh revert
sudo reboot
```

This removes:
- Kernel parameters (nosmt, isolcpus, etc.)
- Systemd slice
- Service override
- Distribution script

## Configuration for Other CPUs

Edit the script to adjust for different CPUs:

```bash
# For 6-core CPU (12 threads with SMT)
HOUSEKEEPING_CPU="0"
AUDIO_CPUS="1-5"
AUDIO_CPUS_LIST="1 2 3 4 5"

# For 4-core CPU (8 threads with SMT)
HOUSEKEEPING_CPU="0"
AUDIO_CPUS="1-3"
AUDIO_CPUS_LIST="1 2 3"
```

## Files Created

| Path | Purpose |
|------|---------|
| `/etc/systemd/system/audio-isolated.slice` | CPU slice for audio |
| `/etc/systemd/system/diretta-renderer.service.d/cpu-tuning.conf` | Service override |
| `/usr/local/bin/distribute-diretta-threads.sh` | Thread distribution script |
| `/var/log/diretta-thread-distribution.log` | Distribution log |

## Further Reading

- [Linux kernel CPU isolation](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [systemd resource control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)
- [Real-time audio on Linux](https://wiki.linuxaudio.org/wiki/system_configuration)
