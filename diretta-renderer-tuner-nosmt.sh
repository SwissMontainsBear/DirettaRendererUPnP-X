#!/bin/bash
#
# diretta-renderer-tuner-nosmt.sh
# Complete CPU isolation and tuning for diretta-renderer.service
#
# This script implements three layers of optimization:
#   1. SMT disabled (nosmt) - 8 physical cores only
#   2. CPU isolation (isolcpus) - cores 1-7 for audio, core 0 for housekeeping
#   3. Thread distribution - spread threads across isolated cores
#
# For Ryzen 7 7700X (8 cores / 16 threads):
#   With nosmt: cores 0-7 available (physical only)
#   Core 0: housekeeping (IRQs, kernel, system tasks)
#   Cores 1-7: isolated for audio processing
#
# Usage:
#   sudo ./diretta-renderer-tuner-nosmt.sh apply
#   sudo reboot
#   sudo ./diretta-renderer-tuner-nosmt.sh verify
#   sudo ./diretta-renderer-tuner-nosmt.sh distribute
#   sudo ./diretta-renderer-tuner-nosmt.sh status

set -euo pipefail

# =============================================================================
# CONFIGURATION - Adjust for your CPU if different from Ryzen 7 7700X
# =============================================================================

# With nosmt on 8-core CPU: only cores 0-7 available
HOUSEKEEPING_CPU="0"
AUDIO_CPUS="1-7"
AUDIO_CPUS_LIST="1 2 3 4 5 6 7"

# =============================================================================
# PATHS AND CONSTANTS
# =============================================================================

GRUB_FILE="/etc/default/grub"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_BIN="/usr/local/bin"

SERVICE_NAME="diretta-renderer.service"
SLICE_NAME="audio-isolated.slice"
DIST_SCRIPT="${LOCAL_BIN}/distribute-diretta-threads.sh"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)" >&2
        exit 1
    fi
}

show_grub() {
    echo "GRUB_CMDLINE_LINUX:"
    grep "^GRUB_CMDLINE_LINUX=" "$GRUB_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (not found)"
}

get_service_pid() {
    systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null || echo ""
}

# =============================================================================
# APPLY - Configures all three layers
# =============================================================================

do_apply() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Diretta Renderer CPU Tuner - Apply Configuration"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration:"
    echo "  SMT:          DISABLED (nosmt)"
    echo "  Housekeeping: CPU ${HOUSEKEEPING_CPU}"
    echo "  Audio:        CPUs ${AUDIO_CPUS} (isolated)"
    echo ""

    # Backup GRUB
    cp "$GRUB_FILE" "${GRUB_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "GRUB backup created"
    echo ""

    echo "BEFORE:"
    show_grub
    echo ""

    # -------------------------------------------------------------------------
    # Layer 1 & 2: Kernel parameters (nosmt + isolation)
    # -------------------------------------------------------------------------
    echo "Configuring kernel parameters..."

    # Remove existing parameters
    sed -i -E 's/ ?nosmt//g' "$GRUB_FILE"
    sed -i -E 's/ ?isolcpus=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?nohz_full=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?nohz=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?rcu_nocbs=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?irqaffinity=[^ "]+//g' "$GRUB_FILE"

    # Build new parameters
    local kernel_params="nosmt isolcpus=${AUDIO_CPUS} nohz=on nohz_full=${AUDIO_CPUS} rcu_nocbs=${AUDIO_CPUS} irqaffinity=${HOUSEKEEPING_CPU}"

    # Add to GRUB_CMDLINE_LINUX
    if grep -qE '^GRUB_CMDLINE_LINUX=""' "$GRUB_FILE"; then
        sed -i "s/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"${kernel_params}\"/" "$GRUB_FILE"
    else
        sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${kernel_params} /" "$GRUB_FILE"
    fi

    # Clean up multiple spaces
    sed -i 's/  */ /g' "$GRUB_FILE"

    echo "AFTER:"
    show_grub
    echo ""

    # Update GRUB
    echo "Updating GRUB bootloader..."
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "WARNING: Could not find grub update command"
        echo "Run manually: grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
    echo ""

    # -------------------------------------------------------------------------
    # Layer 2b: Systemd slice for CPU pinning
    # -------------------------------------------------------------------------
    echo "Creating systemd slice: ${SLICE_NAME}"
    cat << EOF > "${SYSTEMD_DIR}/${SLICE_NAME}"
[Unit]
Description=Isolated CPU slice for audio processing

[Slice]
AllowedCPUs=${AUDIO_CPUS}
CPUQuota=100%
EOF

    # -------------------------------------------------------------------------
    # Layer 2c: Service override
    # -------------------------------------------------------------------------
    echo "Creating service override..."
    local override_dir="${SYSTEMD_DIR}/${SERVICE_NAME}.d"
    mkdir -p "$override_dir"

    cat << EOF > "${override_dir}/cpu-tuning.conf"
[Service]
# Run on isolated audio CPUs
Slice=${SLICE_NAME}

# Real-time scheduling
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=80

# High priority
Nice=-15

# Memory locking
LimitMEMLOCK=infinity
LimitRTPRIO=99

# Distribute threads after startup
ExecStartPost=${DIST_SCRIPT}
EOF

    # -------------------------------------------------------------------------
    # Layer 3: Thread distribution script
    # -------------------------------------------------------------------------
    echo "Creating thread distribution script: ${DIST_SCRIPT}"
    cat << 'SCRIPT' > "${DIST_SCRIPT}"
#!/bin/bash
# Distribute diretta-renderer threads across isolated CPUs
# Called automatically by systemd after service start

SERVICE="diretta-renderer.service"
CPUS="1 2 3 4 5 6 7"
LOG="/var/log/diretta-thread-distribution.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"; }

# Wait for threads to spawn
sleep 2

PID=$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null)
if [[ -z "$PID" || "$PID" == "0" ]]; then
    log "Service not running, exiting"
    exit 0
fi

log "Distributing threads for PID $PID"

CPU_ARRAY=($CPUS)
NUM_CPUS=${#CPU_ARRAY[@]}
i=0

for tid in $(ps -T -o tid= -p "$PID" 2>/dev/null); do
    cpu_idx=$((i % NUM_CPUS))
    target=${CPU_ARRAY[$cpu_idx]}
    if taskset -pc "$target" "$tid" > /dev/null 2>&1; then
        log "  TID $tid -> CPU $target"
    fi
    i=$((i + 1))
done

log "Distribution complete: $i threads across $NUM_CPUS CPUs"
SCRIPT

    chmod +x "${DIST_SCRIPT}"

    # Reload systemd
    echo "Reloading systemd..."
    systemctl daemon-reload

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Configuration Applied Successfully"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "REBOOT REQUIRED for kernel parameters to take effect."
    echo ""
    echo "After reboot:"
    echo "  1. sudo systemctl restart ${SERVICE_NAME}"
    echo "  2. sudo $0 verify"
    echo ""
}

# =============================================================================
# VERIFY - Check all three layers
# =============================================================================

do_verify() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Diretta Renderer CPU Tuner - Verification"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local errors=0

    # -------------------------------------------------------------------------
    # Layer 1: SMT (nosmt)
    # -------------------------------------------------------------------------
    echo "Layer 1: SMT Status"
    echo "-------------------"

    if grep -q "nosmt" /proc/cmdline; then
        echo "[OK] nosmt in kernel cmdline"
    else
        echo "[FAIL] nosmt NOT in kernel cmdline"
        errors=$((errors + 1))
    fi

    if [[ -f /sys/devices/system/cpu/smt/active ]]; then
        local smt_active
        smt_active=$(cat /sys/devices/system/cpu/smt/active)
        if [[ "$smt_active" == "0" ]]; then
            echo "[OK] SMT disabled (smt/active = 0)"
        else
            echo "[FAIL] SMT still enabled (smt/active = $smt_active)"
            errors=$((errors + 1))
        fi
    fi

    local cpu_count
    cpu_count=$(nproc)
    echo "[INFO] CPU count: $cpu_count"
    if [[ "$cpu_count" -eq 8 ]]; then
        echo "[OK] Expected 8 CPUs with nosmt"
    else
        echo "[WARN] Expected 8 CPUs, got $cpu_count"
    fi
    echo ""

    # -------------------------------------------------------------------------
    # Layer 2: CPU Isolation
    # -------------------------------------------------------------------------
    echo "Layer 2: CPU Isolation"
    echo "----------------------"

    local cmdline
    cmdline=$(cat /proc/cmdline)

    if echo "$cmdline" | grep -q "isolcpus=${AUDIO_CPUS}"; then
        echo "[OK] isolcpus=${AUDIO_CPUS}"
    else
        echo "[FAIL] isolcpus not set correctly"
        errors=$((errors + 1))
    fi

    if echo "$cmdline" | grep -q "irqaffinity=${HOUSEKEEPING_CPU}"; then
        echo "[OK] irqaffinity=${HOUSEKEEPING_CPU}"
    else
        echo "[WARN] irqaffinity not set"
    fi

    if [[ -f /sys/devices/system/cpu/isolated ]]; then
        local isolated
        isolated=$(cat /sys/devices/system/cpu/isolated)
        echo "[INFO] Kernel isolated CPUs: ${isolated:-none}"
    fi

    if [[ -f "${SYSTEMD_DIR}/${SLICE_NAME}" ]]; then
        echo "[OK] Systemd slice exists"
    else
        echo "[FAIL] Systemd slice missing"
        errors=$((errors + 1))
    fi

    if [[ -f "${SYSTEMD_DIR}/${SERVICE_NAME}.d/cpu-tuning.conf" ]]; then
        echo "[OK] Service override exists"
    else
        echo "[FAIL] Service override missing"
        errors=$((errors + 1))
    fi
    echo ""

    # -------------------------------------------------------------------------
    # Layer 3: Thread Distribution
    # -------------------------------------------------------------------------
    echo "Layer 3: Thread Distribution"
    echo "----------------------------"

    if [[ -f "${DIST_SCRIPT}" ]]; then
        echo "[OK] Distribution script exists"
    else
        echo "[FAIL] Distribution script missing"
        errors=$((errors + 1))
    fi

    local pid
    pid=$(get_service_pid)

    if [[ -z "$pid" || "$pid" == "0" ]]; then
        echo "[INFO] Service not running - start it to verify thread distribution"
    else
        echo "[OK] Service running (PID: $pid)"
        echo ""
        echo "Thread layout:"
        echo "  TID      CPU"
        echo "  -------  ---"

        local cpu0_count=0
        while read -r tid cpu; do
            printf "  %-7s  %s" "$tid" "$cpu"
            if [[ "$cpu" == "0" ]]; then
                echo " <- WARNING"
                cpu0_count=$((cpu0_count + 1))
            else
                echo ""
            fi
        done < <(ps -T -o tid=,psr= -p "$pid" 2>/dev/null)

        echo ""
        echo "Threads per CPU:"
        ps -T -o psr= -p "$pid" 2>/dev/null | sort -n | uniq -c | while read -r count cpu; do
            printf "  CPU %s: %s thread(s)\n" "$cpu" "$count"
        done

        if [[ $cpu0_count -gt 0 ]]; then
            echo ""
            echo "[WARN] $cpu0_count thread(s) on CPU 0 - run 'distribute' command"
        fi
    fi
    echo ""

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    echo "═══════════════════════════════════════════════════════════════"
    if [[ $errors -eq 0 ]]; then
        echo "  All checks passed"
    else
        echo "  $errors issue(s) detected"
    fi
    echo "═══════════════════════════════════════════════════════════════"
}

# =============================================================================
# DISTRIBUTE - Manually trigger thread distribution
# =============================================================================

do_distribute() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Distributing Threads"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local pid
    pid=$(get_service_pid)

    if [[ -z "$pid" || "$pid" == "0" ]]; then
        echo "ERROR: ${SERVICE_NAME} is not running"
        exit 1
    fi

    echo "PID: $pid"
    echo "Target CPUs: ${AUDIO_CPUS_LIST}"
    echo ""

    local -a cpus=($AUDIO_CPUS_LIST)
    local num_cpus=${#cpus[@]}

    echo "Before:"
    ps -T -o tid=,psr= -p "$pid" 2>/dev/null | while read -r tid cpu; do
        printf "  TID %-7s on CPU %s\n" "$tid" "$cpu"
    done
    echo ""

    echo "Distributing (round-robin):"
    local i=0
    for tid in $(ps -T -o tid= -p "$pid" 2>/dev/null); do
        local cpu_idx=$((i % num_cpus))
        local target_cpu=${cpus[$cpu_idx]}
        local current_cpu
        current_cpu=$(ps -o psr= -p "$tid" 2>/dev/null | tr -d ' ')

        if taskset -pc "$target_cpu" "$tid" > /dev/null 2>&1; then
            echo "  TID $tid: CPU $current_cpu -> $target_cpu"
        else
            echo "  TID $tid: FAILED"
        fi
        i=$((i + 1))
    done

    echo ""
    echo "After (may take a moment for threads to migrate):"
    sleep 1
    ps -T -o tid=,psr= -p "$pid" 2>/dev/null | while read -r tid cpu; do
        printf "  TID %-7s on CPU %s\n" "$tid" "$cpu"
    done
}

# =============================================================================
# STATUS - Quick status check
# =============================================================================

do_status() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Diretta Renderer CPU Tuner - Status"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # SMT
    echo -n "SMT: "
    if [[ -f /sys/devices/system/cpu/smt/active ]]; then
        local smt=$(cat /sys/devices/system/cpu/smt/active)
        if [[ "$smt" == "0" ]]; then
            echo "DISABLED"
        else
            echo "ENABLED"
        fi
    else
        echo "UNKNOWN"
    fi

    # CPU count
    echo "CPUs: $(nproc)"

    # Isolation
    echo -n "Isolated: "
    cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none"

    # Service
    echo -n "Service: "
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        local pid=$(get_service_pid)
        echo "RUNNING (PID $pid)"

        echo ""
        echo "Threads per CPU:"
        ps -T -o psr= -p "$pid" 2>/dev/null | sort -n | uniq -c | while read -r count cpu; do
            printf "  CPU %s: %s\n" "$cpu" "$count"
        done
    else
        echo "STOPPED"
    fi
}

# =============================================================================
# REVERT - Remove all configuration
# =============================================================================

do_revert() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Diretta Renderer CPU Tuner - Revert"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    echo "Removing kernel parameters..."
    sed -i -E 's/ ?nosmt//g' "$GRUB_FILE"
    sed -i -E 's/ ?isolcpus=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?nohz_full=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?nohz=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?rcu_nocbs=[^ "]+//g' "$GRUB_FILE"
    sed -i -E 's/ ?irqaffinity=[^ "]+//g' "$GRUB_FILE"
    sed -i 's/  */ /g' "$GRUB_FILE"

    show_grub
    echo ""

    echo "Updating GRUB..."
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi

    echo "Removing systemd configurations..."
    rm -f "${SYSTEMD_DIR}/${SLICE_NAME}"
    rm -rf "${SYSTEMD_DIR}/${SERVICE_NAME}.d"
    rm -f "${DIST_SCRIPT}"

    systemctl daemon-reload

    echo ""
    echo "Configuration reverted. REBOOT REQUIRED."
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
Diretta Renderer CPU Tuner (nosmt)
==================================

Complete CPU isolation for audio: SMT disabled, cores isolated, threads distributed.

Usage: sudo $0 [command]

Commands:
  apply       - Apply all configuration (requires reboot)
  verify      - Check all layers are working
  distribute  - Manually distribute threads now
  status      - Quick status check
  revert      - Remove all configuration (requires reboot)

Configuration:
  Housekeeping: CPU ${HOUSEKEEPING_CPU}
  Audio:        CPUs ${AUDIO_CPUS}

Workflow:
  1. sudo $0 apply
  2. sudo reboot
  3. sudo systemctl restart ${SERVICE_NAME}
  4. sudo $0 verify

EOF
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-}" in
    apply)
        check_root
        do_apply
        ;;
    verify)
        do_verify
        ;;
    distribute)
        check_root
        do_distribute
        ;;
    status)
        do_status
        ;;
    revert)
        check_root
        do_revert
        ;;
    *)
        usage
        ;;
esac
