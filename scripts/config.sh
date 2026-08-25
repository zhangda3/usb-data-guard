#!/system/bin/sh
#=============================================================
# USB Data Guard - Configuration
#=============================================================
# Edit these values to customize the module's behavior.
# After editing, reboot to apply changes.
#=============================================================

# Poll interval in seconds (how often to check lock state)
# Lower = faster response, higher = less battery drain
POLL_INTERVAL=1

# Fast re-verify interval while LOCKED (seconds).
# The ColorOS USB HAL re-binds gadgets (g1<->g2) after unbind,
# so while locked we re-check much faster to re-block quickly.
LOCKED_POLL_INTERVAL=0.3

# USB state file: records which gadget was bound to which UDC
# when we blocked it (used to restore USB data on unlock)
USB_STATE_FILE=/data/adb/usb_data_guard.usbstate

# USB blocking method:
#   "dwc3"       - Disable the USB controller itself at kernel level
#                  (Qualcomm msm-dwc3 "dynamic_disable" node) + unbind
#                  all gadget UDCs + lock UDC file permissions.
#                  RECOMMENDED on OnePlus/Qualcomm: verified against the
#                  SM7675 kernel source. The kernel REJECTS the USB HAL's
#                  re-enable attempts while disabled.
#                  (dynamic_disable is a write-only sysfs node; the module
#                  tracks state in /data/adb/usb_data_guard.dwc3state.)
#   "udc"        - Unbind USB gadget from UDC controller only (userspace
#                  level; ColorOS HAL keeps re-binding - NOT reliable)
#   "functions"  - Remove data functions only (ineffective on ColorOS)
BLOCK_METHOD=dwc3

# While locked, chmod gadget UDC files to 0444 so the vendor USB HAL
# cannot rewrite them (best effort; needs the HAL's SELinux domain to
# lack CAP_DAC_OVERRIDE). Our root scripts can still write.
# Set to false if USB data fails to restore on unlock.
HARDEN_UDC_PERMS=true

# Unlock debounce: number of consecutive "unlocked" readings required
# before USB data is enabled (prevents brief false unlock during screen wake)
UNLOCK_DEBOUNCE=2

# Manual USB gadget path override (leave empty for auto-detect).
# Auto-detect scans /config/usb_gadget (Qualcomm) and
# /sys/kernel/config/usb_gadget (generic).
# On OnePlus/Qualcomm devices the path is usually: /config/usb_gadget/g1
GADGET_PATH_OVERRIDE=""

# Block when screen is off (even if keyguard isn't showing)
# true  = block on screen off (recommended for security)
# false = only block when keyguard is explicitly showing
BLOCK_ON_SCREEN_OFF=true

# Log file path
LOG_FILE=/data/adb/usb_data_guard.log

# Maximum log file size in KB (old entries will be trimmed)
LOG_MAX_SIZE=100

# Debug mode (verbose logging for troubleshooting)
DEBUG=false

#=============================================================
# Logging Functions (used by all scripts)
#=============================================================

_rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        local max_bytes=$((LOG_MAX_SIZE * 1024))
        if [ "$max_bytes" -gt 0 ] && [ "$size" -gt "$max_bytes" ]; then
            local half=$((max_bytes / 2))
            tail -c "$half" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
}

log_msg() {
    _rotate_log
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG_FILE" 2>/dev/null
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" >> "$LOG_FILE" 2>/dev/null
    fi
}

log_error() {
    _rotate_log
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$LOG_FILE" 2>/dev/null
}
