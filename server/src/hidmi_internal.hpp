#pragma once

#include "hidmi.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <netinet/in.h>
#include <optional>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <tuple>
#include <unistd.h>
#include <variant>
#include <vector>

#ifdef __linux__
#include <arpa/inet.h>
#endif

namespace hidmi::internal {

namespace fs = std::filesystem;

using TomlValue = std::variant<bool, int64_t, double, std::string>;
using TomlTable = std::map<std::string, TomlValue>;

struct ProbeResult {
    bool value = false;
    std::string error;
};

std::string read_file(const fs::path& path);
void write_file(
    const fs::path& path,
    const std::string& text,
    fs::perms perms = fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read | fs::perms::others_read);
std::string trim(std::string value);
bool starts_with(const std::string& value, const std::string& prefix);
std::string strip_comment(const std::string& line);
std::string unquote_toml_string(const std::string& raw);
TomlValue parse_toml_value(const std::string& raw);
std::map<std::string, TomlTable> parse_toml_tables(const std::string& text);
const TomlTable& required_table(const std::map<std::string, TomlTable>& tables, const std::string& name);
const TomlTable& optional_table(const std::map<std::string, TomlTable>& tables, const std::string& name);
std::string table_string(const TomlTable& table, const std::string& key, const std::string& fallback);
std::string table_required_string(const TomlTable& table, const std::string& key);
bool table_bool(const TomlTable& table, const std::string& key, bool fallback);
int table_int(const TomlTable& table, const std::string& key, int fallback);
double table_float(const TomlTable& table, const std::string& key, double fallback);
std::string json_escape(const std::string& value);
std::string message_string(const Message& message, const std::string& key);
std::optional<int64_t> message_int(const Message& message, const std::string& key);
int64_t message_int_default(const Message& message, const std::string& key, int64_t fallback);
std::string hex_bytes(const std::vector<std::uint8_t>& data);
std::uint32_t rotr(std::uint32_t value, int bits);
std::vector<std::uint8_t> sha256(const std::vector<std::uint8_t>& input);
void append_be32(std::string& out, std::uint32_t value);
void append_be64(std::string& out, std::uint64_t value);
std::vector<std::uint8_t> hmac_sha256(const std::string& token, const std::string& payload);
std::string offer_auth_payload(
    std::uint64_t server_id,
    std::uint64_t boot_id,
    const std::string& challenge_nonce,
    const std::string& client_nonce,
    std::uint32_t control_port,
    std::uint32_t mouse_port,
    std::uint32_t keyboard_port,
    std::uint64_t client_unix_ms);
bool valid_offer_tcp_ports(std::uint32_t control, std::uint32_t mouse, std::uint32_t keyboard);
int protocol_absolute_to_hid(std::uint32_t value);
bool tcp_frame_body_requires_active_session(int channel_id, int body_case);
bool is_hid_error_message(const std::string& message);
std::string normalize_tcp_error_message(const std::string& message);
std::string active_trigger(const std::string& text);
bool path_exists(const fs::path& path);
ProbeResult probe_char_device(const fs::path& path);
std::string read_file_no_throw(const fs::path& path, std::string* error = nullptr);
std::int64_t epoch_ms();
std::string iso8601_utc_now();
void write_runtime_status_file(
    bool daemon_running,
    bool tcp_connected,
    bool client_connected,
    bool hid_runtime_available,
    bool client_proto_mismatch,
    const std::string& last_client_connected_at,
    const std::string& last_client_request_at,
    std::int64_t last_client_request_at_ms,
    const std::string& last_client_response_at,
    std::int64_t last_client_response_at_ms,
    const std::string& last_disconnect_reason,
    const std::string& last_hid_error,
    const std::string& last_input_watchdog_release_at,
    int accept_worker_count);
void write_fd_all(int fd, const std::vector<std::uint8_t>& bytes, int timeout_ms = 250);
int run_system(const std::string& command);
void ensure_root(const std::string& action);
bool signal_stop_requested();
void install_daemon_signal_handlers();

}  // namespace hidmi::internal
