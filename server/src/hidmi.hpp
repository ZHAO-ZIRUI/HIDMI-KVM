#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <ostream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace hidmi {

constexpr int kProtoVersion = 1;
constexpr int kDiscoveryPort = 55536;
constexpr int kMinTcpPort = 10000;
constexpr int kMaxTcpPort = 60999;

struct HidConfig {
    std::string keyboard_path = "/dev/hidg0";
    std::string mouse_path = "/dev/hidg1";
    std::string absolute_mouse_path = "/dev/hidg2";
    std::string udc_state_path = "/sys/class/udc/musb-hdrc.5.auto/state";
};

struct LedConfig {
    bool enabled = true;
    std::string primary_path = "/sys/class/leds/green_led";
    std::string secondary_path = "/sys/class/leds/red_led";
};

struct ServerConfig {
    std::string name = "hidmi";
    std::string display_name = "HIDMI KVM";
    std::string token_file = "/etc/hidmi/token";
    int udp_port = kDiscoveryPort;
    bool discovery_only = false;
    int offer_ttl_sec = 30;
    double tcp_timeout_sec = 15.0;
    HidConfig hid;
    LedConfig leds;
};

ServerConfig load_server_config(const std::filesystem::path& path);
ServerConfig parse_server_config(const std::string& text);
std::string normalize_token_file(const std::string& text, const std::string& token_path);

class Json {
public:
    using array = std::vector<Json>;
    using object = std::map<std::string, Json>;
    using value = std::variant<std::nullptr_t, bool, int64_t, double, std::string, array, object>;

    Json();
    Json(std::nullptr_t);
    Json(bool v);
    Json(int v);
    Json(int64_t v);
    Json(double v);
    Json(const char* v);
    Json(std::string v);
    Json(array v);
    Json(object v);

    bool is_null() const;
    const value& raw() const;
    value& raw();
    const object& as_object() const;
    const array& as_array() const;
    std::string as_string(const std::string& fallback = "") const;
    std::optional<int64_t> as_int() const;
    bool as_bool(bool fallback = false) const;

private:
    value value_;
};

using Message = Json::object;

Json parse_json(const std::string& text);
Message parse_json_object(const std::string& text);
std::string dumps_json(const Json& json);

struct ProtocolError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

std::string load_token(const std::filesystem::path& path);
std::string random_b64url(std::size_t bytes = 16);
std::string machine_id();

class HidWriter {
public:
    HidWriter(std::string keyboard_path, std::string mouse_path, std::string absolute_mouse_path);
    ~HidWriter();
    void open();
    void close();
    void close_without_release() noexcept;
    bool keyboard_available() const;
    bool relative_mouse_available() const;
    bool absolute_mouse_available() const;
    bool mandatory_available() const;
    bool absolute_mouse_degraded() const;
    const std::string& last_absolute_error() const;
    bool try_reopen_absolute(bool force = false);
    void write_keyboard_report(int modifiers, const std::vector<int>& keys, int timeout_ms = 250);
    void write_mouse_report(int buttons, int dx, int dy, int wheel, int timeout_ms = 250);
    void write_absolute_mouse_report(int buttons, int x, int y, int timeout_ms = 250);
    void write_pointer_report(int buttons, int x, int y, int dx, int dy, int wheel, bool reliable_edge, int timeout_ms = 250);
    void release_all();

private:
    std::string keyboard_path_;
    std::string mouse_path_;
    std::string absolute_mouse_path_;
    int keyboard_fd_ = -1;
    int mouse_fd_ = -1;
    int absolute_mouse_fd_ = -1;
    int last_absolute_x_ = 16384;
    int last_absolute_y_ = 16384;
    std::chrono::steady_clock::time_point next_absolute_retry_at_{};
    std::string last_absolute_error_;

    void close_absolute_mouse() noexcept;
    void remember_absolute_error(const std::string& reason);
    int clamp_relative_value(int value) const;
};

class LedController {
public:
    using Clock = std::function<double()>;
    LedController(
        std::string primary_path,
        std::string secondary_path,
        std::string udc_state_path,
        double blink_sec = 2.0,
        double pulse_sec = 0.12,
        std::chrono::milliseconds tick = std::chrono::milliseconds(50),
        Clock clock = {});
    ~LedController();

    void start(bool start_thread = true);
    void stop();
    void set_active_client(bool active);
    void latch_protocol_error(const std::string& reason);
    void latch_auth_error(const std::string& reason);
    void latch_hid_error(const std::string& reason);
    void clear_hid_error();
    void clear_errors();
    void notify_input_received();
    void notify_hid_event_sent(bool hold_active = false);
    std::pair<bool, bool> render_once(std::optional<double> now = std::nullopt);

private:
    struct SysfsLed;
    std::unique_ptr<SysfsLed> primary_;
    std::unique_ptr<SysfsLed> secondary_;
    std::string udc_state_path_;
    double blink_sec_;
    double pulse_sec_;
    std::chrono::milliseconds tick_;
    Clock clock_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::thread thread_;
    bool stop_requested_ = false;
    double started_at_ = 0.0;
    bool active_client_ = false;
    bool protocol_error_latched_ = false;
    bool hid_error_latched_ = false;
    bool secondary_hold_active_ = false;
    std::string last_protocol_error_;
    std::string last_auth_error_;
    std::string last_hid_error_;
    double auth_error_started_at_ = 0.0;
    double auth_error_until_ = 0.0;
    double secondary_pulse_until_ = 0.0;

    void run();
    bool protocol_blink_on(double now) const;
    bool auth_error_blink_on(double now, double auth_error_started_at) const;
    bool idle_primary_on(double now) const;
    bool usb_configured() const;
};

class Daemon {
public:
    explicit Daemon(ServerConfig config, std::optional<std::string> token_override = std::nullopt);
    int serve_forever();
    void stop();

private:
    struct PendingSession;
    struct ChannelEndpoint {
        int port = 0;
        int listener_fd = -1;
        int conn_fd = -1;
        bool ready = false;
    };
    struct AcceptWorker {
        std::thread thread;
        std::shared_ptr<std::atomic_bool> done;
    };
    struct PressedInputState {
        int keyboard_modifiers = 0;
        std::vector<int> keyboard_keys;
        int mouse_buttons = 0;
        int absolute_mouse_buttons = 0;

        bool has_pressed() const {
            return keyboard_modifiers != 0
                || !keyboard_keys.empty()
                || mouse_buttons != 0
                || absolute_mouse_buttons != 0;
        }

        void clear() {
            keyboard_modifiers = 0;
            keyboard_keys.clear();
            mouse_buttons = 0;
            absolute_mouse_buttons = 0;
        }
    };
    ServerConfig config_;
    std::string device_id_;
    std::uint64_t server_id_ = 0;
    std::uint64_t boot_id_ = 0;
    std::string challenge_nonce_;
    std::optional<std::string> token_override_;
    std::string token_;
    std::unique_ptr<HidWriter> hid_;
    std::unique_ptr<LedController> led_;
    int udp_fd_ = -1;
    std::atomic<bool> stop_requested_{false};
    std::mutex mutex_;
    std::mutex worker_mutex_;
    std::mutex runtime_mutex_;
    std::mutex hid_mutex_;
    std::map<std::string, std::shared_ptr<PendingSession>> pending_;
    std::vector<AcceptWorker> accept_workers_;
    std::string active_session_id_;
    PressedInputState pressed_input_;
    std::chrono::steady_clock::time_point last_input_activity_{};
    bool runtime_tcp_connected_ = false;
    bool runtime_client_connected_ = false;
    bool runtime_hid_available_ = false;
    bool runtime_client_proto_mismatch_ = false;
    std::string last_client_connected_at_;
    std::string last_client_request_at_;
    std::int64_t last_client_request_at_ms_ = 0;
    std::string last_client_response_at_;
    std::int64_t last_client_response_at_ms_ = 0;
    std::string last_disconnect_reason_;
    std::string last_hid_error_;
    std::string last_input_watchdog_release_at_;
    int runtime_accept_worker_count_ = 0;
    std::chrono::steady_clock::time_point next_hid_retry_at_{};

    void handle_udp_datagram(const std::string& data, const sockaddr_storage& addr, socklen_t addr_len);
    void handle_offer_datagram(const std::string& data, const sockaddr_storage& addr, socklen_t addr_len);
    void broadcast_discover();
    ChannelEndpoint& endpoint_for(PendingSession& session, int channel_id);
    bool all_channels_ready(const PendingSession& session) const;
    void handle_discover(const Message& message, const sockaddr_storage& addr, socklen_t addr_len);
    void handle_accept(const Message& message, const sockaddr_storage& addr, socklen_t addr_len);
    void tcp_channel_worker(std::shared_ptr<PendingSession> session, int channel_id, std::shared_ptr<std::atomic_bool> done);
    void handle_tcp_channel(std::shared_ptr<PendingSession> session, int channel_id, int conn_fd);
    void cleanup_session(std::shared_ptr<PendingSession> session, const std::string& reason, bool release);
    void tcp_accept_worker(std::shared_ptr<PendingSession> session, std::shared_ptr<std::atomic_bool> done);
    void join_accept_workers();
    void reap_accept_workers();
    void handle_tcp_client(std::shared_ptr<PendingSession> session, int conn_fd);
    void verify_hello(const PendingSession& session, const Message& hello);
    void handle_absolute_mouse_stream_message(const Message& message);
    Message handle_control_message(const Message& message);
    void cleanup_expired_sessions();
    void enforce_input_watchdog();
    void send_udp(const sockaddr_storage& addr, socklen_t addr_len, const Message& message);
    void send_udp_error(const sockaddr_storage& addr, socklen_t addr_len, const std::string& code, const std::string& message, bool latch_error = true);
    bool ensure_hid_available(bool force = false);
    void mark_hid_failed(const std::string& reason);
    void retry_hid_if_due();
    HidWriter& require_hid();
    void set_led_active_client(bool active);
    void led_protocol_error(const std::string& reason);
    void led_auth_error(const std::string& reason);
    void led_hid_error(const std::string& reason);
    void led_input_received();
    void led_hid_event_sent(bool hold_active = false);
    void led_hid_success();
    void publish_runtime_status(bool daemon_running);
    void set_runtime_tcp_connected(bool connected);
    void set_runtime_client_connected(bool connected, bool update_timestamp);
    void set_runtime_hid_available(bool available);
    void set_runtime_client_request_activity();
    void set_runtime_client_response_activity();
    void set_runtime_disconnect_reason(const std::string& reason);
    void set_runtime_client_proto_mismatch(bool mismatch);
    void set_runtime_hid_error(const std::string& reason);
    void set_runtime_input_watchdog_release();
    void set_runtime_accept_worker_count(int count);
    void record_keyboard_pressed_state(int modifiers, const std::vector<int>& keys);
    void record_mouse_pressed_state(int buttons);
    void record_absolute_mouse_pressed_state(int buttons);
    void clear_input_pressed_state();
};

struct InstallPaths {
    std::filesystem::path etc_dir = "/etc/hidmi";
    std::filesystem::path install_root = "/etc/hidmi/current";
    std::filesystem::path systemd_dir = "/etc/systemd/system";
    std::filesystem::path system_binary = "/usr/local/bin/hidmi";
    std::filesystem::path runtime_status_path = "/run/hidmi/status.json";
    bool status_requires_root = true;

    std::filesystem::path token_path() const;
    std::filesystem::path installed_config_path() const;
};

struct InstallResult {
    std::string token;
    bool generated_token = false;
    std::filesystem::path config_path;
    std::filesystem::path installed_config_path;
};

std::filesystem::path discover_config(const std::filesystem::path& base_dir = std::filesystem::current_path());
std::filesystem::path resolve_profile_config(const std::string& profile, const std::filesystem::path& base_dir = std::filesystem::current_path());
InstallResult install_service(const std::optional<std::filesystem::path>& config_path, const std::optional<std::string>& token, const InstallPaths& paths = {});
int uninstall_service(const InstallPaths& paths = {}, std::ostream& out = std::cout);
int print_status(const InstallPaths& paths = {}, std::ostream& out = std::cout);
std::string render_hidmi_service(const InstallPaths& paths);
std::string render_gadget_service(const InstallPaths& paths);

void gadget_setup();
void gadget_teardown(const ServerConfig& config);
void release_all(const ServerConfig& config);

int cli_main(const std::vector<std::string>& args, std::ostream& out = std::cout, std::ostream& err = std::cerr);

}  // namespace hidmi
