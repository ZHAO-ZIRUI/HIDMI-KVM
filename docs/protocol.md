# Protocol Reference

Language: English | [Simplified Chinese](protocol.cn.md)

This reference is for contributors changing discovery, authentication, TCP framing, remote input behavior, or protobuf definitions. It describes HIDMI protocol version `1` as implemented by the current macOS client, Linux server, and devtools.

The public overview is in [../README.md](../README.md), the development workflow is in [dev.md](dev.md), and runtime troubleshooting is in [diagnostics.md](diagnostics.md).

## Scope And Source Of Truth

- `proto/` is the protocol source of truth. Each protobuf message or enum lives in its own `.proto` file with a `msg_` or `enum_` filename prefix.
- This document explains behavior, ordering, and implementation constraints; exact field definitions come from the protobuf files.
- Generated Swift and Python bindings are committed under `client/macos/HIDMI/Generated` and `devtools/generated`.
- The C++ server generates protobuf bindings into its build directory with the local `protoc`; generated C++ bindings are not committed.

## Transport Summary

UDP is used for discovery and offer negotiation on port `55536`. UDP payloads are serialized `UdpPacket` messages with `protocol_version = 1`.

TCP is used for the active session. Every TCP payload is framed as a four-byte big-endian unsigned length followed by a serialized `TcpFrame`.

```text
uint32_be length
protobuf(TcpFrame)
```

The active session uses three TCP channels: `CHANNEL_CONTROL`, `CHANNEL_MOUSE`, and `CHANNEL_KEYBOARD`.

## Session Timeline

1. The server broadcasts `Discover` packets while idle or busy.
2. The client selects three distinct TCP ports inside the advertised range and outside the rejected-port set.
3. The client sends `Offer` to UDP port `55536`.
4. The server validates protocol version, server identity, boot identity, port validity, busy state, authentication rate limits, HMAC authentication, and HID availability.
5. The server returns `OfferCallback`. Accepted callbacks include `session_id` and `connect_deadline_ms`; rejected callbacks include `OfferRejectReason`.
6. The server binds the requested TCP listeners and waits for the client to open the control, mouse, and keyboard channels before the deadline.
7. Each TCP channel starts with `ChannelOpen` carrying the expected channel id. The server responds with `ChannelReady`.
8. The session becomes active only after all three channels are ready.
9. The control channel sends one heartbeat per second with `Heartbeat`; the server responds with `HeartbeatAck`.
10. The client closes cleanly with `Goodbye`, and the server responds with `GoodbyeAck` after a best-effort input release.

## Channel Responsibilities

| Channel | Purpose | ACK behavior |
| --- | --- | --- |
| `CHANNEL_CONTROL` | Channel setup, heartbeats, release-all, goodbye, and control errors. | Heartbeats expect `HeartbeatAck`; control lifecycle messages use their own response messages. |
| `CHANNEL_MOUSE` | Ordered `MouseState` frames. | Normal mouse input does not require `Ack`. |
| `CHANNEL_KEYBOARD` | Ordered `KeyboardState` and `KeyboardSpecial` frames. | Keyboard frames require `Ack` and retry on the dedicated TCP3 writer. |

Mouse and keyboard traffic intentionally use separate channels so keyboard ACK/retry behavior cannot block mouse delivery or the control heartbeat path.

## Authentication

Production servers require a shared token. The local protobuf smoke server can be started with `--no-auth`, but that mode is only for local testing.

The client computes `Offer.auth_mac` as HMAC-SHA256 over this canonical byte sequence, using the trimmed UTF-8 token bytes as the HMAC key.

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

Authentication failures can return `TOKEN_AUTH_FAILED` or `AUTH_RATE_LIMITED`.

This authentication model is intended for local-network device pairing. Do not describe it as an internet-facing security boundary.

## TCP Frame Model

Every `TcpFrame` carries the session id, channel id, sequence number, monotonic timestamp, ACK requirement flag, and exactly one body.

The frame sequence number belongs to `TcpFrame`; input message bodies such as `KeyboardState` do not carry their own sequence field.

`ack_required` is used when the sender expects an `Ack`. Keyboard frames require ACK; normal mouse frames do not.

## Input Semantics

Mouse state is sent through a dedicated ordered FIFO writer. It preserves send order only and must not coalesce, sample, rate limit, replace latest state, or drop captured events.

`MouseState.abs_x` and `MouseState.abs_y` use the client absolute range `0...65535`. The server scales them to HID absolute range `0...32767`.

Relative fallback fields `rel_dx`, `rel_dy`, and `wheel_delta_y` are clamped by the server to the HID relative range `-127...127`.

Keyboard state is sent as full `KeyboardState` snapshots containing `modifier_mask` and `pressed_usage_ids`. The server writes a full HID keyboard report for each accepted snapshot.

The macOS client sends keyboard snapshots through a dedicated TCP3 FIFO writer. The writer retries the current frame every `100 ms` until `ACK_OK`, `ACK_DUPLICATED`, or a `3 s` timeout.

Ctrl-Alt-Del is represented as `KeyboardSpecial(KEYBOARD_SPECIAL_CTRL_ALT_DEL)` and is queued on the same TCP3 writer, preserving order with ordinary keyboard snapshots.

`ReleaseAll` is sent on the control channel and asks the server to make a best-effort release of keyboard, relative mouse, and absolute mouse state.

## Message Reference

### UDP Messages

- `UdpPacket` wraps all UDP protocol bodies and carries `protocol_version`.
- `Discover` advertises server identity, boot identity, display name, interface type, TCP port range, rejected ports, challenge nonce, busy state, HID status, pointer availability, and capabilities.
- `Offer` carries selected server identity, client identity, client nonce, client timestamp, three requested TCP ports, and authentication MAC.
- `OfferCallback` accepts or rejects the offer and returns `session_id`, `connect_deadline_ms`, or `reject_reason`.

### TCP Messages

- `TcpFrame` wraps all TCP protocol bodies and carries session, channel, sequence, monotonic timestamp, and ACK metadata.
- `ChannelOpen` opens one TCP channel and declares the expected channel id.
- `ChannelReady` confirms whether the channel was accepted.
- `Heartbeat` carries heartbeat sequence and client send timestamp.
- `HeartbeatAck` echoes heartbeat timing and adds server receive and send timestamps.
- `Ack` uses `ACK_OK`, `ACK_DUPLICATED`, or `ACK_REJECTED` to confirm a target channel and sequence.
- `MouseState` carries absolute pointer coordinates, buttons, wheel movement, reliability, capture timestamp, and relative fallback fields.
- `KeyboardState` carries a full keyboard snapshot with modifier mask and pressed HID usage ids.
- `KeyboardSpecial` carries special keyboard actions such as Ctrl-Alt-Del.
- `ReleaseAll` requests a best-effort release of all currently pressed remote input.
- `Goodbye` requests a clean session close.
- `GoodbyeAck` confirms a clean session close.
- `Error` reports protocol or runtime errors with severity, channel, related sequence, and message text.

### Enums

- `ChannelId` defines `CHANNEL_CONTROL`, `CHANNEL_MOUSE`, and `CHANNEL_KEYBOARD`.
- `AckResult` defines `ACK_OK`, `ACK_DUPLICATED`, and `ACK_REJECTED`.
- `OfferRejectReason` covers authentication failure, TCP port conflicts, identity mismatch, server busy state, protocol mismatch, invalid ports, internal errors, HID unavailability, and authentication rate limiting.
- `HidStatus` reports unknown state, ready state, USB not configured, device unavailable, write failure, gadget unavailable, and absolute pointer degradation.
- `InterfaceType` distinguishes unknown, Ethernet, and WLAN discovery interfaces.
- `KeyboardSpecialId` defines special keyboard commands. The current production client uses `KEYBOARD_SPECIAL_CTRL_ALT_DEL`.
- `GoodbyeReason` describes normal exit, client exit, server shutdown, and error shutdown.
- `ErrorSeverity` distinguishes informational, warning, and fatal errors.

## Compatibility And Change Process

Protocol version `1` describes the current implementation. This document does not define behavior for future protocol versions.

Protocol changes must update `proto/`, regenerate committed Swift and Python bindings, and keep server C++ protobuf generation inside the build directory.

Any change that affects discovery, authentication, channel setup, mouse behavior, keyboard behavior, release behavior, or HID output should update this document and run the relevant checks from [dev.md](dev.md).

At minimum, protocol changes should run protobuf generation, Python devtools compile checks, Debug XCTest, server tests, Release build, and local protobuf smoke verification.
