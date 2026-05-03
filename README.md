# HIDMI

Language: English | [Simplified Chinese](README.cn.md)

HIDMI is a local-network, hardware-level KVM project. It lets a Mac display a target computer's HDMI output and uses a Linux device with USB gadget support to send standard USB HID keyboard and mouse input to the target.

The target computer does not need agent software. If it can output HDMI and recognize a USB keyboard and mouse, it can be controlled in BIOS, boot menus, installers, and operating systems.

## Project Status

- The repository currently includes the macOS client, Linux server, protobuf protocol definitions, and local debugging tools.
- The project currently focuses on source builds and local deployment; end-user packaged release instructions are not provided yet.
- The server needs an installed hardware profile; new devices usually require adding or adjusting a profile.

## Supported Devices

- [x] Orange Pi Zero 3 -> [orangepi-zero-3.toml](./server/conf/orangepi-zero-3.toml)

## Feature Highlights

- **Turn a Mac into a KVM console**: view the target computer in the macOS app and send keyboard, pointer, scroll, and special key input.
- **No target-side software**: input appears as USB HID devices, so it can work in BIOS, boot menus, system installers, and normal desktop environments.
- **Local discovery and token authentication**: the Mac can discover the server on the local network and use a shared token to reduce accidental connections.
- **Designed for device deployment and troubleshooting**: the server includes installation, systemd integration, status checks, runtime diagnostics, and LED state indication.

## How It Works

1. The HDMI capture device brings the target computer's video into the Mac.

2. The macOS client displays the video and sends mouse and keyboard input to the Linux device.

3. The Linux device writes that input through USB gadget as standard HID keyboard and mouse reports, so the target sees ordinary USB peripherals.

## Hardware And System Requirements

- Mac: macOS `26.0` or newer; building from source requires Xcode with Swift `6.0` support.
- Video capture: an HDMI capture device supported by AVFoundation.
- Linux device: USB OTG device mode, Linux USB gadget/configfs, systemd, a C++17 compiler, `protoc`, and protobuf development libraries.
- Target computer: HDMI output and support for USB keyboard and mouse input.
- Network: the Mac and Linux device must be on the same local network, and UDP port `55536` should not be blocked.

## Install

### Linux Server

Build and install the server binary on the Linux device, then install a supported hardware profile with a shared token.

```bash
make -C server
sudo make -C server install
sudo hidmi install <profile> --token '<token>'
sudo hidmi status
```

Use `--config` instead of a profile name when installing a custom hardware configuration.

```bash
sudo hidmi install --config server/conf/<profile>.toml --token '<token>'
```

### macOS Client

Build the Release app from source. The build output is written to `build/macos/Release/HIDMI.app`.

```bash
xcodebuild build -project client/macos/HIDMI.xcodeproj -scheme HIDMI -configuration Release
open build/macos/Release/HIDMI.app
```

## Quick Start

1. Connect the target computer's HDMI output to the capture device, then connect the capture device to the Mac.

2. Connect the Linux device's USB gadget port to the target computer. The target computer will recognize it as a USB keyboard and mouse.

3. Make sure the Mac and Linux device are on the same local network.

4. Start the service on the Linux device and confirm that the status is healthy.

   ```bash
   sudo systemctl start hidmi.service
   sudo hidmi status
   ```

5. Open the HIDMI app on macOS. The app starts discovery automatically, but it does not auto-connect or show a token prompt at startup.

6. Choose the HDMI capture device from the `Video` menu or the status area. If macOS asks for camera permission, allow access in System Settings.

7. Choose the discovered KVM device from the `Input` menu and connect it. If the device requires a token, add or select the token through the token management flow.

8. After the connection is established, move the pointer, click, scroll, and type inside the video preview area.

9. If the target computer appears to keep a key or button pressed, use `Release All Keys`; when a special key sequence is needed, use `Send Ctrl-Alt-Del`.

## Diagnostics And Status

Run the status command on the Linux device when discovery, connection, USB HID output, or LED indication does not behave as expected.

```bash
sudo hidmi status
```

This command requires `sudo` because it checks systemd services, HID gadget nodes, the configured UDC state path, UDP listening state, LED sysfs paths, and the runtime status file under `/run/hidmi/status.json`. For the full output example, row meanings, and common status values, see [docs/diagnostics.md](docs/diagnostics.md).

### LED Quick Reference

When the configured hardware profile provides LED paths, the primary LED is labeled `P` and the secondary LED is labeled `S`. Each sequence below uses five aligned time slots; `🟢⚫` or `🔴⚫` means one blink, `⚫⚫` means the slot is off, and repeated solid color means held on.

| LED | Sequence | Meaning |
| --- | --- | --- |
| `P` | 🟢⚫ 🟢⚫ 🟢⚫ ⚫⚫ ⚫⚫ | Idle. |
| `P` | 🟢🟢 🟢🟢 🟢🟢 🟢🟢 🟢🟢 | Client connected. |
| `P` | 🟢⚫ 🟢⚫ 🟢⚫ 🟢⚫ 🟢⚫ | Temporary protocol, network, or authentication error. |
| `S` | ⚫⚫ ⚫⚫ ⚫⚫ ⚫⚫ ⚫⚫ | Ready. |
| `S` | 🔴⚫ ⚫⚫ ⚫⚫ ⚫⚫ ⚫⚫ | USB is not configured. |
| `S` | 🔴⚫ 🔴⚫ ⚫⚫ ⚫⚫ ⚫⚫ | HID node is unavailable. |
| `S` | 🔴⚫ 🔴⚫ 🔴⚫ ⚫⚫ ⚫⚫ | HID write failed. |
| `S` | 🔴⚫ 🔴⚫ 🔴⚫ 🔴⚫ ⚫⚫ | Gadget is unavailable. |
| `S` | 🔴⚫ 🔴⚫ 🔴⚫ 🔴⚫ 🔴⚫ | Absolute pointer degraded. |

## FAQ

### Does the target computer need software installed?

No. HIDMI appears to the target computer as a standard USB keyboard and mouse, so the target only needs HDMI output and USB HID input support.

### Which target systems are supported?

If the target computer can recognize a standard USB keyboard and mouse, it can usually be controlled. This path does not depend on target-side agent software, so it also applies to BIOS, boot menus, and operating system installers.

### Why is no KVM device shown in the app?

Make sure the Linux device and Mac are on the same local network, UDP port `55536` is not blocked, the server is running, and `sudo hidmi status` shows healthy service and HID device states.

### Why can I see video but not send input?

Check that the `Input` menu is connected to the KVM device, the server HID gadget is configured, the target computer recognizes the USB keyboard and mouse, and the HID rows in `sudo hidmi status` are healthy.

### Why does the app show a token prompt?

Production servers require a configured shared token. Use the token printed by `hidmi install`, or the token specified with `--token` during installation.

### How do I add a new hardware profile?

Server hardware profiles live under `server/conf/`. Adding a device usually requires HID node paths, a UDC state path, and LED paths; see [docs/dev.md](docs/dev.md) for the development and verification workflow.

## More Docs

- [Developer Guide](docs/dev.md): build, test, protobuf generation, and local smoke workflow.
- [Diagnostics Reference](docs/diagnostics.md): `sudo hidmi status` output example, row meanings, and troubleshooting order.
- [Protocol Reference](docs/protocol.md): current protobuf UDP/TCP protocol, authentication, and input semantics.
