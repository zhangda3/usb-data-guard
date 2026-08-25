#!/system/bin/sh
#=============================================================
# USB Data Guard - Installation Script
#=============================================================

ui_print " "
ui_print "==============================="
ui_print "  USB Data Guard Installation"
ui_print "==============================="
ui_print " "
ui_print "[*] 功能特性:"
ui_print "  - 锁屏时自动屏蔽USB数据传输"
ui_print "  - BFU状态(开机未解锁)自动屏蔽"
ui_print "  - 解锁后自动恢复USB数据传输"
ui_print "  - 充电功能不受影响"
ui_print " "
ui_print "[*] 工作原理:"
ui_print "  开机 -> 屏蔽数据(BFU状态)"
ui_print "  解锁 -> 启用数据传输"
ui_print "  锁定 -> 屏蔽数据传输"
ui_print " "

# Set permissions
ui_print "[*] 设置文件权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/scripts/config.sh" 0 0 0755
set_perm "$MODPATH/scripts/usb-control.sh" 0 0 0755
set_perm "$MODPATH/scripts/state-monitor.sh" 0 0 0755

ui_print " "
ui_print "[*] 安装完成!"
ui_print "[*] 重启后模块生效"
ui_print " "
ui_print "[!] 注意: 快充协议(QC/SuperVOOC等)"
ui_print "    需要数据线通信协商的协议在屏蔽"
ui_print "    期间可能无法快充, 基础充电正常"
ui_print " "
ui_print "[*] 配置文件位置:"
ui_print "    $MODPATH/scripts/config.sh"
ui_print " "
ui_print "[*] 日志文件位置:"
ui_print "    /data/adb/usb_data_guard.log"
ui_print " "
ui_print "==============================="
