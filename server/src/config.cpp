#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

constexpr const char* kAllowRuntimeTestOverridesEnv = "HIDMI_ALLOW_RUNTIME_TEST_OVERRIDES";
constexpr const char* kUdcStatePathOverrideEnv = "HIDMI_UDC_STATE_PATH_OVERRIDE";

fs::path absolute_lexical_path(const fs::path& path) {
    std::error_code ec;
    fs::path absolute = path.is_absolute() ? path : fs::absolute(path, ec);
    if (ec) absolute = path;
    return absolute.lexically_normal();
}

bool path_has_prefix(const fs::path& path, const fs::path& prefix) {
    auto path_it = path.begin();
    auto prefix_it = prefix.begin();
    for (; prefix_it != prefix.end(); ++prefix_it, ++path_it) {
        if (path_it == path.end() || *path_it != *prefix_it) return false;
    }
    return true;
}

bool is_transient_udc_state_path(const fs::path& path) {
    fs::path normalized = absolute_lexical_path(path);
    return path_has_prefix(normalized, fs::path("/run")) ||
           path_has_prefix(normalized, fs::path("/tmp")) ||
           path_has_prefix(normalized, fs::path("/var/tmp"));
}

bool runtime_test_overrides_allowed() {
    const char* value = std::getenv(kAllowRuntimeTestOverridesEnv);
    return value && std::string(value) == "1";
}

}  // namespace

ServerConfig load_server_config(const fs::path& path) {
    return parse_server_config(read_file(path));
}

ServerConfig load_runtime_server_config(const fs::path& path) {
    return apply_runtime_test_overrides(load_server_config(path));
}

ServerConfig parse_server_config(const std::string& text) {
    auto tables = parse_toml_tables(text);
    const auto& service = required_table(tables, "service");
    const auto& board = required_table(tables, "board");
    const auto& leds = optional_table(tables, "board.leds");
    ServerConfig cfg;
    cfg.display_name = table_string(service, "name", cfg.display_name);
    cfg.token_file = table_required_string(service, "token_file");
    cfg.udp_port = table_int(service, "discovery_udp_port", cfg.udp_port);
    cfg.discovery_only = table_bool(service, "discovery_only", cfg.discovery_only);
    cfg.offer_ttl_sec = table_int(service, "timeout_offer_ttl_sec", cfg.offer_ttl_sec);
    cfg.tcp_timeout_sec = table_float(service, "timeout_tcp_sec", cfg.tcp_timeout_sec);
    cfg.hid.keyboard_path = table_string(board, "hid_keyboard_path", cfg.hid.keyboard_path);
    cfg.hid.mouse_path = table_string(board, "hid_mouse_path", cfg.hid.mouse_path);
    cfg.hid.absolute_mouse_path = table_string(board, "hid_absolute_mouse_path", cfg.hid.absolute_mouse_path);
    cfg.hid.udc_state_path = table_string(board, "udc_state_path", cfg.hid.udc_state_path);
    cfg.leds.enabled = table_bool(leds, "enabled", cfg.leds.enabled);
    cfg.leds.primary_path = table_string(leds, "primary", cfg.leds.primary_path);
    cfg.leds.secondary_path = table_string(leds, "secondary", cfg.leds.secondary_path);
    return cfg;
}

ServerConfig apply_runtime_test_overrides(ServerConfig config) {
    if (!runtime_test_overrides_allowed()) return config;
    const char* udc_override = std::getenv(kUdcStatePathOverrideEnv);
    if (udc_override && *udc_override) {
        config.hid.udc_state_path = udc_override;
    }
    return config;
}

void validate_persistent_install_config(const ServerConfig& config) {
    fs::path udc_path = config.hid.udc_state_path;
    if (is_transient_udc_state_path(udc_path)) {
        throw std::runtime_error(
            "persistent install config must not use transient/test UDC state path " + udc_path.string() +
            "; use HIDMI_UDC_STATE_PATH_OVERRIDE with HIDMI_ALLOW_RUNTIME_TEST_OVERRIDES=1 for smoke tests");
    }
    std::string error;
    (void)read_file_no_throw(udc_path, &error);
    if (!error.empty()) {
        throw std::runtime_error(
            "persistent install config UDC state path is not readable: " + udc_path.string() + ": " + error);
    }
}

std::string normalize_token_file(const std::string& text, const std::string& token_path) {
    std::string token_line = "token_file = " + json_escape(token_path);
    std::istringstream in(text);
    std::vector<std::string> output;
    std::string line;
    bool in_service = false;
    bool saw_service = false;
    bool replaced = false;
    while (std::getline(in, line)) {
        std::string stripped = trim(line);
        if (starts_with(stripped, "[") && stripped.back() == ']') {
            if (in_service && !replaced) {
                output.push_back(token_line);
                replaced = true;
            }
            in_service = stripped == "[service]";
            saw_service = saw_service || in_service;
        }
        if (in_service && starts_with(stripped, "token_file")) {
            output.push_back(token_line);
            replaced = true;
            continue;
        }
        output.push_back(line);
    }
    if (in_service && !replaced) {
        output.push_back(token_line);
        replaced = true;
    }
    if (!saw_service) {
        throw std::runtime_error("service table is required");
    }
    if (!replaced) {
        throw std::runtime_error("token_file is required");
    }
    std::ostringstream out;
    for (const auto& item : output) {
        out << item << "\n";
    }
    return out.str();
}

}  // namespace hidmi
