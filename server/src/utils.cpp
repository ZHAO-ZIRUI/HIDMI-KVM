#include "hidmi_internal.hpp"

#include <poll.h>

namespace fs = std::filesystem;

namespace hidmi::internal {

std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        throw std::runtime_error("failed to read " + path.string() + ": " + std::strerror(errno));
    }
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

void write_file(const fs::path& path, const std::string& text, fs::perms perms) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        throw std::runtime_error("failed to write " + path.string());
    }
    out << text;
    out.close();
    if (path.string().rfind("/sys/", 0) != 0) {
        fs::permissions(path, perms, fs::perm_options::replace);
    }
}

std::string trim(std::string value) {
    auto not_space = [](unsigned char c) { return !std::isspace(c); };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
    return value;
}

bool starts_with(const std::string& value, const std::string& prefix) {
    return value.rfind(prefix, 0) == 0;
}

int interface_type_from_name(std::string_view name) {
    std::string lower(name);
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    if (starts_with(lower, "wl") || starts_with(lower, "wlan") || starts_with(lower, "wifi") || starts_with(lower, "wlp")) {
        return 2;
    }
    if (starts_with(lower, "eth") || starts_with(lower, "en") || starts_with(lower, "eno") || starts_with(lower, "end") || starts_with(lower, "enp")) {
        return 1;
    }
    return 0;
}

bool is_hid_error_message(const std::string& message) {
    std::string lower = message;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    for (const std::string& marker : {
             "hid",
             "writer unavailable",
             "writer is not available",
             "write timed out",
             "hidg",
             "gadget",
             "/dev/hid",
             "endpoint",
         }) {
        if (lower.find(marker) != std::string::npos) return true;
    }
    return false;
}

}  // namespace hidmi::internal

namespace hidmi {

AuthFailureLimiter::AuthFailureLimiter(
    std::size_t max_failures,
    std::chrono::seconds window,
    std::chrono::seconds block_duration,
    std::chrono::seconds log_interval)
    : max_failures_(max_failures),
      window_(window),
      block_duration_(block_duration),
      log_interval_(log_interval) {}

void AuthFailureLimiter::prune(SourceState& state, std::chrono::steady_clock::time_point now) {
    while (!state.failures.empty() && now - state.failures.front() > window_) {
        state.failures.pop_front();
    }
}

bool AuthFailureLimiter::should_log(SourceState& state, std::chrono::steady_clock::time_point now) {
    if (!state.has_log_at || now - state.last_log_at >= log_interval_) {
        state.last_log_at = now;
        state.has_log_at = true;
        return true;
    }
    return false;
}

AuthFailureLimiter::Decision AuthFailureLimiter::check(
    const std::string& source,
    std::chrono::steady_clock::time_point now) {
    auto it = sources_.find(source);
    if (it == sources_.end()) return {};
    auto& state = it->second;
    prune(state, now);
    if (state.blocked_until > now) {
        return {true, should_log(state, now), static_cast<int>(state.failures.size())};
    }
    if (state.failures.empty()) {
        sources_.erase(it);
    }
    return {};
}

AuthFailureLimiter::Decision AuthFailureLimiter::record_failure(
    const std::string& source,
    std::chrono::steady_clock::time_point now) {
    auto& state = sources_[source];
    prune(state, now);
    state.failures.push_back(now);
    if (state.failures.size() > max_failures_) {
        state.blocked_until = now + block_duration_;
        return {true, should_log(state, now), static_cast<int>(state.failures.size())};
    }
    return {false, should_log(state, now), static_cast<int>(state.failures.size())};
}

void AuthFailureLimiter::record_success(const std::string& source) {
    sources_.erase(source);
}

UsbReenumerationGrace::UsbReenumerationGrace(std::chrono::seconds duration)
    : duration_(duration) {}

bool UsbReenumerationGrace::begin(const std::string& session_id, Clock::time_point now) {
    if (active_for(session_id, now)) return false;
    session_id_ = session_id;
    deadline_ = now + duration_;
    dropped_input_ = false;
    release_needed_ = false;
    gadget_reset_attempted_ = false;
    return true;
}

bool UsbReenumerationGrace::active_for(const std::string& session_id, Clock::time_point now) const {
    return !session_id_.empty() && session_id_ == session_id && now < deadline_;
}

bool UsbReenumerationGrace::expired(Clock::time_point now) const {
    return !session_id_.empty() && now >= deadline_;
}

void UsbReenumerationGrace::note_dropped_input() {
    if (session_id_.empty()) return;
    dropped_input_ = true;
    release_needed_ = true;
}

void UsbReenumerationGrace::note_release_needed() {
    if (!session_id_.empty()) release_needed_ = true;
}

void UsbReenumerationGrace::note_gadget_reset_attempted() {
    if (!session_id_.empty()) gadget_reset_attempted_ = true;
}

void UsbReenumerationGrace::clear() {
    session_id_.clear();
    deadline_ = {};
    dropped_input_ = false;
    release_needed_ = false;
    gadget_reset_attempted_ = false;
}

}  // namespace hidmi

namespace hidmi::internal {

std::string normalize_tcp_error_message(const std::string& message) {
    constexpr const char* kPrefix = "HID_FAILURE:";
    if (starts_with(message, kPrefix)) return message;
    if (is_hid_error_message(message)) return std::string(kPrefix) + " " + message;
    return message;
}

std::string strip_comment(const std::string& line) {
    bool in_string = false;
    bool escaped = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        char c = line[i];
        if (escaped) {
            escaped = false;
        } else if (c == '\\' && in_string) {
            escaped = true;
        } else if (c == '"') {
            in_string = !in_string;
        } else if (c == '#' && !in_string) {
            return line.substr(0, i);
        }
    }
    return line;
}

std::string unquote_toml_string(const std::string& raw) {
    if (raw.size() < 2 || raw.front() != '"' || raw.back() != '"') {
        throw std::runtime_error("invalid string");
    }
    std::string out;
    for (std::size_t i = 1; i + 1 < raw.size(); ++i) {
        char c = raw[i];
        if (c == '\\') {
            if (i + 2 >= raw.size()) {
                throw std::runtime_error("invalid escape");
            }
            char n = raw[++i];
            switch (n) {
                case 'n': out.push_back('\n'); break;
                case 't': out.push_back('\t'); break;
                case 'r': out.push_back('\r'); break;
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                default: throw std::runtime_error("unsupported escape");
            }
        } else {
            out.push_back(c);
        }
    }
    return out;
}

TomlValue parse_toml_value(const std::string& raw) {
    if (starts_with(raw, "\"")) {
        return unquote_toml_string(raw);
    }
    if (raw == "true") {
        return true;
    }
    if (raw == "false") {
        return false;
    }
    if (raw.find_first_of(".eE") != std::string::npos) {
        return std::stod(raw);
    }
    return static_cast<int64_t>(std::stoll(raw));
}

std::map<std::string, TomlTable> parse_toml_tables(const std::string& text) {
    std::map<std::string, TomlTable> tables;
    std::string section;
    std::istringstream input(text);
    std::string line;
    int line_no = 0;
    while (std::getline(input, line)) {
        ++line_no;
        line = trim(strip_comment(line));
        if (line.empty()) {
            continue;
        }
        if (line.front() == '[' && line.back() == ']') {
            section = trim(line.substr(1, line.size() - 2));
            if (section.empty()) {
                throw std::runtime_error("line " + std::to_string(line_no) + ": empty table name");
            }
            tables[section];
            continue;
        }
        if (section.empty()) {
            throw std::runtime_error("line " + std::to_string(line_no) + ": key outside table");
        }
        auto eq = line.find('=');
        if (eq == std::string::npos) {
            throw std::runtime_error("line " + std::to_string(line_no) + ": expected key = value");
        }
        std::string key = trim(line.substr(0, eq));
        std::string raw = trim(line.substr(eq + 1));
        tables[section][key] = parse_toml_value(raw);
    }
    return tables;
}

const TomlTable& required_table(const std::map<std::string, TomlTable>& tables, const std::string& name) {
    auto it = tables.find(name);
    if (it == tables.end()) {
        throw std::runtime_error(name + " must be a table");
    }
    return it->second;
}

const TomlTable& optional_table(const std::map<std::string, TomlTable>& tables, const std::string& name) {
    static const TomlTable empty;
    auto it = tables.find(name);
    if (it == tables.end()) {
        return empty;
    }
    return it->second;
}

std::string table_string(const TomlTable& table, const std::string& key, const std::string& fallback) {
    auto it = table.find(key);
    if (it == table.end()) {
        return fallback;
    }
    auto value = std::get_if<std::string>(&it->second);
    if (!value) {
        throw std::runtime_error(key + " must be a string");
    }
    return *value;
}

std::string table_required_string(const TomlTable& table, const std::string& key) {
    std::string value = table_string(table, key, "");
    if (value.empty()) {
        throw std::runtime_error(key + " is required");
    }
    return value;
}

bool table_bool(const TomlTable& table, const std::string& key, bool fallback) {
    auto it = table.find(key);
    if (it == table.end()) {
        return fallback;
    }
    auto value = std::get_if<bool>(&it->second);
    if (!value) {
        throw std::runtime_error(key + " must be a boolean");
    }
    return *value;
}

int table_int(const TomlTable& table, const std::string& key, int fallback) {
    auto it = table.find(key);
    if (it == table.end()) {
        return fallback;
    }
    auto value = std::get_if<int64_t>(&it->second);
    if (!value) {
        throw std::runtime_error(key + " must be an integer");
    }
    return static_cast<int>(*value);
}

double table_float(const TomlTable& table, const std::string& key, double fallback) {
    auto it = table.find(key);
    if (it == table.end()) {
        return fallback;
    }
    if (auto value = std::get_if<double>(&it->second)) {
        return *value;
    }
    if (auto value = std::get_if<int64_t>(&it->second)) {
        return static_cast<double>(*value);
    }
    throw std::runtime_error(key + " must be a number");
}

std::string json_escape(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : value) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                } else {
                    out << c;
                }
        }
    }
    out << '"';
    return out.str();
}

std::string message_string(const Message& message, const std::string& key) {
    auto it = message.find(key);
    if (it == message.end()) {
        return "";
    }
    return it->second.as_string();
}

std::optional<int64_t> message_int(const Message& message, const std::string& key) {
    auto it = message.find(key);
    if (it == message.end()) {
        return std::nullopt;
    }
    return it->second.as_int();
}

int64_t message_int_default(const Message& message, const std::string& key, int64_t fallback) {
    auto value = message_int(message, key);
    return value ? *value : fallback;
}

std::string hex_bytes(const std::vector<std::uint8_t>& data) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (auto byte : data) {
        out << std::setw(2) << static_cast<int>(byte);
    }
    return out.str();
}

std::uint32_t rotr(std::uint32_t value, int bits) {
    return (value >> bits) | (value << (32 - bits));
}

std::vector<std::uint8_t> sha256(const std::vector<std::uint8_t>& input) {
    static constexpr std::array<std::uint32_t, 64> k = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };
    std::vector<std::uint8_t> data = input;
    std::uint64_t bit_len = static_cast<std::uint64_t>(data.size()) * 8;
    data.push_back(0x80);
    while ((data.size() % 64) != 56) {
        data.push_back(0);
    }
    for (int i = 7; i >= 0; --i) {
        data.push_back(static_cast<std::uint8_t>(bit_len >> (i * 8)));
    }
    std::array<std::uint32_t, 8> h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    for (std::size_t chunk = 0; chunk < data.size(); chunk += 64) {
        std::array<std::uint32_t, 64> w{};
        for (int i = 0; i < 16; ++i) {
            std::size_t j = chunk + i * 4;
            w[i] = (static_cast<std::uint32_t>(data[j]) << 24) |
                   (static_cast<std::uint32_t>(data[j + 1]) << 16) |
                   (static_cast<std::uint32_t>(data[j + 2]) << 8) |
                   static_cast<std::uint32_t>(data[j + 3]);
        }
        for (int i = 16; i < 64; ++i) {
            std::uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            std::uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        auto [a, b, c, d, e, f, g, hh] = std::tuple{h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
        for (int i = 0; i < 64; ++i) {
            std::uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            std::uint32_t ch = (e & f) ^ ((~e) & g);
            std::uint32_t temp1 = hh + s1 + ch + k[i] + w[i];
            std::uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            std::uint32_t temp2 = s0 + maj;
            hh = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    std::vector<std::uint8_t> digest;
    digest.reserve(32);
    for (auto word : h) {
        digest.push_back(static_cast<std::uint8_t>(word >> 24));
        digest.push_back(static_cast<std::uint8_t>(word >> 16));
        digest.push_back(static_cast<std::uint8_t>(word >> 8));
        digest.push_back(static_cast<std::uint8_t>(word));
    }
    return digest;
}

void append_be32(std::string& out, std::uint32_t value) {
    out.push_back(static_cast<char>((value >> 24) & 0xff));
    out.push_back(static_cast<char>((value >> 16) & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>(value & 0xff));
}

void append_be64(std::string& out, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        out.push_back(static_cast<char>((value >> shift) & 0xff));
    }
}

std::vector<std::uint8_t> hmac_sha256(const std::string& token, const std::string& payload) {
    std::vector<std::uint8_t> key(token.begin(), token.end());
    if (key.size() > 64) {
        key = sha256(key);
    }
    key.resize(64, 0);
    std::vector<std::uint8_t> ipad(64), opad(64);
    for (std::size_t i = 0; i < 64; ++i) {
        ipad[i] = key[i] ^ 0x36;
        opad[i] = key[i] ^ 0x5c;
    }
    std::vector<std::uint8_t> inner = ipad;
    inner.insert(inner.end(), payload.begin(), payload.end());
    auto inner_hash = sha256(inner);
    std::vector<std::uint8_t> outer = opad;
    outer.insert(outer.end(), inner_hash.begin(), inner_hash.end());
    return sha256(outer);
}

std::string offer_auth_payload(
    std::uint64_t server_id,
    std::uint64_t boot_id,
    const std::string& challenge_nonce,
    const std::string& client_nonce,
    std::uint32_t control_port,
    std::uint32_t mouse_port,
    std::uint32_t keyboard_port,
    std::uint64_t client_unix_ms) {
    std::string payload;
    append_be32(payload, static_cast<std::uint32_t>(kProtoVersion));
    append_be64(payload, server_id);
    append_be64(payload, boot_id);
    payload += challenge_nonce;
    payload += client_nonce;
    append_be32(payload, control_port);
    append_be32(payload, mouse_port);
    append_be32(payload, keyboard_port);
    append_be64(payload, client_unix_ms);
    return payload;
}

bool valid_offer_tcp_ports(std::uint32_t control, std::uint32_t mouse, std::uint32_t keyboard) {
    if (control == mouse || control == keyboard || mouse == keyboard) return false;
    for (std::uint32_t port : {control, mouse, keyboard}) {
        if (port < static_cast<std::uint32_t>(kMinTcpPort) || port > static_cast<std::uint32_t>(kMaxTcpPort)) return false;
    }
    return true;
}

int protocol_absolute_to_hid(std::uint32_t value) {
    double clamped = std::max(0.0, std::min(65535.0, static_cast<double>(value)));
    return static_cast<int>(std::llround(clamped * 32767.0 / 65535.0));
}

std::string active_trigger(const std::string& text) {
    auto start = text.find('[');
    auto end = text.find(']', start == std::string::npos ? 0 : start);
    if (start != std::string::npos && end != std::string::npos && end > start + 1) {
        return text.substr(start + 1, end - start - 1);
    }
    std::istringstream in(text);
    std::string first;
    in >> first;
    return first;
}

bool path_exists(const fs::path& path) {
    std::error_code ec;
    return fs::exists(path, ec);
}

ProbeResult probe_char_device(const fs::path& path) {
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) {
        return {false, std::strerror(errno)};
    }
    return {S_ISCHR(st.st_mode), ""};
}

std::string read_file_no_throw(const fs::path& path, std::string* error) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        if (error) *error = std::strerror(errno);
        return "";
    }
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

std::int64_t epoch_ms() {
    auto now = std::chrono::system_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
}

std::string iso8601_utc_now() {
    std::time_t now = std::time(nullptr);
    std::tm tm {};
    gmtime_r(&now, &tm);
    char buffer[32] = {};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buffer;
}

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
    const std::string& last_gadget_reset_at,
    const std::string& last_gadget_reset_reason,
    int gadget_reset_count,
    int accept_worker_count) {
    fs::path path = "/run/hidmi/status.json";
    fs::path temp = path;
    temp += ".tmp";
    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);
    if (ec) throw std::runtime_error("create runtime status directory: " + ec.message());
    std::ostringstream document;
    document << "{"
             << "\"daemon_running\":" << (daemon_running ? "true" : "false") << ","
             << "\"tcp_connected\":" << (tcp_connected ? "true" : "false") << ","
             << "\"client_connected\":" << (client_connected ? "true" : "false") << ","
             << "\"hid_runtime_available\":" << (hid_runtime_available ? "true" : "false") << ","
             << "\"client_proto_mismatch\":" << (client_proto_mismatch ? "true" : "false") << ","
             << "\"last_client_connected_at\":" << json_escape(last_client_connected_at) << ","
             << "\"last_client_request_at\":" << json_escape(last_client_request_at) << ","
             << "\"last_client_request_at_ms\":" << last_client_request_at_ms << ","
             << "\"last_client_response_at\":" << json_escape(last_client_response_at) << ","
             << "\"last_client_response_at_ms\":" << last_client_response_at_ms << ","
             << "\"last_disconnect_reason\":" << json_escape(last_disconnect_reason) << ","
             << "\"last_hid_error\":" << json_escape(last_hid_error) << ","
             << "\"last_input_watchdog_release_at\":" << json_escape(last_input_watchdog_release_at) << ","
             << "\"last_gadget_reset_at\":" << json_escape(last_gadget_reset_at) << ","
             << "\"last_gadget_reset_reason\":" << json_escape(last_gadget_reset_reason) << ","
             << "\"gadget_reset_count\":" << gadget_reset_count << ","
             << "\"accept_worker_count\":" << accept_worker_count << ","
             << "\"updated_at_ms\":" << epoch_ms()
             << "}\n";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) throw std::runtime_error("write runtime status: " + std::string(std::strerror(errno)));
        out << document.str();
    }
    fs::permissions(temp, fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read | fs::perms::others_read, fs::perm_options::replace, ec);
    fs::rename(temp, path, ec);
    if (ec) throw std::runtime_error("publish runtime status: " + ec.message());
}

namespace {

void wait_fd_writable(int fd, int timeout_ms) {
    pollfd pfd{};
    pfd.fd = fd;
    pfd.events = POLLOUT;
    while (true) {
        int ready = ::poll(&pfd, 1, timeout_ms);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw std::runtime_error(std::strerror(errno));
        }
        if (ready == 0) {
            throw std::runtime_error("HID write timed out");
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            throw std::runtime_error("HID write fd is not writable");
        }
        if (pfd.revents & POLLOUT) {
            return;
        }
    }
}

}  // namespace

void write_fd_all(int fd, const std::vector<std::uint8_t>& bytes, int timeout_ms) {
    const std::uint8_t* cursor = bytes.data();
    std::size_t remaining = bytes.size();
    while (remaining > 0) {
        wait_fd_writable(fd, timeout_ms);
        ssize_t written = ::write(fd, cursor, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            throw std::runtime_error(std::strerror(errno));
        }
        if (written == 0) {
            throw std::runtime_error("HID write returned 0 bytes");
        }
        cursor += written;
        remaining -= static_cast<std::size_t>(written);
    }
}

int run_system(const std::string& command) {
    int result = std::system(command.c_str());
    if (result == -1) {
        return -1;
    }
    if (!WIFEXITED(result)) {
        return -1;
    }
    return WEXITSTATUS(result);
}

void ensure_root(const std::string& action) {
    if (::geteuid() != 0) {
        throw std::runtime_error(action + " requires root; rerun with sudo");
    }
}

volatile std::sig_atomic_t g_signal_stop_requested = 0;

void reset_signal_stop_request() {
    g_signal_stop_requested = 0;
}

bool signal_stop_requested() {
    return g_signal_stop_requested != 0;
}

void signal_stop(int) {
    g_signal_stop_requested = 1;
}

void install_daemon_signal_handlers() {
    reset_signal_stop_request();
    std::signal(SIGINT, signal_stop);
    std::signal(SIGTERM, signal_stop);
#ifdef SIGPIPE
    std::signal(SIGPIPE, SIG_IGN);
#endif
}


}  // namespace hidmi::internal

namespace hidmi {

std::string load_token(const std::filesystem::path& path) {
    return internal::trim(internal::read_file(path));
}

std::string random_b64url(std::size_t bytes) {
    std::vector<unsigned char> data(bytes);
    std::random_device rd;
    for (auto& byte : data) {
        byte = static_cast<unsigned char>(rd());
    }
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string out;
    int val = 0;
    int valb = -6;
    for (unsigned char c : data) {
        val = (val << 8) + c;
        valb += 8;
        while (valb >= 0) {
            out.push_back(alphabet[(val >> valb) & 0x3f]);
            valb -= 6;
        }
    }
    if (valb > -6) {
        out.push_back(alphabet[((val << 8) >> (valb + 8)) & 0x3f]);
    }
    return out;
}

std::string machine_id() {
    for (const auto& path : {std::filesystem::path("/etc/machine-id"), std::filesystem::path("/var/lib/dbus/machine-id")}) {
        std::error_code ec;
        if (std::filesystem::exists(path, ec)) {
            std::string value = internal::trim(internal::read_file(path));
            if (!value.empty()) return value;
        }
    }
    char hostname[256] = {};
    if (::gethostname(hostname, sizeof(hostname) - 1) != 0 || std::strlen(hostname) == 0) {
        std::strcpy(hostname, "device");
    }
    return std::string(hostname) + "-" + std::to_string(::getpid());
}

}  // namespace hidmi
