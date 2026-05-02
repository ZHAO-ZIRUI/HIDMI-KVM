#!/usr/bin/env python3
"""HIDMI protobuf smoke server with per-frame TCP logging."""

from __future__ import annotations

import argparse
import hmac
import secrets
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from google.protobuf import text_format


GENERATED_DIR = Path(__file__).resolve().parent / "generated"
sys.path.insert(0, str(GENERATED_DIR))

import enum_ack_result_pb2 as ack_enum  # noqa: E402
import enum_channel_id_pb2 as channel_enum  # noqa: E402
import enum_interface_type_pb2 as interface_enum  # noqa: E402
import enum_offer_reject_reason_pb2 as reject_enum  # noqa: E402
import msg_tcp_frame_pb2  # noqa: E402
import msg_udp_packet_pb2  # noqa: E402


PROTO = 1
DEFAULT_HOST = "0.0.0.0"
DEFAULT_UDP_PORT = 55536
DEFAULT_TCP_MIN = 45670
DEFAULT_TCP_MAX = 45690
DEFAULT_DISPLAY_NAME = "HIDMI Protobuf Playground"
MAX_FRAME_BYTES = 1_048_576
CHANNELS = {
    channel_enum.CHANNEL_CONTROL: "control",
    channel_enum.CHANNEL_MOUSE: "mouse",
    channel_enum.CHANNEL_KEYBOARD: "keyboard",
}
CHANNEL_LOG_PREFIX = {
    channel_enum.CHANNEL_CONTROL: "TCP1",
    channel_enum.CHANNEL_MOUSE: "TCP2",
    channel_enum.CHANNEL_KEYBOARD: "TCP3",
}


@dataclass
class SessionState:
    session_id: int = 0
    client_id: int = 0
    client_nonce: bytes = b""
    control_port: int = 0
    mouse_port: int = 0
    keyboard_port: int = 0
    active_channels: set[int] = field(default_factory=set)
    listeners: list[socket.socket] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a HIDMI protobuf smoke server.")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Local address to bind.")
    parser.add_argument("--udp-port", "--port", dest="udp_port", type=int, default=DEFAULT_UDP_PORT)
    parser.add_argument("--tcp-min", type=int, default=DEFAULT_TCP_MIN)
    parser.add_argument("--tcp-max", type=int, default=DEFAULT_TCP_MAX)
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME)
    parser.add_argument("--shared-secret", default="")
    parser.add_argument("--no-auth", action="store_true", help="accept offers without validating auth_mac")
    parser.add_argument("--discover-interval-ms", type=float, default=500.0)
    parser.add_argument(
        "--udp-listen-delay-ms",
        type=float,
        default=3000.0,
        help="delay binding UDP 55536 so same-host clients can receive initial Discover packets",
    )
    parser.add_argument(
        "--keyboard-ack-delay-ms",
        type=float,
        default=0.0,
        help="delay TCP3 keyboard ACKs to test client retry/queue behavior",
    )
    return parser.parse_args()


def monotonic_us() -> int:
    return int(time.monotonic() * 1_000_000)


def recv_exact(conn: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            raise EOFError()
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(conn: socket.socket) -> msg_tcp_frame_pb2.TcpFrame:
    length = struct.unpack(">I", recv_exact(conn, 4))[0]
    if length > MAX_FRAME_BYTES:
        raise ValueError(f"frame too large: {length}")
    payload = recv_exact(conn, length)
    frame = msg_tcp_frame_pb2.TcpFrame()
    frame.ParseFromString(payload)
    return frame


def write_frame(conn: socket.socket, frame: msg_tcp_frame_pb2.TcpFrame) -> None:
    payload = frame.SerializeToString()
    conn.sendall(struct.pack(">I", len(payload)) + payload)


def canonical_offer_auth(
    server_id: int,
    boot_id: int,
    challenge_nonce: bytes,
    client_nonce: bytes,
    control_port: int,
    mouse_port: int,
    keyboard_port: int,
    client_unix_ms: int,
) -> bytes:
    return (
        struct.pack(">IQQ", PROTO, server_id, boot_id)
        + challenge_nonce
        + client_nonce
        + struct.pack(">IIIQ", control_port, mouse_port, keyboard_port, client_unix_ms)
    )


def log_tcp_frame(channel_id: int, frame: msg_tcp_frame_pb2.TcpFrame) -> None:
    prefix = CHANNEL_LOG_PREFIX.get(channel_id, f"TCP{channel_id}")
    rendered = text_format.MessageToString(frame, as_one_line=True).strip()
    print(f"[{time.time():.6f}][{prefix}] {rendered}", flush=True)


class HIDMIProtobufPlayground:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.server_id = int.from_bytes(secrets.token_bytes(8), "big") or 1
        self.boot_id = int.from_bytes(secrets.token_bytes(8), "big") or 1
        self.challenge_nonce = secrets.token_bytes(16)
        self.session: SessionState | None = None
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.discover_interval = max(0.1, args.discover_interval_ms / 1000.0)
        self.rejected_ports: set[int] = set()

    def run(self) -> None:
        udp_thread = threading.Thread(target=self._run_udp, name="udp", daemon=True)
        discover_thread = threading.Thread(target=self._broadcast_discover_loop, name="discover", daemon=True)
        udp_thread.start()
        discover_thread.start()
        print(
            f"broadcasting Discover on UDP {self.args.udp_port}, TCP range {self.args.tcp_min}-{self.args.tcp_max}",
            file=sys.stderr,
            flush=True,
        )
        if self.args.udp_listen_delay_ms:
            print(
                f"waiting {self.args.udp_listen_delay_ms}ms before accepting Offer on UDP {self.args.udp_port}",
                file=sys.stderr,
                flush=True,
            )
        try:
            while not self.stop.wait(0.5):
                pass
        except KeyboardInterrupt:
            self.stop.set()
        self._cleanup_session()

    def _run_udp(self) -> None:
        delay = max(0.0, self.args.udp_listen_delay_ms / 1000.0)
        if delay and self.stop.wait(delay):
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind((self.args.host, self.args.udp_port))
        sock.settimeout(0.2)
        print(
            f"offer listener ready UDP {self.args.host}:{self.args.udp_port}",
            file=sys.stderr,
            flush=True,
        )
        while not self.stop.is_set():
            try:
                data, addr = sock.recvfrom(65_535)
            except socket.timeout:
                continue
            except OSError:
                break
            packet = msg_udp_packet_pb2.UdpPacket()
            try:
                packet.ParseFromString(data)
            except Exception as exc:  # noqa: BLE001
                print(f"invalid UDP protobuf from {addr}: {exc}", file=sys.stderr, flush=True)
                continue
            if packet.protocol_version != PROTO or packet.WhichOneof("body") != "offer":
                continue
            self._handle_offer(sock, addr, packet.offer)

    def _broadcast_discover_loop(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        destinations = [
            ("255.255.255.255", self.args.udp_port),
            ("127.255.255.255", self.args.udp_port),
            ("127.0.0.1", self.args.udp_port),
        ]
        if self.args.host not in {"0.0.0.0", "127.0.0.1"}:
            destinations.append((self.args.host, self.args.udp_port))
        while not self.stop.wait(self.discover_interval):
            packet = self._discover_packet()
            payload = packet.SerializeToString()
            for destination in destinations:
                try:
                    sock.sendto(payload, destination)
                except OSError:
                    pass

    def _discover_packet(self) -> msg_udp_packet_pb2.UdpPacket:
        with self.lock:
            busy = self.session is not None
            rejected = sorted(self.rejected_ports)
        packet = msg_udp_packet_pb2.UdpPacket()
        packet.protocol_version = PROTO
        packet.discover.server_id = self.server_id
        packet.discover.boot_id = self.boot_id
        packet.discover.server_name = self.args.display_name
        packet.discover.interface_type = interface_enum.IFACE_ETHERNET
        packet.discover.tcp_accept_min = self.args.tcp_min
        packet.discover.tcp_accept_max = self.args.tcp_max
        packet.discover.tcp_rejected.extend(rejected)
        packet.discover.challenge_nonce = self.challenge_nonce
        packet.discover.is_busy = busy
        return packet

    def _handle_offer(self, sock: socket.socket, addr: tuple[str, int], offer: object) -> None:
        reject = self._validate_offer(offer)
        if reject != reject_enum.OFFER_REJECT_NONE:
            self._send_offer_callback(sock, addr, False, reject, 0)
            return

        session_id = int.from_bytes(secrets.token_bytes(8), "big") or 1
        ports = [offer.control_tcp_port, offer.mouse_tcp_port, offer.keyboard_tcp_port]
        listeners: list[socket.socket] = []
        try:
            for port in ports:
                listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                listener.bind((self.args.host, port))
                listener.listen(1)
                listener.settimeout(0.2)
                listeners.append(listener)
        except OSError as exc:
            print(f"tcp bind failed: {exc}", file=sys.stderr, flush=True)
            for listener in listeners:
                listener.close()
            self._send_offer_callback(sock, addr, False, reject_enum.TCP_OCCUPIED, 0)
            return

        state = SessionState(
            session_id=session_id,
            client_id=offer.client_id,
            client_nonce=bytes(offer.client_nonce),
            control_port=offer.control_tcp_port,
            mouse_port=offer.mouse_tcp_port,
            keyboard_port=offer.keyboard_tcp_port,
            listeners=listeners,
        )
        with self.lock:
            self._cleanup_session_locked()
            self.session = state
        for channel_id, listener in zip(CHANNELS.keys(), listeners, strict=True):
            thread = threading.Thread(target=self._accept_channel, args=(state, channel_id, listener), daemon=True)
            thread.start()

        self._send_offer_callback(sock, addr, True, reject_enum.OFFER_REJECT_NONE, session_id)
        self.challenge_nonce = secrets.token_bytes(16)

    def _validate_offer(self, offer: object) -> int:
        with self.lock:
            if self.session is not None:
                return reject_enum.SERVER_BUSY
        if offer.server_id != self.server_id or offer.boot_id != self.boot_id:
            return reject_enum.SERVER_ID_MISMATCH
        ports = [offer.control_tcp_port, offer.mouse_tcp_port, offer.keyboard_tcp_port]
        if len(set(ports)) != 3:
            return reject_enum.INVALID_PORT
        if any(port < self.args.tcp_min or port > self.args.tcp_max for port in ports):
            return reject_enum.INVALID_PORT
        if any(port in self.rejected_ports for port in ports):
            return reject_enum.INVALID_PORT
        if not self.args.no_auth:
            payload = canonical_offer_auth(
                self.server_id,
                self.boot_id,
                self.challenge_nonce,
                bytes(offer.client_nonce),
                offer.control_tcp_port,
                offer.mouse_tcp_port,
                offer.keyboard_tcp_port,
                offer.client_unix_ms,
            )
            expected = hmac.digest(self.args.shared_secret.encode("utf-8"), payload, "sha256")
            if not hmac.compare_digest(expected, bytes(offer.auth_mac)):
                return reject_enum.TOKEN_AUTH_FAILED
        return reject_enum.OFFER_REJECT_NONE

    def _send_offer_callback(
        self,
        sock: socket.socket,
        addr: tuple[str, int],
        accept: bool,
        reason: int,
        session_id: int,
    ) -> None:
        packet = msg_udp_packet_pb2.UdpPacket()
        packet.protocol_version = PROTO
        packet.offer_callback.server_id = self.server_id
        packet.offer_callback.boot_id = self.boot_id
        packet.offer_callback.accept = accept
        packet.offer_callback.reject_reason = reason
        packet.offer_callback.session_id = session_id
        packet.offer_callback.connect_deadline_ms = 3000
        sock.sendto(packet.SerializeToString(), addr)

    def _accept_channel(self, state: SessionState, channel_id: int, listener: socket.socket) -> None:
        try:
            while not self.stop.is_set():
                with self.lock:
                    if self.session is not state:
                        return
                try:
                    conn, addr = listener.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
        except OSError:
            return
        thread = threading.Thread(target=self._handle_channel, args=(state, channel_id, conn, addr), daemon=True)
        thread.start()

    def _handle_channel(
        self,
        state: SessionState,
        channel_id: int,
        conn: socket.socket,
        addr: tuple[str, int],
    ) -> None:
        del addr
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.settimeout(3.0)
        try:
            open_frame = read_frame(conn)
            log_tcp_frame(channel_id, open_frame)
            valid_open = (
                open_frame.session_id == state.session_id
                and open_frame.channel_id == channel_id
                and open_frame.WhichOneof("body") == "channel_open"
                and open_frame.channel_open.expected_channel_id == channel_id
            )
            ready = msg_tcp_frame_pb2.TcpFrame()
            ready.session_id = state.session_id
            ready.channel_id = channel_id
            ready.seq = open_frame.seq
            ready.monotonic_us = monotonic_us()
            ready.channel_ready.channel_id = channel_id
            ready.channel_ready.accepted = valid_open
            ready.channel_ready.message = "ready" if valid_open else "channel mismatch"
            write_frame(conn, ready)
            if not valid_open:
                return
            conn.settimeout(None)
            with self.lock:
                state.active_channels.add(channel_id)
            while not self.stop.is_set():
                frame = read_frame(conn)
                log_tcp_frame(channel_id, frame)
                if frame.session_id != state.session_id or frame.channel_id != channel_id:
                    self._send_error(conn, state.session_id, channel_id, frame.seq, "session or channel mismatch")
                    continue
                self._handle_frame(conn, frame)
        except EOFError:
            pass
        except (OSError, ValueError) as exc:
            print(f"tcp channel error: {exc}", file=sys.stderr, flush=True)
        finally:
            try:
                conn.close()
            except OSError:
                pass
            with self.lock:
                if self.session is state:
                    state.active_channels.discard(channel_id)
                    if not state.active_channels:
                        self._cleanup_session_locked()

    def _handle_frame(self, conn: socket.socket, frame: msg_tcp_frame_pb2.TcpFrame) -> None:
        body = frame.WhichOneof("body")
        if body == "heartbeat":
            ack = msg_tcp_frame_pb2.TcpFrame()
            ack.session_id = frame.session_id
            ack.channel_id = channel_enum.CHANNEL_CONTROL
            ack.seq = frame.seq
            ack.monotonic_us = monotonic_us()
            ack.heartbeat_ack.heartbeat_seq = frame.heartbeat.heartbeat_seq
            ack.heartbeat_ack.client_send_mono_us = frame.heartbeat.client_send_mono_us
            ack.heartbeat_ack.server_recv_mono_us = monotonic_us()
            ack.heartbeat_ack.server_send_mono_us = monotonic_us()
            write_frame(conn, ack)
            return
        if body == "release_all":
            return
        if body == "goodbye":
            self._cleanup_session()
            return
        if body == "mouse_state":
            return
        if body == "keyboard_state":
            self._delay_keyboard_ack()
            self._send_ack(conn, frame, ack_enum.ACK_OK)
            return
        if body == "keyboard_special":
            self._delay_keyboard_ack()
            self._send_ack(conn, frame, ack_enum.ACK_OK)
            return
        self._send_error(conn, frame.session_id, frame.channel_id, frame.seq, f"unsupported body: {body}")

    def _send_ack(self, conn: socket.socket, frame: msg_tcp_frame_pb2.TcpFrame, result: int) -> None:
        ack = msg_tcp_frame_pb2.TcpFrame()
        ack.session_id = frame.session_id
        ack.channel_id = frame.channel_id
        ack.seq = frame.seq
        ack.monotonic_us = monotonic_us()
        ack.ack.target_channel_id = frame.channel_id
        ack.ack.target_seq = frame.seq
        ack.ack.result = result
        ack.ack.message = "ok"
        write_frame(conn, ack)

    def _send_error(self, conn: socket.socket, session_id: int, channel_id: int, seq: int, message: str) -> None:
        frame = msg_tcp_frame_pb2.TcpFrame()
        frame.session_id = session_id
        frame.channel_id = channel_id
        frame.seq = seq
        frame.monotonic_us = monotonic_us()
        frame.error.err_id = 1
        frame.error.channel_id = channel_id
        frame.error.related_seq = seq
        frame.error.err_msg = message
        write_frame(conn, frame)

    def _delay_keyboard_ack(self) -> None:
        delay_ms = max(0.0, float(self.args.keyboard_ack_delay_ms))
        if delay_ms:
            time.sleep(delay_ms / 1000.0)

    def _cleanup_session(self) -> None:
        with self.lock:
            self._cleanup_session_locked()

    def _cleanup_session_locked(self) -> None:
        if self.session is None:
            return
        for listener in self.session.listeners:
            try:
                listener.close()
            except OSError:
                pass
        self.session = None


def main() -> int:
    args = parse_args()
    for name in ("udp_port", "tcp_min", "tcp_max"):
        port = getattr(args, name)
        if port < 1 or port > 65_535:
            print(f"error: invalid {name.replace('_', '-')} {port}", file=sys.stderr)
            return 2
    if args.tcp_min > args.tcp_max or args.tcp_max - args.tcp_min + 1 < 3:
        print("error: TCP range must contain at least three ports", file=sys.stderr)
        return 2
    HIDMIProtobufPlayground(args).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
