#!/bin/bash
#
# diretta-renderer-tuner.sh
# CPU isolation and real-time tuning for diretta-renderer.service
#
# Based on audiophile-tuner-fixed.sh but simplified for a single-service setup.
# DirettaRendererUPnP is a standalone UPnP/DLNA renderer - no secondary service needed.
#
# Features:
#   - CPU isolation via kernel parameters (isolcpus, nohz_full, rcu_nocbs)
#   - Systemd slice for CPU pinning
#   - Real-time FIFO scheduling for the audio hot path
#   - IRQ affinity to housekeeping cores
#   - CPU governor set to performance
#
# Usage: sudo ./diretta-renderer-tuner.sh [apply|revert|status]

# --- Bash Best Practices ---
set -euo pipefail

# =============================================================================
# CONFIGURATION - EDIT THESE VALUES TO MATCH YOUR SYSTEM
# =============================================================================

# Example for Ryzen 7 7700X (8 cores / 16 threads: 0-15)
# Adjust for your CPU topology. Use `lscpu -e` to see your layout.

# Housekeeping cores: System tasks, IRQs, kernel work
# Typically use 1-2 physical cores (with their SMT siblings)
HOUSEKEEPING_CPUS="0,8"

# Diretta Renderer cores: Isolated for audio processing
# Use remaining cores for best performance
# The renderer has multiple threads: UPnP, decode, Diretta SDK sending
RENDERER_CPUS="1-7,9-15"

# =============================================================================
# DERIVED VARIABLES (DO NOT EDIT)
# =============================================================================

# System paths
GRUB_FILE="/etc/default/grub"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_BIN_DIR="/usr/local/bin"

# Service configuration
SERVICE_NAME="diretta-renderer.service"
SLICE_NAME="diretta-renderer.slice"

# Helper scripts/services
GOVERNOR_SERVICE="cpu-performance-diretta.service"
IRQ_SCRIPT_NAME="set-irq-affinity-diretta.sh"
IRQ_SCRIPT_PATH="${LOCAL_BIN_DIR}/${IRQ_SCRIPT_NAME}"
THREAD_DIST_SCRIPT_NAME="distribute-diretta-threads.sh"
THREAD_DIST_SCRIPT_PATH="${LOCAL_BIN_DIR}/${THREAD_DIST_SCRIPT_NAME}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root. Please use 'sudo'." >&2
        exit 1
    fi
}

usage() {
    cat <<EOF
Diretta Renderer CPU Tuner
==========================

Usage: sudo $0 [apply|revert|status|redistribute]

Commands:
  apply        - Apply CPU isolation and real-time tuning
  revert       - Remove all tuning configurations
  status       - Check current tuning status
  redistribute - Manually redistribute threads now (for testing)

Configuration (edit script to change):
  HOUSEKEEPING_CPUS = ${HOUSEKEEPING_CPUS}
  RENDERER_CPUS     = ${RENDERER_CPUS}

This script isolates CPU cores for the Diretta Renderer to minimize
audio jitter and ensure consistent low-latency playback.
EOF
}

# Expand CPU range notation (e.g., "1-3,8" -> "1 2 3 8")
expand_cpu_list() {
    local input="$1"
    local result=""

    # Replace commas with spaces, then process ranges
    for part in ${input//,/ }; do
        if [[ "$part" == *-* ]]; then
            local start="${part%-*}"
            local end="${part#*-}"
            for ((i=start; i<=end; i++)); do
                result+="$i "
            done
        else
            result+="$part "
        fi
    done

    echo "$result"
}

# =============================================================================
# APPLY FUNCTIONS
# =============================================================================

apply_grub_config() {
    echo "INFO: Applying GRUB kernel parameters for CPU isolation..."

    # Remove any previous instances of these parameters
    sed -i -E 's/ (isolcpus|nohz|nohz_full|rcu_nocbs|irqaffinity)=[^"]*//g' "${GRUB_FILE}"

    # Build new kernel parameters
    local grub_cmdline="isolcpus=${RENDERER_CPUS} nohz=on nohz_full=${RENDERER_CPUS} rcu_nocbs=${RENDERER_CPUS} irqaffinity=${HOUSEKEEPING_CPUS}"

    # Append to GRUB_CMDLINE_LINUX
    sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 ${grub_cmdline}\"|" "${GRUB_FILE}"

    # Update GRUB
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "WARNING: Could not find update-grub or grub2-mkconfig."
        echo "         Please update GRUB manually."
    fi

    echo "SUCCESS: GRUB configuration updated."
}

apply_systemd_slice() {
    echo "INFO: Creating systemd slice for CPU pinning..."

    cat << EOF > "${SYSTEMD_DIR}/${SLICE_NAME}"
[Unit]
Description=Slice for Diretta Renderer audio service
Before=slices.target

[Slice]
# Pin to isolated audio cores
AllowedCPUs=${RENDERER_CPUS}
# Allow full CPU usage
CPUQuota=100%
EOF

    echo "SUCCESS: Systemd slice created: ${SLICE_NAME}"
}

apply_service_override() {
    echo "INFO: Creating service drop-in for real-time scheduling..."

    local override_dir="${SYSTEMD_DIR}/${SERVICE_NAME}.d"
    mkdir -p "${override_dir}"

    cat << EOF > "${override_dir}/10-isolation.conf"
[Service]
# Use dedicated CPU slice
Slice=${SLICE_NAME}

# Real-time scheduling for audio hot path
# FIFO is preferred for audio daemons (consistent latency)
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=90

# High process priority
Nice=-19

# I/O scheduling - realtime class
IOSchedulingClass=realtime
IOSchedulingPriority=0

# Memory locking for Diretta SDK buffers
LimitMEMLOCK=infinity

# Real-time priority limit
LimitRTPRIO=99

# Distribute threads across cores after startup
# This prevents all threads from piling onto one core
ExecStartPost=${THREAD_DIST_SCRIPT_PATH} \$MAINPID
EOF

    echo "SUCCESS: Service override created: ${override_dir}/10-isolation.conf"
}

apply_irq_config() {
    echo "INFO: Creating IRQ affinity script..."

    cat << EOF > "${IRQ_SCRIPT_PATH}"
#!/bin/bash
# Set all IRQs to housekeeping cores to avoid interrupting audio processing

HOUSEKEEPING_CPUS="${HOUSEKEEPING_CPUS}"
LOG_FILE="/var/log/irq-affinity-diretta.log"

echo "\$(date): Starting IRQ affinity setup for Diretta Renderer" | tee "\$LOG_FILE"

# Set default affinity for new IRQs
echo "\$HOUSEKEEPING_CPUS" > /proc/irq/default_smp_affinity_list 2>> "\$LOG_FILE" || true

# Move all existing IRQs to housekeeping cores
for irq_dir in /proc/irq/*; do
    if [ -f "\$irq_dir/smp_affinity_list" ]; then
        irq=\$(basename "\$irq_dir")
        echo "\$HOUSEKEEPING_CPUS" > "\$irq_dir/smp_affinity_list" 2>> "\$LOG_FILE" || true
    fi
done

echo "\$(date): IRQ affinity setup complete" | tee -a "\$LOG_FILE"
EOF

    chmod +x "${IRQ_SCRIPT_PATH}"

    # Create systemd service
    cat << EOF > "${SYSTEMD_DIR}/set-irq-affinity-diretta.service"
[Unit]
Description=Set IRQ affinity for Diretta Renderer audio isolation
After=network.target

[Service]
Type=oneshot
ExecStart=${IRQ_SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo "SUCCESS: IRQ affinity configuration created."
}

apply_governor_config() {
    echo "INFO: Creating CPU governor service..."

    local expanded_cpus
    expanded_cpus=$(expand_cpu_list "${RENDERER_CPUS}")

    cat << EOF > "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}"
[Unit]
Description=Set CPU governor to performance for Diretta Renderer cores
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in ${expanded_cpus}; do \
    if [ -f /sys/devices/system/cpu/cpu\$cpu/cpufreq/scaling_governor ]; then \
        echo performance > /sys/devices/system/cpu/cpu\$cpu/cpufreq/scaling_governor 2>/dev/null || \
        cpufreq-set -c \$cpu -g performance 2>/dev/null || true; \
    fi; \
done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo "SUCCESS: CPU governor service created."
}

apply_thread_distribution() {
    echo "INFO: Creating thread distribution script..."

    # Get the list of renderer CPUs as an array for round-robin
    local expanded_cpus
    expanded_cpus=$(expand_cpu_list "${RENDERER_CPUS}")

    cat << 'SCRIPT_HEADER' > "${THREAD_DIST_SCRIPT_PATH}"
#!/bin/bash
#
# distribute-diretta-threads.sh
# Distributes DirettaRenderer threads across available cores round-robin
#
# Called by systemd ExecStartPost after the service starts.
# This spreads threads to avoid all 11+ threads piling onto one core.
#

set -euo pipefail

MAIN_PID="${1:-}"
LOG_FILE="/var/log/diretta-thread-distribution.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" | tee -a "$LOG_FILE"
}

if [[ -z "$MAIN_PID" ]]; then
    log "ERROR: No PID provided"
    exit 1
fi

# Wait for threads to spawn (the service needs a moment to initialize)
sleep 1.0

# Check if process still exists
if ! ps -p "$MAIN_PID" > /dev/null 2>&1; then
    log "WARNING: Process $MAIN_PID no longer exists, skipping"
    exit 0
fi

SCRIPT_HEADER

    # Now add the CPU array (this part uses the expanded variable)
    cat << SCRIPT_CPUS >> "${THREAD_DIST_SCRIPT_PATH}"
# Available renderer CPUs (from tuner configuration)
RENDERER_CPUS_ARRAY=(${expanded_cpus})
NUM_CPUS=\${#RENDERER_CPUS_ARRAY[@]}

SCRIPT_CPUS

    cat << 'SCRIPT_BODY' >> "${THREAD_DIST_SCRIPT_PATH}"
log "Starting thread distribution for PID $MAIN_PID"
log "Available CPUs: ${RENDERER_CPUS_ARRAY[*]} ($NUM_CPUS cores)"

# Get all thread IDs for this process
TIDS=$(ps -T -o tid= -p "$MAIN_PID" 2>/dev/null | tr -d ' ')

if [[ -z "$TIDS" ]]; then
    log "WARNING: No threads found for PID $MAIN_PID"
    exit 0
fi

# Count threads
THREAD_COUNT=$(echo "$TIDS" | wc -l)
log "Found $THREAD_COUNT threads to distribute"

# Distribute threads round-robin across available CPUs
i=0
while read -r tid; do
    if [[ -n "$tid" ]]; then
        cpu_index=$(( i % NUM_CPUS ))
        target_cpu=${RENDERER_CPUS_ARRAY[$cpu_index]}

        if taskset -pc "$target_cpu" "$tid" > /dev/null 2>&1; then
            log "  Thread $tid -> CPU $target_cpu"
        else
            log "  Thread $tid -> CPU $target_cpu (failed, may have exited)"
        fi

        i=$(( i + 1 ))
    fi
done <<< "$TIDS"

log "Thread distribution complete: $i threads distributed across $NUM_CPUS CPUs"

# Show final distribution
log "Final thread layout:"
ps -T -o tid=,psr=,comm= -p "$MAIN_PID" 2>/dev/null | while read -r line; do
    log "  $line"
done

exit 0
SCRIPT_BODY

    chmod +x "${THREAD_DIST_SCRIPT_PATH}"
    echo "SUCCESS: Thread distribution script created: ${THREAD_DIST_SCRIPT_PATH}"
}

# =============================================================================
# REVERT FUNCTIONS
# =============================================================================

revert_grub_config() {
    echo "INFO: Reverting GRUB kernel parameters..."

    sed -i -E 's/ (isolcpus|nohz|nohz_full|rcu_nocbs|irqaffinity)=[^"]*//g' "${GRUB_FILE}"

    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi

    echo "SUCCESS: GRUB configuration reverted."
}

revert_systemd_config() {
    echo "INFO: Removing systemd configurations..."

    # Remove slice
    rm -f "${SYSTEMD_DIR}/${SLICE_NAME}"

    # Remove service override
    rm -rf "${SYSTEMD_DIR}/${SERVICE_NAME}.d"

    # Remove IRQ service and script
    rm -f "${SYSTEMD_DIR}/set-irq-affinity-diretta.service"
    rm -f "${IRQ_SCRIPT_PATH}"

    # Remove governor service
    rm -f "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}"

    # Remove thread distribution script
    rm -f "${THREAD_DIST_SCRIPT_PATH}"

    echo "SUCCESS: Systemd configurations removed."
}

# =============================================================================
# STATUS FUNCTION
# =============================================================================

check_status() {
    echo "=== Diretta Renderer Tuner Status ==="
    echo ""

    local has_error=0

    # 1. GRUB parameters
    echo -n "1. GRUB CPU isolation: "
    if grep -q "isolcpus=" /proc/cmdline; then
        echo "ACTIVE"
        echo "   Current: $(cat /proc/cmdline | grep -oE 'isolcpus=[^ ]+')"
    else
        echo "NOT ACTIVE (requires reboot after apply)"
        has_error=1
    fi

    # 2. Systemd slice
    echo -n "2. Systemd slice (${SLICE_NAME}): "
    if [[ -f "${SYSTEMD_DIR}/${SLICE_NAME}" ]]; then
        echo "EXISTS"
    else
        echo "MISSING"
        has_error=1
    fi

    # 3. Service override
    echo -n "3. Service override: "
    if [[ -f "${SYSTEMD_DIR}/${SERVICE_NAME}.d/10-isolation.conf" ]]; then
        echo "EXISTS"
    else
        echo "MISSING"
        has_error=1
    fi

    # 4. IRQ affinity
    echo -n "4. IRQ affinity service: "
    if [[ -f "${SYSTEMD_DIR}/set-irq-affinity-diretta.service" ]]; then
        local irq_status
        irq_status=$(systemctl is-active set-irq-affinity-diretta.service 2>/dev/null || echo "inactive")
        echo "EXISTS (${irq_status})"
    else
        echo "MISSING"
        has_error=1
    fi

    # 5. Governor service
    echo -n "5. CPU governor service: "
    if [[ -f "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}" ]]; then
        local gov_status
        gov_status=$(systemctl is-active "${GOVERNOR_SERVICE}" 2>/dev/null || echo "inactive")
        echo "EXISTS (${gov_status})"
    else
        echo "MISSING"
        has_error=1
    fi

    # 6. Thread distribution script
    echo -n "6. Thread distribution script: "
    if [[ -f "${THREAD_DIST_SCRIPT_PATH}" ]]; then
        echo "EXISTS"
    else
        echo "MISSING"
        has_error=1
    fi

    echo ""

    # Service status
    echo "=== Service Status ==="
    echo ""
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo "Service: RUNNING"
        systemctl show "${SERVICE_NAME}" -p Slice,CPUSchedulingPolicy,Nice 2>/dev/null | sed 's/^/  /'

        # Show actual CPU affinity
        local main_pid
        main_pid=$(systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null)
        if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
            echo ""
            echo "  Process affinity (allowed CPUs):"
            taskset -pc "$main_pid" 2>/dev/null | sed 's/^/    /' || echo "    (unable to read)"

            echo ""
            echo "  Thread distribution (current):"
            echo "    TID      CPU  COMMAND"
            ps -T -o tid=,psr=,comm= -p "$main_pid" 2>/dev/null | while read -r tid psr comm; do
                printf "    %-8s %-4s %s\n" "$tid" "$psr" "$comm"
            done

            # Count threads per CPU
            echo ""
            echo "  Threads per CPU:"
            ps -T -o psr= -p "$main_pid" 2>/dev/null | sort | uniq -c | while read -r count cpu; do
                printf "    CPU %s: %s threads\n" "$cpu" "$count"
            done
        fi
    else
        echo "Service: NOT RUNNING"
    fi

    echo ""

    # Summary
    if [[ $has_error -eq 0 ]]; then
        echo "=== All configurations in place ==="
        if ! grep -q "isolcpus=" /proc/cmdline; then
            echo "NOTE: Reboot required for kernel parameters to take effect."
        fi
    else
        echo "=== Some configurations missing - run 'apply' ==="
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root

    case "${1:-}" in
        apply)
            echo "=== Applying Diretta Renderer CPU Tuning ==="
            echo ""
            echo "Configuration:"
            echo "  Housekeeping CPUs: ${HOUSEKEEPING_CPUS}"
            echo "  Renderer CPUs:     ${RENDERER_CPUS}"
            echo ""

            apply_grub_config
            apply_systemd_slice
            apply_thread_distribution
            apply_service_override
            apply_irq_config
            apply_governor_config

            echo ""
            echo "INFO: Reloading systemd daemon..."
            systemctl daemon-reload

            echo "INFO: Enabling helper services..."
            systemctl enable set-irq-affinity-diretta.service "${GOVERNOR_SERVICE}" 2>/dev/null || true

            echo ""
            echo "=== Configuration Applied ==="
            echo ""
            echo "IMPORTANT: A REBOOT is required for CPU isolation to take effect."
            echo ""
            echo "After reboot:"
            echo "  - Restart the service: sudo systemctl restart ${SERVICE_NAME}"
            echo "  - Check status: sudo $0 status"
            echo ""
            ;;

        revert)
            echo "=== Reverting Diretta Renderer CPU Tuning ==="
            echo ""

            # Disable services first
            systemctl disable set-irq-affinity-diretta.service "${GOVERNOR_SERVICE}" 2>/dev/null || true

            revert_grub_config
            revert_systemd_config

            echo ""
            echo "INFO: Reloading systemd daemon..."
            systemctl daemon-reload

            echo ""
            echo "=== Configuration Reverted ==="
            echo ""
            echo "IMPORTANT: A REBOOT is required for kernel parameter changes."
            echo ""
            ;;

        status)
            check_status
            ;;

        redistribute)
            echo "=== Manual Thread Redistribution ==="
            echo ""

            # Check if service is running
            if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
                echo "ERROR: ${SERVICE_NAME} is not running"
                exit 1
            fi

            # Get main PID
            local main_pid
            main_pid=$(systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null)
            if [[ -z "$main_pid" || "$main_pid" == "0" ]]; then
                echo "ERROR: Could not get PID for ${SERVICE_NAME}"
                exit 1
            fi

            echo "Service PID: $main_pid"
            echo ""

            # Check if distribution script exists
            if [[ -f "${THREAD_DIST_SCRIPT_PATH}" ]]; then
                echo "Running thread distribution script..."
                "${THREAD_DIST_SCRIPT_PATH}" "$main_pid"
            else
                echo "Thread distribution script not found at ${THREAD_DIST_SCRIPT_PATH}"
                echo "Run 'apply' first to create it, or distributing manually..."
                echo ""

                # Manual distribution
                local expanded_cpus
                expanded_cpus=$(expand_cpu_list "${RENDERER_CPUS}")
                local -a cpu_array=($expanded_cpus)
                local num_cpus=${#cpu_array[@]}

                echo "Distributing threads across CPUs: ${cpu_array[*]}"
                echo ""

                local i=0
                ps -T -o tid= -p "$main_pid" 2>/dev/null | tr -d ' ' | while read -r tid; do
                    if [[ -n "$tid" ]]; then
                        local cpu_index=$(( i % num_cpus ))
                        local target_cpu=${cpu_array[$cpu_index]}
                        if taskset -pc "$target_cpu" "$tid" > /dev/null 2>&1; then
                            echo "  Thread $tid -> CPU $target_cpu"
                        else
                            echo "  Thread $tid -> CPU $target_cpu (failed)"
                        fi
                        i=$(( i + 1 ))
                    fi
                done
            fi

            echo ""
            echo "=== Current Thread Layout ==="
            echo "TID      CPU  COMMAND"
            ps -T -o tid=,psr=,comm= -p "$main_pid" 2>/dev/null | while read -r tid psr comm; do
                printf "%-8s %-4s %s\n" "$tid" "$psr" "$comm"
            done
            ;;

        *)
            usage
            ;;
    esac
}

main "$@"
