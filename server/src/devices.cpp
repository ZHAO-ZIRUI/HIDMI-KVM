#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

namespace {

constexpr double kNetworkErrorBlinkDurationSec = 5.0;
constexpr double kShortFlashOnSec = 0.12;
constexpr double kShortFlashOffSec = 0.12;
constexpr auto kAbsoluteMouseRetryInterval = std::chrono::seconds(3);

void write_hid_report(int fd, const std::vector<std::uint8_t>& report, int timeout_ms, const std::string& context) {
    try {
        write_fd_all(fd, report, timeout_ms);
    } catch (const std::exception& exc) {
        throw std::runtime_error(context + ": " + exc.what());
    }
}

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
    write_hid_report(keyboard_fd_, report, timeout_ms, "keyboard HID write failed");
}

void HidWriter::write_mouse_report(int buttons, int dx, int dy, int wheel, int timeout_ms) {
    if (mouse_fd_ < 0) throw std::runtime_error("mouse HID device is not open");
    if (buttons < 0 || buttons > 0x07) throw std::runtime_error("buttons must be 0..7");
    for (int value : {dx, dy, wheel}) {
        if (value < -127 || value > 127) throw std::runtime_error("mouse movement values must be -127..127");
    }
    write_hid_report(
        mouse_fd_,
        {static_cast<std::uint8_t>(buttons), static_cast<std::uint8_t>(dx), static_cast<std::uint8_t>(dy), static_cast<std::uint8_t>(wheel)},
        timeout_ms,
        "mouse HID write failed"
    );
}

void HidWriter::write_absolute_mouse_report(int buttons, int x, int y, int timeout_ms) {
    if (absolute_mouse_fd_ < 0) throw std::runtime_error("absolute mouse HID device is not open");
    if (buttons < 0 || buttons > 0x07) throw std::runtime_error("buttons must be 0..7");
    if (x < 0 || x > 32767) throw std::runtime_error("x must be 0..32767");
    if (y < 0 || y > 32767) throw std::runtime_error("y must be 0..32767");
    last_absolute_x_ = x;
    last_absolute_y_ = y;
    write_hid_report(
        absolute_mouse_fd_,
        {static_cast<std::uint8_t>(buttons), static_cast<std::uint8_t>(x), static_cast<std::uint8_t>(x >> 8), static_cast<std::uint8_t>(y), static_cast<std::uint8_t>(y >> 8)},
        timeout_ms,
        "absolute mouse HID write failed"
    );
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
    if (keyboard_fd_ >= 0) write_hid_report(keyboard_fd_, {0, 0, 0, 0, 0, 0, 0, 0}, 250, "keyboard HID release failed");
    if (mouse_fd_ >= 0) write_hid_report(mouse_fd_, {0, 0, 0, 0}, 250, "mouse HID release failed");
    if (absolute_mouse_fd_ >= 0) {
        write_hid_report(
            absolute_mouse_fd_,
            {0, static_cast<std::uint8_t>(last_absolute_x_), static_cast<std::uint8_t>(last_absolute_x_ >> 8), static_cast<std::uint8_t>(last_absolute_y_), static_cast<std::uint8_t>(last_absolute_y_ >> 8)},
            250,
            "absolute mouse HID release failed"
        );
    }
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
      tick_(tick),
      clock_(std::move(clock)) {
    (void)pulse_sec;
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
    set_network_state(active ? NetworkLedState::Active : NetworkLedState::Idle);
}

void LedController::set_network_state(NetworkLedState state) {
    std::lock_guard<std::mutex> lock(mutex_);
    network_state_ = state;
    if (state != NetworkLedState::Other) {
        network_other_until_ = 0.0;
        last_network_error_.clear();
    }
    cv_.notify_all();
}

void LedController::set_hid_state(HidLedState state, const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    hid_state_ = state;
    last_hid_error_ = reason;
    cv_.notify_all();
}

void LedController::latch_protocol_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    network_state_ = NetworkLedState::Other;
    network_other_until_ = clock_() + kNetworkErrorBlinkDurationSec;
    last_network_error_ = reason;
    cv_.notify_all();
}

void LedController::latch_auth_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    network_state_ = NetworkLedState::Other;
    network_other_until_ = clock_() + kNetworkErrorBlinkDurationSec;
    last_network_error_ = reason;
    cv_.notify_all();
}

void LedController::latch_hid_error(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    hid_state_ = HidLedState::WriteFailed;
    last_hid_error_ = reason;
    cv_.notify_all();
}

void LedController::clear_hid_error() {
    std::lock_guard<std::mutex> lock(mutex_);
    hid_state_ = HidLedState::Ready;
    last_hid_error_.clear();
    cv_.notify_all();
}

void LedController::clear_errors() {
    std::lock_guard<std::mutex> lock(mutex_);
    network_state_ = NetworkLedState::Idle;
    hid_state_ = HidLedState::Ready;
    network_other_until_ = 0.0;
    last_network_error_.clear();
    last_hid_error_.clear();
    cv_.notify_all();
}

void LedController::notify_input_received() {
    // Input receipt no longer drives LED state.
}

void LedController::notify_hid_event_sent(bool hold_active) {
    (void)hold_active;
    // Successful input no longer pulses or holds the S LED.
}

std::pair<bool, bool> LedController::render_once(std::optional<double> now_value) {
    double now = now_value.value_or(clock_());
    NetworkLedState network_state;
    HidLedState hid_state;
    double network_other_until;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        network_state = network_state_;
        hid_state = hid_state_;
        network_other_until = network_other_until_;
    }
    if (network_state == NetworkLedState::Other && network_other_until > 0.0 && now >= network_other_until) {
        network_state = NetworkLedState::Idle;
    }

    bool primary_on = false;
    if (network_state == NetworkLedState::Active) {
        primary_on = true;
    } else if (network_state == NetworkLedState::Other) {
        primary_on = short_blink_on(now);
    } else {
        primary_on = idle_primary_on(now);
    }

    if (hid_state != HidLedState::GadgetUnavailable && !usb_configured()) {
        hid_state = HidLedState::UsbNotConfigured;
    }
    bool secondary_on = multi_flash_on(now, hid_flash_count(hid_state));
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

bool LedController::short_blink_on(double now) const {
    constexpr double cycle = kShortFlashOnSec + kShortFlashOffSec;
    double elapsed = std::fmod(now - started_at_, cycle);
    if (elapsed < 0) elapsed += cycle;
    return elapsed < kShortFlashOnSec;
}

bool LedController::idle_primary_on(double now) const {
    return multi_flash_on(now, 3);
}

bool LedController::multi_flash_on(double now, int count) const {
    if (count <= 0) return false;
    double interval = blink_sec_ > 0.0 ? blink_sec_ : 2.0;
    double active_span = kShortFlashOnSec * count + kShortFlashOffSec * std::max(0, count - 1);
    double cycle = active_span + interval;
    double elapsed = std::fmod(now - started_at_, cycle);
    if (elapsed < 0) elapsed += cycle;
    for (int index = 0; index < count; ++index) {
        double start = index * (kShortFlashOnSec + kShortFlashOffSec);
        if (elapsed >= start && elapsed < start + kShortFlashOnSec) return true;
    }
    return false;
}

int LedController::hid_flash_count(HidLedState state) const {
    switch (state) {
    case HidLedState::Ready:
        return 0;
    case HidLedState::UsbNotConfigured:
        return 1;
    case HidLedState::NodeUnavailable:
        return 2;
    case HidLedState::WriteFailed:
        return 3;
    case HidLedState::GadgetUnavailable:
        return 4;
    case HidLedState::AbsoluteDegraded:
        return 5;
    }
    return 0;
}

bool LedController::usb_configured() const {
    try {
        return trim(read_file(udc_state_path_)) == "configured";
    } catch (...) {
        return false;
    }
}

}  // namespace hidmi
