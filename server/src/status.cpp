#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

std::string service_output(const std::string& command) {
    std::array<char, 256> buffer{};
    std::string output;
    FILE* pipe = ::popen(command.c_str(), "r");
    if (!pipe) return "unavailable";
    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe)) {
        output += buffer.data();
    }
    ::pclose(pipe);
    return trim(output);
}

bool udp_port_listening(int port) {
    for (const auto& path : {fs::path("/proc/net/udp"), fs::path("/proc/net/udp6")}) {
        std::error_code ec;
        if (!fs::exists(path, ec)) continue;
        std::ifstream in(path);
        std::string line;
        std::getline(in, line);
        while (std::getline(in, line)) {
            std::istringstream fields(line);
            std::string sl, local;
            fields >> sl >> local;
            auto colon = local.find(':');
            if (colon == std::string::npos) continue;
            std::string hex_port = local.substr(colon + 1);
            int value = std::stoi(hex_port, nullptr, 16);
            if (value == port) return true;
        }
    }
    return false;
}

namespace {

struct RuntimeStatusSnapshot {
    bool daemon_running = false;
    bool tcp_connected = false;
    bool client_connected = false;
    bool hid_runtime_available = false;
    bool client_proto_mismatch = false;
    std::string last_client_connected_at;
    std::string last_client_request_at;
    std::int64_t last_client_request_at_ms = 0;
    std::string last_client_response_at;
    std::int64_t last_client_response_at_ms = 0;
    std::string last_disconnect_reason;
    std::string last_hid_error;
    std::string last_input_watchdog_release_at;
    int accept_worker_count = 0;
    std::int64_t updated_at_ms = 0;
};

enum class StatusColor {
    None,
    Green,
    Red,
    Cyan,
    Gray,
};

struct StatusCell {
    std::string text;
    StatusColor color = StatusColor::None;
};

struct StatusLine {
    std::string item;
    StatusCell status;
    bool separator = false;
};

StatusCell green(std::string text) { return {std::move(text), StatusColor::Green}; }
StatusCell red(std::string text) { return {std::move(text), StatusColor::Red}; }
StatusCell cyan(std::string text) { return {std::move(text), StatusColor::Cyan}; }
StatusCell gray(std::string text) { return {std::move(text), StatusColor::Gray}; }

std::string quote_status_arg(const std::string& value) {
    return "(" + value + ")";
}

std::string pad_right(const std::string& value, std::size_t width) {
    if (value.size() >= width) return value;
    return value + std::string(width - value.size(), ' ');
}

bool status_use_color(std::ostream& out) {
    if (std::getenv("NO_COLOR")) return false;
    return &out == &std::cout && ::isatty(STDOUT_FILENO);
}

std::string colorize_status(const std::string& text, StatusColor color_kind, bool use_color) {
    if (!use_color) return text;
    const char* color = "";
    switch (color_kind) {
        case StatusColor::Green: color = "\033[32m"; break;
        case StatusColor::Red: color = "\033[31m"; break;
        case StatusColor::Cyan: color = "\033[36m"; break;
        case StatusColor::Gray: color = "\033[90m"; break;
        case StatusColor::None: return text;
    }
    return std::string(color) + text + "\033[0m";
}

std::string path_leaf(const std::string& path) {
    if (path.empty()) return "<not configured>";
    fs::path parsed(path);
    for (auto it = parsed.end(); it != parsed.begin();) {
        --it;
        std::string part = it->string();
        if (!part.empty() && part != "/") return part;
    }
    return path;
}

std::optional<bool> object_bool(const Message& object, const std::string& key) {
    auto it = object.find(key);
    if (it == object.end()) return std::nullopt;
    if (auto value = std::get_if<bool>(&it->second.raw())) return *value;
    return std::nullopt;
}

std::optional<RuntimeStatusSnapshot> read_runtime_status(const fs::path& path, std::string& error) {
    std::string read_error;
    std::string text = read_file_no_throw(path, &read_error);
    if (!read_error.empty()) {
        error = read_error;
        return std::nullopt;
    }
    try {
        Message object = parse_json_object(text);
        RuntimeStatusSnapshot snapshot;
        snapshot.daemon_running = object_bool(object, "daemon_running").value_or(false);
        snapshot.tcp_connected = object_bool(object, "tcp_connected").value_or(false);
        snapshot.client_connected = object_bool(object, "client_connected").value_or(false);
        snapshot.hid_runtime_available = object_bool(object, "hid_runtime_available").value_or(false);
        snapshot.client_proto_mismatch = object_bool(object, "client_proto_mismatch").value_or(false);
        snapshot.last_client_connected_at = message_string(object, "last_client_connected_at");
        snapshot.last_client_request_at = message_string(object, "last_client_request_at");
        snapshot.last_client_request_at_ms = message_int_default(object, "last_client_request_at_ms", 0);
        snapshot.last_client_response_at = message_string(object, "last_client_response_at");
        snapshot.last_client_response_at_ms = message_int_default(object, "last_client_response_at_ms", 0);
        snapshot.last_disconnect_reason = message_string(object, "last_disconnect_reason");
        snapshot.last_hid_error = message_string(object, "last_hid_error");
        snapshot.last_input_watchdog_release_at = message_string(object, "last_input_watchdog_release_at");
        snapshot.accept_worker_count = static_cast<int>(message_int_default(object, "accept_worker_count", 0));
        snapshot.updated_at_ms = message_int_default(object, "updated_at_ms", 0);
        return snapshot;
    } catch (const std::exception& exc) {
        error = exc.what();
        return std::nullopt;
    }
}

StatusCell service_status(const std::string& name, bool* ok_out = nullptr) {
    std::string active = service_output("systemctl is-active " + name + " 2>/dev/null");
    std::string enabled = service_output("systemctl is-enabled " + name + " 2>/dev/null");
    bool ok = active == "active" && enabled == "enabled";
    if (ok_out) *ok_out = ok;
    if (ok) return green("OK");
    std::vector<std::string> parts;
    if (active != "active") parts.push_back("NOT ACTIVE");
    if (enabled != "enabled") parts.push_back("NOT ENABLED");
    std::string text;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        if (i) text += ", ";
        text += parts[i];
    }
    if (text.empty()) text = "ERR";
    return red(text);
}

StatusCell hid_status(const std::string& path, bool* ok_out = nullptr) {
    ProbeResult probe = probe_char_device(path);
    if (ok_out) *ok_out = probe.value;
    if (probe.value) return green("OK" + quote_status_arg(path));
    std::string detail = path.empty() ? "<not configured>" : path;
    return red("ERR" + quote_status_arg(detail));
}

bool led_available(const std::string& path) {
    if (path.empty()) return false;
    std::error_code ec;
    return fs::exists(fs::path(path) / "brightness", ec);
}

StatusCell led_status(const std::string& path, bool enabled, bool* ok_out = nullptr) {
    std::string name = path_leaf(path);
    if (!enabled) {
        if (ok_out) *ok_out = false;
        return gray("OFF" + quote_status_arg(name));
    }
    bool ok = led_available(path);
    if (ok_out) *ok_out = ok;
    return ok ? green("OK" + quote_status_arg(name)) : red("ERR" + quote_status_arg(name));
}

void print_table(std::ostream& out, const std::vector<StatusLine>& rows) {
    const std::size_t item_width = 28;
    std::size_t status_width = 12;
    for (const auto& row : rows) {
        if (!row.separator) status_width = std::max(status_width, row.status.text.size());
    }
    bool use_color = status_use_color(out);
    std::string separator = "+" + std::string(item_width + 2, '-') + "+" + std::string(status_width + 2, '-') + "+\n";
    out << separator;
    out << "| " << pad_right("Item", item_width)
        << " | " << pad_right("Status", status_width) << " |\n";
    out << separator;
    for (const auto& row : rows) {
        if (row.separator) {
            out << separator;
            continue;
        }
        std::string status = pad_right(row.status.text, status_width);
        out << "| " << pad_right(row.item, item_width)
            << " | " << colorize_status(status, row.status.color, use_color) << " |\n";
    }
    out << separator;
}

}  // namespace

}  // namespace

int print_status(const InstallPaths& paths, std::ostream& out) {
    if (paths.status_requires_root && ::geteuid() != 0) {
        throw std::runtime_error("hidmi status requires sudo; rerun with sudo");
    }

    std::vector<StatusLine> rows;
    std::optional<ServerConfig> cfg;
    bool config_ok = false;
    try {
        cfg = load_server_config(paths.installed_config_path());
        config_ok = true;
    } catch (const std::exception& exc) {
        (void)exc;
    }

    bool hidmi_service_ok = false;
    bool gadget_service_ok = false;
    StatusCell hidmi_service = service_status("hidmi.service", &hidmi_service_ok);
    StatusCell gadget_service = service_status("hidmi-gadget.service", &gadget_service_ok);
    bool services_ok = hidmi_service_ok && gadget_service_ok;

    bool hid_keyboard_ok = false;
    bool hid_mouse_ok = false;
    bool hid_absolute_ok = false;
    StatusCell hid_keyboard = cfg ? hid_status(cfg->hid.keyboard_path, &hid_keyboard_ok) : red("ERR(config unavailable)");
    StatusCell hid_mouse = cfg ? hid_status(cfg->hid.mouse_path, &hid_mouse_ok) : red("ERR(config unavailable)");
    StatusCell hid_absolute = cfg ? hid_status(cfg->hid.absolute_mouse_path, &hid_absolute_ok) : red("ERR(config unavailable)");
    bool hid_devices_ok = cfg && hid_keyboard_ok && hid_mouse_ok && hid_absolute_ok;

    bool hid_available_ok = false;
    StatusCell hid_available = red("ERR(config unavailable)");
    bool udp_ok = false;
    StatusCell udp_discovery = red("ERR(config unavailable)");
    if (cfg) {
        std::string udc_error;
        std::string udc_state = trim(read_file_no_throw(cfg->hid.udc_state_path, &udc_error));
        if (udc_error.empty() && udc_state == "configured") {
            hid_available_ok = true;
            hid_available = green("OK(configured)");
        } else if (udc_error.empty()) {
            hid_available = red("ERR" + quote_status_arg(udc_state.empty() ? "unknown" : udc_state));
        } else {
            hid_available = red("ERR" + quote_status_arg(udc_error));
        }
        udp_ok = udp_port_listening(cfg->udp_port);
        udp_discovery = udp_ok ? green("OK" + quote_status_arg(std::to_string(cfg->udp_port))) : red("ERR" + quote_status_arg(std::to_string(cfg->udp_port)));
    }

    std::string runtime_error;
    auto runtime = read_runtime_status(paths.runtime_status_path, runtime_error);
    bool runtime_stale = false;
    if (runtime) {
        runtime_stale = runtime->updated_at_ms <= 0 || epoch_ms() - runtime->updated_at_ms > 10000;
    }
    bool runtime_ok = runtime && !runtime_stale && runtime->daemon_running;
    bool tcp_accept_ok = hidmi_service_ok && runtime_ok;
    StatusCell tcp_accept = tcp_accept_ok ? green("OK") : red("ERR");
    StatusCell hid_runtime = runtime_ok && runtime->hid_runtime_available
        ? green("OK")
        : (runtime_ok ? red("ERR" + quote_status_arg(runtime->last_hid_error.empty() ? "unavailable" : runtime->last_hid_error)) : red("ERR"));

    bool led_primary_ok = false;
    bool led_secondary_ok = false;
    StatusCell led_enabled = red("ERR(config unavailable)");
    StatusCell led_primary = red("ERR(config unavailable)");
    StatusCell led_secondary = red("ERR(config unavailable)");
    if (cfg) {
        led_primary = led_status(cfg->leds.primary_path, cfg->leds.enabled, &led_primary_ok);
        led_secondary = led_status(cfg->leds.secondary_path, cfg->leds.enabled, &led_secondary_ok);
        if (!cfg->leds.enabled) {
            led_enabled = gray("OFF");
        } else {
            led_enabled = (led_primary_ok && led_secondary_ok) ? green("OK") : red("ERR");
        }
    }

    bool client_connected = runtime_ok && runtime->client_connected;
    bool proto_mismatch = runtime_ok && runtime->client_proto_mismatch;
    bool client_stale = false;
    if (runtime_ok && runtime->client_connected && runtime->last_client_request_at_ms > 0) {
        auto stale_after_ms = static_cast<std::int64_t>((cfg ? cfg->tcp_timeout_sec : 15.0) * 1000.0);
        client_stale = epoch_ms() - runtime->last_client_request_at_ms > stale_after_ms;
    }
    StatusCell client_connection;
    if (proto_mismatch) {
        client_connection = red("ERR(proto mismatch)");
    } else if (client_stale) {
        client_connection = gray("STALE");
    } else if (client_connected) {
        client_connection = green("OK");
    } else if (runtime_ok) {
        client_connection = green("IDLE");
    } else {
        client_connection = red("ERR");
    }
    StatusCell last_connected = cyan((runtime && !runtime->last_client_connected_at.empty()) ? runtime->last_client_connected_at : "never");
    StatusCell last_disconnect = cyan((runtime && !runtime->last_disconnect_reason.empty()) ? runtime->last_disconnect_reason : "none");
    StatusCell input_watchdog = cyan((runtime && !runtime->last_input_watchdog_release_at.empty()) ? runtime->last_input_watchdog_release_at : "never");
    StatusCell accept_workers = runtime_ok ? cyan(std::to_string(runtime->accept_worker_count)) : red("ERR");

    bool infra_ok = config_ok && services_ok && hid_devices_ok && hid_available_ok && udp_ok && tcp_accept_ok && (!runtime_ok || runtime->hid_runtime_available);
    StatusCell overall = !infra_ok || proto_mismatch ? red("ERR") : (client_connected && !client_stale ? green("OK") : green("IDLE"));

    rows.push_back({"Overall", overall});
    rows.push_back({"", {}, true});
    rows.push_back({"Device", cfg ? cyan(cfg->name) : red("ERR(config unavailable)")});
    rows.push_back({"Display Name", cfg ? cyan(cfg->display_name) : red("ERR(config unavailable)")});
    rows.push_back({"", {}, true});
    rows.push_back({"Service hidmi.service", hidmi_service});
    rows.push_back({"Service hidmi-gadget.service", gadget_service});
    rows.push_back({"", {}, true});
    rows.push_back({"HID Keyboard", hid_keyboard});
    rows.push_back({"HID Mouse", hid_mouse});
    rows.push_back({"HID Absolute Mouse", hid_absolute});
    rows.push_back({"HID Available", hid_available});
    rows.push_back({"HID Runtime", hid_runtime});
    rows.push_back({"", {}, true});
    rows.push_back({"UDP Discovery", udp_discovery});
    rows.push_back({"TCP Accept", tcp_accept});
    rows.push_back({"TCP Workers", accept_workers});
    rows.push_back({"", {}, true});
    rows.push_back({"LED Enabled", led_enabled});
    rows.push_back({"LED Primary", led_primary});
    rows.push_back({"LED Secondary", led_secondary});
    rows.push_back({"", {}, true});
    rows.push_back({"Client Connection", client_connection});
    rows.push_back({"Last Connected", last_connected});
    rows.push_back({"Last Disconnect", last_disconnect});
    rows.push_back({"Input Watchdog", input_watchdog});
    print_table(out, rows);
    return 0;
}

}  // namespace hidmi
