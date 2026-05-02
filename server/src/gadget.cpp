#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

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

std::string first_udc() {
    DIR* dir = ::opendir("/sys/class/udc");
    if (!dir) throw std::runtime_error("no UDC found under /sys/class/udc");
    std::vector<std::string> names;
    while (auto* entry = ::readdir(dir)) {
        std::string name = entry->d_name;
        if (name != "." && name != "..") names.push_back(name);
    }
    ::closedir(dir);
    std::sort(names.begin(), names.end());
    if (names.empty()) throw std::runtime_error("no UDC found under /sys/class/udc");
    return names.front();
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

}  // namespace

void gadget_setup() {
    run_system("modprobe libcomposite >/dev/null 2>&1");
    if (!fs::exists("/sys/kernel/config/usb_gadget")) {
        run_system("mount -t configfs none /sys/kernel/config");
    }
    fs::path root = "/sys/kernel/config/usb_gadget/hidmi";
    remove_gadget(root);
    remove_gadget("/sys/kernel/config/usb_gadget/hid_bridge");
    std::string udc = first_udc();
    fs::create_directories(root);
    write_file(root / "idVendor", "0x1d6b\n");
    write_file(root / "idProduct", "0x0104\n");
    write_file(root / "bcdDevice", "0x0100\n");
    write_file(root / "bcdUSB", "0x0200\n");
    write_file(root / "strings/0x409/serialnumber", "HIDMI-HID-001\n");
    write_file(root / "strings/0x409/manufacturer", "HIDMI\n");
    write_file(root / "strings/0x409/product", "HIDMI KVM HID Emulator\n");
    write_file(root / "configs/c.1/strings/0x409/configuration", "HIDMI KVM HID Config\n");
    write_file(root / "configs/c.1/MaxPower", "500\n");
    configure_hid_function(root / "functions/hid.kbd", 1, 1, 8, kKeyboardDescriptor);
    configure_hid_function(root / "functions/hid.mouse", 2, 1, 4, kMouseDescriptor);
    configure_hid_function(root / "functions/hid.abs", 0, 0, 5, kAbsoluteMouseDescriptor);
    for (const auto& function : {"hid.kbd", "hid.mouse", "hid.abs"}) {
        fs::path link = root / "configs/c.1" / function;
        std::error_code ec;
        fs::remove(link, ec);
        fs::create_directory_symlink(root / "functions" / function, link);
    }
    write_file(root / "UDC", udc + "\n");
    std::cout << "OK: gadget bound to " << udc << "\n";
}

void release_all(const ServerConfig& config) {
    write_bytes_if_exists(config.hid.keyboard_path, {0,0,0,0,0,0,0,0});
    write_bytes_if_exists(config.hid.mouse_path, {0,0,0,0});
    if (!config.hid.absolute_mouse_path.empty()) write_bytes_if_exists(config.hid.absolute_mouse_path, {0,0,0x40,0,0x40});
}

void gadget_teardown(const ServerConfig& config) {
    release_all(config);
    fs::path root = "/sys/kernel/config/usb_gadget/hidmi";
    if (!fs::exists(root)) {
        std::cout << "OK: gadget does not exist\n";
        return;
    }
    remove_gadget(root);
    std::cout << "OK: gadget removed\n";
}

}  // namespace hidmi
