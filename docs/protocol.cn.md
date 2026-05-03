# 协议参考

语言：中文 | [English](protocol.md)

本文档面向需要修改发现、认证、TCP framing、远程输入行为或 protobuf 定义的贡献者。它描述当前 macOS 客户端、Linux 服务端和 devtools 实现的 HIDMI 协议版本 `1`。

公共概览位于 [../README.cn.md](../README.cn.md)，开发流程位于 [dev.cn.md](dev.cn.md)，运行时排障位于 [diagnostics.cn.md](diagnostics.cn.md)。

## 范围和事实来源

- `proto/` 是协议源码的唯一事实来源。每个 protobuf message 或 enum 都位于独立 `.proto` 文件中，并使用 `msg_` 或 `enum_` 文件名前缀。
- 本文档解释行为、顺序和实现约束；精确字段定义以 protobuf 文件为准。
- 生成后的 Swift 和 Python 绑定已提交在 `client/macos/HIDMI/Generated` 和 `devtools/generated`。
- C++ 服务端会使用本地 `protoc` 将 protobuf 绑定生成到构建目录中；生成的 C++ 绑定不提交。

## 传输概览

UDP 用于在端口 `55536` 上执行发现和 offer 协商。UDP payload 是序列化后的 `UdpPacket` 消息，并使用 `protocol_version = 1`。

TCP 用于活动会话。每个 TCP payload 都使用四字节大端无符号长度作为帧头，后面跟随序列化后的 `TcpFrame`。

```text
uint32_be length
protobuf(TcpFrame)
```

活动会话使用三条 TCP 通道：`CHANNEL_CONTROL`、`CHANNEL_MOUSE` 和 `CHANNEL_KEYBOARD`。

## 会话时序

1. 服务端在空闲或忙碌时广播 `Discover` packet。
2. 客户端在服务端公布的范围内选择三个互不相同且不在拒绝列表中的 TCP 端口。
3. 客户端向 UDP 端口 `55536` 发送 `Offer`。
4. 服务端验证协议版本、服务端身份、启动身份、端口有效性、忙碌状态、认证限速、HMAC 认证和 HID 可用性。
5. 服务端返回 `OfferCallback`。接受时包含 `session_id` 和 `connect_deadline_ms`；拒绝时包含 `OfferRejectReason`。
6. 服务端绑定客户端请求的 TCP listener，并在截止时间前等待客户端打开控制、鼠标和键盘通道。
7. 每条 TCP 通道都以携带预期通道 id 的 `ChannelOpen` 开始。服务端以 `ChannelReady` 响应。
8. 只有三条通道全部 ready 后，会话才进入活动状态。
9. 控制通道每秒发送一次 `Heartbeat`；服务端以 `HeartbeatAck` 响应。
10. 客户端使用 `Goodbye` 正常关闭；服务端会尽力释放输入后返回 `GoodbyeAck`。

## 通道职责

| 通道 | 用途 | ACK 行为 |
| --- | --- | --- |
| `CHANNEL_CONTROL` | 通道建立、心跳、释放所有输入、goodbye 和控制错误。 | 心跳期望 `HeartbeatAck`；控制生命周期消息使用各自的响应消息。 |
| `CHANNEL_MOUSE` | 有序 `MouseState` frame。 | 普通鼠标输入不需要 `Ack`。 |
| `CHANNEL_KEYBOARD` | 有序 `KeyboardState` 和 `KeyboardSpecial` frame。 | 键盘 frame 需要 `Ack`，并由专用 TCP3 写入器重试。 |

鼠标和键盘流量刻意使用不同通道，这样键盘 ACK/重试行为不会阻塞鼠标发送或控制通道心跳路径。

## 认证

生产服务端需要共享令牌。本地 protobuf smoke server 可以使用 `--no-auth` 启动，但该模式仅用于本地测试。

客户端使用裁剪空白后的 UTF-8 令牌字节作为 HMAC key，对以下规范字节序列计算 HMAC-SHA256，并写入 `Offer.auth_mac`。

```text
uint32_be protocol_version
uint64_be server_id
uint64_be boot_id
bytes challenge_nonce
bytes client_nonce
uint32_be control_tcp_port
uint32_be mouse_tcp_port
uint32_be keyboard_tcp_port
uint64_be client_unix_ms
```

认证失败可能返回 `TOKEN_AUTH_FAILED` 或 `AUTH_RATE_LIMITED`。

该认证模型用于局域网设备配对。不应把它描述成面向公网的安全边界。

## TCP Frame 模型

每个 `TcpFrame` 都携带会话 id、通道 id、序列号、单调时间戳、ACK 需求标记，以及一个 body。

frame 序列号属于 `TcpFrame`；`KeyboardState` 等输入消息 body 不携带独立序列字段。

当发送方期望收到 `Ack` 时使用 `ack_required`。键盘 frame 需要 ACK；普通鼠标 frame 不需要 ACK。

## 输入语义

鼠标状态通过专用有序 FIFO 写入器发送。该写入器只保证发送顺序，不得合并、采样、限速、替换最新状态或丢弃已捕获事件。

`MouseState.abs_x` 和 `MouseState.abs_y` 使用客户端绝对坐标范围 `0...65535`。服务端会将其缩放到 HID 绝对坐标范围 `0...32767`。

相对回退字段 `rel_dx`、`rel_dy` 和 `wheel_delta_y` 会被服务端限制到 HID 相对范围 `-127...127`。

键盘状态以完整 `KeyboardState` 快照发送，其中包含 `modifier_mask` 和 `pressed_usage_ids`。服务端会为每个接受的快照写入完整 HID 键盘报告。

macOS 客户端通过专用 TCP3 FIFO 写入器发送键盘快照。该写入器每 `100 ms` 重试当前 frame，直到收到 `ACK_OK`、`ACK_DUPLICATED`，或达到 `3 s` 超时。

Ctrl-Alt-Del 表示为 `KeyboardSpecial(KEYBOARD_SPECIAL_CTRL_ALT_DEL)`，并排入同一个 TCP3 写入器，从而与普通键盘快照保持顺序。

`ReleaseAll` 通过控制通道发送，用于请求服务端尽力释放键盘、相对鼠标和绝对鼠标状态。

## 消息参考

### UDP 消息

- `UdpPacket` 包装所有 UDP 协议 body，并携带 `protocol_version`。
- `Discover` 公布服务端身份、启动身份、显示名称、接口类型、TCP 端口范围、拒绝端口、challenge nonce、忙碌状态、HID 状态、指针可用性和能力列表。
- `Offer` 携带选定的服务端身份、客户端身份、client nonce、客户端时间戳、三个请求的 TCP 端口和认证 MAC。
- `OfferCallback` 接受或拒绝 offer，并返回 `session_id`、`connect_deadline_ms` 或 `reject_reason`。

### TCP 消息

- `TcpFrame` 包装所有 TCP 协议 body，并携带会话、通道、序列、单调时间戳和 ACK 元数据。
- `ChannelOpen` 打开一条 TCP 通道，并声明预期的通道 id。
- `ChannelReady` 确认该通道是否被接受。
- `Heartbeat` 携带心跳序列和客户端发送时间戳。
- `HeartbeatAck` 回显心跳时序，并补充服务端接收和发送时间戳。
- `Ack` 使用 `ACK_OK`、`ACK_DUPLICATED` 或 `ACK_REJECTED` 确认目标通道和序列。
- `MouseState` 携带绝对指针坐标、按钮、滚轮、可靠性、捕获时间戳和相对回退字段。
- `KeyboardState` 携带完整键盘快照的修饰键 mask 和已按下 HID usage id。
- `KeyboardSpecial` 携带 Ctrl-Alt-Del 等特殊键盘动作。
- `ReleaseAll` 请求尽力释放所有当前按下的远程输入。
- `Goodbye` 请求干净关闭会话。
- `GoodbyeAck` 确认干净关闭会话。
- `Error` 使用严重级别、通道、关联序列和消息文本报告协议或运行时错误。

### 枚举

- `ChannelId` 定义 `CHANNEL_CONTROL`、`CHANNEL_MOUSE` 和 `CHANNEL_KEYBOARD`。
- `AckResult` 定义 `ACK_OK`、`ACK_DUPLICATED` 和 `ACK_REJECTED`。
- `OfferRejectReason` 覆盖认证失败、TCP 端口占用、身份不匹配、服务端忙、协议不匹配、无效端口、内部错误、HID 不可用和认证限速。
- `HidStatus` 报告未知状态、就绪状态、USB 未配置、设备不可用、写入失败、gadget 不可用和绝对指针降级。
- `InterfaceType` 区分未知、以太网和 WLAN 发现接口。
- `KeyboardSpecialId` 定义特殊键盘命令。当前生产客户端使用 `KEYBOARD_SPECIAL_CTRL_ALT_DEL`。
- `GoodbyeReason` 描述正常退出、客户端退出、服务端关闭和错误关闭。
- `ErrorSeverity` 区分信息、警告和致命错误。

## 兼容性和变更流程

协议版本 `1` 描述当前实现。本文档不定义未来协议版本的行为。

协议变更必须更新 `proto/`，重新生成已提交的 Swift 和 Python 绑定，并保持服务端 C++ protobuf 绑定在构建目录内生成。

任何影响发现、认证、通道建立、鼠标行为、键盘行为、释放行为或 HID 输出的变更，都应更新本文档，并运行 [dev.cn.md](dev.cn.md) 中的相关检查。

协议变更至少应运行 protobuf 生成、Python devtools 编译检查、Debug XCTest、服务端测试、Release 构建和本地 protobuf smoke 验证。
