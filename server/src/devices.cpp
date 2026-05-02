#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

constexpr double kAuthErrorBlinkDurationSec = 5.0;
constexpr double kAuthErrorBlinkCadenceSec = 0.20;
constexpr double kAuthErrorBlinkOnSec = 0.10;
constexpr auto kAbsoluteMouseRetryInterval = std::chrono::seconds(3);

}  // namespace

HidWriter::HidWriter(std::string keyboard_path, std::string mouse_path, std::string absolute_mouse_path)
    : keyboard_path_(std::move(keyboard_path)), mouse_path_(std::move(mouse_path)), absolute_mouse_path_(std::move(absolute_mouse_path)) {}

HidWriter::~HidWriter() {
    try { close(); } catch (...) {}
}

void HidWriter::open() {
    close_without_release();
    try {
        keyboard_fd_ = ::open(keyboard_path_.c_str(), O_WRONLY | O_NONBLOCK);
        if (keyboard_fd_ < 0) throw std::runtime_error("open keyboard HID: " + std::string(std::strerror(errno)));
        mouse_fd_ = ::open(mouse_path_.c_str(), O_WRONLY | O_NONBLOCK);
        if (mouse_fd_ < 0) throw std::runtime_error("open mouse HID: " + std::string(std::strerror(errno)));
        try_reopen_absolute(true);
    } catch (...) {
        close_without_release();
        throw;
    }
}

void HidWriter::close() {
    std::exception_ptr release_error;
    try {
        release_all();
    } catch (...) {
        release_error = std::current_exception();
    }
    if (keyboard_fd_ >= 0) { ::close(keyboard_fd_); keyboard_fd_ = -1; }
    if (mouse_fd_ >= 0) { ::close(mouse_fd_); mouse_fd_ = -1; }
    if (absolute_mouse_fd_ >= 0) { ::close(absolute_mouse_fd_); absolute_mouse_fd_ = -1; }
    if (release_error) std::rethrow_exception(release_error);
}

void HidWriter::close_without_release() noexcept {
    if (keyboard_fd_ >= 0) { ::close(keyboard_fd_); keyboard_fd_ = -1; }
    if (mouse_fd_ >= 0) { ::close(mouse_fd_); mouse_fd_ = -1; }
    close_absolute_mouse();
}

bool HidWriter::keyboard_available() const {
    return keyboard_fd_ >= 0;
}

bool HidWriter::relative_mouse_available() const {
    return mouse_fd_ >= 0;
}

bool HidWriter::absolute_mouse_available() const {
    return absolute_mouse_fd_ >= 0;
}

bool HidWriter::mandatory_available() const {
    return keyboard_available() && relative_mouse_available();
}

bool HidWriter::absolute_mouse_degraded() const {
    return !absolute_mouse_path_.empty() && absolute_mouse_fd_ < 0;
}

const std::string& HidWriter::last_absolute_error() const {
    return last_absolute_error_;
}

bool HidWriter::try_reopen_absolute(bool force) {
    if (absolute_mouse_fd_ >= 0) return true;
    if (absolute_mouse_path_.empty()) {
        last_absolute_error_.clear();
        return false;
    }
    auto now = std::chrono::steady_clock::now();
    if (!force && next_absolute_retry_at_ != std::chrono::steady_clock::time_point{} && now < next_absolute_retry_at_) {
        return false;
    }
    int fd = ::open(absolute_mouse_path_.c_str(), O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        remember_absolute_error("open absolute mouse HID: " + std::string(std::strerror(errno)));
        return false;
    }
    absolute_mouse_fd_ = fd;
    last_absolute_error_.clear();
    next_absolute_retry_at_ = {};
    return true;
}

void HidWriter::write_keyboard_report(int modifiers, const std::vector<int>& keys, int timeout_ms) {
    if (keyboard_fd_ < 0) throw std::runtime_error("keyboard HID device is not open");
    if (modifiers < 0 || modifiers > 0xff) throw std::runtime_error("modifiers must be 0..255");
    if (keys.size() > 6) throw std::runtime_error("at most 6 simultaneous key usages are supported");
    std::vector<std::uint8_t> report = {static_cast<std::uint8_t>(modifiers), 0, 0, 0, 0, 0, 0, 0};
    for (std::size_t i = 0; i < keys.size(); ++i) {
        if (keys[i] < 0 || keys[i] > 0xff) throw std::runtime_error("key usage must be 0..255");
        report[i + 2] = static_cast<std::uint8_t>(keys[i]);
    }
    write_fd_all(keyboard_fd_, report, timeout_ms);
}

void HidWriter::write_mouse_report(int buttons, int dx, int dy, int wheel, int timeout_ms) {
    if (mouse_fd_ < 0) throw std::runtime_error("mouse HID device is not open");
    if (buttons < 0 || buttons > 0x07) throw std::runtime_error("buttons must be 0..7");
    for (int value : {dx, dy, wheel}) {
        if (value < -127 || value > 127) throw std::runtime_error("mouse movement values must be -127..127");
    }
    write_fd_all(mouse_fd_, {static_cast<std::uint8_t>(buttons), static_cast<std::uint8_t>(dx), static_cast<std::uint8_t>(dy), static_cast<std::uint8_t>(wheel)}, timeout_ms);
}

void HidWriter::write_absolute_mouse_report(int buttons, int x, int y, int timeout_ms) {
    if (absolute_mouse_fd_ < 0) throw std::runtime_error("absolute mouse HID device is not open");
    if (buttons < 0 || buttons > 0x07) throw std::runtime_error("buttons must be 0..7");
    if (x < 0 || x > 32767) throw std::runtime_error("x must be 0..32767");
    if (y < 0 || y > 32767) throw std::runtime_error("y must be 0..32767");
    last_absolute_x_ = x;
    last_absolute_y_ = y;
    write_fd_all(absolute_mouse_fd_, {static_cast<std::uint8_t>(buttons), static_cast<std::uint8_t>(x), static_cast<std::uint8_t>(x >> 8), static_cast<std::uint8_t>(y), static_cast<std::uint8_t>(y >> 8)}, timeout_ms);
}

void HidWriter::write_pointer_report(int buttons, int x, int y, int dx, int dy, int wheel, bool reliable_edge, int timeout_ms) {
    if (buttons < 0 || buttons > 0x07) throw std::runtime_error("buttons must be 0..7");
    dx = clamp_relative_value(dx);
    dy = clamp_relative_value(dy);
    wheel = clamp_relative_value(wheel);

    bool wrote_absolute = false;
    if (try_reopen_absolute(false)) {
        try {
            write_absolute_mouse_report(buttons, x, y, timeout_ms);
            wrote_absolute = true;
        } catch (const std::exception& exc) {
            close_absolute_mouse();
            remember_absolute_error(std::string("absolute mouse write failed: ") + exc.what());
        }
    }

    if (!wrote_absolute) {
        if (reliable_edge || dx != 0 || dy != 0 || wheel != 0) {
            write_mouse_report(buttons, dx, dy, wheel, timeout_ms);
        }
        return;
    }

    if (wheel != 0) {
        write_mouse_report(buttons, 0, 0, wheel, timeout_ms);
    }
}

void HidWriter::release_all() {
    if (keyboard_fd_ >= 0) write_fd_all(keyboard_fd_, {0, 0, 0, 0, 0, 0, 0, 0});
    if (mouse_fd_ >= 0) write_fd_all(mouse_fd_, {0, 0, 0, 0});
    if (absolute_mouse_fd_ >= 0) write_fd_all(absolute_mouse_fd_, {0, static_cast<std::uint8_t>(last_absolute_x_), static_cast<std::uint8_t>(last_absolute_x_ >> 8), static_cast<std::uint8_t>(last_absolute_y_), static_cast<std::uint8_t>(last_absolute_y_ >> 8)});
}

void HidWriter::close_absolute_mouse() noexcept {
    if (absolute_mouse_fd_ >= 0) {
        ::close(absolute_mouse_fd_);
        absolute_mouse_fd_ = -1;
    }
}

void HidWriter::remember_absolute_error(const std::string& reason) {
    last_absolute_error_ = reason;
    next_absolute_retry_at_ = std::chrono::steady_clock::now() + kAbsoluteMouseRetryInterval;
}

int HidWriter::clamp_relative_value(int value) const {
    return std::max(-127, std::min(127, value));
}

struct LedController::SysfsLed {
    fs::path path;
    std::string name;
    fs::path brightness_path;
    fs::path trigger_path;
    std::string original_brightness;
    std::string original_trigger;
    bool available = false;
    bool prepared = false;
    bool warned = false;

    SysfsLed(std::string led_path, std::string led_name) : path(std::move(led_path)), name(std::move(led_name)) {
        if (!path.empty()) {
            brightness_path = path / "brightness";
            trigger_path = path / "trigger";
        }
    }
    void warn(const std::string& message) {
        if (!warned) {
            std::cerr << "WARNING: " << name << " LED unavailable at " << (path.empty() ? "<not configured>" : path.string()) << ": " << message << "\n";
            warned = true;
        }
    }
    void prepare() {
        if (brightness_path.empty()) { warn("path is not configured"); return; }
        if (!path_exists(brightness_path)) { warn("brightness file is missing"); return; }
        try {
            original_brightness = trim(read_file(brightness_path));
        } catch (const std::exception& exc) {
            warn(std::string("failed to read brightness: ") + exc.what());
            return;
        }
        if (path_exists(trigger_path)) {
            try {
                original_trigger = active_trigger(trim(read_file(trigger_path)));
                write_file(trigger_path, "none\n");
            } catch (const std::exception& exc) {
                warn(std::string("failed to set trigger: ") + exc.what());
            }
        }
        available = true;
        prepared = true;
    }
    void set_on(bool on) {
        if (!available) return;
        try {
            write_file(brightness_path, on ? "1\n" : "0\n");
        } catch (const std::exception& exc) {
            available = false;
            warn(std::string("failed to write brightness: ") + exc.what());
        }
    }
    void restore() {
        if (!prepared) return;
        try {
            if (!original_brightness.empty()) write_file(brightness_path, original_brightness + "\n");
        } catch (const std::exception& exc) {
            warn(std::string("failed to restore brightness: ") + exc.what());
        }
        try {
            if (!original_trigger.empty() && path_exists(trigger_path)) write_file(trigger_path, original_trigger + "\n");
        } catch (const std::exception& exc) {
            warn(std::string("failed to restore trigger: ") + exc.what());
        }
    }
};

LedController::LedController(std::string primary_path, std::string secondary_path, std::string udc_state_path, double blink_sec, double pulse_sec, std::chrono::milliseconds tick, Clock clock)
    : primary_(std::make_unique<SysfsLed>(std::move(primary_path), "primary")),
      secondary_(std::make_unique<SysfsLed>(std::move(secondary_path), "secondary")),
      udc_state_path_(std::move(udc_state_path)),
      blink_sec_(blink_sec),
      pulse_sec_(pulse_sec),
      tick_(tick),
      clock_(std::move(clock)) {
    if (!clock_) {
        auto start = std::chrono::steady_clock::now();
        clock_ = [start]() {
            return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        };
    }
}

LedController::~LedController() { stop(); }

void LedController::start(bool start_thread) {
    primary_->prepare();
    secondary_->prepare();
    primary_->set_on(false);
    secondary_->set_on(false);
    started_at_ = clock_();
    if (!start_thread || thread_.joinable()) return;
    stop_requested_ = false;
    thread_ = std::thread([this] { run(); });
}

void LedController::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_requested_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    primary_->restore();
    secondary_->restore();
}

void LedController::set_active_client(bool active) {
    std::lock_guard<std::mutex> lock(mutex_);
    active_client_ = active;
    if (active) {
        auth_error_until_ = 0.0;
        last_auth_error_.clear();
    }
    cv_.notify_all();
}

void LedController::latch_protocol_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    protocol_error_latched_ = true;
    last_protocol_error_ = reason;
    cv_.notify_all();
}

void LedController::latch_auth_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now = clock_();
    auth_error_started_at_ = now;
    auth_error_until_ = now + kAuthErrorBlinkDurationSec;
    last_auth_error_ = reason;
    cv_.notify_all();
}

void LedController::latch_hid_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    hid_error_latched_ = true;
    last_hid_error_ = reason;
    cv_.notify_all();
}

void LedController::clear_hid_error() {
    std::lock_guard<std::mutex> lock(mutex_);
    hid_error_latched_ = false;
    last_hid_error_.clear();
    cv_.notify_all();
}

void LedController::clear_errors() {
    std::lock_guard<std::mutex> lock(mutex_);
    protocol_error_latched_ = false;
    hid_error_latched_ = false;
    auth_error_until_ = 0.0;
    last_protocol_error_.clear();
    last_auth_error_.clear();
    last_hid_error_.clear();
    cv_.notify_all();
}

void LedController::notify_input_received() {
    // Input receipt does not drive LED state; S lights only after a HID event is sent.
}

void LedController::notify_hid_event_sent(bool hold_active) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now = clock_();
    secondary_hold_active_ = hold_active;
    secondary_pulse_until_ = now + pulse_sec_;
    cv_.notify_all();
}

std::pair<bool, bool> LedController::render_once(std::optional<double> now_value) {
    double now = now_value.value_or(clock_());
    bool active, protocol_error, hid_error;
    bool secondary_hold_active;
    double auth_error_started_at, auth_error_until, secondary_pulse_until;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        active = active_client_;
        protocol_error = protocol_error_latched_;
        hid_error = hid_error_latched_;
        secondary_hold_active = secondary_hold_active_;
        auth_error_started_at = auth_error_started_at_;
        auth_error_until = auth_error_until_;
        secondary_pulse_until = secondary_pulse_until_;
    }
    bool primary_on;
    bool secondary_on;
    if (protocol_error) {
        primary_on = protocol_blink_on(now);
        secondary_on = primary_on;
    } else {
        primary_on = active ? true : idle_primary_on(now);
        if (now < auth_error_until) {
            secondary_on = auth_error_blink_on(now, auth_error_started_at);
        } else if (hid_error || !usb_configured()) {
            secondary_on = true;
        } else if (secondary_hold_active) {
            secondary_on = true;
        } else if (now < secondary_pulse_until) {
            secondary_on = true;
        } else {
            secondary_on = false;
        }
    }
    primary_->set_on(primary_on);
    secondary_->set_on(secondary_on);
    return {primary_on, secondary_on};
}

void LedController::run() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!stop_requested_) {
        cv_.wait_for(lock, tick_);
        if (!stop_requested_) {
            lock.unlock();
            render_once();
            lock.lock();
        }
    }
}

bool LedController::protocol_blink_on(double now) const {
    if (blink_sec_ <= 0) return true;
    double elapsed = std::fmod(now - started_at_, blink_sec_);
    if (elapsed < 0) elapsed += blink_sec_;
    return elapsed < blink_sec_ / 2.0;
}

bool LedController::auth_error_blink_on(double now, double auth_error_started_at) const {
    double elapsed = std::fmod(now - auth_error_started_at, kAuthErrorBlinkCadenceSec);
    if (elapsed < 0) elapsed += kAuthErrorBlinkCadenceSec;
    return elapsed < kAuthErrorBlinkOnSec;
}

bool LedController::idle_primary_on(double now) const {
    constexpr double short_on = 0.12;
    constexpr double short_off = 0.12;
    constexpr double interval = 2.0;
    constexpr double cycle = short_on * 3 + short_off * 2 + interval;
    double elapsed = std::fmod(now - started_at_, cycle);
    if (elapsed < 0) elapsed += cycle;
    return elapsed < short_on ||
           (elapsed >= short_on + short_off && elapsed < short_on * 2 + short_off) ||
           (elapsed >= short_on * 2 + short_off * 2 && elapsed < short_on * 3 + short_off * 2);
}

bool LedController::usb_configured() const {
    try {
        return trim(read_file(udc_state_path_)) == "configured";
    } catch (...) {
        return false;
    }
}

}  // namespace hidmi
