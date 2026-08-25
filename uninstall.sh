#!/system/bin/sh
#=============================================================
# USB Data Guard - Uninstall Cleanup
#=============================================================
# Restores USB data transfer when module is uninstalled.
#
# v1.0.3: restore ALL gadgets on both mount points
# (Qualcomm /config + generic /sys/kernel/config).
#=============================================================

# v1.0.4: restore UDC file permissions first (block mode chmods
# them 0444 to keep the USB HAL out), then re-enable the dwc3
# controller at kernel level, then restore gadget bindings.

for _base in /config/usb_gadget /sys/kernel/config/usb_gadget; do
    [ -d "$_base" ] || continue
    for _dir in "$_base"/*/; do
        [ -f "${_dir}UDC" ] || continue
        chmod 0644 "${_dir}UDC" 2>/dev/null
    done
done

for _dwc3 in /sys/bus/platform/drivers/msm-dwc3/*/dynamic_disable; do
    [ -f "$_dwc3" ] || continue
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 sh -c "echo 0 > $_dwc3" 2>/dev/null
    else
        echo 0 > "$_dwc3" 2>/dev/null
    fi
    break
done
rm -f /data/adb/usb_data_guard.dwc3state 2>/dev/null

# Restore saved gadget bindings first (if state file exists)
_STATE="/data/adb/usb_data_guard.usbstate"
if [ -f "$_STATE" ]; then
    while IFS='|' read -r _gadget _udc; do
        [ -z "$_gadget" ] || [ -z "$_udc" ] && continue
        [ -f "${_gadget}/UDC" ] || continue
        echo "$_udc" > "${_gadget}/UDC" 2>/dev/null
    done < "$_STATE"
    rm -f "$_STATE" 2>/dev/null
fi

# Fallback: bind any unbound gadget to the default UDC
_udc=$(getprop sys.usb.controller 2>/dev/null)
[ -z "$_udc" ] && _udc=$(ls /sys/class/udc/ 2>/dev/null | head -1)

for _base in /config/usb_gadget /sys/kernel/config/usb_gadget; do
    [ -d "$_base" ] || continue
    for _dir in "$_base"/*/; do
        [ -f "${_dir}UDC" ] || continue
        if [ -z "$(cat "${_dir}UDC" 2>/dev/null)" ] && [ -n "$_udc" ]; then
            echo "$_udc" > "${_dir}UDC" 2>/dev/null
        fi
    done
done

# Legacy fallback
if [ -f /sys/class/android_usb/android0/enable ]; then
    echo 1 > /sys/class/android_usb/android0/enable 2>/dev/null
fi

# Kill service if running
_PID_FILE="/data/adb/usb_data_guard.pid"
if [ -f "$_PID_FILE" ]; then
    _pid=$(cat "$_PID_FILE" 2>/dev/null)
    [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
    rm -f "$_PID_FILE" 2>/dev/null
fi

# Clean up log and state files
rm -f /data/adb/usb_data_guard.log 2>/dev/null
rm -f /data/adb/usb_data_guard.usbstate 2>/dev/null
