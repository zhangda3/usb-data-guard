#!/system/bin/sh
#=============================================================
# USB Data Guard - Early Boot Blocking (post-fs-data phase)
#=============================================================
# Runs early during boot to block USB data ASAP.
# At this stage, USB gadget may not be fully initialized yet.
# Full blocking and monitoring happens in service.sh.
# Note: /data may not be mounted yet, so no logging here.
#
# v1.0.3: unbind EVERY gadget that has a bound UDC, on both
# mount points (/config for Qualcomm, /sys/kernel/config
# generic). Dual-gadget (g1/g2) devices must have both taken
# down or the USB HAL will just use the other one.
#=============================================================

# v1.0.4: disable the USB controller at the KERNEL level first.
# The Qualcomm msm-dwc3 driver exposes a "dynamic_disable" sysfs
# node (see drivers/usb/dwc3/dwc3-msm-core.c in the SM7675 kernel
# source). Setting it to 1 tears down the gadget session, powers
# the controller down into LPM, and makes the kernel REJECT all
# later Type-C/extcon/role-switch re-enable events - so neither
# the USB HAL nor anything else can bring data back until we
# write 0 on unlock.
#=============================================================

# Disable dwc3 controller first (bounded wait: store handler may
# wait a couple of seconds for USB Low Power Mode entry).
for _dwc3 in /sys/bus/platform/drivers/msm-dwc3/*/dynamic_disable; do
    [ -f "$_dwc3" ] || continue
    ( echo 1 > "$_dwc3" ) 2>/dev/null &
    _i=0
    while [ "$_i" -lt 20 ]; do
        [ "$(cat "$_dwc3" 2>/dev/null)" = "1" ] && break
        sleep 0.1
        _i=$((_i + 1))
    done
    break
done

# Save bindings to state file so service.sh can restore later
# (only if /data is already writable at this stage)
_STATE="/data/adb/usb_data_guard.usbstate"

for _base in /config/usb_gadget /sys/kernel/config/usb_gadget; do
    [ -d "$_base" ] || continue
    for _dir in "$_base"/*/; do
        [ -f "${_dir}UDC" ] || continue
        _gadget="${_dir%/}"
        _udc=$(cat "${_dir}UDC" 2>/dev/null)
        [ -z "$_udc" ] && continue
        # Record binding for later restoration
        if touch "$_STATE" 2>/dev/null; then
            grep -v "^${_gadget}|" "$_STATE" > "${_STATE}.tmp" 2>/dev/null
            echo "${_gadget}|${_udc}" >> "${_STATE}.tmp"
            mv "${_STATE}.tmp" "$_STATE" 2>/dev/null
        fi
        echo "" > "${_dir}UDC" 2>/dev/null
        if [ -n "$(cat "${_dir}UDC" 2>/dev/null)" ]; then
            # Qualcomm kernels may need "none" instead of empty string
            echo "none" > "${_dir}UDC" 2>/dev/null
        fi
    done
done

# Legacy fallback
if [ -f /sys/class/android_usb/android0/enable ]; then
    echo 0 > /sys/class/android_usb/android0/enable 2>/dev/null
fi
