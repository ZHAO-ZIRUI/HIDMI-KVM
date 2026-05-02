#include "hidmi.hpp"
#include "hidmi_internal.hpp"
#include "msg_tcp_frame.pb.h"
#include "msg_udp_packet.pb.h"

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;
namespace hidpb = hidmi::kvm::input::v1;

namespace {

void expect(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}

std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

void write_file(const fs::path& path, const std::string& text = "") {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << text;
}

std::string config_text(
    const std::string& token_file = "/etc/hidmi/token",
    bool leds_enabled = true,
    const std::string& primary_led = "/sys/class/leds/primary",
    const std::string& secondary_led = "/sys/class/leds/secondary") {
    return
        "[service]\n"
        "name = \"Test HIDMI\"\n"
        "token_file = \"" + token_file + "\"\n"
        "discovery_udp_port = 55536\n"
        "timeout_offer_ttl_sec = 30\n"
        "timeout_tcp_sec = 15.0\n"
        "\n"
        "[board]\n"
        "hid_keyboard_path = \"/dev/hidg0\"\n"
        "hid_mouse_path = \"/dev/hidg1\"\n"
        "hid_absolute_mouse_path = \"/dev/hidg2\"\n"
        "udc_state_path = \"/sys/class/udc/test/state\"\n"
        "\n"
        "[board.leds]\n"
        "enabled = " + std::string(leds_enabled ? "true" : "false") + "\n"
        "primary = \"" + primary_led + "\"\n"
        "secondary = \"" + secondary_led + "\"\n";
}

std::string table_line(const std::string& text, const std::string& item) {
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.find("| " + item) != std::string::npos) return line;
    }
    return "";
}

void create_led(const fs::path& path, const std::string& brightness = "1\n") {
    write_file(path / "brightness", brightness);
}

int count_open_fds() {
    fs::path root = fs::exists("/proc/self/fd") ? fs::path("/proc/self/fd") : fs::path("/dev/fd");
    int count = 0;
    for (const auto& entry : fs::directory_iterator(root)) {
        (void)entry;
        ++count;
    }
    return count;
}

void test_config() {
    auto cfg = hidmi::parse_server_config(config_text());
    expect(cfg.display_name == "Test HIDMI", "service name mapping failed");
    expect(cfg.udp_port == 55536, "UDP port mapping failed");
    expect(hidmi::kDiscoveryPort == 55536, "default UDP port must match current protocol");
    expect(cfg.token_file == "/etc/hidmi/token", "token_file mapping failed");
    expect(cfg.hid.keyboard_path == "/dev/hidg0", "keyboard path mapping failed");
    expect(cfg.leds.primary_path == "/sys/class/leds/primary", "primary LED mapping failed");
    bool failed = false;
    try {
        hidmi::parse_server_config("[service]\nname=\"x\"\n[board]\n");
    } catch (const std::exception&) {
        failed = true;
    }
    expect(failed, "missing token_file should fail");
}

void test_profile_resolution() {
    fs::path root = fs::temp_directory_path() / ("hidmi-profile-test-" + hidmi::random_b64url(8));
    fs::path conf = root / "server" / "conf";
    fs::create_directories(conf);
    fs::path profile = conf / "sample-board.toml";
    write_file(profile, config_text());
    expect(hidmi::resolve_profile_config("sample-board", root) == fs::absolute(profile), "profile resolution failed");
    fs::remove_all(root);
}

void test_status_json_parsing_helpers() {
    auto message = hidmi::parse_json_object(
        "{\"daemon_running\":true,\"last_client_request_at\":\"2026-05-02T00:00:00Z\",\"last_client_request_at_ms\":42}");
    expect(message["daemon_running"].as_bool(false), "JSON bool parse failed");
    expect(hidmi::internal::message_string(message, "last_client_request_at") == "2026-05-02T00:00:00Z", "JSON string helper failed");
    expect(hidmi::internal::message_int_default(message, "last_client_request_at_ms", 0) == 42, "JSON int helper failed");
    expect(hidmi::internal::message_int_default(message, "missing", 7) == 7, "JSON int fallback failed");
}

void test_protobuf_tcp_frame_length_prefix() {
    hidpb::TcpFrame frame;
    frame.set_session_id(0x0102030405060708ull);
    frame.set_channel_id(hidpb::CHANNEL_KEYBOARD);
    frame.set_seq(42);
    frame.set_ack_required(true);
    auto* state = frame.mutable_keyboard_state();
    state->set_modifier_mask(5);
    state->add_pressed_usage_ids(4);
    state->add_pressed_usage_ids(5);

    std::string payload = frame.SerializeAsString();
    std::string wire;
    hidmi::internal::append_be32(wire, static_cast<std::uint32_t>(payload.size()));
    wire += payload;

    std::uint32_t length =
        (static_cast<unsigned char>(wire[0]) << 24) |
        (static_cast<unsigned char>(wire[1]) << 16) |
        (static_cast<unsigned char>(wire[2]) << 8) |
        static_cast<unsigned char>(wire[3]);
    expect(length == payload.size(), "protobuf frame length prefix must be uint32 big-endian");

    hidpb::TcpFrame parsed;
    expect(parsed.ParseFromString(wire.substr(4)), "protobuf TCP frame parse failed");
    expect(parsed.session_id() == frame.session_id(), "protobuf TCP frame session mismatch");
    expect(parsed.channel_id() == hidpb::CHANNEL_KEYBOARD, "protobuf TCP frame channel mismatch");
    expect(parsed.keyboard_state().modifier_mask() == 5, "protobuf keyboard state modifier mismatch");
    expect(parsed.keyboard_state().pressed_usage_ids_size() == 2, "protobuf keyboard state key count mismatch");
}

void test_protobuf_udp_discover_and_offer_helpers() {
    hidpb::UdpPacket packet;
    packet.set_protocol_version(hidmi::kProtoVersion);
    auto* discover = packet.mutable_discover();
    discover->set_server_id(123);
    discover->set_boot_id(456);
    discover->set_server_name("Test HIDMI");
    discover->set_interface_type(hidpb::IFACE_ETHERNET);
    discover->set_tcp_accept_min(hidmi::kMinTcpPort);
    discover->set_tcp_accept_max(hidmi::kMinTcpPort + 2);
    discover->set_challenge_nonce("0123456789abcdef");
    discover->set_hid_status(hidpb::HID_STATUS_ABSOLUTE_DEGRADED);
    discover->set_hid_available(true);
    discover->set_absolute_pointer_available(false);
    discover->set_relative_pointer_available(true);
    discover->add_capabilities("keyboard");
    discover->add_capabilities("mouse");
    discover->add_capabilities("relative_pointer");

    hidpb::UdpPacket parsed;
    expect(parsed.ParseFromString(packet.SerializeAsString()), "UDP protobuf parse failed");
    expect(parsed.protocol_version() == hidmi::kProtoVersion, "UDP protocol version mismatch");
    expect(parsed.body_case() == hidpb::UdpPacket::kDiscover, "UDP packet should carry Discover");
    expect(parsed.discover().tcp_accept_min() == hidmi::kMinTcpPort, "Discover TCP minimum mismatch");
    expect(parsed.discover().hid_status() == hidpb::HID_STATUS_ABSOLUTE_DEGRADED, "Discover HID status mismatch");
    expect(parsed.discover().hid_available(), "Discover HID availability mismatch");
    expect(!parsed.discover().absolute_pointer_available(), "Discover absolute availability mismatch");
    expect(parsed.discover().relative_pointer_available(), "Discover relative availability mismatch");
    expect(parsed.discover().capabilities_size() == 3, "Discover capability count mismatch");

    hidpb::MouseState mouse;
    mouse.set_abs_x(65000);
    mouse.set_abs_y(64000);
    mouse.set_rel_dx(-12);
    mouse.set_rel_dy(9);
    hidpb::MouseState parsed_mouse;
    expect(parsed_mouse.ParseFromString(mouse.SerializeAsString()), "MouseState protobuf parse failed");
    expect(parsed_mouse.abs_x() == 65000, "MouseState abs_x mismatch");
    expect(parsed_mouse.rel_dx() == -12, "MouseState rel_dx mismatch");
    expect(parsed_mouse.rel_dy() == 9, "MouseState rel_dy mismatch");

    expect(hidpb::HID_UNAVAILABLE == static_cast<hidpb::OfferRejectReason>(8), "HID_UNAVAILABLE enum value mismatch");
    expect(hidpb::AUTH_RATE_LIMITED == static_cast<hidpb::OfferRejectReason>(9), "AUTH_RATE_LIMITED enum value mismatch");

    expect(hidmi::internal::valid_offer_tcp_ports(hidmi::kMinTcpPort, hidmi::kMinTcpPort + 1, hidmi::kMinTcpPort + 2), "valid Offer TCP ports rejected");
    expect(!hidmi::internal::valid_offer_tcp_ports(hidmi::kMinTcpPort, hidmi::kMinTcpPort, hidmi::kMinTcpPort + 1), "duplicate Offer TCP ports accepted");
    expect(!hidmi::internal::valid_offer_tcp_ports(9999, hidmi::kMinTcpPort, hidmi::kMinTcpPort + 1), "out-of-range Offer TCP port accepted");
}

void test_protobuf_offer_hmac_and_absolute_scaling() {
    std::string challenge;
    for (unsigned value : {0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99}) {
        challenge.push_back(static_cast<char>(value));
    }
    std::string client_nonce;
    for (unsigned value : {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}) {
        client_nonce.push_back(static_cast<char>(value));
    }
    auto payload = hidmi::internal::offer_auth_payload(
        0x0102030405060708ull,
        0x1112131415161718ull,
        challenge,
        client_nonce,
        10000,
        10001,
        10002,
        0x0102030405060708ull);
    expect(payload.size() == 72, "Offer auth payload length mismatch");
    expect(
        hidmi::internal::hex_bytes(std::vector<std::uint8_t>(payload.begin(), payload.end())) ==
            "0000000101020304050607081112131415161718aabbccddeeff0011223344556677889900112233445566778899aabbccddeeff0000271000002711000027120102030405060708",
        "Offer auth canonical bytes mismatch");
    expect(
        hidmi::internal::hex_bytes(hidmi::internal::hmac_sha256("secret", payload)) ==
            "de58d49dcaa6f17f0d1d58a844861cdb7ef5fd18d58a8ecf96ec0d4b21d8bbd9",
        "Offer HMAC mismatch");

    expect(hidmi::internal::protocol_absolute_to_hid(0) == 0, "absolute coordinate 0 should map to HID 0");
    expect(hidmi::internal::protocol_absolute_to_hid(65535) == 32767, "absolute coordinate 65535 should map to HID 32767");
    expect(hidmi::internal::protocol_absolute_to_hid(32768) == 16384, "absolute midpoint should map to HID midpoint");
}

void test_tcp_error_message_normalization() {
    auto unavailable = hidmi::internal::normalize_tcp_error_message("HID writer is not available; retrying");
    expect(unavailable.rfind("HID_FAILURE:", 0) == 0, "HID writer unavailable should be prefixed");
    auto timeout = hidmi::internal::normalize_tcp_error_message("HID write timed out");
    expect(timeout.rfind("HID_FAILURE:", 0) == 0, "HID write timeout should be prefixed");
    auto endpoint = hidmi::internal::normalize_tcp_error_message("USB gadget endpoint is unavailable");
    expect(endpoint.rfind("HID_FAILURE:", 0) == 0, "USB gadget endpoint failure should be prefixed");
    auto already_prefixed = hidmi::internal::normalize_tcp_error_message("HID_FAILURE: failed to open /dev/hidg0");
    expect(already_prefixed == "HID_FAILURE: failed to open /dev/hidg0", "HID prefix should not be duplicated");
    auto protocol = hidmi::internal::normalize_tcp_error_message("frame channel/session mismatch");
    expect(protocol == "frame channel/session mismatch", "protocol errors should not be HID-prefixed");
    expect(!hidmi::internal::is_hid_error_message("unsupported keyboard frame"), "protocol text should not be HID classified");
    expect(!hidmi::internal::is_hid_error_message("Broken pipe"), "ACK socket failure should not be HID classified");
    expect(hidmi::internal::normalize_tcp_error_message("socket write returned zero") == "socket write returned zero", "TCP write failure should remain network classified");
}

void test_tcp_business_frames_require_active_session() {
    expect(
        hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_MOUSE, hidpb::TcpFrame::kMouseState),
        "mouse state should require an active three-channel session");
    expect(
        hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_KEYBOARD, hidpb::TcpFrame::kKeyboardState),
        "keyboard state should require an active three-channel session");
    expect(
        hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_KEYBOARD, hidpb::TcpFrame::kKeyboardSpecial),
        "keyboard special should require an active three-channel session");
    expect(
        hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_CONTROL, hidpb::TcpFrame::kReleaseAll),
        "release-all should not write HID before activation");
    expect(
        !hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_CONTROL, hidpb::TcpFrame::kHeartbeat),
        "heartbeat should be allowed before activation");
    expect(
        !hidmi::internal::tcp_frame_body_requires_active_session(hidpb::CHANNEL_CONTROL, hidpb::TcpFrame::kGoodbye),
        "goodbye should be allowed to clean up before activation");
}

void test_hid_reports() {
    fs::path root = fs::temp_directory_path() / ("hidmi-test-" + hidmi::random_b64url(8));
    fs::create_directories(root);
    fs::path keyboard = root / "kbd";
    fs::path mouse = root / "mouse";
    fs::path absolute = root / "abs";
    write_file(keyboard);
    write_file(mouse);
    write_file(absolute);
    {
        hidmi::HidWriter writer(keyboard.string(), mouse.string(), absolute.string());
        writer.open();
        writer.write_keyboard_report(0, {4});
        writer.write_mouse_report(1, -1, 20, -2);
        writer.write_absolute_mouse_report(1, 32767, 12345);
        writer.release_all();
        writer.close();
    }
    expect(read_file(keyboard).substr(0, 8) == std::string("\x00\x00\x04\x00\x00\x00\x00\x00", 8), "keyboard report mismatch");
    expect(read_file(mouse).substr(0, 4) == std::string("\x01\xff\x14\xfe", 4), "mouse report mismatch");
    expect(read_file(absolute).substr(0, 5) == std::string("\x01\xff\x7f\x39\x30", 5), "absolute report mismatch");
    fs::remove_all(root);
}

void test_hid_writer_allows_missing_absolute_mouse() {
    fs::path root = fs::temp_directory_path() / ("hidmi-absolute-missing-test-" + hidmi::random_b64url(8));
    fs::create_directories(root);
    fs::path keyboard = root / "kbd";
    fs::path mouse = root / "mouse";
    fs::path absolute = root / "missing-abs";
    write_file(keyboard);
    write_file(mouse);
    {
        hidmi::HidWriter writer(keyboard.string(), mouse.string(), absolute.string());
        writer.open();
        expect(writer.mandatory_available(), "mandatory HID devices should be available without absolute mouse");
        expect(!writer.absolute_mouse_available(), "missing absolute mouse should be degraded");
        expect(writer.absolute_mouse_degraded(), "missing absolute mouse should report degraded state");
        writer.write_pointer_report(1, 300, 400, 7, -5, 3, true);
        expect(read_file(mouse).substr(0, 4) == std::string("\x01\x07\xfb\x03", 4), "relative fallback pointer report mismatch");
        writer.close();
    }
    fs::remove_all(root);
}

void test_hid_writer_reopens_absolute_mouse_after_degraded_start() {
    fs::path root = fs::temp_directory_path() / ("hidmi-absolute-reopen-test-" + hidmi::random_b64url(8));
    fs::create_directories(root);
    fs::path keyboard = root / "kbd";
    fs::path mouse = root / "mouse";
    fs::path absolute = root / "abs";
    write_file(keyboard);
    write_file(mouse);
    {
        hidmi::HidWriter writer(keyboard.string(), mouse.string(), absolute.string());
        writer.open();
        expect(!writer.absolute_mouse_available(), "absolute mouse should start degraded when path is absent");
        write_file(absolute);
        expect(writer.try_reopen_absolute(true), "absolute mouse should reopen after the path appears");
        writer.write_pointer_report(2, 300, 400, 9, 9, 0, false);
        expect(read_file(absolute).substr(0, 5) == std::string("\x02\x2c\x01\x90\x01", 5), "reopened absolute pointer report mismatch");
        writer.close();
    }
    fs::remove_all(root);
}

void test_hid_writer_failed_open_does_not_leak_fd() {
    fs::path root = fs::temp_directory_path() / ("hidmi-fd-leak-test-" + hidmi::random_b64url(8));
    fs::create_directories(root);
    fs::path keyboard = root / "kbd";
    fs::path missing_mouse = root / "missing-mouse";
    fs::path absolute = root / "abs";
    write_file(keyboard);
    write_file(absolute);
    int before = count_open_fds();
    for (int i = 0; i < 20; ++i) {
        hidmi::HidWriter writer(keyboard.string(), missing_mouse.string(), absolute.string());
        bool failed = false;
        try {
            writer.open();
        } catch (const std::exception&) {
            failed = true;
        }
        expect(failed, "HID open should fail when mandatory relative mouse is missing");
        expect(!writer.keyboard_available(), "failed HID open should close the keyboard fd");
        expect(!writer.relative_mouse_available(), "failed HID open should not leave relative mouse open");
        expect(!writer.absolute_mouse_available(), "failed HID open should not leave absolute mouse open");
    }
    int after = count_open_fds();
    expect(after <= before + 1, "repeated failed HID opens should not leak file descriptors");
    fs::remove_all(root);
}

void test_units() {
    hidmi::InstallPaths paths;
    auto service = hidmi::render_hidmi_service(paths);
    auto gadget = hidmi::render_gadget_service(paths);
    expect(service.find("ExecStart=/usr/local/bin/hidmi daemon --config /etc/hidmi/current/conf/installed.toml") != std::string::npos, "daemon unit path mismatch");
    expect(service.find("Requires=hidmi-gadget.service") == std::string::npos, "daemon unit should not require gadget setup");
    expect(service.find("Wants=network-online.target hidmi-gadget.service") != std::string::npos, "daemon unit should still want gadget setup");
    expect(gadget.find("gadget-setup --config") != std::string::npos, "gadget setup unit mismatch");
}

void test_led_network_states() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-idle-test-" + hidmi::random_b64url(8));
    fs::path udc = root / "state";
    write_file(udc, "configured\n");
    double now = 0.0;
    hidmi::LedController led("", "", udc.string(), 2.0, 0.30, std::chrono::milliseconds(50), [&] { return now; });
    expect(led.render_once(0.00).first, "idle P first short flash should be on");
    expect(!led.render_once(0.13).first, "idle P first gap should be off");
    expect(led.render_once(0.25).first, "idle P second short flash should be on");
    expect(!led.render_once(0.37).first, "idle P second gap should be off");
    expect(led.render_once(0.49).first, "idle P third short flash should be on");
    expect(!led.render_once(0.61).first, "idle P long interval should be off");
    expect(led.render_once(2.61).first, "idle P should repeat after interval");
    led.set_active_client(true);
    expect(led.render_once(1.30).first, "active client should hold P on");
    led.set_active_client(false);
    expect(!led.render_once(1.30).first, "inactive client should return P to idle pattern");
    led.set_network_state(hidmi::NetworkLedState::Other);
    expect(led.render_once(1.20).first, "network OTHER should use continuous short blink on phase");
    expect(!led.render_once(1.33).first, "network OTHER should use continuous short blink off phase");
    fs::remove_all(root);
}

void expect_hid_flash_count(hidmi::LedController& led, hidmi::HidLedState state, int count, const std::string& name) {
    led.set_hid_state(state);
    if (count == 0) {
        expect(!led.render_once(0.01).second, name + " should keep S off");
        expect(!led.render_once(0.25).second, name + " should keep S off later in the cycle");
        return;
    }
    for (int index = 0; index < count; ++index) {
        double start = index * 0.24;
        expect(led.render_once(start + 0.01).second, name + " flash " + std::to_string(index + 1) + " should be on");
        expect(!led.render_once(start + 0.13).second, name + " flash " + std::to_string(index + 1) + " gap should be off");
    }
    double active_span = 0.24 * count - 0.12;
    expect(!led.render_once(active_span + 0.01).second, name + " should enter the long off interval after its flashes");
    expect(led.render_once(active_span + 2.01).second, name + " should repeat after the long off interval");
}

void test_led_hid_flash_states() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-error-test-" + hidmi::random_b64url(8));
    fs::path udc = root / "state";
    write_file(udc, "configured\n");
    double now = 0.0;
    hidmi::LedController led("", "", udc.string(), 2.0, 0.30, std::chrono::milliseconds(50), [&] { return now; });
    expect_hid_flash_count(led, hidmi::HidLedState::Ready, 0, "HID_READY");
    expect_hid_flash_count(led, hidmi::HidLedState::UsbNotConfigured, 1, "USB_NOT_CONFIGURED");
    expect_hid_flash_count(led, hidmi::HidLedState::NodeUnavailable, 2, "HID_NODE_UNAVAILABLE");
    expect_hid_flash_count(led, hidmi::HidLedState::WriteFailed, 3, "HID_WRITE_FAILED");
    expect_hid_flash_count(led, hidmi::HidLedState::GadgetUnavailable, 4, "GADGET_UNAVAILABLE");
    expect_hid_flash_count(led, hidmi::HidLedState::AbsoluteDegraded, 5, "ABSOLUTE_DEGRADED");

    write_file(udc, "not attached\n");
    led.set_hid_state(hidmi::HidLedState::NodeUnavailable);
    expect(led.render_once(0.01).second, "UDC not configured should flash S once");
    expect(!led.render_once(0.25).second, "UDC not configured should take priority over HID node two-flash state");
    led.set_hid_state(hidmi::HidLedState::GadgetUnavailable);
    expect(led.render_once(0.73).second, "gadget unavailable should retain four-flash priority over UDC state");
    led.latch_protocol_error("bad packet");
    auto on = led.render_once(0.25);
    expect(on.first && on.second, "gadget state should keep S independent while protocol error drives P");
    fs::remove_all(root);
}

void test_led_protocol_and_auth_are_network_only() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-protocol-test-" + hidmi::random_b64url(8));
    fs::path udc = root / "state";
    write_file(udc, "configured\n");
    double now = 0.0;
    hidmi::LedController led("", "", udc.string(), 2.0, 0.30, std::chrono::milliseconds(50), [&] { return now; });
    led.latch_protocol_error("bad packet");
    auto on = led.render_once(0.05);
    expect(on.first && !on.second, "protocol error should blink P only in on phase");
    auto off = led.render_once(1.20);
    expect(!off.second, "protocol error should not drive S in off phase either");
    led.set_hid_state(hidmi::HidLedState::Ready);
    now = 2.00;
    led.latch_auth_error("bad token");
    expect(led.render_once(2.17).first, "auth failure should blink P in the on phase");
    expect(!led.render_once(2.17).second, "auth failure should not drive S");
    expect(!led.render_once(7.05).first, "transient network error should expire after 5s");
    fs::remove_all(root);
}

void test_led_input_events_do_not_drive_s() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-event-test-" + hidmi::random_b64url(8));
    fs::path udc = root / "state";
    write_file(udc, "configured\n");
    double now = 0.0;
    hidmi::LedController led("", "", udc.string(), 2.0, 0.12, std::chrono::milliseconds(50), [&] { return now; });
    led.notify_hid_event_sent();
    expect(!led.render_once(0.000).second, "S should not light after a single successful HID event");
    expect(!led.render_once(0.100).second, "S should remain off after a single successful HID event");

    now = 0.020;
    led.notify_hid_event_sent();
    expect(!led.render_once(0.130).second, "repeated HID events should not pulse S");

    now = 0.200;
    led.notify_hid_event_sent();
    expect(!led.render_once(0.300).second, "later HID events should not pulse S");

    now = 0.400;
    led.notify_hid_event_sent(true);
    expect(!led.render_once(1.000).second, "held keyboard or button report should not hold S on");
    now = 1.000;
    led.notify_hid_event_sent(false);
    expect(!led.render_once(1.100).second, "release event should not pulse S");
    fs::remove_all(root);
}

void test_write_fd_all_fails_on_closed_fd() {
    bool failed = false;
    try {
        hidmi::internal::write_fd_all(-1, std::vector<std::uint8_t>{1, 2, 3}, 1);
    } catch (const std::exception&) {
        failed = true;
    }
    expect(failed, "write_fd_all should fail instead of succeeding on an invalid fd");
}

void test_led_start_clears_outputs() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-start-test-" + hidmi::random_b64url(8));
    fs::path primary = root / "green_led";
    fs::path secondary = root / "red_led";
    fs::path udc = root / "state";
    create_led(primary, "1\n");
    create_led(secondary, "1\n");
    write_file(udc, "configured\n");
    {
        hidmi::LedController led(primary.string(), secondary.string(), udc.string(), 2.0, 0.30, std::chrono::milliseconds(50), [] { return 0.0; });
        led.start(false);
        expect(read_file(primary / "brightness") == "0\n", "primary LED should be off immediately after start");
        expect(read_file(secondary / "brightness") == "0\n", "secondary LED should be off immediately after start");
    }
    fs::remove_all(root);
}

void test_led_missing_paths_are_nonfatal() {
    fs::path root = fs::temp_directory_path() / ("hidmi-led-missing-test-" + hidmi::random_b64url(8));
    fs::path secondary = root / "red_led";
    fs::path udc = root / "state";
    create_led(secondary, "1\n");
    write_file(udc, "configured\n");
    {
        hidmi::LedController led((root / "missing_primary").string(), secondary.string(), udc.string(), 2.0, 0.30, std::chrono::milliseconds(50), [] { return 0.0; });
        led.start(false);
        expect(read_file(secondary / "brightness") == "0\n", "available secondary LED should still be cleared when primary is missing");
    }
    fs::remove_all(root);
}

void test_status_table() {
    fs::path root = fs::temp_directory_path() / ("hidmi-status-test-" + hidmi::random_b64url(8));
    hidmi::InstallPaths paths;
    paths.etc_dir = root / "etc";
    paths.install_root = root / "current";
    paths.systemd_dir = root / "systemd";
    paths.system_binary = root / "bin" / "hidmi";
    paths.runtime_status_path = root / "run" / "status.json";
    paths.status_requires_root = false;
    write_file(paths.installed_config_path(), config_text(paths.token_path().string()));
    write_file(paths.runtime_status_path,
        "{\"daemon_running\":true,\"tcp_connected\":false,\"client_connected\":false,"
        "\"client_proto_mismatch\":true,"
        "\"last_client_connected_at\":\"2026-01-02T03:04:05Z\",\"updated_at_ms\":9999999999999}\n");
    std::ostringstream out;
    hidmi::print_status(paths, out);
    std::string text = out.str();
    expect(text.find("| Overall") != std::string::npos, "status table missing overall row");
    expect(text.find("| Device") != std::string::npos, "status table missing device row");
    expect(text.find("| Display Name") != std::string::npos, "status table missing display row");
    expect(text.find("| Install Root") == std::string::npos, "status table should not include install root row");
    expect(text.find("| Config File") == std::string::npos, "status table should not include config row");
    expect(text.find("Detail") == std::string::npos, "status table should have only two columns");
    expect(text.find("| Service hidmi.service") != std::string::npos, "status table missing service row");
    expect(text.find("| HID Keyboard") != std::string::npos, "status table missing HID row");
    expect(text.find("| HID Available") != std::string::npos, "status table missing HID availability row");
    expect(text.find("| UDP Discovery") != std::string::npos, "status table missing discovery row");
    expect(text.find("| TCP Accept") != std::string::npos, "status table missing TCP row");
    expect(text.find("| LED Enabled") != std::string::npos, "status table missing LED enabled row");
    expect(text.find("| LED Primary") != std::string::npos, "status table missing LED primary row");
    expect(text.find("| LED Secondary") != std::string::npos, "status table missing LED secondary row");
    expect(text.find("| TCP Accept") < text.find("| LED Enabled"), "LED group should appear after TCP Accept");
    expect(text.find("| LED Secondary") < text.find("| Client Connection"), "client group should appear after LED group");
    expect(text.find("| Client Connection") != std::string::npos, "status table missing client row");
    expect(text.find("| Last Connected") != std::string::npos, "status table missing last client row");
    expect(text.find("ERR(proto mismatch)") != std::string::npos, "status table missing proto mismatch state");
    expect(text.find("2026-01-02T03:04:05Z") != std::string::npos, "status table missing last client timestamp");
    fs::remove_all(root);
}

void test_status_led_states() {
    fs::path root = fs::temp_directory_path() / ("hidmi-status-led-test-" + hidmi::random_b64url(8));
    hidmi::InstallPaths paths;
    paths.etc_dir = root / "etc";
    paths.install_root = root / "current";
    paths.runtime_status_path = root / "run" / "status.json";
    paths.status_requires_root = false;
    write_file(paths.runtime_status_path,
        "{\"daemon_running\":true,\"tcp_connected\":false,\"client_connected\":false,"
        "\"client_proto_mismatch\":false,"
        "\"last_client_connected_at\":\"\",\"updated_at_ms\":9999999999999}\n");

    fs::path primary = root / "leds" / "green_led";
    fs::path secondary = root / "leds" / "red_led";
    create_led(primary);
    create_led(secondary);
    write_file(paths.installed_config_path(), config_text(paths.token_path().string(), true, primary.string(), secondary.string()));
    std::ostringstream out_ok;
    hidmi::print_status(paths, out_ok);
    std::string ok_text = out_ok.str();
    expect(table_line(ok_text, "LED Enabled").find("OK") != std::string::npos, "LED enabled should report OK when both LEDs exist");
    expect(ok_text.find("OK(green_led)") != std::string::npos, "primary LED should report basename when available");
    expect(ok_text.find("OK(red_led)") != std::string::npos, "secondary LED should report basename when available");

    fs::remove(secondary / "brightness");
    write_file(paths.installed_config_path(), config_text(paths.token_path().string(), true, primary.string(), secondary.string()));
    std::ostringstream out_missing;
    hidmi::print_status(paths, out_missing);
    std::string missing_text = out_missing.str();
    expect(missing_text.find("ERR(red_led)") != std::string::npos, "missing secondary brightness should report LED ERR with basename");
    expect(table_line(ok_text, "Overall") == table_line(missing_text, "Overall"), "LED errors should not affect Overall status");

    write_file(paths.installed_config_path(), config_text(paths.token_path().string(), false, primary.string(), secondary.string()));
    std::ostringstream out_off;
    hidmi::print_status(paths, out_off);
    std::string off_text = out_off.str();
    expect(table_line(off_text, "LED Enabled").find("OFF") != std::string::npos, "disabled LEDs should report LED Enabled OFF");
    expect(table_line(off_text, "LED Primary").find("OFF(green_led)") != std::string::npos, "disabled primary LED should report OFF with basename");

    setenv("NO_COLOR", "1", 1);
    std::ostringstream out_no_color;
    hidmi::print_status(paths, out_no_color);
    unsetenv("NO_COLOR");
    expect(out_no_color.str().find("\033[") == std::string::npos, "NO_COLOR should disable ANSI status colors");
    fs::remove_all(root);
}

void test_status_stale_client_connection() {
    fs::path root = fs::temp_directory_path() / ("hidmi-status-stale-test-" + hidmi::random_b64url(8));
    hidmi::InstallPaths paths;
    paths.etc_dir = root / "etc";
    paths.install_root = root / "current";
    paths.runtime_status_path = root / "run" / "status.json";
    paths.status_requires_root = false;
    write_file(paths.installed_config_path(), config_text(paths.token_path().string()));
    write_file(paths.runtime_status_path,
        "{\"daemon_running\":true,\"tcp_connected\":true,\"client_connected\":true,"
        "\"client_proto_mismatch\":false,"
        "\"last_client_connected_at\":\"2026-01-02T03:04:05Z\","
        "\"last_client_request_at\":\"2026-01-02T03:04:06Z\","
        "\"last_client_request_at_ms\":1,"
        "\"last_client_response_at\":\"2026-01-02T03:04:06Z\","
        "\"last_client_response_at_ms\":1,"
        "\"last_disconnect_reason\":\"\","
        "\"updated_at_ms\":9999999999999}\n");

    std::ostringstream out;
    hidmi::print_status(paths, out);
    std::string text = out.str();
    expect(table_line(text, "Client Connection").find("STALE") != std::string::npos, "stale runtime activity should report Client Connection STALE");
    fs::remove_all(root);
}

void test_status_requires_sudo() {
    if (::geteuid() == 0) return;
    std::ostringstream out;
    std::ostringstream err;
    int rc = hidmi::cli_main({"status"}, out, err);
    expect(rc == 1, "non-root status should fail");
    expect(out.str().find("| Overall") == std::string::npos, "non-root status should not print a table");
    expect(err.str().find("ERROR: hidmi status requires sudo; rerun with sudo") != std::string::npos, "non-root status should explain sudo requirement");
}

}  // namespace

int main() {
    try {
        test_config();
        test_profile_resolution();
        test_status_json_parsing_helpers();
        test_protobuf_tcp_frame_length_prefix();
        test_protobuf_udp_discover_and_offer_helpers();
        test_protobuf_offer_hmac_and_absolute_scaling();
        test_tcp_error_message_normalization();
        test_tcp_business_frames_require_active_session();
        test_hid_reports();
        test_hid_writer_allows_missing_absolute_mouse();
        test_hid_writer_reopens_absolute_mouse_after_degraded_start();
        test_hid_writer_failed_open_does_not_leak_fd();
        test_units();
        test_led_network_states();
        test_led_hid_flash_states();
        test_led_protocol_and_auth_are_network_only();
        test_led_input_events_do_not_drive_s();
        test_write_fd_all_fails_on_closed_fd();
        test_led_start_clears_outputs();
        test_led_missing_paths_are_nonfatal();
        test_status_table();
        test_status_led_states();
        test_status_stale_client_connection();
        test_status_requires_sudo();
    } catch (const std::exception& exc) {
        std::cerr << "FAIL: " << exc.what() << "\n";
        return 1;
    }
    return 0;
}
