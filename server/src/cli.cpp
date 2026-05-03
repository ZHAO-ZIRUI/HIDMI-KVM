#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

std::optional<std::string> option_value(const std::vector<std::string>& args, const std::string& name) {
    for (std::size_t i = 0; i < args.size(); ++i) {
        if (args[i] == name && i + 1 < args.size()) return args[i + 1];
    }
    return std::nullopt;
}

std::vector<std::string> positional_args(const std::vector<std::string>& args) {
    std::vector<std::string> result;
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (args[i] == "--config" || args[i] == "--token") {
            ++i;
            continue;
        }
        if (args[i].rfind("--", 0) == 0) continue;
        result.push_back(args[i]);
    }
    return result;
}

fs::path config_from_cli(const std::vector<std::string>& args, bool allow_default_discovery) {
    auto config_arg = option_value(args, "--config");
    auto positionals = positional_args(args);
    if (config_arg && !positionals.empty()) {
        throw std::runtime_error("use either PROFILE or --config, not both");
    }
    if (config_arg) return fs::absolute(*config_arg);
    if (!positionals.empty()) return resolve_profile_config(positionals.front());
    if (allow_default_discovery) return fs::absolute(discover_config());
    throw std::runtime_error("PROFILE or --config is required");
}

void print_help(std::ostream& out) {
    out << "usage: hidmi <command> [options]\n\n"
        << "commands:\n"
        << "  install PROFILE [--token TOKEN]\n"
        << "  install --config PATH [--token TOKEN]\n"
        << "  uninstall\n"
        << "  status\n"
        << "  run PROFILE [--token TOKEN]\n"
        << "  run --config PATH [--token TOKEN]\n"
        << "  daemon --config PATH\n"
        << "  gadget-setup --config PATH\n"
        << "  gadget-teardown --config PATH\n";
}

}  // namespace

int cli_main(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.empty() || args[0] == "--help" || args[0] == "-h") {
        print_help(out);
        return 0;
    }
    try {
        const std::string& command = args[0];
        if (command == "install") {
            auto token_arg = option_value(args, "--token");
            auto result = install_service(config_from_cli(args, true), token_arg);
            if (result.generated_token) out << "TOKEN: " << result.token << "\n";
            return 0;
        }
        if (command == "uninstall") return uninstall_service({}, out);
        if (command == "status") return print_status({}, out);
        if (command == "run") {
            ensure_root("run");
            auto config_path = config_from_cli(args, false);
            auto token_arg = option_value(args, "--token");
            ServerConfig cfg = load_runtime_server_config(config_path);
            gadget_setup(cfg);
            Daemon daemon(cfg, token_arg);
            install_daemon_signal_handlers();
            try {
                int rc = daemon.serve_forever();
                gadget_teardown(cfg);
                return rc;
            } catch (...) {
                try { gadget_teardown(cfg); } catch (...) {}
                throw;
            }
        }
        if (command == "daemon") {
            auto config_arg = option_value(args, "--config");
            if (!config_arg) throw std::runtime_error("--config is required");
            ServerConfig cfg = load_runtime_server_config(*config_arg);
            Daemon daemon(cfg);
            install_daemon_signal_handlers();
            int rc = daemon.serve_forever();
            return rc;
        }
        if (command == "gadget-setup") {
            auto config_arg = option_value(args, "--config");
            ServerConfig cfg = config_arg ? load_server_config(*config_arg) : ServerConfig{};
            gadget_setup(cfg);
            return 0;
        }
        if (command == "gadget-teardown") {
            auto config_arg = option_value(args, "--config");
            if (!config_arg) throw std::runtime_error("--config is required");
            gadget_teardown(load_server_config(*config_arg));
            return 0;
        }
        err << "ERROR: unsupported command " << command << "\n";
        print_help(err);
        return 1;
    } catch (const std::exception& exc) {
        err << "ERROR: " << exc.what() << "\n";
        return 1;
    }
}

}  // namespace hidmi
