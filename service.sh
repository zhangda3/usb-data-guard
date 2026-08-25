#!/system/bin/sh
#=============================================================
# USB Data Guard - Main Service (late-start service)
#=============================================================
# This is the main entry point that runs as a KernelSU
# late-start service. It:
#   1. Waits for boot to complete
#   2. Blocks USB data (BFU initial state)
#   3. Starts the lock/unlock monitoring loop
#=============================================================

MODDIR=${0%/*}

# Source scripts
. "$MODDIR/scripts/config.sh"
. "$MODDIR/scripts/usb-control.sh"
. "$MODDIR/scripts/state-monitor.sh"

# Prevent multiple instances
PID_FILE="/data/adb/usb_data_guard.pid"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Another instance is running, exit
        exit 0
    fi
fi
echo $$ > "$PID_FILE" 2>/dev/null

# Cleanup on exit
trap 'rm -f "$PID_FILE" 2>/dev/null' EXIT

#----------------------------------------------------------
# Wait for boot to complete
#----------------------------------------------------------
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

# Additional wait for USB service to initialize
sleep 3

log_msg "========================================"
log_msg "USB Data Guard Service Starting"
log_msg "Kernel: $(uname -r 2>/dev/null)"
log_msg "Device: $(getprop ro.product.model 2>/dev/null)"
log_msg "Android: $(getprop ro.build.version.release 2>/dev/null) ($(getprop ro.build.version.sdk 2>/dev/null))"
log_msg "========================================"

#----------------------------------------------------------
# Initialize USB control (detect gadget, save UDC name)
#----------------------------------------------------------
init_usb_control

#----------------------------------------------------------
# Initial block - BFU state (device is locked after boot)
# The device just booted, user hasn't unlocked yet.
# This is the BFU (Before First Unlock) state.
#----------------------------------------------------------
log_msg "Initial state: BFU/Locked - Blocking USB data"
block_usb_data

#----------------------------------------------------------
# Start monitoring loop
# Monitors lock/unlock transitions and controls USB data
#----------------------------------------------------------
log_msg "Starting state monitor..."
monitor_loop
