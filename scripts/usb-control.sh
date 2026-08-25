#!/system/bin/sh
#=============================================================
# USB Data Guard - USB Data Control Functions
#=============================================================
# Handles blocking/enabling USB data transfer while
# keeping charging functionality intact.
#
# v1.0.4: KERNEL-LEVEL blocking via Qualcomm msm-dwc3 driver.
#         Source-verified against the SM7675 (Ace 3V) kernel:
#         drivers/usb/dwc3/dwc3-msm-core.c exposes a writable
#         "dynamic_disable" sysfs node on the msm-dwc3 platform
#         device. Writing 1 tears down the gadget session at the
#         controller level (soft disconnect + Low Power Mode) AND
#         sets mdwc->dynamic_disable, which makes the kernel REJECT
#         all later Type-C/PD/extcon/usb_role_switch re-enable
#         events ("Event not allowed") and fail power-collapse
#         resume. This closes the endless fight against the USB
#         HAL that plain UDC unbind could never win.
#
# v1.0.3: MULTI-GADGET support. Qualcomm/ColorOS devices have
#         TWO gadgets (g1/g2) under /config/usb_gadget. When
#         one is unbound, the USB HAL re-binds the OTHER one.
#         Blocking now unbinds EVERY gadget with a bound UDC,
#         and verification only passes when NO gadget is bound.
#         Per-gadget UDC names are saved to a state file for
#         restoration on unlock.
#
# v1.0.1: Qualcomm devices mount configfs at /config
#         (not /sys/kernel/config). Scan both mount points.
#=============================================================

LEGACY_USB_PATH="/sys/class/android_usb/android0"

# State file: records gadget|udc bindings taken down by us,
# used to restore USB data when unlocked.
# Set by config.sh if defined there.
USB_STATE_FILE="${USB_STATE_FILE:-/data/adb/usb_data_guard.usbstate}"

#----------------------------------------------------------
# List all gadget directories (both mount points).
# One per line. Respects GADGET_PATH_OVERRIDE if set.
#----------------------------------------------------------
list_gadgets() {
    if [ -n "$GADGET_PATH_OVERRIDE" ] && [ -d "$GADGET_PATH_OVERRIDE" ]; then
        echo "$GADGET_PATH_OVERRIDE"
        return 0
    fi
    local base dir
    for base in /config/usb_gadget /sys/kernel/config/usb_gadget; do
        [ -d "$base" ] || continue
        for dir in "$base"/*/; do
            [ -f "${dir}UDC" ] && echo "${dir%/}"
        done
    done
    return 0
}

#----------------------------------------------------------
# Primary gadget: the one currently bound to a UDC
# (used for status display and the "functions" method).
#----------------------------------------------------------
detect_usb_gadget() {
    GADGET_PATH=""
    local g udc
    for g in $(list_gadgets); do
        udc=$(cat "$g/UDC" 2>/dev/null)
        if [ -n "$udc" ]; then
            GADGET_PATH="$g"
            USB_UDC_NAME="$udc"
            return 0
        fi
    done
    # Fallback: first gadget dir at all
    for g in $(list_gadgets); do
        GADGET_PATH="$g"
        return 0
    done
    return 1
}

#----------------------------------------------------------
# Get the UDC controller name
#----------------------------------------------------------
get_udc_name() {
    local udc
    if [ -n "$GADGET_PATH" ]; then
        udc=$(cat "$GADGET_PATH/UDC" 2>/dev/null)
        if [ -n "$udc" ]; then
            echo "$udc"
            return 0
        fi
    fi
    udc=$(getprop sys.usb.controller 2>/dev/null)
    if [ -n "$udc" ]; then
        echo "$udc"
        return 0
    fi
    udc=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    if [ -n "$udc" ]; then
        echo "$udc"
        return 0
    fi
    return 1
}

#----------------------------------------------------------
# Initialize USB control (detection + logging)
#----------------------------------------------------------
init_usb_control() {
    detect_usb_gadget

    local count=0 bound=0 g udc list=""
    for g in $(list_gadgets); do
        count=$((count + 1))
        udc=$(cat "$g/UDC" 2>/dev/null)
        if [ -n "$udc" ]; then
            bound=$((bound + 1))
            list="$list $g(UDC:$udc)"
        else
            list="$list $g(unbound)"
        fi
    done

    if [ "$count" -gt 0 ]; then
        log_msg "Gadgets found: $count ->$list"
        log_msg "Primary gadget: ${GADGET_PATH:-none}"
    elif [ -f "$LEGACY_USB_PATH/enable" ]; then
        log_msg "Legacy android_usb interface detected"
    else
        log_error "No USB gadget interface detected! Tried: /config/usb_gadget, /sys/kernel/config/usb_gadget"
    fi
}

#----------------------------------------------------------
# Write helper: configfs UDC writes may need "" or "none"
#----------------------------------------------------------
_write_udc_file() {
    # $1 = gadget path, $2 = value ("" to unbind, or UDC name)
    if [ -z "$2" ]; then
        echo "" > "$1/UDC" 2>/dev/null && return 0
        echo "none" > "$1/UDC" 2>/dev/null && return 0
        return 1
    else
        echo "$2" > "$1/UDC" 2>/dev/null && return 0
        return 1
    fi
}

#----------------------------------------------------------
# State file helpers (gadget|udc pairs)
#----------------------------------------------------------
_save_binding() {
    # $1 = gadget path, $2 = udc name
    touch "$USB_STATE_FILE" 2>/dev/null || return 1
    grep -v "^$1|" "$USB_STATE_FILE" > "${USB_STATE_FILE}.tmp" 2>/dev/null
    echo "$1|$2" >> "${USB_STATE_FILE}.tmp"
    mv "${USB_STATE_FILE}.tmp" "$USB_STATE_FILE" 2>/dev/null
}

_get_saved_udc() {
    # $1 = gadget path
    [ -f "$USB_STATE_FILE" ] || return 1
    grep "^$1|" "$USB_STATE_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

#==========================================================
# Method 0 (default): DWC3 dynamic_disable (kernel level)
#
# Qualcomm's msm-dwc3 glue driver exposes:
#   /sys/bus/platform/drivers/msm-dwc3/<dev>/dynamic_disable
# (verified in the SM7675 kernel source, dwc3-msm-core.c):
#   write 1 -> state machine drops ID/B_SESS_VLD, gadget session
#              is torn down, controller enters LPM (host sees a
#              real disconnect), and dwc3_ext_event_notify()
#              REJECTS all subsequent extcon / role-switch
#              events while the flag is set. Charging is not
#              affected: VBUS/PD handling lives in the charger
#              IC + pmic_glink, independent of dwc3.
#   write 0 -> events are allowed again and the peripheral
#              session restarts if a cable is present.
# Layered on top: all gadget UDCs are still unbound (belt and
# suspenders), and UDC configfs files are chmod'd 0444 so the
# vendor USB HAL (if its SELinux domain lacks CAP_DAC_OVERRIDE)
# cannot rewrite them while we are locked.
#==========================================================

DWC3_DISABLE_NODE=""
# dynamic_disable is DEVICE_ATTR_WO (write-only, no show function),
# so it CANNOT be read back with cat. We track the intended state
# in this file instead. (Set/cleared by _dwc3_set.)
DWC3_STATE_FILE="/data/adb/usb_data_guard.dwc3state"

find_dwc3_node() {
    if [ -n "$DWC3_DISABLE_NODE" ] && [ -f "$DWC3_DISABLE_NODE" ]; then
        return 0
    fi
    local d
    for d in /sys/bus/platform/drivers/msm-dwc3/*/dynamic_disable; do
        [ -f "$d" ] || continue
        DWC3_DISABLE_NODE="$d"
        return 0
    done
    return 1
}

dwc3_is_disabled() {
    # dynamic_disable sysfs node is write-only, so read OUR state file.
    [ -f "$DWC3_STATE_FILE" ] || return 1
    [ "$(cat "$DWC3_STATE_FILE" 2>/dev/null)" = "1" ]
}

_dwc3_set() {
    # $1 = 1 (disable controller) or 0 (re-enable)
    find_dwc3_node || return 1
    local val="$1"
    # Write SYNCHRONOUSLY. The kernel store handler (dwc3-msm-core.c
    # dynamic_disable_store) flushes the OTG state-machine work before
    # returning, so once echo returns the controller has fully
    # transitioned (LPM on disable; runtime-PM re-enabled + state
    # re-evaluated on enable). A background subshell would race with
    # the UDC rebind that follows on unlock and lose the write.
    # Use `timeout` so a stuck store handler can't hang the monitor.
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 sh -c "echo $val > $DWC3_DISABLE_NODE" 2>/dev/null
        local rc=$?
        [ "$rc" -ne 0 ] && { log_error "dynamic_disable write $val failed (rc=$rc)"; return 1; }
    else
        echo "$val" > "$DWC3_DISABLE_NODE" 2>/dev/null || { log_error "dynamic_disable write $val failed"; return 1; }
    fi
    echo "$val" > "$DWC3_STATE_FILE" 2>/dev/null
    log_debug "dynamic_disable <- $val"
    return 0
}

_harden_udc_files() {
    # Best effort: make gadget UDC files read-only for the USB HAL's
    # SELinux domain (root keeps CAP_DAC_OVERRIDE and can still write).
    [ "$HARDEN_UDC_PERMS" = "true" ] || return 0
    local g
    for g in $(list_gadgets); do
        chmod 0444 "$g/UDC" 2>/dev/null
    done
    return 0
}

_restore_udc_perms() {
    local g
    for g in $(list_gadgets); do
        chmod 0644 "$g/UDC" 2>/dev/null
    done
    return 0
}

_block_dwc3() {
    if find_dwc3_node; then
        if _dwc3_set 1; then
            log_msg "DWC3 controller disabled at kernel level"
        else
            log_error "dynamic_disable=1 failed - relying on UDC unbind only"
        fi
    else
        log_error "msm-dwc3 dynamic_disable node not found - UDC-only mode"
    fi
    _block_udc_all
    _harden_udc_files
}

_enable_dwc3() {
    # Order matters: restore write perms -> re-enable controller
    # (synchronous, kernel flushes sm_work) -> settle -> re-bind UDC
    # -> verify, retry once if the gadget did not attach.
    _restore_udc_perms
    if find_dwc3_node; then
        if _dwc3_set 0; then
            log_msg "DWC3 controller re-enabled, restoring gadget"
            # The kernel store handler flushed the state machine, but
            # give runtime PM a brief moment to propagate the resume.
            sleep 0.5
        else
            log_error "dynamic_disable=0 failed - controller may stay off, trying rebind anyway"
        fi
    fi
    _enable_udc_all
    # Verify the gadget actually re-attached; retry once.
    if is_usb_blocked; then
        log_msg "USB still blocked after first rebind - retrying"
        sleep 0.5
        _enable_udc_all
    fi
    if is_usb_blocked; then
        log_error "USB data restore FAILED - gadget did not re-bind"
    else
        log_debug "USB data restored (gadget re-bound)"
    fi
}

#==========================================================
# Public API: block_usb_data / enable_usb_data
#==========================================================

block_usb_data() {
    case "$BLOCK_METHOD" in
        dwc3)
            _block_dwc3
            ;;
        functions)
            _block_functions
            ;;
        udc|*)
            _block_udc_all
            ;;
    esac
}

enable_usb_data() {
    case "$BLOCK_METHOD" in
        dwc3)
            _enable_dwc3
            ;;
        functions)
            _enable_functions
            ;;
        udc|*)
            _enable_udc_all
            ;;
    esac
}

#==========================================================
# Verify block while locked: re-assert the kernel-level flag,
# then check that no gadget has a bound UDC.
#==========================================================

verify_usb_blocked() {
    if [ "$BLOCK_METHOD" = "dwc3" ] && find_dwc3_node; then
        dwc3_is_disabled || _dwc3_set 1
    fi
    is_usb_blocked
}

#==========================================================
# Method 1 (default): UDC unbind/rebind - ALL gadgets
# Unbinds every gadget that has a UDC bound. This is the
# critical fix for Qualcomm dual-gadget (g1/g2) devices:
# the USB HAL re-binds the other gadget when one is taken
# down, so ALL of them must be unbound.
#==========================================================

_block_udc_all() {
    local g udc n=0 any=0
    for g in $(list_gadgets); do
        udc=$(cat "$g/UDC" 2>/dev/null)
        [ -z "$udc" ] && continue
        any=1
        _save_binding "$g" "$udc"
        if _write_udc_file "$g" ""; then
            n=$((n + 1))
            log_debug "Blocked: $g (was: $udc)"
        else
            log_error "UDC unbind failed: $g (SELinux?)"
        fi
    done

    if [ "$any" = "0" ]; then
        # No gadget was bound - nothing to do
        return 0
    fi

    if [ "$n" -eq 0 ]; then
        # Bound gadget existed but all unbind writes failed
        return 1
    fi

    # Legacy/typec fallback only when no configfs gadget exists at all
    if [ -z "$(list_gadgets)" ]; then
        if [ -f "$LEGACY_USB_PATH/enable" ]; then
            echo 0 > "$LEGACY_USB_PATH/enable" 2>/dev/null
        else
            echo "none" > /sys/class/typec/port0/data_role 2>/dev/null
        fi
    fi
    return 0
}

_enable_udc_all() {
    local restored=0 g udc saved

    # Restore gadgets we took down (from state file)
    if [ -s "$USB_STATE_FILE" ]; then
        while IFS='|' read -r g udc; do
            [ -z "$g" ] || [ -z "$udc" ] && continue
            [ -f "$g/UDC" ] || continue
            if _write_udc_file "$g" "$udc"; then
                restored=$((restored + 1))
                log_debug "Enabled: $g ($udc)"
            else
                # UDC name may have changed (rare) - try property
                udc=$(getprop sys.usb.controller 2>/dev/null)
                [ -z "$udc" ] && udc=$(ls /sys/class/udc/ 2>/dev/null | head -1)
                if [ -n "$udc" ] && _write_udc_file "$g" "$udc"; then
                    restored=$((restored + 1))
                    log_debug "Enabled: $g ($udc, fallback)"
                else
                    log_error "UDC rebind failed: $g"
                fi
            fi
        done < "$USB_STATE_FILE"
        rm -f "$USB_STATE_FILE" 2>/dev/null
    fi

    # Fallback: nothing to restore but nothing is bound either
    # (e.g. state file lost after hard reboot) - bind primary gadget
    if [ "$restored" -eq 0 ]; then
        local bound=0
        for g in $(list_gadgets); do
            [ -n "$(cat "$g/UDC" 2>/dev/null)" ] && bound=1
        done
        if [ "$bound" = "0" ]; then
            detect_usb_gadget
            udc=$(get_udc_name)
            if [ -n "$GADGET_PATH" ] && [ -n "$udc" ]; then
                _write_udc_file "$GADGET_PATH" "$udc" && log_debug "Enabled: $GADGET_PATH ($udc, fresh bind)"
            fi
        fi
    fi

    # Legacy fallback
    if [ -z "$(list_gadgets)" ] && [ -f "$LEGACY_USB_PATH/enable" ]; then
        echo 1 > "$LEGACY_USB_PATH/enable" 2>/dev/null
    fi
    return 0
}

#==========================================================
# Method 2: Function removal (alternative, single gadget)
# NOTE: ColorOS/OxygenOS USB service rebuilds gadget configs,
# so this method is largely ineffective on OnePlus devices.
#==========================================================

_block_functions() {
    if [ -z "$GADGET_PATH" ]; then
        _block_udc_all
        return
    fi

    local config_dir
    config_dir=$(ls -d "$GADGET_PATH"/configs/*/ 2>/dev/null | head -1)
    config_dir="${config_dir%/}"

    if [ -z "$config_dir" ]; then
        _block_udc_all
        return
    fi

    local link func_name
    for link in "$config_dir"/*; do
        if [ -L "$link" ]; then
            func_name=$(basename "$link")
            rm "$link" 2>/dev/null
        fi
    done

    local udc
    udc=$(cat "$GADGET_PATH/UDC" 2>/dev/null)
    if [ -n "$udc" ]; then
        _write_udc_file "$GADGET_PATH" ""
        _write_udc_file "$GADGET_PATH" "$udc"
    fi
    log_debug "Blocked: function removal ($GADGET_PATH)"
}

_enable_functions() {
    if [ -z "$GADGET_PATH" ]; then
        _enable_udc_all
        return
    fi

    # Let the system USB service rebuild the composition:
    # toggle UDC so the HAL re-composes the gadget.
    local udc
    udc=$(cat "$GADGET_PATH/UDC" 2>/dev/null)
    if [ -z "$udc" ]; then
        udc=$(get_udc_name)
    fi
    if [ -n "$udc" ]; then
        _write_udc_file "$GADGET_PATH" "$udc"
    fi
    # Trigger system recomposition via usb config property
    setprop sys.usb.config none 2>/dev/null
    log_debug "Enabled: recompose triggered"
}

#==========================================================
# Status check
# udc method: blocked ONLY when NO gadget anywhere has a
# bound UDC. This catches the HAL switching g1<->g2.
#==========================================================

is_usb_blocked() {
    # No configfs gadgets at all - try legacy
    if [ -z "$(list_gadgets)" ]; then
        if [ -f "$LEGACY_USB_PATH/enable" ]; then
            local enabled
            enabled=$(cat "$LEGACY_USB_PATH/enable" 2>/dev/null)
            [ "$enabled" = "0" ] && return 0
        fi
        return 1
    fi

    if [ "$BLOCK_METHOD" = "functions" ]; then
        local config_dir count
        config_dir=$(ls -d "$GADGET_PATH"/configs/*/ 2>/dev/null | head -1)
        config_dir="${config_dir%/}"
        if [ -n "$config_dir" ]; then
            count=$(find "$config_dir" -maxdepth 1 -type l 2>/dev/null | wc -l)
            [ "$count" -eq 0 ] && return 0
        fi
        return 1
    fi

    # udc method: any gadget with a bound UDC means NOT blocked
    local g
    for g in $(list_gadgets); do
        if [ -n "$(cat "$g/UDC" 2>/dev/null)" ]; then
            return 1
        fi
    done
    return 0
}
