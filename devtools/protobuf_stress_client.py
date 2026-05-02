#!/usr/bin/env python3
"""Stress client for the HIDMI protobuf smoke server.

The client speaks the current protobuf UDP/TCP protocol against
devtools/protobuf_smoke_server.py:

1. Listen for Discover on UDP 55536.
2. Send Offer with three requested TCP ports.
3. Open control, mouse, and keyboard TCP channels.
4. Generate configurable heartbeat, mouse, and keyboard load.
"""

from __future__ import annotations

import argparse
import hmac
import math
import random
import secrets
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path


GENERATED_DIR = Path(__file__).resolve().parent / "generated"
sys.path.insert(0, str(GENERATED_DIR))

import enum_ack_result_pb2 as ack_enum  # noqa: E402
import enum_channel_id_pb2 as channel_enum  # noqa: E402
import enum_goodbye_reason_pb2 as goodbye_enum  # noqa: E402
import enum_offer_reject_reason_pb2 as reject_enum  # noqa: E402
import msg_tcp_frame_pb2  # noqa: E402
import msg_udp_packet_pb2  # noqa: E402


PROTO = 1
DEFAULT_UDP_PORT = 55536
MAX_FRAME_BYTES = 1_048_576

CHANNEL_NAMES = {
    channel_enum.CHANNEL_CONTROL: "control",
    channel_enum.CHANNEL_MOUSE: "mouse",
    channel_enum.CHANNEL_KEYBOARD: "keyboard",
}


@dataclass(frozen=True)
class DiscoveredServer:
    host: str
    udp_port: int
    server_id: int
    boot_id: int
    server_name: str
    tcp_accept_min: int
    tcp_accept_max: int
    tcp_rejected: set[int]
    challenge_nonce: bytes


@dataclass(frozen=True)
class OfferedSession:
    session_id: int
    control_port: int
    mouse_port: int
    keyboard_port: int
    connect_deadline_ms: int


class StressStats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self._reset_unlocked()

    def _reset_unlocked(self) -> None:
        self.started_at = time.monotonic()
        self.control_sent = 0
        self.mouse_sent = 0
        self.keyboard_sent = 0
        self.control_recv = 0
        self.mouse_recv = 0
        self.keyboard_recv = 0
        self.bytes_sent = 0
        self.bytes_recv = 0
        self.heartbeat_acks = 0
        self.keyboard_acks = 0
        self.ack_rejected = 0
        self.errors = 0
        self.unexpected = 0
        self.send_errors = 0
        self.recv_errors = 0
        self.heartbeat_rtts_us: list[int] = []
        self.keyboard_ack_rtts_us: list[int] = []

    def mark_sent(self, channel_id: int, byte_count: int) -> None:
        with self.lock:
            if channel_id == channel_enum.CHANNEL_CONTROL:
                self.control_sent += 1
            elif channel_id == channel_enum.CHANNEL_MOUSE:
                self.mouse_sent += 1
            elif channel_id == channel_enum.CHANNEL_KEYBOARD:
                self.keyboard_sent += 1
            self.bytes_sent += byte_count

    def mark_received(self, channel_id: int, byte_count: int) -> None:
        with self.lock:
            if channel_id == channel_enum.CHANNEL_CONTROL:
                self.control_recv += 1
            elif channel_id == channel_enum.CHANNEL_MOUSE:
                self.mouse_recv += 1
            elif channel_id == channel_enum.CHANNEL_KEYBOARD:
                self.keyboard_recv += 1
            self.bytes_recv += byte_count

    def mark_heartbeat_ack(self, rtt_us: int) -> None:
        with self.lock:
            self.heartbeat_acks += 1
            self.heartbeat_rtts_us.append(max(0, rtt_us))

    def mark_keyboard_ack(self, rtt_us: int, result: int) -> None:
        with self.lock:
            self.keyboard_acks += 1
            if result not in {ack_enum.ACK_OK, ack_enum.ACK_DUPLICATED}:
                self.ack_rejected += 1
            self.keyboard_ack_rtts_us.append(max(0, rtt_us))

    def mark_error(self) -> None:
        with self.lock:
            self.errors += 1

    def mark_unexpected(self) -> None:
        with self.lock:
            self.unexpected += 1

    def mark_send_error(self) -> None:
        with self.lock:
            self.send_errors += 1

    def mark_recv_error(self) -> None:
        with self.lock:
            self.recv_errors += 1

    def snapshot(self) -> dict[str, object]:
        with self.lock:
            return {
                "elapsed": time.monotonic() - self.started_at,
                "control_sent": self.control_sent,
                "mouse_sent": self.mouse_sent,
                "keyboard_sent": self.keyboard_sent,
                "control_recv": self.control_recv,
                "mouse_recv": self.mouse_recv,
                "keyboard_recv": self.keyboard_recv,
                "bytes_sent": self.bytes_sent,
                "bytes_recv": self.bytes_recv,
                "heartbeat_acks": self.heartbeat_acks,
                "keyboard_acks": self.keyboard_acks,
                "ack_rejected": self.ack_rejected,
                "errors": self.errors,
                "unexpected": self.unexpected,
                "send_errors": self.send_errors,
                "recv_errors": self.recv_errors,
                "heartbeat_rtts_us": list(self.heartbeat_rtts_us),
                "keyboard_ack_rtts_us": list(self.keyboard_ack_rtts_us),
            }


class TcpChannel:
    def __init__(
        self,
        host: str,
        port: int,
        channel_id: int,
        session_id: int,
        timeout: float,
        stats: StressStats,
    ) -> None:
        self.host = host
        self.port = port
        self.channel_id = channel_id
        self.session_id = session_id
        self.timeout = timeout
        self.stats = stats
        self.sock: socket.socket | None = None
        self.write_lock = threading.Lock()

    def open(self) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(self.timeout)
        self.sock = sock

        frame = base_frame(self.session_id, self.channel_id, 1, ack_required=True)
        frame.channel_open.expected_channel_id = self.channel_id
        self.send(frame)
        ready = self.read()
        if (
            ready.WhichOneof("body") != "channel_ready"
            or ready.channel_ready.channel_id != self.channel_id
            or not ready.channel_ready.accepted
        ):
            message = ready.channel_ready.message if ready.WhichOneof("body") == "channel_ready" else "bad response"
            raise RuntimeError(f"{CHANNEL_NAMES[self.channel_id]} channel rejected: {message}")
        sock.settimeout(0.2)

    def send(self, frame: msg_tcp_frame_pb2.TcpFrame, track: bool = True) -> None:
        payload = frame.SerializeToString()
        data = struct.pack(">I", len(payload)) + payload
        sock = self._socket()
        with self.write_lock:
            sock.sendall(data)
        if track:
            self.stats.mark_sent(self.channel_id, len(data))

    def read(self) -> msg_tcp_frame_pb2.TcpFrame:
        sock = self._socket()
        length_bytes = recv_exact(sock, 4)
        length = struct.unpack(">I", length_bytes)[0]
        if length > MAX_FRAME_BYTES:
            raise ValueError(f"frame too large: {length}")
        payload = recv_exact(sock, length)
        frame = msg_tcp_frame_pb2.TcpFrame()
        frame.ParseFromString(payload)
        self.stats.mark_received(frame.channel_id, 4 + length)
        return frame

    def close(self) -> None:
        if self.sock is None:
            return
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.sock = None

    def _socket(self) -> socket.socket:
        if self.sock is None:
            raise RuntimeError(f"{CHANNEL_NAMES[self.channel_id]} channel is not open")
        return self.sock


class HIDMIProtobufStressClient:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.client_id = int.from_bytes(secrets.token_bytes(8), "big") or 1
        self.client_nonce = secrets.token_bytes(16)
        self.stats = StressStats()
        self.stop_senders = threading.Event()
        self.stop_all = threading.Event()
        self.pending_lock = threading.Lock()
        self.pending_heartbeats: dict[int, int] = {}
        self.pending_keyboard: dict[int, int] = {}
        self.channels: dict[int, TcpChannel] = {}
        self.reader_threads: list[threading.Thread] = []
        self.sender_threads: list[threading.Thread] = []

    def run(self) -> int:
        server = self.discover()
        session = self.offer(server)
        connect_host = self.args.connect_host or server.host
        self.connect_channels(connect_host, session)
        self.stats.reset()

        print(
            f"connected session={session.session_id} host={connect_host} "
            f"ports={session.control_port}/{session.mouse_port}/{session.keyboard_port}",
            file=sys.stderr,
            flush=True,
        )

        self.start_readers()
        self.start_senders()
        self.run_until_complete()
        self.stop_senders.set()
        for thread in self.sender_threads:
            thread.join(timeout=1.0)

        self.drain_acks(self.args.ack_drain_sec)
        self.close_session()
        for thread in self.reader_threads:
            thread.join(timeout=1.0)

        self.print_summary()
        return 1 if self.has_failures() else 0

    def discover(self) -> DiscoveredServer:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind((self.args.bind_host, self.args.udp_port))
            sock.settimeout(0.2)

            deadline = time.monotonic() + self.args.discover_timeout_sec
            while time.monotonic() < deadline:
                try:
                    data, addr = sock.recvfrom(65_535)
                except socket.timeout:
                    continue

                packet = msg_udp_packet_pb2.UdpPacket()
                try:
                    packet.ParseFromString(data)
                except Exception:  # noqa: BLE001
                    continue
                if packet.protocol_version != PROTO or packet.WhichOneof("body") != "discover":
                    continue
                discover = packet.discover
                if discover.is_busy:
                    continue
                if self.args.server_host and addr[0] != self.args.server_host:
                    continue
                if self.args.server_name and self.args.server_name not in discover.server_name:
                    continue
                lower = int(discover.tcp_accept_min)
                upper = int(discover.tcp_accept_max)
                if lower < 1 or upper > 65_535 or lower > upper:
                    continue
                server = DiscoveredServer(
                    host=addr[0],
                    udp_port=self.args.udp_port,
                    server_id=int(discover.server_id),
                    boot_id=int(discover.boot_id),
                    server_name=discover.server_name,
                    tcp_accept_min=lower,
                    tcp_accept_max=upper,
                    tcp_rejected=set(int(port) for port in discover.tcp_rejected),
                    challenge_nonce=bytes(discover.challenge_nonce),
                )
                print(
                    f"discovered {server.server_name or server.host} at {server.host}, "
                    f"tcp range {server.tcp_accept_min}-{server.tcp_accept_max}",
                    file=sys.stderr,
                    flush=True,
                )
                return server
        finally:
            sock.close()
        raise TimeoutError(f"no Discover received within {self.args.discover_timeout_sec:.1f}s")

    def offer(self, server: DiscoveredServer) -> OfferedSession:
        deadline = time.monotonic() + self.args.offer_timeout_sec
        last_reject = "timeout"

        while time.monotonic() < deadline:
            control_port, mouse_port, keyboard_port = choose_ports(server)
            unix_ms = int(time.time() * 1000)
            packet = msg_udp_packet_pb2.UdpPacket()
            packet.protocol_version = PROTO
            packet.offer.server_id = server.server_id
            packet.offer.boot_id = server.boot_id
            packet.offer.client_id = self.client_id
            packet.offer.client_nonce = self.client_nonce
            packet.offer.client_unix_ms = unix_ms
            packet.offer.control_tcp_port = control_port
            packet.offer.mouse_tcp_port = mouse_port
            packet.offer.keyboard_tcp_port = keyboard_port
            packet.offer.auth_mac = canonical_offer_auth(
                self.args.shared_secret,
                server.server_id,
                server.boot_id,
                server.challenge_nonce,
                self.client_nonce,
                control_port,
                mouse_port,
                keyboard_port,
                unix_ms,
            )

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.settimeout(max(0.05, self.args.offer_retry_ms / 1000.0))
                sock.sendto(packet.SerializeToString(), (server.host, server.udp_port))
                while time.monotonic() < deadline:
                    try:
                        data, _ = sock.recvfrom(65_535)
                    except socket.timeout:
                        break
                    callback_packet = msg_udp_packet_pb2.UdpPacket()
                    try:
                        callback_packet.ParseFromString(data)
                    except Exception:  # noqa: BLE001
                        continue
                    if (
                        callback_packet.protocol_version != PROTO
                        or callback_packet.WhichOneof("body") != "offer_callback"
                    ):
                        continue
                    callback = callback_packet.offer_callback
                    if callback.server_id != server.server_id or callback.boot_id != server.boot_id:
                        continue
                    if callback.accept:
                        return OfferedSession(
                            session_id=int(callback.session_id),
                            control_port=control_port,
                            mouse_port=mouse_port,
                            keyboard_port=keyboard_port,
                            connect_deadline_ms=int(callback.connect_deadline_ms),
                        )

                    last_reject = enum_value_name(
                        reject_enum.DESCRIPTOR.enum_types_by_name["OfferRejectReason"],
                        int(callback.reject_reason),
                    )
                    print(f"offer rejected: {last_reject}", file=sys.stderr, flush=True)
                    if callback.reject_reason not in {reject_enum.TCP_OCCUPIED, reject_enum.INVALID_PORT}:
                        raise RuntimeError(f"Offer rejected: {last_reject}")
                    break
            finally:
                sock.close()

        raise TimeoutError(f"Offer was not accepted before timeout, last result: {last_reject}")

    def connect_channels(self, host: str, session: OfferedSession) -> None:
        timeout = max(self.args.connect_timeout_sec, session.connect_deadline_ms / 1000.0)
        definitions = [
            (channel_enum.CHANNEL_CONTROL, session.control_port),
            (channel_enum.CHANNEL_MOUSE, session.mouse_port),
            (channel_enum.CHANNEL_KEYBOARD, session.keyboard_port),
        ]
        try:
            for channel_id, port in definitions:
                channel = TcpChannel(host, port, channel_id, session.session_id, timeout, self.stats)
                channel.open()
                self.channels[channel_id] = channel
        except Exception:
            for channel in self.channels.values():
                channel.close()
            raise

    def start_readers(self) -> None:
        for channel in self.channels.values():
            thread = threading.Thread(
                target=self.reader_loop,
                args=(channel,),
                name=f"reader-{CHANNEL_NAMES[channel.channel_id]}",
                daemon=True,
            )
            thread.start()
            self.reader_threads.append(thread)

    def start_senders(self) -> None:
        senders = [
            (self.args.heartbeat_hz, self.control_loop, "send-control"),
            (self.args.mouse_hz, self.mouse_loop, "send-mouse"),
            (self.args.keyboard_hz, self.keyboard_loop, "send-keyboard"),
        ]
        for rate, target, name in senders:
            if rate <= 0:
                continue
            thread = threading.Thread(target=target, name=name, daemon=True)
            thread.start()
            self.sender_threads.append(thread)

    def run_until_complete(self) -> None:
        if self.args.duration_sec <= 0:
            end_at = math.inf
        else:
            end_at = time.monotonic() + self.args.duration_sec

        next_report = time.monotonic() + self.args.report_interval_sec
        try:
            while time.monotonic() < end_at and not self.stop_all.is_set():
                now = time.monotonic()
                if self.args.report_interval_sec > 0 and now >= next_report:
                    self.print_progress()
                    next_report = now + self.args.report_interval_sec
                time.sleep(0.05)
        except KeyboardInterrupt:
            print("interrupted; stopping senders", file=sys.stderr, flush=True)

    def control_loop(self) -> None:
        channel = self.channels[channel_enum.CHANNEL_CONTROL]
        seq = 0
        interval = 1.0 / self.args.heartbeat_hz
        next_send = time.monotonic()
        while not self.stop_senders.is_set() and not self.stop_all.is_set():
            seq = next_u32(seq)
            sent_at = monotonic_us()
            frame = base_frame(channel.session_id, channel.channel_id, seq, ack_required=True)
            frame.heartbeat.heartbeat_seq = seq
            frame.heartbeat.client_send_mono_us = sent_at
            with self.pending_lock:
                self.pending_heartbeats[seq] = sent_at
            self.send_or_stop(channel, frame)
            next_send = sleep_until_next(next_send, interval, self.stop_senders)

    def mouse_loop(self) -> None:
        channel = self.channels[channel_enum.CHANNEL_MOUSE]
        seq = 0
        index = 0
        buttons = 0
        interval = 1.0 / self.args.mouse_hz
        next_send = time.monotonic()
        while not self.stop_senders.is_set() and not self.stop_all.is_set():
            seq = next_u32(seq)
            index += 1
            wheel_y = 0
            wheel_x = 0
            if self.args.mouse_edge_every > 0 and index % self.args.mouse_edge_every == 0:
                buttons = 0 if buttons else 1
            if self.args.wheel_every > 0 and index % self.args.wheel_every == 0:
                wheel_y = 1 if (index // self.args.wheel_every) % 2 else -1
            frame = base_frame(channel.session_id, channel.channel_id, seq, ack_required=False)
            frame.mouse_state.abs_x = (index * 997) % 65_536
            frame.mouse_state.abs_y = (index * 1531) % 65_536
            frame.mouse_state.buttons_mask = buttons
            frame.mouse_state.wheel_delta_y = wheel_y
            frame.mouse_state.wheel_delta_x = wheel_x
            frame.mouse_state.has_reliable_edge = (
                (self.args.mouse_edge_every > 0 and index % self.args.mouse_edge_every == 0)
                or wheel_y != 0
                or wheel_x != 0
            )
            frame.mouse_state.sample_mono_us = monotonic_us()
            self.send_or_stop(channel, frame)
            next_send = sleep_until_next(next_send, interval, self.stop_senders)

    def keyboard_loop(self) -> None:
        channel = self.channels[channel_enum.CHANNEL_KEYBOARD]
        seq = 0
        interval = 1.0 / self.args.keyboard_hz
        next_send = time.monotonic()
        while not self.stop_senders.is_set() and not self.stop_all.is_set():
            if self.args.keyboard_inflight > 0:
                while not self.stop_senders.is_set():
                    with self.pending_lock:
                        pending_count = len(self.pending_keyboard)
                    if pending_count < self.args.keyboard_inflight:
                        break
                    time.sleep(0.001)

            seq = next_u32(seq)
            sent_at = monotonic_us()
            frame = base_frame(channel.session_id, channel.channel_id, seq, ack_required=True)
            if seq % 2:
                frame.keyboard_state.pressed_usage_ids.append(self.args.keyboard_usage)
            frame.keyboard_state.modifier_mask = self.args.keyboard_modifier_mask & 0xFF
            with self.pending_lock:
                self.pending_keyboard[seq] = sent_at
            self.send_or_stop(channel, frame)
            next_send = sleep_until_next(next_send, interval, self.stop_senders)

    def reader_loop(self, channel: TcpChannel) -> None:
        while not self.stop_all.is_set():
            try:
                frame = channel.read()
            except socket.timeout:
                continue
            except OSError:
                if not self.stop_all.is_set():
                    self.stats.mark_recv_error()
                return
            except Exception as exc:  # noqa: BLE001
                if not self.stop_all.is_set():
                    self.stats.mark_recv_error()
                    print(
                        f"{CHANNEL_NAMES[channel.channel_id]} read error: {exc}",
                        file=sys.stderr,
                        flush=True,
                    )
                return

            if frame.session_id != channel.session_id:
                self.stats.mark_error()
                continue
            body = frame.WhichOneof("body")
            if body == "heartbeat_ack":
                with self.pending_lock:
                    sent_at = self.pending_heartbeats.pop(frame.heartbeat_ack.heartbeat_seq, None)
                if sent_at is not None:
                    self.stats.mark_heartbeat_ack(monotonic_us() - sent_at)
                else:
                    self.stats.mark_unexpected()
            elif body == "ack":
                with self.pending_lock:
                    sent_at = self.pending_keyboard.pop(frame.ack.target_seq, None)
                if sent_at is not None and frame.ack.target_channel_id == channel_enum.CHANNEL_KEYBOARD:
                    self.stats.mark_keyboard_ack(monotonic_us() - sent_at, int(frame.ack.result))
                else:
                    self.stats.mark_unexpected()
            elif body == "error":
                self.stats.mark_error()
                print(
                    f"{CHANNEL_NAMES[channel.channel_id]} error seq={frame.error.related_seq}: "
                    f"{frame.error.err_msg}",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                self.stats.mark_unexpected()

    def send_or_stop(self, channel: TcpChannel, frame: msg_tcp_frame_pb2.TcpFrame) -> None:
        try:
            channel.send(frame)
        except OSError as exc:
            self.stats.mark_send_error()
            print(f"{CHANNEL_NAMES[channel.channel_id]} send error: {exc}", file=sys.stderr, flush=True)
            self.stop_all.set()

    def drain_acks(self, seconds: float) -> None:
        deadline = time.monotonic() + max(0.0, seconds)
        while time.monotonic() < deadline:
            with self.pending_lock:
                pending = len(self.pending_heartbeats) + len(self.pending_keyboard)
            if pending == 0:
                return
            time.sleep(0.01)

    def close_session(self) -> None:
        control = self.channels.get(channel_enum.CHANNEL_CONTROL)
        if control is not None:
            try:
                frame = base_frame(control.session_id, control.channel_id, 0, ack_required=False)
                frame.release_all.reason = "stress_client_shutdown"
                control.send(frame, track=False)
            except OSError:
                pass
            try:
                frame = base_frame(control.session_id, control.channel_id, 0, ack_required=False)
                frame.goodbye.reason = goodbye_enum.GOODBYE_CLIENT_EXIT
                frame.goodbye.message = "stress client closing"
                control.send(frame, track=False)
            except OSError:
                pass

        self.stop_all.set()
        for channel in self.channels.values():
            channel.close()

    def print_progress(self) -> None:
        snapshot = self.stats.snapshot()
        with self.pending_lock:
            pending_keyboard = len(self.pending_keyboard)
            pending_heartbeats = len(self.pending_heartbeats)
        elapsed = max(0.001, float(snapshot["elapsed"]))
        total_sent = (
            int(snapshot["control_sent"])
            + int(snapshot["mouse_sent"])
            + int(snapshot["keyboard_sent"])
        )
        print(
            "progress "
            f"elapsed={elapsed:.1f}s "
            f"sent={total_sent} ({total_sent / elapsed:.0f}/s) "
            f"mouse={snapshot['mouse_sent']} "
            f"keyboard={snapshot['keyboard_sent']} "
            f"hb_ack={snapshot['heartbeat_acks']} "
            f"key_ack={snapshot['keyboard_acks']} "
            f"pending_hb={pending_heartbeats} "
            f"pending_key={pending_keyboard} "
            f"errors={snapshot['errors']}",
            file=sys.stderr,
            flush=True,
        )

    def print_summary(self) -> None:
        snapshot = self.stats.snapshot()
        with self.pending_lock:
            pending_heartbeats = len(self.pending_heartbeats)
            pending_keyboard = len(self.pending_keyboard)
        elapsed = max(0.001, float(snapshot["elapsed"]))
        total_sent = (
            int(snapshot["control_sent"])
            + int(snapshot["mouse_sent"])
            + int(snapshot["keyboard_sent"])
        )
        print("=== HIDMI protobuf stress summary ===")
        print(f"elapsed_sec: {elapsed:.3f}")
        print(f"sent_frames: {total_sent} ({total_sent / elapsed:.1f}/s)")
        print(
            "sent_by_channel: "
            f"control={snapshot['control_sent']} "
            f"mouse={snapshot['mouse_sent']} "
            f"keyboard={snapshot['keyboard_sent']}"
        )
        print(
            "received_by_channel: "
            f"control={snapshot['control_recv']} "
            f"mouse={snapshot['mouse_recv']} "
            f"keyboard={snapshot['keyboard_recv']}"
        )
        print(f"bytes_sent: {snapshot['bytes_sent']}")
        print(f"bytes_recv: {snapshot['bytes_recv']}")
        print(f"heartbeat_acks: {snapshot['heartbeat_acks']} pending={pending_heartbeats}")
        print(f"keyboard_acks: {snapshot['keyboard_acks']} pending={pending_keyboard}")
        print(
            "problems: "
            f"errors={snapshot['errors']} "
            f"unexpected={snapshot['unexpected']} "
            f"ack_rejected={snapshot['ack_rejected']} "
            f"send_errors={snapshot['send_errors']} "
            f"recv_errors={snapshot['recv_errors']}"
        )
        print_latency("heartbeat_rtt_ms", snapshot["heartbeat_rtts_us"])
        print_latency("keyboard_ack_rtt_ms", snapshot["keyboard_ack_rtts_us"])

    def has_failures(self) -> bool:
        snapshot = self.stats.snapshot()
        with self.pending_lock:
            pending = len(self.pending_heartbeats) + len(self.pending_keyboard)
        return any(
            int(snapshot[key]) > 0
            for key in ("errors", "ack_rejected", "send_errors", "recv_errors")
        ) or pending > 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a protobuf stress client against devtools/protobuf_smoke_server.py."
    )
    parser.add_argument("--bind-host", default="0.0.0.0", help="Local UDP address used for Discover listening.")
    parser.add_argument("--udp-port", type=int, default=DEFAULT_UDP_PORT)
    parser.add_argument("--server-host", default="", help="Only accept Discover packets from this host.")
    parser.add_argument("--server-name", default="", help="Only accept Discover packets whose name contains this text.")
    parser.add_argument("--connect-host", default="", help="Override TCP connect host after discovery.")
    parser.add_argument("--shared-secret", default="", help="Token used for Offer HMAC.")
    parser.add_argument("--discover-timeout-sec", type=float, default=10.0)
    parser.add_argument("--offer-timeout-sec", type=float, default=10.0)
    parser.add_argument("--offer-retry-ms", type=float, default=200.0)
    parser.add_argument("--connect-timeout-sec", type=float, default=3.0)
    parser.add_argument("--duration-sec", type=float, default=10.0, help="0 means run until interrupted.")
    parser.add_argument("--heartbeat-hz", type=float, default=1.0)
    parser.add_argument("--mouse-hz", type=float, default=1000.0)
    parser.add_argument("--keyboard-hz", type=float, default=100.0)
    parser.add_argument("--keyboard-inflight", type=int, default=256)
    parser.add_argument("--keyboard-usage", type=int, default=4, help="USB HID usage id to toggle; 4 is 'a'.")
    parser.add_argument("--keyboard-modifier-mask", type=int, default=0)
    parser.add_argument(
        "--mouse-edge-every",
        type=int,
        default=500,
        help="Toggle mouse button every N mouse frames; 0 disables edge frames.",
    )
    parser.add_argument("--wheel-every", type=int, default=0, help="Emit wheel delta every N mouse frames.")
    parser.add_argument("--ack-drain-sec", type=float, default=2.0)
    parser.add_argument("--report-interval-sec", type=float, default=1.0)
    return parser.parse_args()


def canonical_offer_auth(
    shared_secret: str,
    server_id: int,
    boot_id: int,
    challenge_nonce: bytes,
    client_nonce: bytes,
    control_port: int,
    mouse_port: int,
    keyboard_port: int,
    client_unix_ms: int,
) -> bytes:
    payload = (
        struct.pack(">IQQ", PROTO, server_id, boot_id)
        + challenge_nonce
        + client_nonce
        + struct.pack(">IIIQ", control_port, mouse_port, keyboard_port, client_unix_ms)
    )
    return hmac.digest(shared_secret.strip().encode("utf-8"), payload, "sha256")


def recv_exact(sock: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise EOFError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def base_frame(session_id: int, channel_id: int, seq: int, ack_required: bool) -> msg_tcp_frame_pb2.TcpFrame:
    frame = msg_tcp_frame_pb2.TcpFrame()
    frame.session_id = session_id
    frame.channel_id = channel_id
    frame.seq = seq
    frame.monotonic_us = monotonic_us()
    frame.ack_required = ack_required
    return frame


def monotonic_us() -> int:
    return int(time.monotonic() * 1_000_000)


def next_u32(value: int) -> int:
    return (value + 1) & 0xFFFF_FFFF or 1


def sleep_until_next(next_send: float, interval: float, stop_event: threading.Event) -> float:
    next_send += interval
    delay = next_send - time.monotonic()
    if delay > 0:
        stop_event.wait(delay)
    elif -delay > max(interval * 10, 0.25):
        next_send = time.monotonic()
    return next_send


def choose_ports(server: DiscoveredServer) -> tuple[int, int, int]:
    candidates = [
        port
        for port in range(server.tcp_accept_min, server.tcp_accept_max + 1)
        if port not in server.tcp_rejected
    ]
    if len(candidates) < 3:
        raise RuntimeError("server advertised fewer than three usable TCP ports")
    return tuple(random.sample(candidates, 3))  # type: ignore[return-value]


def enum_value_name(enum_descriptor: object, value: int) -> str:
    values_by_number = getattr(enum_descriptor, "values_by_number")
    enum_value = values_by_number.get(value)
    if enum_value is None:
        return f"UNKNOWN({value})"
    return str(enum_value.name)


def percentile(samples: list[int], p: float) -> float:
    if not samples:
        return 0.0
    ordered = sorted(samples)
    index = (len(ordered) - 1) * p
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return float(ordered[int(index)])
    lower_weight = upper - index
    upper_weight = index - lower
    return ordered[lower] * lower_weight + ordered[upper] * upper_weight


def print_latency(label: str, samples_obj: object) -> None:
    samples = list(samples_obj)  # type: ignore[arg-type]
    if not samples:
        print(f"{label}: no samples")
        return
    print(
        f"{label}: "
        f"p50={percentile(samples, 0.50) / 1000.0:.3f} "
        f"p95={percentile(samples, 0.95) / 1000.0:.3f} "
        f"p99={percentile(samples, 0.99) / 1000.0:.3f} "
        f"max={max(samples) / 1000.0:.3f}"
    )


def validate_args(args: argparse.Namespace) -> None:
    if not 1 <= args.udp_port <= 65_535:
        raise ValueError("--udp-port must be in 1...65535")
    for name in (
        "discover_timeout_sec",
        "offer_timeout_sec",
        "connect_timeout_sec",
        "offer_retry_ms",
        "ack_drain_sec",
    ):
        value = getattr(args, name)
        if value < 0 or not math.isfinite(value):
            raise ValueError(f"--{name.replace('_', '-')} must be finite and non-negative")
    for name in ("heartbeat_hz", "mouse_hz", "keyboard_hz"):
        value = getattr(args, name)
        if value < 0 or not math.isfinite(value):
            raise ValueError(f"--{name.replace('_', '-')} must be finite and non-negative")
    if args.keyboard_inflight < 0:
        raise ValueError("--keyboard-inflight must be non-negative")
    if not 0 <= args.keyboard_usage <= 255:
        raise ValueError("--keyboard-usage must be in 0...255")
    if args.mouse_edge_every < 0 or args.wheel_every < 0:
        raise ValueError("--mouse-edge-every and --wheel-every must be non-negative")


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        return HIDMIProtobufStressClient(args).run()
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
