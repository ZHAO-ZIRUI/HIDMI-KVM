# 排障指南

语言：中文 | [English](diagnostics.md)

本文档面向正在诊断 Linux 服务端的贡献者和设备维护者。它说明如何阅读 `sudo hidmi status`、应该先看哪些状态，以及哪些辅助命令有用。

开发和构建流程请参阅 [dev.cn.md](dev.cn.md)。协议行为请参阅 [protocol.cn.md](protocol.cn.md)。

## 快速判断

- 先看 `Overall`。`OK` 表示设备健康且已连接；`IDLE` 通常表示设备健康并正在等待客户端；`ERR` 表示需要继续查看其他状态行。
- 如果发现失败，优先检查配置和 UDP 状态行。
- 如果能发现但连接失败，优先检查 TCP、客户端连接、认证和 HID runtime 状态行。
- 如果能看到画面但不能输入，优先检查 HID 状态行，以及 macOS `Input` 菜单是否已连接。
- 如果 LED 行为异常，先对照 README 的 LED 状态速查，再检查状态表中的 LED 行。

## 状态命令

当发现、连接、USB HID 输出或 LED 指示不符合预期时，请在 Linux 设备上运行该命令。

```bash
sudo hidmi status
```

该命令需要 `sudo`，因为它会检查 systemd 服务、HID gadget 节点、已配置的 UDC state 路径、UDP 监听状态、LED sysfs 路径，以及 `/run/hidmi/status.json` 运行时状态文件。

## 常用辅助命令

当服务状态行不健康时，使用 systemd status 查看服务状态。

```bash
systemctl status hidmi.service
systemctl status hidmi-gadget.service
```

当服务正在运行但连接、HID 或运行时状态不符合预期时，查看 journal 日志。

```bash
journalctl -u hidmi.service -n 200 --no-pager
journalctl -u hidmi-gadget.service -n 200 --no-pager
```

更换线缆、重启服务或重新连接目标电脑后，再次运行已安装的状态命令。

```bash
sudo hidmi status
```

## 按症状排查

### 应用发现不到 KVM 设备

- 确认 Mac 和 Linux 设备位于同一个局域网内。
- 确认 UDP 端口 `55536` 没有被网络阻断。
- 检查 `UDP Discovery`、`Device`、`Display Name` 和 `Service hidmi.service`。
- 查看 `journalctl -u hidmi.service` 中是否有启动或端口绑定错误。

### 应用能发现设备但无法连接

- 检查 `TCP Accept`、`Client Connection`、`HID Runtime` 和 `HID Available`。
- 确认已安装令牌和 macOS 应用中选择的令牌一致。
- 查看服务日志中是否有 offer 拒绝、认证失败、TCP 绑定失败或通道超时消息。

### 能看到画面但不能输入

- 确认 macOS `Input` 菜单已经连接到 KVM 设备。
- 检查 `HID Keyboard`、`HID Mouse`、`HID Absolute Mouse`、`HID Available` 和 `Input Watchdog`。
- 确认目标电脑识别到 Linux 设备提供的 USB 键盘和鼠标。
- 如果按键或按钮看起来卡住，请在 macOS 应用中使用 `Release All Keys`。

### LED 状态不符合预期

- 将物理 LED 模式与 README 中的 LED 状态速查对照。
- 检查 `LED Enabled`、`LED Primary` 和 `LED Secondary`。
- 如果 LED 行健康但模式仍不符合预期，请检查硬件 profile 中的 LED 路径和服务日志。

### 令牌或认证失败

- 确认生产服务端使用了预期的共享令牌安装。
- 确认 macOS 应用中为该设备选择了匹配的令牌。
- 检查 `Client Connection` 和服务日志中是否有认证拒绝或限速信息。

## 输出示例

下表展示状态输出的形态。具体设备名、路径、LED 名称和状态值会随硬件配置与运行状态变化。

```text
+------------------------------+------------------------------------------+
| Item                         | Status                                   |
+------------------------------+------------------------------------------+
| Overall                      | IDLE                                     |
+------------------------------+------------------------------------------+
| Device                       | hidmi                                    |
| Display Name                 | HIDMI KVM                                |
+------------------------------+------------------------------------------+
| Service hidmi.service        | OK                                       |
| Service hidmi-gadget.service | OK                                       |
+------------------------------+------------------------------------------+
| HID Keyboard                 | OK(/dev/hidg0)                           |
| HID Mouse                    | OK(/dev/hidg1)                           |
| HID Absolute Mouse           | OK(/dev/hidg2)                           |
| HID Available                | OK(configured)                           |
| UDC State Path               | /sys/class/udc/<controller>/state        |
| HID Runtime                  | OK                                       |
| Gadget Reset Count           | 0                                        |
| Last Gadget Reset            | never                                    |
+------------------------------+------------------------------------------+
| UDP Discovery                | OK(55536)                                |
| TCP Accept                   | OK                                       |
| TCP Workers                  | 0                                        |
+------------------------------+------------------------------------------+
| LED Enabled                  | OK                                       |
| LED Primary                  | OK(green_led)                            |
| LED Secondary                | OK(red_led)                              |
+------------------------------+------------------------------------------+
| Client Connection            | IDLE                                     |
| Last Connected               | never                                    |
| Last Disconnect              | none                                     |
| Input Watchdog               | never                                    |
+------------------------------+------------------------------------------+
```

## 字段参考

### 总体

- **Overall**
    - `OK`: 设备健康且已连接客户端。
    - `IDLE`: 设备健康，但当前没有客户端连接。
    - `ERR`: 至少一项基础检查失败，或客户端协议版本不匹配。

### 配置

- **Device**
    - 取值：服务端配置中的已安装硬件配置名称。
    - `ERR(config unavailable)`: 已安装配置不可读取。
- **Display Name**
    - 取值：发现阶段广播给 macOS 的显示名称。
    - `ERR(config unavailable)`: 已安装配置不可读取。
- **UDC State Path**
    - 取值：用于检查 USB gadget 是否 configured 的 sysfs 路径。
    - `ERR(config unavailable)`: 已安装配置不可读取。

### systemd 服务

- **Service hidmi.service**
    - `OK`: 主 UDP/TCP daemon 处于 `active` 且 `enabled` 状态。
    - `NOT ACTIVE`: systemd 服务当前未运行。
    - `NOT ENABLED`: systemd 服务未设置为开机启用。
- **Service hidmi-gadget.service**
    - `OK`: USB HID gadget 设置服务处于 `active` 且 `enabled` 状态。
    - `NOT ACTIVE`: systemd 服务当前未运行。
    - `NOT ENABLED`: systemd 服务未设置为开机启用。

### HID 和 USB Gadget

- **HID Keyboard**
    - `OK(<path>)`: 已配置的键盘 HID gadget 节点存在且可写。
    - `ERR(<path>)`: 节点缺失、不可写，或不是可用的字符设备。
- **HID Mouse**
    - `OK(<path>)`: 已配置的相对鼠标 HID gadget 节点存在且可写。
    - `ERR(<path>)`: 节点缺失、不可写，或不是可用的字符设备。
- **HID Absolute Mouse**
    - `OK(<path>)`: 已配置的绝对指针 HID gadget 节点存在且可写。
    - `ERR(<path>)`: 绝对指针节点不可用，指针能力可能降级。
- **HID Available**
    - `OK(configured)`: USB device controller 已进入 `configured` 状态，可以输出 HID。
    - `ERR(...)`: UDC state 路径缺失、不可读，或当前状态不是 `configured`。
- **HID Runtime**
    - `OK`: daemon 运行时当前可以写入 HID gadget 设备。
    - `ERR(...)`: 运行时状态缺失、过期，或最近一次 HID 写入检查失败。
- **Gadget Reset Count**
    - 取值：daemon 执行 soft gadget reset 的次数。
    - `ERR`: 运行时状态缺失或过期。
- **Last Gadget Reset**
    - `never`: 当前运行状态中没有记录 gadget reset。
    - 时间和原因：最近一次 gadget reset 的时间与原因。

### 网络

- **UDP Discovery**
    - `OK(55536)`: 发现 socket 正在配置的 UDP 端口上监听。
    - `ERR(55536)`: 发现 socket 未在配置的 UDP 端口上监听。
- **TCP Accept**
    - `OK`: daemon 运行时已准备好接受三条 TCP 通道。
    - `ERR`: 主服务或运行时状态不可用。
- **TCP Workers**
    - 取值：当前 TCP accept worker 线程数量。
    - `ERR`: 运行时状态缺失或过期。

### LED

- **LED Enabled**
    - `OK`: LED 指示已启用，且两个 LED 路径都可用。
    - `OFF`: 配置中关闭了 LED 指示。
    - `ERR(...)`: LED 配置缺失，或至少一个 LED 路径不可用。
- **LED Primary**
    - `OK(<name>)`: 主 LED 路径可用。
    - `OFF(<name>)`: LED 指示被配置为关闭。
    - `ERR(<name>)`: 主 LED 路径不可用。
- **LED Secondary**
    - `OK(<name>)`: 副 LED 路径可用。
    - `OFF(<name>)`: LED 指示被配置为关闭。
    - `ERR(<name>)`: 副 LED 路径不可用。

### 客户端连接

- **Client Connection**
    - `OK`: macOS 客户端已连接且状态正常。
    - `IDLE`: daemon 正常运行，正在等待客户端连接。
    - `STALE`: 客户端连接记录存在，但最近请求已超时。
    - `ERR(proto mismatch)`: 客户端和服务端协议版本不匹配。
    - `ERR`: 运行时状态不可用。
- **Last Connected**
    - `never`: 当前运行状态中没有成功连接记录。
    - 时间：macOS 客户端上次完成连接的时间。
- **Last Disconnect**
    - `none`: 当前运行状态中没有断开原因。
    - 原因：daemon 记录的最近一次断开原因。
- **Input Watchdog**
    - `never`: watchdog 尚未触发过输入释放。
    - 时间：服务端上次因 watchdog 触发而释放输入的时间。
