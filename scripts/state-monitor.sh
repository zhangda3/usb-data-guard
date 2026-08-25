#!/system/bin/sh
#=============================================================
# USB Data Guard - State Monitor
#=============================================================
# Detects screen lock/unlock and BFU/AFU states via dumpsys.
# Monitors lock state changes and controls USB data accordingly.
#
# v1.0.2: Traditional keyguard fields (mShowingLockscreen /
# isStatusBarKeyguard) are REMOVED on ColorOS/OxygenOS 15+,
# Xiaomi HyperOS, Huawei etc. Detection now uses universal
# fields first, with one-time method probing + caching, and
# a debounce on the locked->unlocked transition.
#
# v1.0.3: While locked, re-verify runs every LOCKED_POLL_INTERVAL
# (default 0.3s) instead of POLL_INTERVAL, shrinking the window
# in which the USB HAL can re-bind a gadget.
#=============================================================

# Cached detection method (set by probe_keyguard_method)
KEYGUARD_METHOD=""

#----------------------------------------------------------
# Check if screen is off (not Awake)
# Returns 0 if screen is off/asleep/dreaming
#----------------------------------------------------------
is_screen_off() {
    local wakefulness
    wakefulness=$(dumpsys power 2>/dev/null | grep -o "mWakefulness=[A-Za-z]*" | head -1 | cut -d= -f2)

    # If we got a result and it's not "Awake", screen is off
    if [ -n "$wakefulness" ] && [ "$wakefulness" != "Awake" ]; then
        return 0
    fi
    return 1
}

#----------------------------------------------------------
# Individual keyguard detection methods.
# Each returns 0 (locked) / 1 (not locked) / 2 (field not found).
#----------------------------------------------------------

# mDreamingLockscreen in "dumpsys window" — true whenever device is
# locked, regardless of screen on/off. Universal on most Android.
_kg_dreaming_window() {
    local r
    r=$(dumpsys window 2>/dev/null | grep -o "mDreamingLockscreen=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# mScreenLocked in "dumpsys deviceidle" — universal since Android M
_kg_deviceidle() {
    local r
    r=$(dumpsys deviceidle 2>/dev/null | grep -o "mScreenLocked=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# mScreenState in "dumpsys nfc" — OFF_LOCKED/ON_LOCKED/ON_UNLOCKED
_kg_nfc() {
    local r
    r=$(dumpsys nfc 2>/dev/null | grep -o "mScreenState=[A-Z_]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    case "$r" in
        OFF_LOCKED|ON_LOCKED) return 0 ;;
    esac
    return 1
}

# mInputRestricted in "dumpsys window policy" — works on newer
# ColorOS/OxygenOS/Xiaomi where mShowingLockscreen was removed
_kg_inputrestricted() {
    local r
    r=$(dumpsys window policy 2>/dev/null | grep -o "mInputRestricted=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# mDreamingLockscreen in "dumpsys window policy" (newer location)
_kg_dreaming_policy() {
    local r
    r=$(dumpsys window policy 2>/dev/null | grep -o "mDreamingLockscreen=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# mShowingLockscreen in "dumpsys window policy"
_kg_showing_policy() {
    local r
    r=$(dumpsys window policy 2>/dev/null | grep -o "mShowingLockscreen=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# mShowingLockscreen in plain "dumpsys window" (older Android)
_kg_showing_window() {
    local r
    r=$(dumpsys window 2>/dev/null | grep -o "mShowingLockscreen=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# isStatusBarKeyguard in "dumpsys window policy"
_kg_statusbar_keyguard() {
    local r
    r=$(dumpsys window policy 2>/dev/null | grep -o "isStatusBarKeyguard=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

# KeyguardServiceDelegate "showing=" in "dumpsys window policy"
_kg_delegate_showing() {
    local r
    r=$(dumpsys window policy 2>/dev/null | grep -A2 "KeyguardServiceDelegate" | grep -o "showing=[a-z]*" | head -1 | cut -d= -f2)
    [ -z "$r" ] && return 2
    [ "$r" = "true" ] && return 0
    return 1
}

#----------------------------------------------------------
# Probe which detection method works on this device.
# Runs each method; the first whose field exists is cached
# and used exclusively afterwards (efficiency + stability).
# Call once at monitor start.
#----------------------------------------------------------
probe_keyguard_method() {
    local methods="dreaming_window deviceidle nfc inputrestricted dreaming_policy showing_policy showing_window statusbar_keyguard delegate_showing"
    local m
    for m in $methods; do
        "_kg_$m"
        case $? in
            0|1)
                KEYGUARD_METHOD="$m"
                log_msg "Keyguard detection method: $m"
                return 0
                ;;
        esac
    done
    log_error "No keyguard detection method available! Please report diagnostics:"
    log_error "  dumpsys window policy | grep -iE 'keyguard|restricted|dreaming'"
    log_error "  dumpsys deviceidle | grep mScreenLocked"
    log_error "  dumpsys nfc | grep mScreenState"
    KEYGUARD_METHOD="none"
    return 1
}

#----------------------------------------------------------
# Check if keyguard is showing (device locked with screen on)
# Uses cached method when available; otherwise probes all.
#----------------------------------------------------------
is_keyguard_showing() {
    # Fast path: cached method
    if [ -n "$KEYGUARD_METHOD" ] && [ "$KEYGUARD_METHOD" != "none" ]; then
        "_kg_$KEYGUARD_METHOD"
        return $?
    fi

    # Slow path: try all methods in order
    local m
    for m in dreaming_window deviceidle nfc inputrestricted dreaming_policy showing_policy showing_window statusbar_keyguard delegate_showing; do
        "_kg_$m"
        case $? in
            0) return 0 ;;
            1) return 1 ;;
        esac
    done
    return 1
}

#----------------------------------------------------------
# Check if device is currently locked
# Combines screen state and keyguard state checks.
# BFU (Before First Unlock) = keyguard showing after boot = locked
# Returns 0 if locked, 1 if unlocked
#----------------------------------------------------------
is_device_locked() {
    # Screen off = locked (covers sleep, doze, AOD, dream)
    if [ "$BLOCK_ON_SCREENOFF" = "true" ] || [ "$BLOCK_ON_SCREEN_OFF" = "true" ]; then
        if is_screen_off; then
            return 0
        fi
    fi

    # Screen on but keyguard showing = locked (covers BFU, lock screen)
    if is_keyguard_showing; then
        return 0
    fi

    return 1  # Unlocked
}

#----------------------------------------------------------
# Main monitoring loop
# Continuously polls lock state and controls USB data.
# When locked: block USB data + verify block persists
# When unlocked: enable USB data (after UNLOCK_DEBOUNCE
# consecutive readings, to avoid flapping at screen wake)
#----------------------------------------------------------
monitor_loop() {
    local last_state=""
    local current_state
    local unlock_debounce=0
    local reblock_count=0
    local last_reblock_log=0
    local now

    # Determine which keyguard detection method this device supports
    probe_keyguard_method

    log_msg "Monitor started (interval: ${POLL_INTERVAL}s, locked-interval: ${LOCKED_POLL_INTERVAL:-$POLL_INTERVAL}s, method: ${BLOCK_METHOD}, keyguard: ${KEYGUARD_METHOD})"

    while true; do
        # Determine current lock state
        if is_device_locked; then
            current_state="locked"
            unlock_debounce=0
        else
            # Require N consecutive unlocked readings before enabling USB
            # (prevents brief false "unlocked" during screen wake)
            unlock_debounce=$((unlock_debounce + 1))
            if [ "$unlock_debounce" -ge "${UNLOCK_DEBOUNCE:-2}" ]; then
                current_state="unlocked"
            else
                current_state="locked"
            fi
        fi

        # Detect state transitions
        if [ "$current_state" != "$last_state" ]; then
            if [ "$current_state" = "locked" ]; then
                log_msg "State -> LOCKED: Blocking USB data"
                block_usb_data
                unlock_debounce=0
            else
                log_msg "State -> UNLOCKED: Enabling USB data"
                enable_usb_data
            fi
            last_state="$current_state"
        fi

        # When locked, verify USB is still blocked on EVERY gadget.
        # v1.0.4: verify_usb_blocked() also re-asserts the dwc3
        # kernel-level disable (msm-dwc3 dynamic_disable), which is
        # the primary defense; UDC unbind checks remain as backup.
        if [ "$current_state" = "locked" ]; then
            if ! verify_usb_blocked; then
                block_usb_data
                reblock_count=$((reblock_count + 1))
                # Throttled INFO log: at most once per 60s, so the log
                # is not flooded if the HAL fights us continuously
                now=$(date +%s 2>/dev/null || echo 0)
                if [ $((now - last_reblock_log)) -ge 60 ]; then
                    log_msg "USB was rebound while locked (total re-blocks: $reblock_count) - re-blocking"
                    last_reblock_log="$now"
                else
                    log_debug "USB rebound while locked - re-blocking"
                fi
            fi
            # Fast re-verify while locked to shrink the rebind window
            sleep "${LOCKED_POLL_INTERVAL:-$POLL_INTERVAL}"
        else
            sleep "$POLL_INTERVAL"
        fi
    done
}
