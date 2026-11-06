#!/bin/bash
# Cross-platform iSCSI mounter for Linux (Bash version)
# Alternative to PowerShell version for environments without pwsh

# ============================================
# CONFIGURATION (hardcoded for one-liner deployment)
# ============================================
ISCSI_TARGET_IP="192.168.1.100"
ISCSI_IQN="iqn.2024-10.com.proxmox:it-share"
PROXMOX_API_URL="https://192.168.1.100:8006/api2/json"
PROXMOX_API_TOKEN="root@pam!token-id=YOUR-TOKEN-HERE"
INACTIVITY_TIMEOUT_MINUTES=15
MOUNT_POINT="/mnt/it-share"

# ============================================
# LOGGING
# ============================================
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "INFO")
            echo -e "\033[36m[$timestamp] [INFO] $message\033[0m"
            ;;
        "SUCCESS")
            echo -e "\033[32m[$timestamp] [SUCCESS] $message\033[0m"
            ;;
        "WARNING")
            echo -e "\033[33m[$timestamp] [WARNING] $message\033[0m"
            ;;
        "ERROR")
            echo -e "\033[31m[$timestamp] [ERROR] $message\033[0m"
            ;;
    esac
}

# ============================================
# CHECK REQUIREMENTS
# ============================================
check_requirements() {
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "This script must be run as root (use sudo)"
        exit 1
    fi

    if ! command -v iscsiadm &> /dev/null; then
        log "ERROR" "iscsiadm not found. Install open-iscsi: apt install open-iscsi or yum install iscsi-initiator-utils"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log "ERROR" "curl not found. Install: apt install curl or yum install curl"
        exit 1
    fi
}

# ============================================
# MOUNT ISCSI
# ============================================
mount_iscsi() {
    log "INFO" "Mounting iSCSI target on Linux..."

    # Check if already connected
    if iscsiadm -m session 2>&1 | grep -q "$ISCSI_IQN"; then
        log "WARNING" "Target already connected"
        return 0
    fi

    # Discover target
    log "INFO" "Discovering target..."
    iscsiadm -m discovery -t st -p "$ISCSI_TARGET_IP" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to discover target"
        return 1
    fi

    # Login to target
    log "INFO" "Logging in to target..."
    iscsiadm -m node -T "$ISCSI_IQN" -p "$ISCSI_TARGET_IP" --login > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to login to target"
        return 1
    fi

    # Wait for device to appear
    log "INFO" "Waiting for device to appear..."
    sleep 5

    # Find the device
    DEVICE=$(lsblk -o NAME,SIZE | grep -E "sd[b-z]" | head -n 1 | awk '{print $1}')
    if [ -z "$DEVICE" ]; then
        log "ERROR" "iSCSI device not found"
        return 1
    fi

    DEVICE_PATH="/dev/$DEVICE"

    # Create mount point if not exists
    mkdir -p "$MOUNT_POINT"

    # Mount device
    log "INFO" "Mounting $DEVICE_PATH to $MOUNT_POINT..."
    mount "$DEVICE_PATH" "$MOUNT_POINT" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        # Try formatting if mount fails
        log "WARNING" "Mount failed, attempting to format as ext4..."
        mkfs.ext4 -F "$DEVICE_PATH" > /dev/null 2>&1
        mount "$DEVICE_PATH" "$MOUNT_POINT" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to mount device"
            return 1
        fi
    fi

    log "SUCCESS" "Successfully mounted to $MOUNT_POINT"
    return 0
}

# ============================================
# DISMOUNT ISCSI
# ============================================
dismount_iscsi() {
    log "INFO" "Dismounting iSCSI target on Linux..."

    # Unmount
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Successfully unmounted $MOUNT_POINT"
        fi
    fi

    # Logout from target
    iscsiadm -m node -T "$ISCSI_IQN" -p "$ISCSI_TARGET_IP" --logout > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Successfully disconnected from iSCSI target"
    else
        log "WARNING" "Logout failed (may already be disconnected)"
    fi

    return 0
}

# ============================================
# DISCONNECT VIA PROXMOX API
# ============================================
disconnect_proxmox() {
    log "INFO" "Disconnecting iSCSI target via Proxmox API..."

    # Note: Adjust this endpoint based on your Proxmox setup
    local url="$PROXMOX_API_URL/nodes/localhost/qemu/agent/exec"
    local body="{\"command\": \"iscsiadm -m node -T $ISCSI_IQN --logout\"}"

    curl -k -X POST "$url" \
        -H "Authorization: PVEAPIToken=$PROXMOX_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        log "SUCCESS" "Successfully sent disconnect command to Proxmox"
    else
        log "ERROR" "Failed to disconnect via Proxmox API"
    fi

    return 0
}

# ============================================
# ACTIVITY MONITOR
# ============================================
start_activity_monitor() {
    local parent_pid=$1
    log "INFO" "Starting activity monitor (timeout: $INACTIVITY_TIMEOUT_MINUTES min)..."

    (
        last_activity=$(date +%s)
        check_interval=60

        while true; do
            sleep $check_interval

            # Check if parent process is still running
            if ! kill -0 "$parent_pid" 2>/dev/null; then
                log "INFO" "Parent process died, exiting monitor"
                exit 0
            fi

            # Check for file activity
            has_activity=0
            if [ -d "$MOUNT_POINT" ]; then
                latest=$(find "$MOUNT_POINT" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
                if [ -n "$latest" ]; then
                    latest_time=$(echo "$latest" | cut -d. -f1)
                    if [ "$latest_time" -gt "$last_activity" ]; then
                        has_activity=1
                    fi
                fi
            fi

            if [ "$has_activity" -eq 1 ]; then
                last_activity=$(date +%s)
                log "INFO" "Activity detected, resetting timer"
            fi

            # Check timeout
            current_time=$(date +%s)
            inactive_seconds=$((current_time - last_activity))
            inactive_minutes=$((inactive_seconds / 60))

            if [ "$inactive_minutes" -ge "$INACTIVITY_TIMEOUT_MINUTES" ]; then
                log "WARNING" "Inactivity timeout reached, disconnecting..."
                disconnect_proxmox
                exit 0
            fi
        done
    ) &

    local monitor_pid=$!
    log "SUCCESS" "Activity monitor started (PID: $monitor_pid)"
    echo "$monitor_pid"
}

# ============================================
# CLEANUP ON EXIT
# ============================================
cleanup() {
    log "INFO" "Shutting down..."
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null
    fi
    dismount_iscsi
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# ============================================
# MAIN
# ============================================
ACTION="${1:-mount}"
NO_MONITOR="${2:-false}"

check_requirements

case "$ACTION" in
    mount)
        if mount_iscsi; then
            if [ "$NO_MONITOR" = "false" ]; then
                MONITOR_PID=$(start_activity_monitor $$)
                log "SUCCESS" "Share mounted and monitor running. Press Ctrl+C to stop."
                log "INFO" "Share path: $MOUNT_POINT"

                # Keep running until Ctrl+C
                while true; do
                    sleep 10
                done
            else
                log "SUCCESS" "Share mounted successfully (no monitor)."
                log "INFO" "Share path: $MOUNT_POINT"
            fi
        else
            exit 1
        fi
        ;;
    unmount)
        dismount_iscsi
        ;;
    status)
        log "INFO" "Status check not implemented yet"
        ;;
    *)
        log "ERROR" "Unknown action: $ACTION"
        echo "Usage: $0 {mount|unmount|status} [--no-monitor]"
        exit 1
        ;;
esac
