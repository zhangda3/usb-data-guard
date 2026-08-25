#!/system/bin/sh
#=============================================================
# USB Data Guard - Action Button (KernelSU Manager)
#=============================================================
# Shows current status when tapped in KernelSU Manager.
#=============================================================

MODDIR=${0%/*}

. "$MODDIR/scripts/config.sh"
. "$MODDIR/scripts/usb-control.sh"
. "$MODDIR/scripts/state-monitor.sh"

init_usb_control

# Get lock state
if is_device_locked; then
    LOCK_STATE="已锁定"
else
    LOCK_STATE="已解锁"
fi

# Get USB state
if is_usb_blocked; then
    USB_STATE="数据已屏蔽"
else
    USB_STATE="数据已启用"
fi

# Get service status
PID_FILE="/data/adb/usb_data_guard.pid"
if [ -f "$PID_FILE" ]; then
    SVC_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$SVC_PID" ] && kill -0 "$SVC_PID" 2>/dev/null; then
        SVC_STATUS="运行中 (PID: $SVC_PID)"
    else
        SVC_STATUS="未运行 (PID文件残留)"
    fi
else
    SVC_STATUS="未运行"
fi

echo "==========================="
echo "  USB Data Guard 状态"
echo "==========================="
echo ""
echo "设备状态 : $LOCK_STATE"
echo "USB数据  : $USB_STATE"
echo "服务状态 : $SVC_STATUS"
echo ""
echo "Gadget   : ${GADGET_PATH:-未检测到}"
echo "UDC      : ${USB_UDC_NAME:-未检测到}"
echo "屏蔽方式 : $BLOCK_METHOD"
if find_dwc3_node; then
    if dwc3_is_disabled; then
        echo "DWC3内核 : 已禁用 ($DWC3_DISABLE_NODE)"
    else
        echo "DWC3内核 : 运行中 ($DWC3_DISABLE_NODE)"
    fi
fi
echo "轮询间隔 : ${POLL_INTERVAL}秒"
echo ""
echo "日志文件 : $LOG_FILE"
echo "==========================="
