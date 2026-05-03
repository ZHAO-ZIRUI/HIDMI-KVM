# Troubleshooting Guide

Language: English | [Simplified Chinese](diagnostics.cn.md)

This guide is for contributors and operators diagnosing a running Linux server. It explains how to read `sudo hidmi status`, where to look first, and which follow-up commands are useful.

For setup and development workflow, see [dev.md](dev.md). For protocol behavior, see [protocol.md](protocol.md).

## Quick Triage

- Start with `Overall`. `OK` means the device is healthy and connected; `IDLE` usually means the device is healthy and waiting for a client; `ERR` means another row needs attention.
- If discovery fails, check the configuration and UDP rows first.
- If discovery works but connection fails, check TCP, client connection, authentication, and HID runtime rows.
- If video works but input does not, check the HID rows and whether the macOS `Input` menu is connected.
- If LED behavior looks wrong, use the README LED quick reference and then check the LED rows in the status table.

## Status Command

Run the command on the Linux device when discovery, connection, USB HID output, or LED indication does not behave as expected.

```bash
sudo hidmi status
```

The command requires `sudo` because it checks systemd services, HID gadget nodes, the configured UDC state path, UDP listening state, LED sysfs paths, and the runtime status file under `/run/hidmi/status.json`.

## Useful Follow-Up Commands

Use systemd status when a service row is not healthy.

```bash
systemctl status hidmi.service
systemctl status hidmi-gadget.service
```

Use journal logs when the service is running but connection, HID, or runtime state is unexpected.

```bash
journalctl -u hidmi.service -n 200 --no-pager
journalctl -u hidmi-gadget.service -n 200 --no-pager
```

Use the installed status command again after changing cabling, restarting services, or reconnecting the target computer.

```bash
sudo hidmi status
```

## Symptom Paths

### The App Does Not Discover A KVM Device

- Confirm the Mac and Linux device are on the same local network.
- Confirm UDP port `55536` is not blocked by the network.
- Check `UDP Discovery`, `Device`, `Display Name`, and `Service hidmi.service`.
- Review `journalctl -u hidmi.service` for startup or bind errors.

### The App Discovers The Device But Cannot Connect

- Check `TCP Accept`, `Client Connection`, `HID Runtime`, and `HID Available`.
- Confirm the installed token matches the token selected in the macOS app.
- Review service logs for offer rejection, authentication failure, TCP bind failure, or channel timeout messages.

### Video Works But Input Does Not

- Confirm the macOS `Input` menu is connected to the KVM device.
- Check `HID Keyboard`, `HID Mouse`, `HID Absolute Mouse`, `HID Available`, and `Input Watchdog`.
- Confirm the target computer recognizes the USB keyboard and mouse presented by the Linux device.
- Use `Release All Keys` from the macOS app if a key or button appears stuck.

### LED State Looks Wrong

- Compare the physical LED pattern with the README LED quick reference.
- Check `LED Enabled`, `LED Primary`, and `LED Secondary`.
- If LED rows are healthy but the pattern still looks wrong, check the hardware profile LED paths and service logs.

### Token Or Authentication Fails

- Confirm the production server was installed with the expected shared token.
- Confirm the macOS app has the matching token selected for that device.
- Check `Client Connection` and service logs for authentication rejection or rate limiting.

## Output Example

The table below shows the shape of the output. Device names, paths, LED names, and status values vary by hardware profile and runtime state.

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

## Row Reference

### Overall

- **Overall**
    - `OK`: the device is healthy and a client is connected.
    - `IDLE`: the device is healthy, but no client is connected.
    - `ERR`: at least one infrastructure check failed, or the client protocol version does not match.

### Configuration

- **Device**
    - Value: installed hardware profile name from the server configuration.
    - `ERR(config unavailable)`: the installed configuration cannot be read.
- **Display Name**
    - Value: display name advertised to macOS during discovery.
    - `ERR(config unavailable)`: the installed configuration cannot be read.
- **UDC State Path**
    - Value: sysfs path used to check whether the USB gadget is configured.
    - `ERR(config unavailable)`: the installed configuration cannot be read.

### systemd Services

- **Service hidmi.service**
    - `OK`: the main UDP/TCP daemon is `active` and `enabled`.
    - `NOT ACTIVE`: the systemd service is not currently running.
    - `NOT ENABLED`: the systemd service is not enabled at boot.
- **Service hidmi-gadget.service**
    - `OK`: the USB HID gadget setup service is `active` and `enabled`.
    - `NOT ACTIVE`: the systemd service is not currently running.
    - `NOT ENABLED`: the systemd service is not enabled at boot.

### HID And USB Gadget

- **HID Keyboard**
    - `OK(<path>)`: the configured keyboard HID gadget node exists and is writable.
    - `ERR(<path>)`: the node is missing, not writable, or not a usable character device.
- **HID Mouse**
    - `OK(<path>)`: the configured relative mouse HID gadget node exists and is writable.
    - `ERR(<path>)`: the node is missing, not writable, or not a usable character device.
- **HID Absolute Mouse**
    - `OK(<path>)`: the configured absolute pointer HID gadget node exists and is writable.
    - `ERR(<path>)`: the absolute pointer node is unavailable, and pointer capability may be degraded.
- **HID Available**
    - `OK(configured)`: the USB device controller is in the `configured` state and can output HID reports.
    - `ERR(...)`: the UDC state path is missing, unreadable, or not currently `configured`.
- **HID Runtime**
    - `OK`: the daemon runtime can currently write to the HID gadget devices.
    - `ERR(...)`: runtime status is missing or stale, or the latest HID write check failed.
- **Gadget Reset Count**
    - Value: number of soft gadget resets performed by the daemon.
    - `ERR`: runtime status is missing or stale.
- **Last Gadget Reset**
    - `never`: no gadget reset has been recorded in the current runtime state.
    - Time and reason: when the latest gadget reset happened and why.

### Network

- **UDP Discovery**
    - `OK(55536)`: the discovery socket is listening on the configured UDP port.
    - `ERR(55536)`: the discovery socket is not listening on the configured UDP port.
- **TCP Accept**
    - `OK`: the daemon runtime is ready to accept the three TCP channels.
    - `ERR`: the main service or runtime status is unavailable.
- **TCP Workers**
    - Value: current number of TCP accept worker threads.
    - `ERR`: runtime status is missing or stale.

### LED

- **LED Enabled**
    - `OK`: LED indication is enabled and both LED paths are available.
    - `OFF`: LED indication is disabled in the configuration.
    - `ERR(...)`: LED configuration is missing, or at least one LED path is unavailable.
- **LED Primary**
    - `OK(<name>)`: the primary LED path is available.
    - `OFF(<name>)`: LED indication is configured off.
    - `ERR(<name>)`: the primary LED path is unavailable.
- **LED Secondary**
    - `OK(<name>)`: the secondary LED path is available.
    - `OFF(<name>)`: LED indication is configured off.
    - `ERR(<name>)`: the secondary LED path is unavailable.

### Client Connection

- **Client Connection**
    - `OK`: a macOS client is connected and healthy.
    - `IDLE`: the daemon is healthy and waiting for a client.
    - `STALE`: a client connection is recorded, but recent requests have timed out.
    - `ERR(proto mismatch)`: the client and server protocol versions do not match.
    - `ERR`: runtime status is unavailable.
- **Last Connected**
    - `never`: no successful connection is recorded in the current runtime state.
    - Time: last time a macOS client completed a connection.
- **Last Disconnect**
    - `none`: no disconnect reason is recorded in the current runtime state.
    - Reason: latest disconnect reason recorded by the daemon.
- **Input Watchdog**
    - `never`: the watchdog has not released input yet.
    - Time: last time the server released input because the watchdog fired.
