# GrapheneOS补完计划1--USB Data Guard - KernelSU Module--实现部分GrapheneOS的功能

## 版本历史

### v1.0.5
- **修复解锁后 USB 数据无法恢复（关键）**：v1.0.4 屏蔽生效但解锁后一直屏蔽。根因经内核源码（`dwc3-msm-core.c:5474`）确认——`dynamic_disable` 是 `DEVICE_ATTR_WO`（**只写属性，无 show 函数，`cat` 读不到值**）。v1.0.4 的三个连锁错误：
  1. `cat dynamic_disable` 永远返回空 → `dwc3_is_disabled()` 恒为 false、`_dwc3_set()` 轮询 cat 8 秒必超时
  2. `echo 0` 在**后台子 shell** 执行，主进程没等写完成就立刻重绑 UDC → 此时内核 store 处理函数还在 `flush_work` 重启控制器 → 重绑写入丢失 → gadget 永不附加
  3. 锁定态每 0.3 秒的 `verify` 都因 cat 读不到而反复 `echo 1`，堆积后台子 shell
- 修复方案（三层）：
  - **状态文件跟踪**：`dynamic_disable` 无法读回，改用 `/data/adb/usb_data_guard.dwc3state` 记录预期状态（"1"/"0"），`dwc3_is_disabled()` 读它，轻量可靠。
  - **同步写入**：`echo` 直接写入（不再后台化）。内核 store 处理函数本身会 `flush_work(&sm_work)` 后才返回，所以 echo 返回即代表控制器状态已完全切换。用 `timeout 10` 包裹防止极端情况下内核 store 卡死拖垮监控循环。
  - **解锁顺序**：恢复权限 → 同步写 `0` → `sleep 0.5` 让 runtime PM 传播 → 重绑 UDC → `is_usb_blocked` 验证，失败则 0.5 秒后重绑一次。源码已确认写 `0` 的恢复路径完整（清标志 + `pm_runtime_disable/set_suspended/enable` + `dwc3_ext_event_notify` 重评状态机）。
- `post-fs-data.sh` / `uninstall.sh` 同步写入改造（卸载时清理 dwc3 状态文件）。

### v1.0.4
- **内核级屏蔽（关键升级，基于 SM7675 内核源码研究）**：纯用户态 UDC 解绑永远在和 ColorOS USB HAL 对抗（HAL 通过 dwc3 gadget 的 runtime PM 路径随时可复活数据连接）。本版本改用高通 `msm-dwc3` 驱动自带的官方开关：
  - 节点：`/sys/bus/platform/drivers/msm-dwc3/<dev>/dynamic_disable`（源码位置 `drivers/usb/dwc3/dwc3-msm-core.c`）
  - 写 `1`：驱动状态机断开会话、控制器进 LPM（主机侧看到真实断开），并置 `mdwc->dynamic_disable` 标志——此后 `dwc3_ext_event_notify()` **在内核层直接拒绝** Type-C/PD/extcon/角色切换事件（"Event not allowed"），电源恢复路径 `dwc3_msm_power_collapse_por()` 也返回 `-EINVAL`。USB HAL 无法再复活数据通道。
  - 写 `0`：恢复事件放行，外设会话按需重启。
  - 充电不受影响：VBUS/PD 由充电 IC + pmic_glink 独立处理，与 dwc3 数据栈无关。
- **纵深防御三层**：① dwc3 内核禁用；② 全 gadget UDC 解绑（沿用 v1.0.3）；③ 锁定时将各 gadget 的 `UDC` 文件 `chmod 0444`（configfs 支持 setattr），无 `CAP_DAC_OVERRIDE` 的 HAL 域无法重写（root 不受影响）。可通过 `HARDEN_UDC_PERMS=false` 关闭。
- 锁定态验证循环改为 `verify_usb_blocked()`：同时校验内核标志与 gadget 绑定，任一失效立即重建。
- `post-fs-data.sh` 开机即写 `dynamic_disable=1`（带 2 秒上限等待，内核 store 会等 LPM）；`uninstall.sh` 卸载时恢复权限、写 `0`、恢复绑定。
- 若 `dynamic_disable` 节点不存在（非高通平台），自动回退到 v1.0.3 的纯 UDC 行为并记日志。

### v1.0.3
- **修复多 gadget 设备屏蔽失效（关键）**：OnePlus 等高通设备在 `/config/usb_gadget/` 下有 **g1 和 g2 两个 gadget**。之前只解绑启动时检测到的那一个，ColorOS USB HAL 随即将另一个重新绑定到 UDC，而验证函数只盯旧 gadget（UDC 已空）→ 模块误以为已屏蔽。现在：
  - 屏蔽时解绑**所有**已绑定 UDC 的 gadget（两个挂载点全部扫描）
  - 验证时要求**没有任何** gadget 处于绑定状态才算已屏蔽（能捕获 g1↔g2 切换）
  - 每个 gadget 的 UDC 绑定关系保存到状态文件（`/data/adb/usb_data_guard.usbstate`），解锁时逐个恢复
- **锁定态快速重验证**：新增 `LOCKED_POLL_INTERVAL=0.3`（秒），锁定状态下每 0.3 秒检查一次是否被系统重新绑定并立即再次解绑，大幅缩小数据暴露窗口；解锁状态仍按 `POLL_INTERVAL=1` 轮询。
- 重新绑定事件以限流方式记入日志（每 60 秒最多一条 INFO），可观察 HAL 对抗情况。
- `post-fs-data.sh` 早期屏蔽同样解绑所有已绑定 gadget 并记录状态；`uninstall.sh` 恢复所有 gadget。

### v1.0.2
- **修复亮屏即恢复数据传输**：ColorOS/OxygenOS 15+、HyperOS 等新系统已移除 `mShowingLockscreen`/`isStatusBarKeyguard` 字段，导致亮屏后锁屏检测失败、误判为已解锁。改用通用字段并按优先级探测：
  1. `dumpsys window` 的 `mDreamingLockscreen`（通用，不受亮/灭屏影响）
  2. `dumpsys deviceidle` 的 `mScreenLocked`（Android 6+ 通用）
  3. `dumpsys nfc` 的 `mScreenState`（`ON_LOCKED`/`ON_UNLOCKED`）
  4. `dumpsys window policy` 的 `mInputRestricted`（OPPO 系新系统实测有效）
  5. 旧字段作为回退
- 启动时一次性探测可用字段并缓存（每秒轮询只跑一个命令，降低开销），探测结果写入日志。
- 新增解锁防抖（`UNLOCK_DEBOUNCE=2`）：需连续 2 次读到"已解锁"才恢复 USB，防止亮屏瞬间误判闪烁。
- 默认屏蔽方式改为 `udc`（实机验证有效）；`functions` 模式会被 ColorOS USB 服务重建配置，在 OnePlus 上无效，仅保留作其他设备选项。

### v1.0.1
- **修复高通平台 gadget 路径检测失败**：高通设备（OnePlus/小米等）的 configfs 挂载在 `/config` 而非 `/sys/kernel/config`，gadget 实际路径为 `/config/usb_gadget/g1`。现已同时扫描两个挂载点，优先选择已绑定 UDC 的活动 gadget。
- **修复 Android 15/16 锁屏检测**：`mShowingLockscreen` 字段位于 `dumpsys window policy` 输出（而非 `dumpsys window`），现已优先使用 `dumpsys window policy`，并新增 `showingAndNotOccluded`、`isStatusBarKeyguard` 检测。
- UDC 解绑兼容：空字符串写入失败时自动改写 `none`（高通内核补丁值）。
- UDC 名称获取新增 `sys.usb.controller` 系统属性来源（如 `a600000.dwc3`）。
- 新增 `GADGET_PATH_OVERRIDE` 配置项：自动检测失败时可手动指定 gadget 路径。
- 修复 `functions` 模式下 `is_usb_blocked` 验证逻辑（原来错误地检查 UDC）。

### v1.0.0
- 初始版本。

## 功能概述

锁屏/BFU 状态下自动屏蔽 USB 数据传输，解锁后自动恢复。保护设备免受通过 USB 接口的数据窃取，同时不影响充电功能。

## 工作原理

```
开机 (Boot)
  │
  ├─ post-fs-data.sh → 尝试早期屏蔽（USB可能未初始化）
  │
  ├─ service.sh 启动 → 等待 boot_completed
  │     │
  │     ├─ 初始屏蔽（BFU 状态：开机后未解锁 = 锁定）
  │     │
  │     └─ 启动监控循环（每秒轮询）
  │           │
  │           ├─ 检测到锁定  → 屏蔽 USB 数据
  │           ├─ 检测到解锁  → 启用 USB 数据
  │           └─ 锁定时验证屏蔽是否仍生效（防重绑定）
```

### 状态检测

通过 `dumpsys` 命令检测设备锁定状态：

| 检测项 | 方法 | 说明 |
|--------|------|------|
| 屏幕状态 | `dumpsys power` → `mWakefulness` | Asleep/Dreaming/Doze = 锁定 |
| Keyguard | `dumpsys window` → `mShowingLockscreen` | true = 锁定 |
| 焦点窗口 | `dumpsys window` → `mCurrentFocus` | Keyguard 焦点 = 锁定 |

### BFU / AFU 状态处理

- **BFU (Before First Unlock)**：开机后用户尚未输入密码，Keyguard 显示中 → 自动屏蔽
- **AFU (After First Unlock)**：用户已解锁过一次 → 正常监控锁屏/解锁

## USB 数据屏蔽方法

### 方法 1: UDC 解绑（默认）

将 USB gadget 从 UDC 控制器解绑，停止所有 USB 数据通信。
充电由独立的充电 IC 硬件管理，不受影响。

```
屏蔽: echo "" > /sys/kernel/config/usb_gadget/<gadget>/UDC
启用: echo "<udc_name>" > /sys/kernel/config/usb_gadget/<gadget>/UDC
```

### 方法 2: 功能移除（可选）

仅移除数据功能链接（MTP/ADB/PTP），保持 gadget 绑定。
对快充协议兼容性更好，但实现更复杂。

在 `config.sh` 中设置 `BLOCK_METHOD=functions` 启用。

## 安装

1. 将 `usb-data-guard-*.zip` 传入手机
2. 打开 KernelSU 管理器 → 模块 → 从存储安装
3. 选择 zip 文件安装
4. 重启设备

## 配置

编辑 `scripts/config.sh` 文件修改配置：

```bash
POLL_INTERVAL=1          # 轮询间隔（秒）
BLOCK_METHOD=udc         # 屏蔽方法: udc / functions
BLOCK_ON_SCREEN_OFF=true # 屏幕关闭时也屏蔽
LOG_FILE=/data/adb/usb_data_guard.log
DEBUG=false              # 调试日志
```

配置文件路径：`/data/adb/modules/usb_data_guard/scripts/config.sh`

## 快捷操作

在 KernelSU 管理器中点击模块的操作按钮，查看当前状态。

## 日志

```
adb shell cat /data/adb/usb_data_guard.log
```

## 充电说明

| 充电方式 | 屏蔽数据时 | 说明 |
|----------|-----------|------|
| 基础 USB 充电 (5V) | 正常 | 充电 IC 独立于 USB 控制器 |
| USB PD 快充 | 正常 | PD 通过 CC 引脚协商 |
| QC 快充 | 可能无法快充 | 需要数据线通信 |
| SuperVOOC/Warp | 可能无法快充 | 需要数据线通信 |

> 使用原装充电器和数据线时，部分 OnePlus 设备的 SuperVOOC 使用专用触点，不受影响。

## 卸载

在 KernelSU 管理器中删除模块，卸载脚本会自动恢复 USB 数据传输。

## 兼容性

- KernelSU v1.0+
- Android 12+ (tested on Android 14/16)
- 需要 configfs USB gadget 支持（现代设备均支持）
- 已测试：OnePlus PJF110 / Kernel 6.1.161
- 别的手机可以查询自己手机对应芯片的内核然后据此修改即可，内核源码命名方式通常为android_kernel_手机品牌名称-手机处理器芯片型号_u_14.0.1_手机品牌名称_手机型号，据此在GitHub或者Google搜索即可，如android_kernel_oneplus_sm7675-oneplus-sm7675_u_14.0.1_oneplus_ace3v
