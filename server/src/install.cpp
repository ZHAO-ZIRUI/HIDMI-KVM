#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

fs::path InstallPaths::token_path() const { return etc_dir / "token"; }
fs::path InstallPaths::installed_config_path() const { return install_root / "conf" / "installed.toml"; }

std::filesystem::path discover_config(const fs::path& base_dir) {
    fs::path conf = base_dir / "conf";
    if (!fs::is_directory(conf)) throw std::runtime_error("no config TOML found under ./conf; pass --config");
    fs::path preferred = conf / "orangepi-zero-3.toml";
    if (fs::exists(preferred)) return preferred;
    std::vector<fs::path> configs;
    for (const auto& entry : fs::directory_iterator(conf)) {
        if (entry.path().extension() == ".toml") configs.push_back(entry.path());
    }
    std::sort(configs.begin(), configs.end());
    if (configs.size() == 1) return configs.front();
    if (configs.empty()) throw std::runtime_error("no config TOML found under ./conf; pass --config");
    throw std::runtime_error("multiple config files found under ./conf; pass --config");
}

std::filesystem::path resolve_profile_config(const std::string& profile, const fs::path& base_dir) {
    if (profile.empty()) throw std::runtime_error("profile name is required");
    std::string filename = profile;
    if (filename.size() < 5 || filename.substr(filename.size() - 5) != ".toml") {
        filename += ".toml";
    }
    std::vector<fs::path> candidates = {
        base_dir / "server" / "conf" / filename,
        base_dir / "conf" / filename,
        fs::path("/etc/hidmi/profiles") / filename,
    };
    if (const char* env = std::getenv("HIDMI_CONFIG_DIR")) {
        candidates.insert(candidates.begin(), fs::path(env) / filename);
    }
    for (const auto& candidate : candidates) {
        std::error_code ec;
        if (fs::is_regular_file(candidate, ec)) return fs::absolute(candidate);
    }
    throw std::runtime_error("unknown hardware profile " + profile + "; pass --config");
}

InstallResult install_service(const std::optional<fs::path>& config_path_opt, const std::optional<std::string>& token_opt, const InstallPaths& paths) {
    ensure_root("install");
    if (!fs::is_regular_file(paths.system_binary)) {
        throw std::runtime_error("system binary missing at " + paths.system_binary.string() + "; run sudo make install first");
    }
    fs::path config_path = config_path_opt ? fs::absolute(*config_path_opt) : fs::absolute(discover_config());
    (void)load_server_config(config_path);
    std::string token = token_opt.value_or(random_b64url(32));
    run_system("systemctl stop hidmi.service >/dev/null 2>&1");
    run_system("systemctl stop hidmi-gadget.service >/dev/null 2>&1");
    fs::create_directories(paths.etc_dir);
    fs::permissions(paths.etc_dir, fs::perms::owner_all, fs::perm_options::replace);
    fs::path temp_root = paths.install_root.parent_path() / ".current.tmp";
    fs::remove_all(temp_root);
    fs::create_directories(temp_root / "conf");
    fs::path temp_config = temp_root / "conf" / "installed.toml";
    write_file(temp_config, normalize_token_file(read_file(config_path), paths.token_path().string()));
    fs::remove_all(paths.install_root);
    fs::rename(temp_root, paths.install_root);
    write_file(paths.token_path(), token + "\n", fs::perms::owner_read | fs::perms::owner_write);
    write_file(paths.systemd_dir / "hidmi.service", render_hidmi_service(paths));
    write_file(paths.systemd_dir / "hidmi-gadget.service", render_gadget_service(paths));
    if (run_system("systemctl daemon-reload") != 0) throw std::runtime_error("systemctl daemon-reload failed");
    if (run_system("systemctl enable --now hidmi-gadget.service hidmi.service") != 0) throw std::runtime_error("systemctl enable --now failed");
    return {token, !token_opt.has_value(), config_path, paths.installed_config_path()};
}

int uninstall_service(const InstallPaths& paths, std::ostream& out) {
    ensure_root("uninstall");
    run_system("systemctl stop hidmi.service >/dev/null 2>&1");
    run_system("systemctl stop hidmi-gadget.service >/dev/null 2>&1");
    run_system("systemctl disable hidmi.service hidmi-gadget.service >/dev/null 2>&1");
    std::error_code ec;
    fs::remove(paths.systemd_dir / "hidmi.service", ec);
    fs::remove(paths.systemd_dir / "hidmi-gadget.service", ec);
    run_system("systemctl daemon-reload >/dev/null 2>&1");
    out << "Retained runtime copy: " << paths.install_root << "\n";
    out << "Retained token file: " << paths.token_path() << "\n";
    return 0;
}

std::string render_hidmi_service(const InstallPaths& paths) {
    return "[Unit]\n"
           "Description=HIDMI KVM TCP/UDP daemon\n"
           "After=network-online.target hidmi-gadget.service\n"
           "Wants=network-online.target hidmi-gadget.service\n"
           "Requires=hidmi-gadget.service\n\n"
           "[Service]\n"
           "Type=simple\n"
           "WorkingDirectory=" + paths.install_root.string() + "\n"
           "ExecStart=" + paths.system_binary.string() + " daemon --config " + paths.installed_config_path().string() + "\n"
           "Restart=on-failure\n"
           "RestartSec=2\n"
           "User=root\n\n"
           "[Install]\n"
           "WantedBy=multi-user.target\n";
}

std::string render_gadget_service(const InstallPaths& paths) {
    return "[Unit]\n"
           "Description=Configure USB HID Gadget for HIDMI KVM\n"
           "DefaultDependencies=no\n"
           "After=local-fs.target\n"
           "Before=hidmi.service\n\n"
           "[Service]\n"
           "Type=oneshot\n"
           "ExecStart=" + paths.system_binary.string() + " gadget-setup --config " + paths.installed_config_path().string() + "\n"
           "ExecStop=" + paths.system_binary.string() + " gadget-teardown --config " + paths.installed_config_path().string() + "\n"
           "RemainAfterExit=yes\n\n"
           "[Install]\n"
           "WantedBy=multi-user.target\n";
}

}  // namespace hidmi
