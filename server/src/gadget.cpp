#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

constexpr auto kDefaultValidationPoll = std::chrono::milliseconds(100);

void write_bytes_if_exists(const std::string& path, const std::vector<std::uint8_t>& bytes) {
    if (path.empty() || !path_exists(path)) return;
    int fd = ::open(path.c_str(), O_WRONLY);
    if (fd < 0) return;
    try { write_fd_all(fd, bytes); } catch (...) {}
    ::close(fd);
}

void remove_symlinks(const fs::path& root) {
    std::error_code ec;
    if (!fs::exists(root, ec)) return;
    for (auto it = fs::recursive_directory_iterator(root, fs::directory_options::skip_permission_denied, ec); it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_symlink(ec)) {
            fs::remove(it->path(), ec);
        }
    }
}

void remove_gadget(const fs::path& root) {
    std::error_code ec;
    if (!fs::exists(root, ec)) return;
    write_file(root / "UDC", "\n");
    remove_symlinks(root / "configs");
    for (const auto& relative : {
             "configs/c.1/strings/0x409", "configs/c.1/strings", "configs/c.1", "configs",
             "functions/hid.abs", "functions/hid.mouse", "functions/hid.kbd", "functions",
             "strings/0x409", "strings", "os_desc", ""}) {
        fs::remove(root / relative, ec);
    }
}

std::string first_udc(const fs::path& udc_root) {
    DIR* dir = ::opendir(udc_root.c_str());
    if (!dir) throw std::runtime_error("no UDC found under " + udc_root.string());
    std::vector<std::string> names;
    while (auto* entry = ::readdir(dir)) {
        std::string name = entry->d_name;
        if (name != "." && name != "..") names.push_back(name);
    }
    ::closedir(dir);
    std::sort(names.begin(), names.end());
    if (names.empty()) throw std::runtime_error("no UDC found under " + udc_root.string());
    return names.front();
}

bool using_default_configfs(const GadgetSetupPaths& paths) {
    return paths.configfs_root == fs::path("/sys/kernel/config");
}

std::string read_udc_state(const ServerConfig& config) {
    try {
        return trim(read_file(config.hid.udc_state_path));
    } catch (const std::exception& exc) {
        return std::string("unreadable: ") + exc.what();
    }
}

std::string probe_hid_write(const std::string& path, const std::vector<std::uint8_t>& report) {
    if (path.empty()) return "path is not configured";
    int fd = ::open(path.c_str(), O_WRONLY | O_NONBLOCK);
    if (fd < 0) return std::strerror(errno);
    try {
        write_fd_all(fd, report, 100);
        ::close(fd);
        return {};
    } catch (const std::exception& exc) {
        ::close(fd);
        return exc.what();
    }
}

void write_descriptor(const fs::path& path, const std::vector<std::uint8_t>& bytes) {
    fs::create_directories(path.parent_path());
    int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) throw std::runtime_error("failed to write " + path.string());
    try {
        write_fd_all(fd, bytes);
        ::close(fd);
    } catch (...) {
        ::close(fd);
        throw;
    }
}

void configure_hid_function(const fs::path& path, int protocol, int subclass, int report_length, const std::vector<std::uint8_t>& descriptor) {
    fs::create_directories(path);
    write_file(path / "protocol", std::to_string(protocol) + "\n");
    write_file(path / "subclass", std::to_string(subclass) + "\n");
    write_file(path / "report_length", std::to_string(report_length) + "\n");
    write_descriptor(path / "report_desc", descriptor);
    try { write_file(path / "no_out_endpoint", "1\n"); } catch (...) {}
}

const std::vector<std::uint8_t> kKeyboardDescriptor = {
    0x05,0x01,0x09,0x06,0xa1,0x01,0x05,0x07,0x19,0xe0,0x29,0xe7,0x15,0x00,0x25,0x01,
    0x75,0x01,0x95,0x08,0x81,0x02,0x95,0x01,0x75,0x08,0x81,0x03,0x95,0x05,0x75,0x01,
    0x05,0x08,0x19,0x01,0x29,0x05,0x91,0x02,0x95,0x01,0x75,0x03,0x91,0x03,0x95,0x06,
    0x75,0x08,0x15,0x00,0x25,0x65,0x05,0x07,0x19,0x00,0x29,0x65,0x81,0x00,0xc0};
const std::vector<std::uint8_t> kMouseDescriptor = {
    0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,0xa1,0x00,0x05,0x09,0x19,0x01,0x29,0x03,
    0x15,0x00,0x25,0x01,0x95,0x03,0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x05,0x81,0x03,
    0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x03,
    0x81,0x06,0xc0,0xc0};
const std::vector<std::uint8_t> kAbsoluteMouseDescriptor = {
    0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,0xa1,0x00,0x05,0x09,0x19,0x01,0x29,0x03,
    0x15,0x00,0x25,0x01,0x95,0x03,0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x05,0x81,0x03,
    0x05,0x01,0x09,0x30,0x09,0x31,0x16,0x00,0x00,0x26,0xff,0x7f,0x35,0x00,0x46,0xff,
    0x7f,0x75,0x10,0x95,0x02,0x81,0x02,0xc0,0xc0};

GadgetValidationResult validate_once(const ServerConfig& config) {
    GadgetValidationResult result;
    result.keyboard_error = probe_hid_write(config.hid.keyboard_path, {0,0,0,0,0,0,0,0});
    result.mouse_error = probe_hid_write(config.hid.mouse_path, {0,0,0,0});
    result.keyboard_ready = result.keyboard_error.empty();
    result.mouse_ready = result.mouse_error.empty();
    result.mandatory_ready = result.keyboard_ready && result.mouse_ready;
    if (!config.hid.absolute_mouse_path.empty()) {
        result.absolute_error = probe_hid_write(config.hid.absolute_mouse_path, {0,0,0x40,0,0x40});
        result.absolute_ready = result.absolute_error.empty();
        result.absolute_degraded = !result.absolute_ready;
    }
    return result;
}

std::string validation_error_summary(const GadgetValidationResult& result) {
    std::vector<std::string> parts;
    if (!result.keyboard_ready) parts.push_back("keyboard: " + result.keyboard_error);
    if (!result.mouse_ready) parts.push_back("mouse: " + result.mouse_error);
    if (parts.empty()) return "unknown";
    std::string out;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        if (i) out += "; ";
        out += parts[i];
    }
    return out;
}

GadgetValidationResult setup_once(
    const ServerConfig& config,
    const GadgetSetupPaths& paths,
    std::chrono::milliseconds validation_timeout) {
    run_system("modprobe libcomposite >/dev/null 2>&1");
    if (using_default_configfs(paths) && !fs::exists(paths.configfs_root / "usb_gadget")) {
        run_system("mount -t configfs none /sys/kernel/config");
    }
    remove_gadget(paths.gadget_root);
    remove_gadget(paths.legacy_gadget_root);
    std::string udc = first_udc(paths.udc_root);
    fs::create_directories(paths.gadget_root);
    write_file(paths.gadget_root / "idVendor", "0x1d6b\n");
    write_file(paths.gadget_root / "idProduct", "0x0104\n");
    write_file(paths.gadget_root / "bcdDevice", "0x0100\n");
    write_file(paths.gadget_root / "bcdUSB", "0x0200\n");
    write_file(paths.gadget_root / "strings/0x409/serialnumber", "HIDMI-HID-001\n");
    write_file(paths.gadget_root / "strings/0x409/manufacturer", "HIDMI\n");
    write_file(paths.gadget_root / "strings/0x409/product", "HIDMI KVM HID Emulator\n");
    write_file(paths.gadget_root / "configs/c.1/strings/0x409/configuration", "HIDMI KVM HID Config\n");
    write_file(paths.gadget_root / "configs/c.1/MaxPower", "500\n");
    configure_hid_function(paths.gadget_root / "functions/hid.kbd", 1, 1, 8, kKeyboardDescriptor);
    configure_hid_function(paths.gadget_root / "functions/hid.mouse", 2, 1, 4, kMouseDescriptor);
    configure_hid_function(paths.gadget_root / "functions/hid.abs", 0, 0, 5, kAbsoluteMouseDescriptor);
    for (const auto& function : {"hid.kbd", "hid.mouse", "hid.abs"}) {
        fs::path link = paths.gadget_root / "configs/c.1" / function;
        std::error_code ec;
        fs::remove(link, ec);
        fs::create_directory_symlink(paths.gadget_root / "functions" / function, link);
    }
    write_file(paths.gadget_root / "UDC", udc + "\n");
    std::cout << "OK: gadget bound to " << udc << "\n";

    std::string udc_state = read_udc_state(config);
    if (udc_state != "configured") {
        std::cerr << "WARNING: UDC is not configured after binding: " << udc_state << "\n";
    }

    GadgetValidationResult validation = validate_gadget_hid_devices(config, validation_timeout, kDefaultValidationPoll);
    if (!validation.mandatory_ready) {
        throw std::runtime_error("HID gadget validation failed: " + validation_error_summary(validation));
    }
    if (validation.absolute_degraded) {
        std::cerr << "WARNING: absolute HID is degraded: " << validation.absolute_error << "\n";
    }
    return validation;
}

}  // namespace

GadgetValidationResult validate_gadget_hid_devices(
    const ServerConfig& config,
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds poll_interval) {
    auto deadline = std::chrono::steady_clock::now() + timeout;
    GadgetValidationResult last = validate_once(config);
    while (!last.mandatory_ready && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(poll_interval);
        last = validate_once(config);
    }
    return last;
}

GadgetValidationResult gadget_setup(
    const ServerConfig& config,
    const GadgetSetupPaths& paths,
    std::chrono::milliseconds validation_timeout) {
    try {
        return setup_once(config, paths, validation_timeout);
    } catch (const std::exception& first) {
        std::cerr << "WARNING: gadget setup failed; rebuilding once: " << first.what() << "\n";
        try {
            remove_gadget(paths.gadget_root);
        } catch (const std::exception& exc) {
            std::cerr << "WARNING: failed to remove gadget before retry: " << exc.what() << "\n";
        }
        return setup_once(config, paths, validation_timeout);
    }
}

GadgetValidationResult gadget_setup() {
    return gadget_setup(ServerConfig{});
}

void release_all(const ServerConfig& config) {
    write_bytes_if_exists(config.hid.keyboard_path, {0,0,0,0,0,0,0,0});
    write_bytes_if_exists(config.hid.mouse_path, {0,0,0,0});
    if (!config.hid.absolute_mouse_path.empty()) write_bytes_if_exists(config.hid.absolute_mouse_path, {0,0,0x40,0,0x40});
}

void gadget_teardown(const ServerConfig& config, const GadgetSetupPaths& paths) {
    release_all(config);
    if (!fs::exists(paths.gadget_root)) {
        std::cout << "OK: gadget does not exist\n";
        return;
    }
    remove_gadget(paths.gadget_root);
    std::cout << "OK: gadget removed\n";
}

}  // namespace hidmi
