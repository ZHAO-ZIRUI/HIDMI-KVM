#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

ServerConfig load_server_config(const fs::path& path) {
    return parse_server_config(read_file(path));
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
