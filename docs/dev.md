# Contributor Development Guide

Language: English | [Simplified Chinese](dev.cn.md)

This guide is for external contributors who want to build, test, or change HIDMI from source. Start with the public overview in [../README.md](../README.md), use [diagnostics.md](diagnostics.md) when investigating a running server, and use [protocol.md](protocol.md) when changing wire behavior.

## When To Use This Guide

- Use this guide when you need to build the macOS client or Linux server locally.
- Use this guide when you are changing client behavior, server behavior, hardware profiles, protobuf definitions, or developer tools.
- Use this guide to choose the smallest verification set that matches your change.

## Development Prerequisites

- macOS client work requires macOS `26.0` or newer and Xcode with Swift `6.0` support. DMG packaging also uses the macOS `hdiutil` tool.
- Linux server work requires CMake or Make, a C++17 compiler, `protoc`, protobuf development libraries, systemd for install validation, and USB gadget support for hardware testing.
- Protobuf and smoke-tool work requires Python 3 and the packages listed in `devtools/requirements.txt`.
- Local build output belongs under `build/` and should remain untracked.

## Repository Map

- `client/macos/` contains the Swift macOS client, Xcode project, localized strings, app resources, tests, and committed Swift protobuf bindings.
- `server/` contains the native Linux C++ server, hardware profiles, install logic, USB gadget setup, HID writers, runtime status, and C++ tests.
- `proto/` is the protocol source of truth. Each protobuf message or enum lives in its own file with a `msg_` or `enum_` filename prefix.
- `devtools/` contains protobuf generation, generated Python protobuf bindings, the local protobuf smoke server, and the stress client.
- `package_dmg.sh` and `build_server.sh` are root-level shortcuts for local DMG packaging and CMake server builds.

## Common Development Tasks

### Build And Test The macOS Client

Run Debug XCTest and a Release build when changing client behavior, menus, token handling, input capture, or generated Swift protobuf bindings.

```bash
xcodebuild test -project client/macos/HIDMI.xcodeproj -scheme HIDMI -configuration Debug
xcodebuild build -project client/macos/HIDMI.xcodeproj -scheme HIDMI -configuration Release
```

Success means XCTest completes without failures and the Release app exists at `build/macos/Release/HIDMI.app`.

Use the root packaging script when you need a local DMG artifact.

```bash
./package_dmg.sh
```

Success means the Release app builds and `build/dist/HIDMI.dmg` is created. Use `./package_dmg.sh --skip-build` to package an existing app bundle, or `./package_dmg.sh --help` for output and volume-name options.

### Build And Test The Linux Server

Use CMake for local verification because it generates C++ protobuf bindings inside the build directory.

```bash
./build_server.sh --test
```

Success means the server target builds and `hidmi_tests` exits with status `0`.

The script wraps the equivalent CMake flow below and writes the server binary to `build/server-cmake/hidmi`.

```bash
cmake -S server -B build/server-cmake
cmake --build build/server-cmake -j4
./build/server-cmake/hidmi_tests
```

Use Make on a target Linux device or when validating install behavior.

```bash
make -C server
make -C server test
sudo make -C server install
```

Success means the `hidmi` CLI is installed in the selected prefix and the test target passes.

### Install A Hardware Profile

After installing the server binary, install a supported hardware profile with a shared token.

```bash
sudo hidmi install <profile> --token '<token>'
sudo hidmi status
```

Success means `sudo hidmi status` prints a status table and the service, HID, UDP, and TCP rows are healthy for the current hardware state.

Use `--config` for a custom hardware profile.

```bash
sudo hidmi install --config server/conf/<profile>.toml --token '<token>'
```

Persistent profiles should point at real HID gadget nodes and a readable UDC state path.

### Regenerate Protobuf Bindings

Edit protobuf definitions only under `proto/`, then regenerate the committed Swift and Python outputs.

```bash
devtools/generate_protos.sh
```

Success means Swift outputs are updated under `client/macos/HIDMI/Generated` and Python outputs are updated under `devtools/generated`.

The C++ server intentionally generates its protobuf bindings inside the server build directory with the local `protoc`; those generated C++ files are not committed.

### Prepare Python Devtools

Set up the Python environment before running smoke tools or compile checks.

```bash
python3 -m venv build/devtools-protobuf-venv
build/devtools-protobuf-venv/bin/python -m pip install -r devtools/requirements.txt
build/devtools-protobuf-venv/bin/python -m py_compile devtools/protobuf_smoke_server.py devtools/protobuf_stress_client.py devtools/generated/*_pb2.py
```

Success means package installation finishes and `py_compile` exits without syntax or import errors.

### Run The Local Protobuf Smoke Server

Use the local smoke server to exercise discovery, TCP channel setup, decoded frame logging, and keyboard retry behavior without production authentication.

```bash
build/devtools-protobuf-venv/bin/python devtools/protobuf_smoke_server.py --no-auth
```

Before testing the Release app, close any existing HIDMI process and open the built app.

```bash
pkill -x HIDMI || true
open build/macos/Release/HIDMI.app
```

Success means connecting through the `Input` menu causes the smoke server to print decoded frames as `[timestamp][TCP1/2/3] ...`, where `TCP1` is control, `TCP2` is mouse, and `TCP3` is keyboard.

Use `--keyboard-ack-delay-ms <ms>` to exercise TCP3 retry behavior.

## Verification Matrix

- Protobuf definitions changed: run `devtools/generate_protos.sh`, Python devtools compile checks, macOS tests, server tests, and local smoke server verification.
- macOS client behavior changed: run Debug XCTest and the Release build; add smoke verification when connection or input behavior changed.
- Linux server behavior, hardware profiles, HID output, status reporting, or protocol handling changed: run CMake server build and `hidmi_tests`; use a target device for install or USB gadget changes.
- Developer tools changed: run the Python devtools environment setup and compile checks.
- Documentation-only changes: run Markdown review, link review, and text scans; builds are not required unless a documented command or behavior needs confirmation.

## Architecture Constraints

- User-visible macOS app text should go through `client/macos/HIDMI/en.lproj/Localizable.strings` and `client/macos/HIDMI/zh-Hans.lproj/Localizable.strings`.
- Runtime `Input` and `View` menus are owned by static SwiftUI `Commands`; avoid dynamic top-level menu insertion or replacement unless the architecture intentionally changes.
- Startup begins discovery only; it should not auto-connect, show token prompts, or call LocalAuthentication at launch.
- Token management uses `LocalHIDMITokenStore` and stores app-owned token data under Application Support `HIDMI/tokens.json`.
- Mouse input uses an ordered FIFO writer and must preserve captured event order without coalescing, sampling, rate limiting, replacing the latest state, or dropping events.
- Keyboard input uses the dedicated TCP3 ACK and retry writer and must not be blocked by the control-channel heartbeat path.
- Use `HIDMI_INPUT_TRACE=1` only for opt-in input diagnostics; default runtime logs should not continuously print mouse positions.
