# 贡献者开发指南

语言：中文 | [English](dev.md)

本文档面向希望从源码构建、测试或修改 HIDMI 的外部贡献者。公共概览请先阅读 [../README.cn.md](../README.cn.md)，排查运行中服务端请阅读 [diagnostics.cn.md](diagnostics.cn.md)，修改通信行为请阅读 [protocol.cn.md](protocol.cn.md)。

## 何时阅读本文档

- 需要在本地构建 macOS 客户端或 Linux 服务端时，请阅读本文档。
- 修改客户端行为、服务端行为、硬件配置、protobuf 定义或开发工具时，请阅读本文档。
- 需要为一次变更选择最小验证范围时，请阅读本文档。

## 开发前准备

- macOS 客户端开发需要 macOS `26.0` 或更新版本，以及支持 Swift `6.0` 的 Xcode。
- Linux 服务端开发需要 CMake 或 Make、C++17 编译器、`protoc`、protobuf 开发库、用于安装验证的 systemd，以及用于硬件测试的 USB gadget 支持。
- Protobuf 和 smoke 工具开发需要 Python 3，以及 `devtools/requirements.txt` 中列出的依赖。
- 本地构建输出应放在 `build/` 下，并保持未跟踪状态。

## 仓库结构

- `client/macos/` 包含 Swift macOS 客户端、Xcode 工程、本地化字符串、应用资源、测试，以及已提交的 Swift protobuf 绑定。
- `server/` 包含原生 Linux C++ 服务端、硬件配置、安装逻辑、USB gadget 设置、HID 写入器、运行时状态和 C++ 测试。
- `proto/` 是协议源码的唯一事实来源。每个 protobuf message 或 enum 都位于独立文件中，并使用 `msg_` 或 `enum_` 文件名前缀。
- `devtools/` 包含 protobuf 生成脚本、已生成的 Python protobuf 绑定、本地 protobuf smoke server 和 stress client。

## 常见开发任务

### 构建并测试 macOS 客户端

修改客户端行为、菜单、令牌处理、输入捕获或已生成 Swift protobuf 绑定时，请运行 Debug XCTest 和 Release 构建。

```bash
xcodebuild test -project client/macos/HIDMI.xcodeproj -scheme HIDMI -configuration Debug
xcodebuild build -project client/macos/HIDMI.xcodeproj -scheme HIDMI -configuration Release
```

成功标准是 XCTest 无失败完成，并且 Release 应用存在于 `build/macos/Release/HIDMI.app`。

### 构建并测试 Linux 服务端

本地验证优先使用 CMake，因为它会在构建目录中生成 C++ protobuf 绑定。

```bash
cmake -S server -B build/server-cmake
cmake --build build/server-cmake -j4
./build/server-cmake/hidmi_tests
```

成功标准是服务端目标完成构建，并且 `hidmi_tests` 以状态码 `0` 退出。

在目标 Linux 设备上，或验证安装行为时，可以使用 Make。

```bash
make -C server
make -C server test
sudo make -C server install
```

成功标准是 `hidmi` CLI 安装到所选 prefix，并且 test 目标通过。

### 安装硬件配置

安装服务端二进制文件后，使用共享令牌安装受支持的硬件配置。

```bash
sudo hidmi install <profile> --token '<token>'
sudo hidmi status
```

成功标准是 `sudo hidmi status` 打印状态表，并且 service、HID、UDP 和 TCP 行在当前硬件状态下正常。

自定义硬件配置请使用 `--config`。

```bash
sudo hidmi install --config server/conf/<profile>.toml --token '<token>'
```

持久 profile 应指向真实的 HID gadget 节点和可读取的 UDC state 路径。

### 重新生成 Protobuf 绑定

只在 `proto/` 下编辑 protobuf 定义，然后重新生成已提交的 Swift 和 Python 输出。

```bash
devtools/generate_protos.sh
```

成功标准是 Swift 输出更新到 `client/macos/HIDMI/Generated`，Python 输出更新到 `devtools/generated`。

C++ 服务端会刻意使用本地 `protoc` 在服务端构建目录中生成 protobuf 绑定；这些生成的 C++ 文件不提交。

### 准备 Python Devtools

运行 smoke 工具或编译检查前，请先准备 Python 环境。

```bash
python3 -m venv build/devtools-protobuf-venv
build/devtools-protobuf-venv/bin/python -m pip install -r devtools/requirements.txt
build/devtools-protobuf-venv/bin/python -m py_compile devtools/protobuf_smoke_server.py devtools/protobuf_stress_client.py devtools/generated/*_pb2.py
```

成功标准是依赖安装完成，并且 `py_compile` 没有语法或导入错误。

### 运行本地 Protobuf Smoke Server

使用本地 smoke server 在不启用生产认证的情况下验证发现、TCP 通道建立、解码 frame 日志和键盘重试行为。

```bash
build/devtools-protobuf-venv/bin/python devtools/protobuf_smoke_server.py --no-auth
```

测试 Release 应用前，请先关闭已有 HIDMI 进程，再打开构建出的应用。

```bash
pkill -x HIDMI || true
open build/macos/Release/HIDMI.app
```

成功标准是通过 `Input` 菜单连接后，smoke server 以 `[timestamp][TCP1/2/3] ...` 打印解码后的 frame，其中 `TCP1` 是控制通道，`TCP2` 是鼠标通道，`TCP3` 是键盘通道。

可以使用 `--keyboard-ack-delay-ms <ms>` 测试 TCP3 重试行为。

## 验证矩阵

- 修改 protobuf 定义：运行 `devtools/generate_protos.sh`、Python devtools 编译检查、macOS 测试、服务端测试和本地 smoke server 验证。
- 修改 macOS 客户端行为：运行 Debug XCTest 和 Release 构建；连接或输入行为变化时增加 smoke 验证。
- 修改 Linux 服务端行为、硬件配置、HID 输出、状态报告或协议处理：运行 CMake 服务端构建和 `hidmi_tests`；安装或 USB gadget 变化需要在目标设备上验证。
- 修改开发工具：运行 Python devtools 环境准备和编译检查。
- 仅修改文档：进行 Markdown 审阅、链接审阅和文本扫描；除非文档中的命令或行为需要确认，否则不要求构建。

## 架构约束

- macOS 应用中用户可见的文本应通过 `client/macos/HIDMI/en.lproj/Localizable.strings` 和 `client/macos/HIDMI/zh-Hans.lproj/Localizable.strings` 管理。
- 运行时 `Input` 和 `View` 菜单由静态 SwiftUI `Commands` 拥有；除非有意修改架构，否则避免动态插入或替换顶级菜单。
- 启动阶段只开始发现流程；启动时不应自动连接、显示令牌提示或调用 LocalAuthentication。
- 令牌管理使用 `LocalHIDMITokenStore`，并将应用自有令牌数据存储在 Application Support `HIDMI/tokens.json` 下。
- 鼠标输入使用有序 FIFO 写入器，必须保持捕获事件顺序，不合并、采样、限速、替换最新状态或丢弃事件。
- 键盘输入使用专用 TCP3 ACK 和重试写入器，并且不得被控制通道心跳路径阻塞。
- 仅在主动排查输入问题时使用 `HIDMI_INPUT_TRACE=1`；默认运行日志不应持续打印鼠标位置。
