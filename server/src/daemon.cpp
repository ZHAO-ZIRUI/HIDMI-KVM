#include "hidmi_internal.hpp"
#include "msg_tcp_frame.pb.h"
#include "msg_udp_packet.pb.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/tcp.h>

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;
namespace pb = hidmi::kvm::input::v1;

struct Daemon::PendingSession {
    std::string session_id;
    std::uint64_t session_id_value = 0;
    std::uint64_t server_id = 0;
    std::uint64_t boot_id = 0;
    std::string challenge_nonce;
    std::uint64_t client_id_value = 0;
    std::string client_nonce_bytes;
    std::string offer_auth_mac;
    ChannelEndpoint control;
    ChannelEndpoint mouse;
    ChannelEndpoint keyboard;
    std::chrono::steady_clock::time_point expires_at;
    std::chrono::steady_clock::time_point last_activity;
    std::string disconnect_reason;
    bool cleanup_requested = false;
    bool active = false;
    std::uint32_t last_keyboard_seq = 0;
};

namespace {

constexpr auto kHidRetryInterval = std::chrono::seconds(3);
constexpr auto kHidFailureWindow = std::chrono::seconds(30);
constexpr auto kGadgetResetCooldown = std::chrono::seconds(30);
constexpr int kHidFailureResetThreshold = 2;
constexpr std::uint32_t kMaxTcpFrameBytes = 64 * 1024;

struct SocketReadTimeout : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct SocketPeerClosed : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct BroadcastInterface {
    std::string name;
    sockaddr_in broadcast_addr{};
    in_addr source_addr{};
    unsigned int if_index = 0;
    pb::InterfaceType type = pb::IFACE_UNKNOWN;
};

void close_fd(int& fd) {
    if (fd >= 0) {
        ::close(fd);
        fd = -1;
    }
}

void shutdown_fd(int fd) {
    if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR);
    }
}

std::uint64_t fnv1a64(const std::string& text) {
    std::uint64_t hash = 14695981039346656037ull;
    for (unsigned char byte : text) {
        hash ^= byte;
        hash *= 1099511628211ull;
    }
    return hash == 0 ? 1 : hash;
}

std::uint64_t random_u64() {
    std::random_device rd;
    std::uint64_t value = (static_cast<std::uint64_t>(rd()) << 32) ^ static_cast<std::uint64_t>(rd());
    return value == 0 ? 1 : value;
}

std::string random_bytes(std::size_t count) {
    std::random_device rd;
    std::string out(count, '\0');
    for (char& byte : out) {
        byte = static_cast<char>(rd() & 0xff);
    }
    return out;
}

std::uint64_t monotonic_us() {
    auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now).count());
}

void set_socket_timeout(int fd, double seconds) {
    seconds = std::max(0.1, seconds);
    timeval tv{};
    tv.tv_sec = static_cast<time_t>(seconds);
    tv.tv_usec = static_cast<suseconds_t>((seconds - tv.tv_sec) * 1000000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

void set_tcp_no_delay(int fd) {
    int enabled = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
}

std::string peer_ip_string(const sockaddr_storage& addr) {
    char buffer[INET6_ADDRSTRLEN] = {};
    if (addr.ss_family == AF_INET) {
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(&addr);
        if (::inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer))) {
            return buffer;
        }
    }
#ifdef AF_INET6
    if (addr.ss_family == AF_INET6) {
        const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>(&addr);
        if (::inet_ntop(AF_INET6, &ipv6->sin6_addr, buffer, sizeof(buffer))) {
            return buffer;
        }
    }
#endif
    return "unknown";
}

bool constant_time_equal(const std::string& a, const std::vector<std::uint8_t>& b) {
    if (a.size() != b.size()) return false;
    unsigned char diff = 0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        diff |= static_cast<unsigned char>(static_cast<unsigned char>(a[i]) ^ b[i]);
    }
    return diff == 0;
}

void write_socket_all(int fd, const std::string& data) {
    const char* cursor = data.data();
    std::size_t remaining = data.size();
    while (remaining > 0) {
        int flags = 0;
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        ssize_t written = ::send(fd, cursor, remaining, flags);
        if (written < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error(std::strerror(errno));
        }
        if (written == 0) {
            throw std::runtime_error("socket write returned zero");
        }
        cursor += written;
        remaining -= static_cast<std::size_t>(written);
    }
}

std::string read_exact(int fd, std::size_t count) {
    std::string data(count, '\0');
    std::size_t offset = 0;
    while (offset < count) {
        ssize_t got = ::recv(fd, data.data() + offset, count - offset, 0);
        if (got == 0) throw SocketPeerClosed("connection closed");
        if (got < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) throw SocketReadTimeout("socket read timeout");
            throw std::runtime_error(std::strerror(errno));
        }
        offset += static_cast<std::size_t>(got);
    }
    return data;
}

pb::TcpFrame read_frame(int fd) {
    auto length_data = read_exact(fd, 4);
    auto length = (static_cast<std::uint32_t>(static_cast<unsigned char>(length_data[0])) << 24)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(length_data[1])) << 16)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(length_data[2])) << 8)
        | static_cast<std::uint32_t>(static_cast<unsigned char>(length_data[3]));
    if (length > kMaxTcpFrameBytes) throw ProtocolError("TCP frame too large");
    auto payload = read_exact(fd, length);
    pb::TcpFrame frame;
    if (!frame.ParseFromString(payload)) throw ProtocolError("invalid TCP frame protobuf");
    return frame;
}

void write_frame(int fd, const pb::TcpFrame& frame) {
    std::string payload;
    if (!frame.SerializeToString(&payload)) throw ProtocolError("failed to serialize TCP frame");
    if (payload.size() > kMaxTcpFrameBytes) throw ProtocolError("TCP frame too large");
    std::string data;
    append_be32(data, static_cast<std::uint32_t>(payload.size()));
    data.append(payload);
    write_socket_all(fd, data);
}

template <typename Session>
pb::TcpFrame base_frame(const Session& session, pb::ChannelId channel, std::uint32_t seq = 0) {
    pb::TcpFrame frame;
    frame.set_session_id(session.session_id_value);
    frame.set_channel_id(channel);
    frame.set_seq(seq);
    frame.set_monotonic_us(monotonic_us());
    return frame;
}

template <typename Session>
void send_ack(int fd, const Session& session, pb::ChannelId channel, std::uint32_t target_seq, pb::AckResult result, const std::string& message = "") {
    auto frame = base_frame(session, channel, target_seq);
    auto* ack = frame.mutable_ack();
    ack->set_target_channel_id(channel);
    ack->set_target_seq(target_seq);
    ack->set_result(result);
    ack->set_message(message);
    write_frame(fd, frame);
}

template <typename Session>
void send_error(int fd, const Session& session, pb::ChannelId channel, std::uint32_t related_seq, const std::string& message) {
    auto frame = base_frame(session, channel, related_seq);
    auto* error = frame.mutable_error();
    error->set_err_id(1);
    error->set_severity(pb::ERROR_FATAL);
    error->set_channel_id(channel);
    error->set_related_seq(related_seq);
    error->set_err_msg(normalize_tcp_error_message(message));
    write_frame(fd, frame);
}

int bind_tcp_listener_exact(int port) {
    if (port < kMinTcpPort || port > kMaxTcpPort) throw ProtocolError("invalid TCP port");
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) throw std::runtime_error(std::strerror(errno));
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || ::listen(fd, 1) != 0) {
        int err = errno;
        ::close(fd);
        errno = err;
        throw std::runtime_error(std::strerror(errno));
    }
    return fd;
}

std::vector<BroadcastInterface> enumerate_broadcast_interfaces(int udp_port) {
    std::vector<BroadcastInterface> interfaces;
    ifaddrs* list = nullptr;
    if (::getifaddrs(&list) == 0 && list) {
        std::set<std::pair<std::string, std::uint32_t>> seen;
        for (ifaddrs* item = list; item; item = item->ifa_next) {
            if (!item->ifa_name || !item->ifa_addr || !item->ifa_broadaddr) continue;
            if (item->ifa_addr->sa_family != AF_INET || item->ifa_broadaddr->sa_family != AF_INET) continue;
            auto flags = item->ifa_flags;
            if ((flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 || (flags & IFF_BROADCAST) == 0) continue;

            auto broadcast = *reinterpret_cast<sockaddr_in*>(item->ifa_broadaddr);
            broadcast.sin_port = htons(static_cast<std::uint16_t>(udp_port));
            std::string name(item->ifa_name);
            auto key = std::make_pair(name, broadcast.sin_addr.s_addr);
            if (!seen.insert(key).second) continue;
            interfaces.push_back(BroadcastInterface{
                name,
                broadcast,
                reinterpret_cast<sockaddr_in*>(item->ifa_addr)->sin_addr,
                ::if_nametoindex(name.c_str()),
                static_cast<pb::InterfaceType>(internal::interface_type_from_name(name))
            });
        }
        ::freeifaddrs(list);
    }

    if (interfaces.empty()) {
        sockaddr_in dest{};
        dest.sin_family = AF_INET;
        dest.sin_port = htons(static_cast<std::uint16_t>(udp_port));
        dest.sin_addr.s_addr = htonl(INADDR_BROADCAST);
        interfaces.push_back(BroadcastInterface{"", dest, {}, 0, pb::IFACE_UNKNOWN});
    }
    return interfaces;
}

void send_discover_datagram(int fd, const std::string& payload, const BroadcastInterface& target) {
#if defined(__linux__) && defined(IP_PKTINFO)
    if (target.if_index != 0) {
        iovec iov{};
        iov.iov_base = const_cast<char*>(payload.data());
        iov.iov_len = payload.size();

        char control[CMSG_SPACE(sizeof(in_pktinfo))]{};
        msghdr message{};
        message.msg_name = const_cast<sockaddr_in*>(&target.broadcast_addr);
        message.msg_namelen = sizeof(target.broadcast_addr);
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        message.msg_control = control;
        message.msg_controllen = sizeof(control);

        cmsghdr* cmsg = CMSG_FIRSTHDR(&message);
        cmsg->cmsg_level = IPPROTO_IP;
        cmsg->cmsg_type = IP_PKTINFO;
        cmsg->cmsg_len = CMSG_LEN(sizeof(in_pktinfo));
        auto* info = reinterpret_cast<in_pktinfo*>(CMSG_DATA(cmsg));
        info->ipi_ifindex = static_cast<int>(target.if_index);
        info->ipi_spec_dst = target.source_addr;

        if (::sendmsg(fd, &message, 0) >= 0) {
            return;
        }
    }
#endif
    ::sendto(
        fd,
        payload.data(),
        payload.size(),
        0,
        reinterpret_cast<const sockaddr*>(&target.broadcast_addr),
        sizeof(target.broadcast_addr)
    );
}

void enable_udp_ipv4_pktinfo(int fd) {
#if defined(__linux__) && defined(IP_PKTINFO)
    int enabled = 1;
    ::setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &enabled, sizeof(enabled));
#else
    (void)fd;
#endif
}

bool send_udp_datagram_from_received_interface(
    int fd,
    const std::string& payload,
    const sockaddr_storage& addr,
    socklen_t addr_len,
    unsigned int if_index,
    std::uint32_t local_ipv4,
    bool has_pktinfo) {
#if defined(__linux__) && defined(IP_PKTINFO)
    if (has_pktinfo && addr.ss_family == AF_INET && (if_index != 0 || local_ipv4 != 0)) {
        sockaddr_storage destination = addr;
        iovec iov{};
        iov.iov_base = const_cast<char*>(payload.data());
        iov.iov_len = payload.size();

        char control[CMSG_SPACE(sizeof(in_pktinfo))]{};
        msghdr message{};
        message.msg_name = &destination;
        message.msg_namelen = addr_len;
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        message.msg_control = control;
        message.msg_controllen = sizeof(control);

        cmsghdr* cmsg = CMSG_FIRSTHDR(&message);
        cmsg->cmsg_level = IPPROTO_IP;
        cmsg->cmsg_type = IP_PKTINFO;
        cmsg->cmsg_len = CMSG_LEN(sizeof(in_pktinfo));
        auto* info = reinterpret_cast<in_pktinfo*>(CMSG_DATA(cmsg));
        info->ipi_ifindex = static_cast<int>(if_index);
        info->ipi_spec_dst.s_addr = local_ipv4;

        if (::sendmsg(fd, &message, 0) >= 0) {
            return true;
        }
    }
#else
    (void)if_index;
    (void)local_ipv4;
    (void)has_pktinfo;
#endif
    return ::sendto(fd, payload.data(), payload.size(), 0, reinterpret_cast<const sockaddr*>(&addr), addr_len) >= 0;
}

std::uint64_t buttons_mask_to_int(std::uint64_t mask) {
    return mask & 0xff;
}

}  // namespace

namespace internal {

bool tcp_frame_body_requires_active_session(int channel_id, int body_case) {
    auto channel = static_cast<pb::ChannelId>(channel_id);
    switch (channel) {
    case pb::CHANNEL_CONTROL:
        return body_case == pb::TcpFrame::kReleaseAll;
    case pb::CHANNEL_MOUSE:
        return body_case == pb::TcpFrame::kMouseState;
    case pb::CHANNEL_KEYBOARD:
        return body_case == pb::TcpFrame::kKeyboardState || body_case == pb::TcpFrame::kKeyboardSpecial;
    default:
        return false;
    }
}

}  // namespace internal

Daemon::Daemon(ServerConfig config, std::optional<std::string> token_override)
    : config_(std::move(config)),
      device_id_(machine_id()),
      server_id_(fnv1a64(device_id_)),
      boot_id_(random_u64()),
      challenge_nonce_(random_bytes(16)),
      token_override_(std::move(token_override)) {}

Daemon::ChannelEndpoint& Daemon::endpoint_for(PendingSession& session, int channel_id) {
    switch (static_cast<pb::ChannelId>(channel_id)) {
    case pb::CHANNEL_CONTROL:
        return session.control;
    case pb::CHANNEL_MOUSE:
        return session.mouse;
    case pb::CHANNEL_KEYBOARD:
        return session.keyboard;
    default:
        throw ProtocolError("unknown channel");
    }
}

bool Daemon::all_channels_ready(const PendingSession& session) const {
    return session.control.ready && session.mouse.ready && session.keyboard.ready;
}

bool Daemon::session_is_active(const std::shared_ptr<PendingSession>& session) {
    std::lock_guard<std::mutex> lock(mutex_);
    return session && session->active && !session->cleanup_requested && active_session_id_ == session->session_id;
}

int Daemon::serve_forever() {
    token_ = token_override_.value_or("");
    if (token_.empty()) token_ = load_token(config_.token_file);
    if (token_.empty()) throw std::runtime_error("missing token file " + config_.token_file + "; token is required");
    if (config_.leds.enabled) {
        led_ = std::make_unique<LedController>(config_.leds.primary_path, config_.leds.secondary_path, config_.hid.udc_state_path);
        led_->start(true);
    }
    if (!config_.discovery_only) {
        if (!ensure_hid_available(true)) {
            perform_gadget_soft_reset("startup HID open failed", true);
        }
    }

    udp_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_fd_ < 0) throw std::runtime_error(std::strerror(errno));
    int one = 1;
    setsockopt(udp_fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(udp_fd_, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    enable_udp_ipv4_pktinfo(udp_fd_);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<std::uint16_t>(config_.udp_port));
    if (::bind(udp_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) throw std::runtime_error(std::strerror(errno));
    set_socket_timeout(udp_fd_, 0.2);
    std::cerr << "UDP protobuf discovery listening on 0.0.0.0:" << config_.udp_port << "\n";
    publish_runtime_status(true);

    try {
        auto next_runtime_publish = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        auto next_discover = std::chrono::steady_clock::now();
        while (!stop_requested_ && !signal_stop_requested()) {
            cleanup_expired_sessions();
            reap_accept_workers();
            enforce_input_watchdog();
            update_usb_reenumeration_grace();
            if (!usb_grace_blocks_hid_retry()) {
                retry_hid_if_due();
            }

            auto now = std::chrono::steady_clock::now();
            if (now >= next_runtime_publish) {
                publish_runtime_status(true);
                next_runtime_publish = now + std::chrono::seconds(5);
            }
            bool busy = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                busy = !active_session_id_.empty() || !pending_.empty();
            }
            if (now >= next_discover) {
                broadcast_discover();
                next_discover = now + (busy ? std::chrono::seconds(2) : std::chrono::seconds(1));
            }

            std::array<char, 65535> buffer{};
            UdpPeerContext peer{};
            peer.addr_len = sizeof(peer.addr);
#if defined(__linux__) && defined(IP_PKTINFO)
            iovec iov{};
            iov.iov_base = buffer.data();
            iov.iov_len = buffer.size();

            char control[CMSG_SPACE(sizeof(in_pktinfo))]{};
            msghdr message{};
            message.msg_name = &peer.addr;
            message.msg_namelen = sizeof(peer.addr);
            message.msg_iov = &iov;
            message.msg_iovlen = 1;
            message.msg_control = control;
            message.msg_controllen = sizeof(control);

            ssize_t got = ::recvmsg(udp_fd_, &message, 0);
            peer.addr_len = message.msg_namelen;
            if (got >= 0) {
                for (cmsghdr* cmsg = CMSG_FIRSTHDR(&message); cmsg; cmsg = CMSG_NXTHDR(&message, cmsg)) {
                    if (cmsg->cmsg_level == IPPROTO_IP && cmsg->cmsg_type == IP_PKTINFO) {
                        auto* info = reinterpret_cast<in_pktinfo*>(CMSG_DATA(cmsg));
                        peer.if_index = info->ipi_ifindex > 0 ? static_cast<unsigned int>(info->ipi_ifindex) : 0;
                        peer.local_ipv4 = info->ipi_spec_dst.s_addr != 0 ? info->ipi_spec_dst.s_addr : info->ipi_addr.s_addr;
                        peer.has_pktinfo = peer.if_index != 0 || peer.local_ipv4 != 0;
                        break;
                    }
                }
            }
#else
            ssize_t got = ::recvfrom(udp_fd_, buffer.data(), buffer.size(), 0, reinterpret_cast<sockaddr*>(&peer.addr), &peer.addr_len);
#endif
            if (got < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
                if (stop_requested_ || signal_stop_requested()) break;
                throw std::runtime_error(std::strerror(errno));
            }
            handle_udp_datagram(std::string(buffer.data(), static_cast<std::size_t>(got)), peer);
        }
    } catch (...) {
        stop();
        throw;
    }
    stop();
    return 0;
}

void Daemon::stop() {
    stop_requested_ = true;
    close_fd(udp_fd_);
    std::vector<std::shared_ptr<PendingSession>> sessions;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& [_, session] : pending_) sessions.push_back(session);
        pending_.clear();
        active_session_id_.clear();
    }
    for (auto& session : sessions) {
        shutdown_fd(session->control.listener_fd);
        shutdown_fd(session->mouse.listener_fd);
        shutdown_fd(session->keyboard.listener_fd);
        shutdown_fd(session->control.conn_fd);
        shutdown_fd(session->mouse.conn_fd);
        shutdown_fd(session->keyboard.conn_fd);
    }
    join_accept_workers();
    clear_input_pressed_state();
    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) {
            try {
                hid_->close();
            } catch (const std::exception& exc) {
                std::cerr << "WARNING: failed to close HID devices during shutdown: " << exc.what() << "\n";
            }
            hid_.reset();
        }
    }
    if (led_) {
        try {
            led_->stop();
        } catch (const std::exception& exc) {
            std::cerr << "WARNING: failed to stop LED controller during shutdown: " << exc.what() << "\n";
        }
        led_.reset();
    }
    set_runtime_client_connected(false, false);
    set_runtime_tcp_connected(false);
    publish_runtime_status(false);
}

void Daemon::handle_udp_datagram(const std::string& data, const UdpPeerContext& peer) {
    pb::UdpPacket packet;
    if (!packet.ParseFromString(data)) {
        led_protocol_error("bad UDP protobuf");
        return;
    }
    if (packet.protocol_version() != kProtoVersion) {
        set_runtime_client_proto_mismatch(true);
    }
    if (packet.body_case() != pb::UdpPacket::kOffer) {
        return;
    }
    handle_offer_datagram(data, peer);
}

void Daemon::broadcast_discover() {
    bool busy = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        busy = !active_session_id_.empty() || !pending_.empty();
    }

    bool relative_available = false;
    bool absolute_available = false;
    bool hid_available = false;
    pb::HidStatus hid_status = pb::HID_STATUS_DEVICE_UNAVAILABLE;
    if (config_.discovery_only) {
        hid_status = pb::HID_STATUS_DEVICE_UNAVAILABLE;
    } else if (!usb_configured_for_hid()) {
        hid_status = pb::HID_STATUS_USB_NOT_CONFIGURED;
    } else {
        std::string last_hid_error;
        {
            std::lock_guard<std::mutex> lock(runtime_mutex_);
            last_hid_error = last_hid_error_;
        }
        {
            std::lock_guard<std::mutex> hid_lock(hid_mutex_);
            if (hid_) {
                relative_available = hid_->relative_mouse_available();
                absolute_available = hid_->absolute_mouse_available();
                hid_available = hid_->mandatory_available();
                if (hid_available) {
                    hid_status = absolute_available ? pb::HID_STATUS_READY : pb::HID_STATUS_ABSOLUTE_DEGRADED;
                }
            } else if (!last_hid_error.empty()) {
                hid_status = pb::HID_STATUS_WRITE_FAILED;
            }
        }
    }

    for (const auto& target : enumerate_broadcast_interfaces(config_.udp_port)) {
        pb::UdpPacket packet;
        packet.set_protocol_version(kProtoVersion);
        auto* discover = packet.mutable_discover();
        discover->set_server_id(server_id_);
        discover->set_boot_id(boot_id_);
        discover->set_server_name(config_.display_name);
        discover->set_interface_type(target.type);
        discover->set_tcp_accept_min(kMinTcpPort);
        discover->set_tcp_accept_max(kMaxTcpPort);
        discover->set_challenge_nonce(challenge_nonce_);
        discover->set_is_busy(busy);
        discover->set_hid_status(hid_status);
        discover->set_hid_available(hid_available);
        discover->set_absolute_pointer_available(absolute_available);
        discover->set_relative_pointer_available(relative_available);
        if (hid_available) {
            discover->add_capabilities("keyboard");
            discover->add_capabilities("mouse");
            discover->add_capabilities("release_all");
            discover->add_capabilities("relative_pointer");
            if (absolute_available) {
                discover->add_capabilities("absolute_pointer");
            }
        }

        std::string payload;
        if (!packet.SerializeToString(&payload)) continue;
        send_discover_datagram(udp_fd_, payload, target);
    }
}

bool Daemon::usb_configured_for_hid() const {
    try {
        return trim(read_file(config_.hid.udc_state_path)) == "configured";
    } catch (...) {
        return false;
    }
}

bool Daemon::hid_ready_for_offer() {
    if (config_.discovery_only) {
        led_hid_state(HidLedState::NodeUnavailable, "discovery-only mode");
        set_runtime_hid_available(false);
        return false;
    }
    if (!usb_configured_for_hid()) {
        led_hid_state(HidLedState::UsbNotConfigured, "USB is not configured");
        set_runtime_hid_available(false);
        return false;
    }
    if (!ensure_hid_available(false)) return false;
    std::lock_guard<std::mutex> hid_lock(hid_mutex_);
    return hid_ && hid_->mandatory_available();
}

void Daemon::handle_offer_datagram(const std::string& data, const UdpPeerContext& peer) {
    const std::string source_ip = peer_ip_string(peer.addr);
    auto send_callback = [&](bool accept, pb::OfferRejectReason reason, std::uint64_t session_id = 0) {
        pb::UdpPacket response;
        response.set_protocol_version(kProtoVersion);
        auto* callback = response.mutable_offer_callback();
        callback->set_server_id(server_id_);
        callback->set_boot_id(boot_id_);
        callback->set_accept(accept);
        callback->set_reject_reason(reason);
        callback->set_session_id(session_id);
        callback->set_connect_deadline_ms(static_cast<std::uint32_t>(std::max(1000, config_.offer_ttl_sec * 1000)));
        std::string payload;
        if (response.SerializeToString(&payload)) {
            send_udp_datagram_from_received_interface(
                udp_fd_,
                payload,
                peer.addr,
                peer.addr_len,
                peer.if_index,
                peer.local_ipv4,
                peer.has_pktinfo);
        }
    };

    cleanup_expired_sessions();
    pb::UdpPacket packet;
    if (!packet.ParseFromString(data) || packet.body_case() != pb::UdpPacket::kOffer) {
        send_callback(false, pb::INTERNAL_ERROR);
        return;
    }
    if (packet.protocol_version() != kProtoVersion) {
        set_runtime_client_proto_mismatch(true);
        led_protocol_error("Offer protocol version mismatch");
        send_callback(false, pb::PROTOCOL_VERSION_MISMATCH);
        return;
    }
    const auto& offer = packet.offer();
    if (offer.server_id() != server_id_ || offer.boot_id() != boot_id_) {
        send_callback(false, pb::SERVER_ID_MISMATCH);
        return;
    }
    if (!internal::valid_offer_tcp_ports(offer.control_tcp_port(), offer.mouse_tcp_port(), offer.keyboard_tcp_port())) {
        led_protocol_error("invalid Offer TCP ports");
        send_callback(false, pb::INVALID_PORT);
        return;
    }
    auto same_offer_fingerprint = [&](const PendingSession& session) {
        return !session.active
            && !session.cleanup_requested
            && session.client_id_value == offer.client_id()
            && session.client_nonce_bytes == offer.client_nonce()
            && session.control.port == static_cast<int>(offer.control_tcp_port())
            && session.mouse.port == static_cast<int>(offer.mouse_tcp_port())
            && session.keyboard.port == static_cast<int>(offer.keyboard_tcp_port())
            && session.offer_auth_mac == offer.auth_mac();
    };
    {
        std::uint64_t duplicate_session_id = 0;
        bool busy = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto& [_, session] : pending_) {
                if (same_offer_fingerprint(*session)) {
                    duplicate_session_id = session->session_id_value;
                    break;
                }
            }
            busy = !active_session_id_.empty() || !pending_.empty();
        }
        if (duplicate_session_id != 0) {
            send_callback(true, pb::OFFER_REJECT_NONE, duplicate_session_id);
            return;
        }
        if (busy) {
            led_network_error("server busy");
            send_callback(false, pb::SERVER_BUSY);
            return;
        }
    }
    auto rate_decision = auth_failure_limiter_.check(source_ip, std::chrono::steady_clock::now());
    if (rate_decision.rate_limited) {
        led_auth_error("offer token authentication rate limited");
        if (rate_decision.should_log) {
            std::cerr << "WARNING: offer authentication rate limited from " << source_ip << "\n";
        }
        send_callback(false, pb::AUTH_RATE_LIMITED);
        return;
    }
    auto auth_payload = internal::offer_auth_payload(
        offer.server_id(),
        offer.boot_id(),
        challenge_nonce_,
        offer.client_nonce(),
        offer.control_tcp_port(),
        offer.mouse_tcp_port(),
        offer.keyboard_tcp_port(),
        offer.client_unix_ms());
    auto expected_mac = internal::hmac_sha256(token_, auth_payload);
    if (!constant_time_equal(offer.auth_mac(), expected_mac)) {
        auto decision = auth_failure_limiter_.record_failure(source_ip, std::chrono::steady_clock::now());
        led_auth_error(decision.rate_limited ? "offer token authentication rate limited" : "offer token authentication failed");
        if (decision.should_log) {
            std::cerr << "WARNING: offer authentication failed from " << source_ip;
            if (decision.rate_limited) std::cerr << " (rate limited)";
            std::cerr << "\n";
        }
        send_callback(false, decision.rate_limited ? pb::AUTH_RATE_LIMITED : pb::TOKEN_AUTH_FAILED);
        return;
    }
    auth_failure_limiter_.record_success(source_ip);
    if (!hid_ready_for_offer()) {
        send_callback(false, pb::HID_UNAVAILABLE);
        return;
    }

    auto session = std::make_shared<PendingSession>();
    session->session_id_value = random_u64();
    session->session_id = std::to_string(session->session_id_value);
    session->server_id = server_id_;
    session->boot_id = boot_id_;
    session->challenge_nonce = challenge_nonce_;
    session->client_id_value = offer.client_id();
    session->client_nonce_bytes = offer.client_nonce();
    session->offer_auth_mac = offer.auth_mac();
    session->control.port = static_cast<int>(offer.control_tcp_port());
    session->mouse.port = static_cast<int>(offer.mouse_tcp_port());
    session->keyboard.port = static_cast<int>(offer.keyboard_tcp_port());
    session->expires_at = std::chrono::steady_clock::now() + std::chrono::seconds(config_.offer_ttl_sec);
    session->last_activity = std::chrono::steady_clock::now();

    try {
        session->control.listener_fd = bind_tcp_listener_exact(session->control.port);
        session->mouse.listener_fd = bind_tcp_listener_exact(session->mouse.port);
        session->keyboard.listener_fd = bind_tcp_listener_exact(session->keyboard.port);
    } catch (const ProtocolError&) {
        led_protocol_error("invalid Offer TCP port");
        send_callback(false, pb::INVALID_PORT);
        return;
    } catch (const std::exception&) {
        close_fd(session->control.listener_fd);
        close_fd(session->mouse.listener_fd);
        close_fd(session->keyboard.listener_fd);
        led_network_error("TCP listener occupied");
        send_callback(false, pb::TCP_OCCUPIED);
        return;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_[session->session_id] = session;
    }
    set_led_network_state(NetworkLedState::Other);
    try {
        std::lock_guard<std::mutex> lock(worker_mutex_);
        for (pb::ChannelId channel : {pb::CHANNEL_CONTROL, pb::CHANNEL_MOUSE, pb::CHANNEL_KEYBOARD}) {
            auto done = std::make_shared<std::atomic_bool>(false);
            std::thread thread(&Daemon::tcp_channel_worker, this, session, static_cast<int>(channel), done);
            accept_workers_.push_back(AcceptWorker{std::move(thread), done});
        }
        set_runtime_accept_worker_count(static_cast<int>(accept_workers_.size()));
    } catch (...) {
        cleanup_session(session, "failed to start TCP channel workers", false);
        send_callback(false, pb::INTERNAL_ERROR);
        return;
    }

    challenge_nonce_ = random_bytes(16);
    send_callback(true, pb::OFFER_REJECT_NONE, session->session_id_value);
}

void Daemon::tcp_channel_worker(std::shared_ptr<PendingSession> session, int channel_id, std::shared_ptr<std::atomic_bool> done) {
    struct DoneGuard {
        std::shared_ptr<std::atomic_bool> done;
        ~DoneGuard() { if (done) done->store(true); }
    } done_guard{std::move(done)};

    pb::ChannelId channel = static_cast<pb::ChannelId>(channel_id);
    int listener_fd = -1;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listener_fd = endpoint_for(*session, channel_id).listener_fd;
    }
    int conn_fd = -1;
    while (!stop_requested_ && !signal_stop_requested() && listener_fd >= 0 && std::chrono::steady_clock::now() < session->expires_at) {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(listener_fd, &read_set);
        timeval tv{0, 200000};
        int ready = ::select(listener_fd + 1, &read_set, nullptr, nullptr, &tv);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) continue;
        conn_fd = ::accept(listener_fd, nullptr, nullptr);
        break;
    }
    close_fd(listener_fd);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        endpoint_for(*session, channel_id).listener_fd = -1;
        endpoint_for(*session, channel_id).conn_fd = conn_fd;
    }
    if (conn_fd < 0) return;

    set_tcp_no_delay(conn_fd);
    set_socket_timeout(conn_fd, config_.tcp_timeout_sec);
    set_runtime_tcp_connected(true);
    try {
        handle_tcp_channel(session, channel_id, conn_fd);
    } catch (const SocketReadTimeout&) {
        cleanup_session(session, "tcp read timeout", true);
    } catch (const SocketPeerClosed&) {
        cleanup_session(session, "peer closed", true);
    } catch (const std::exception& exc) {
        try {
            send_error(conn_fd, *session, channel, 0, exc.what());
        } catch (...) {
        }
        cleanup_session(session, std::string("tcp channel failed: ") + exc.what(), true);
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& endpoint = endpoint_for(*session, channel_id);
        if (endpoint.conn_fd == conn_fd) endpoint.conn_fd = -1;
    }
    close_fd(conn_fd);
}

void Daemon::handle_tcp_channel(std::shared_ptr<PendingSession> session, int channel_id, int conn_fd) {
    pb::ChannelId channel = static_cast<pb::ChannelId>(channel_id);
    auto open = read_frame(conn_fd);
    if (open.session_id() != session->session_id_value || open.channel_id() != channel || open.body_case() != pb::TcpFrame::kChannelOpen
        || open.channel_open().expected_channel_id() != channel) {
        auto ready = base_frame(*session, channel, open.seq());
        auto* body = ready.mutable_channel_ready();
        body->set_channel_id(channel);
        body->set_accepted(false);
        body->set_message("channel binding rejected");
        write_frame(conn_fd, ready);
        throw ProtocolError("channel binding rejected");
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        endpoint_for(*session, channel_id).ready = true;
        session->last_activity = std::chrono::steady_clock::now();
    }
    auto ready = base_frame(*session, channel, open.seq());
    auto* ready_body = ready.mutable_channel_ready();
    ready_body->set_channel_id(channel);
    ready_body->set_accepted(true);
    ready_body->set_message("ready");
    write_frame(conn_fd, ready);

    bool became_active = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (all_channels_ready(*session) && !session->active) {
            if (!active_session_id_.empty() && active_session_id_ != session->session_id) {
                throw ProtocolError("another session became active");
            }
            active_session_id_ = session->session_id;
            session->active = true;
            became_active = true;
        }
    }
    if (became_active) {
        set_led_active_client(true);
        set_runtime_client_connected(true, true);
    }

    while (!stop_requested_) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (session->cleanup_requested) return;
        }
        pb::TcpFrame frame;
        try {
            frame = read_frame(conn_fd);
        } catch (const SocketReadTimeout&) {
            if (channel == pb::CHANNEL_CONTROL) throw;
            continue;
        }
        if (frame.session_id() != session->session_id_value || frame.channel_id() != channel) {
            throw ProtocolError("frame channel/session mismatch");
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            session->last_activity = std::chrono::steady_clock::now();
            last_input_activity_ = session->last_activity;
        }
        set_runtime_client_request_activity();

        if (internal::tcp_frame_body_requires_active_session(channel_id, static_cast<int>(frame.body_case())) && !session_is_active(session)) {
            led_network_error("business frame before session active");
            if (channel == pb::CHANNEL_KEYBOARD || frame.body_case() == pb::TcpFrame::kReleaseAll) {
                if (frame.ack_required()) {
                    send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_REJECTED, "session is not active");
                    set_runtime_client_response_activity();
                }
            }
            continue;
        }

        if (channel == pb::CHANNEL_CONTROL) {
            if (frame.body_case() == pb::TcpFrame::kHeartbeat) {
                auto response = base_frame(*session, channel, frame.seq());
                auto* ack = response.mutable_heartbeat_ack();
                ack->set_heartbeat_seq(frame.heartbeat().heartbeat_seq());
                ack->set_client_send_mono_us(frame.heartbeat().client_send_mono_us());
                ack->set_server_recv_mono_us(monotonic_us());
                ack->set_server_send_mono_us(monotonic_us());
                write_frame(conn_fd, response);
                set_runtime_client_response_activity();
                continue;
            }
            if (frame.body_case() == pb::TcpFrame::kReleaseAll) {
                led_input_received();
                std::string hid_error;
                if (drop_input_for_usb_grace(session)) {
                    led_hid_event_sent(false);
                } else {
                    try {
                        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
                        if (hid_) {
                            hid_->release_all();
                            led_hid_success(*hid_);
                        }
                        clear_input_pressed_state();
                        led_hid_event_sent(false);
                    } catch (const std::exception& exc) {
                        if (!handle_hid_write_failure(session, "release all failed", exc, false)) {
                            hid_error = exc.what();
                        }
                    }
                }
                if (frame.ack_required()) {
                    send_ack(
                        conn_fd,
                        *session,
                        channel,
                        frame.seq(),
                        hid_error.empty() ? pb::ACK_OK : pb::ACK_REJECTED,
                        hid_error
                    );
                    set_runtime_client_response_activity();
                }
                continue;
            }
            if (frame.body_case() == pb::TcpFrame::kGoodbye) {
                if (!drop_input_for_usb_grace(session)) {
                    try {
                        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
                        if (hid_) hid_->release_all();
                        clear_input_pressed_state();
                    } catch (const std::exception& exc) {
                        handle_hid_write_failure(session, "goodbye release failed", exc, false);
                    }
                }
                auto response = base_frame(*session, channel, frame.seq());
                response.mutable_goodbye_ack()->set_reason(frame.goodbye().reason());
                write_frame(conn_fd, response);
                cleanup_session(session, "client goodbye", false);
                return;
            }
            throw ProtocolError("unsupported control frame");
        }

        if (channel == pb::CHANNEL_MOUSE) {
            if (frame.body_case() != pb::TcpFrame::kMouseState) {
                throw ProtocolError("unsupported mouse frame");
            }
            const auto& mouse = frame.mouse_state();
            int buttons = static_cast<int>(buttons_mask_to_int(mouse.buttons_mask()));
            int x = internal::protocol_absolute_to_hid(mouse.abs_x());
            int y = internal::protocol_absolute_to_hid(mouse.abs_y());
            int dx = std::max(-127, std::min(127, static_cast<int>(mouse.rel_dx())));
            int dy = std::max(-127, std::min(127, static_cast<int>(mouse.rel_dy())));
            int wheel = std::max(-127, std::min(127, static_cast<int>(mouse.wheel_delta_y())));
            led_input_received();
            if (drop_input_for_usb_grace(session)) {
                continue;
            }
            try {
                std::lock_guard<std::mutex> hid_lock(hid_mutex_);
                auto& writer = require_hid();
                writer.write_pointer_report(
                    buttons,
                    x,
                    y,
                    dx,
                    dy,
                    wheel,
                    mouse.has_reliable_edge(),
                    mouse.has_reliable_edge() ? 25 : 10
                );
                record_mouse_pressed_state(buttons);
                record_absolute_mouse_pressed_state(buttons);
                led_hid_event_sent(buttons != 0);
                led_hid_success(writer);
            } catch (const std::exception& exc) {
                bool usb_grace = handle_hid_write_failure(session, "mouse state failed", exc, true);
                if (!usb_grace && mouse.has_reliable_edge()) throw;
            }
            continue;
        }

        if (channel == pb::CHANNEL_KEYBOARD) {
            if (frame.body_case() == pb::TcpFrame::kKeyboardState) {
                if (frame.seq() == session->last_keyboard_seq) {
                    send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_DUPLICATED);
                    set_runtime_client_response_activity();
                    continue;
                }
                const auto& state = frame.keyboard_state();
                std::vector<int> keys;
                keys.reserve(6);
                for (int index = 0; index < state.pressed_usage_ids_size() && index < 6; ++index) {
                    keys.push_back(static_cast<int>(std::min<std::uint32_t>(state.pressed_usage_ids(index), 0xff)));
                }
                int modifiers = static_cast<int>(std::min<std::uint32_t>(state.modifier_mask(), 0xff));
                led_input_received();
                if (drop_input_for_usb_grace(session)) {
                    session->last_keyboard_seq = frame.seq();
                    send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                    set_runtime_client_response_activity();
                    continue;
                }
                try {
                    std::lock_guard<std::mutex> hid_lock(hid_mutex_);
                    auto& writer = require_hid();
                    writer.write_keyboard_report(modifiers, keys);
                    record_keyboard_pressed_state(modifiers, keys);
                    led_hid_event_sent(modifiers != 0 || !keys.empty());
                    led_hid_success(writer);
                    session->last_keyboard_seq = frame.seq();
                } catch (const std::exception& exc) {
                    if (handle_hid_write_failure(session, "keyboard state failed", exc, true)) {
                        session->last_keyboard_seq = frame.seq();
                        send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                        set_runtime_client_response_activity();
                        continue;
                    }
                    throw;
                }
                send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                set_runtime_client_response_activity();
                continue;
            }
            if (frame.body_case() == pb::TcpFrame::kKeyboardSpecial) {
                if (frame.keyboard_special().spec_id() != pb::KEYBOARD_SPECIAL_CTRL_ALT_DEL) {
                    send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_REJECTED, "unsupported special key");
                    set_runtime_client_response_activity();
                    continue;
                }
                led_input_received();
                if (drop_input_for_usb_grace(session)) {
                    send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                    set_runtime_client_response_activity();
                    continue;
                }
                try {
                    std::lock_guard<std::mutex> hid_lock(hid_mutex_);
                    auto& writer = require_hid();
                    writer.release_all();
                    writer.write_keyboard_report(0x05, {0x4c});
                    record_keyboard_pressed_state(0x05, {0x4c});
                    led_hid_event_sent(true);
                    std::this_thread::sleep_for(std::chrono::milliseconds(30));
                    writer.write_keyboard_report(0, {});
                    clear_input_pressed_state();
                    led_hid_event_sent(false);
                    led_hid_success(writer);
                } catch (const std::exception& exc) {
                    if (handle_hid_write_failure(session, "keyboard special failed", exc, true)) {
                        send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                        set_runtime_client_response_activity();
                        continue;
                    }
                    throw;
                }
                send_ack(conn_fd, *session, channel, frame.seq(), pb::ACK_OK);
                set_runtime_client_response_activity();
                continue;
            }
            throw ProtocolError("unsupported keyboard frame");
        }
    }
}

void Daemon::cleanup_session(std::shared_ptr<PendingSession> session, const std::string& reason, bool release) {
    bool should_release = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (session->cleanup_requested) return;
        session->cleanup_requested = true;
        session->disconnect_reason = reason;
        should_release = release && session->active;
        if (active_session_id_ == session->session_id) active_session_id_.clear();
        if (usb_grace_.session_id() == session->session_id) usb_grace_.clear();
        pending_.erase(session->session_id);
    }
    if (should_release) {
        try {
            std::lock_guard<std::mutex> hid_lock(hid_mutex_);
            if (hid_) hid_->release_all();
        } catch (const std::exception& exc) {
            mark_hid_failed(std::string("safety release failed: ") + exc.what());
        } catch (...) {
            mark_hid_failed("safety release failed");
        }
        clear_input_pressed_state();
    }
    shutdown_fd(session->control.listener_fd);
    shutdown_fd(session->mouse.listener_fd);
    shutdown_fd(session->keyboard.listener_fd);
    shutdown_fd(session->control.conn_fd);
    shutdown_fd(session->mouse.conn_fd);
    shutdown_fd(session->keyboard.conn_fd);
    set_runtime_disconnect_reason(reason);
    set_runtime_client_connected(false, false);
    set_runtime_tcp_connected(false);
    set_led_active_client(false);
}

void Daemon::join_accept_workers() {
    std::vector<AcceptWorker> workers;
    {
        std::lock_guard<std::mutex> lock(worker_mutex_);
        workers.swap(accept_workers_);
        set_runtime_accept_worker_count(0);
    }
    for (auto& worker : workers) {
        if (!worker.thread.joinable()) continue;
        if (worker.thread.get_id() == std::this_thread::get_id()) {
            worker.thread.detach();
        } else {
            worker.thread.join();
        }
    }
}

void Daemon::reap_accept_workers() {
    std::vector<AcceptWorker> completed;
    {
        std::lock_guard<std::mutex> lock(worker_mutex_);
        for (auto it = accept_workers_.begin(); it != accept_workers_.end();) {
            if (it->done && it->done->load()) {
                completed.push_back(std::move(*it));
                it = accept_workers_.erase(it);
            } else {
                ++it;
            }
        }
        set_runtime_accept_worker_count(static_cast<int>(accept_workers_.size()));
    }
    for (auto& worker : completed) {
        if (worker.thread.joinable()) worker.thread.join();
    }
}

void Daemon::cleanup_expired_sessions() {
    auto now = std::chrono::steady_clock::now();
    std::vector<std::shared_ptr<PendingSession>> expired;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = pending_.begin(); it != pending_.end();) {
            if (it->first != active_session_id_ && now >= it->second->expires_at) {
                expired.push_back(it->second);
                it = pending_.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (auto& session : expired) {
        cleanup_session(session, "offer expired", false);
    }
}

void Daemon::enforce_input_watchdog() {
    std::shared_ptr<PendingSession> session;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_session_id_.empty() || !pressed_input_.has_pressed()) return;
        auto now = std::chrono::steady_clock::now();
        if (last_input_activity_.time_since_epoch().count() == 0 || now - last_input_activity_ <= std::chrono::seconds(2)) return;
        auto it = pending_.find(active_session_id_);
        if (it != pending_.end()) {
            session = it->second;
            session->disconnect_reason = "input watchdog release";
        }
        active_session_id_.clear();
        pressed_input_.clear();
        last_input_activity_ = now;
    }
    try {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) hid_->release_all();
    } catch (const std::exception& exc) {
        mark_hid_failed(std::string("input watchdog release failed: ") + exc.what());
    } catch (...) {
        mark_hid_failed("input watchdog release failed");
    }
    if (session) {
        std::cerr << "WARNING: input watchdog released pressed state for session " << session->session_id << "\n";
        shutdown_fd(session->control.conn_fd);
        shutdown_fd(session->mouse.conn_fd);
        shutdown_fd(session->keyboard.conn_fd);
    }
    set_runtime_input_watchdog_release();
    set_runtime_disconnect_reason("input watchdog release");
    set_runtime_client_connected(false, false);
    set_led_active_client(false);
}

void Daemon::update_usb_reenumeration_grace() {
    auto now = std::chrono::steady_clock::now();
    std::shared_ptr<PendingSession> session;
    bool grace_active = false;
    bool grace_expired = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_session_id_.empty()) {
            usb_grace_.clear();
            return;
        }
        auto it = pending_.find(active_session_id_);
        if (it == pending_.end() || it->second->cleanup_requested) {
            usb_grace_.clear();
            return;
        }
        session = it->second;
        grace_active = usb_grace_.active_for(active_session_id_, now);
        grace_expired = usb_grace_.session_id() == active_session_id_ && usb_grace_.expired(now);
    }

    if (!usb_configured_for_hid()) {
        if (grace_expired) {
            if (try_gadget_reset_for_grace(session, "USB is not configured; attempting gadget reset before disconnect")) {
                return;
            }
            cleanup_session(session, "usb not configured grace expired", false);
            return;
        }
        if (!grace_active) {
            begin_usb_reenumeration_grace(session, "USB is not configured; waiting for re-enumeration", false);
            return;
        }
        set_runtime_hid_available(false);
        led_hid_state(HidLedState::UsbNotConfigured, "USB is not configured; waiting for re-enumeration");
        return;
    }

    if (!grace_active && !grace_expired) return;

    if (!ensure_hid_available(true)) {
        if (grace_expired) {
            if (try_gadget_reset_for_grace(session, "HID recovery grace expired; attempting gadget reset before disconnect")) {
                return;
            }
            cleanup_session(session, "HID recovery grace expired", false);
        }
        return;
    }

    finish_usb_reenumeration_grace(session, "USB re-enumeration grace recovered");
}

bool Daemon::usb_grace_blocks_hid_retry() {
    auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(mutex_);
    return !active_session_id_.empty() && usb_grace_.active_for(active_session_id_, now);
}

bool Daemon::begin_usb_reenumeration_grace(std::shared_ptr<PendingSession> session, const std::string& reason, bool dropped_input, bool allow_when_configured) {
    if (!session) return false;
    bool usb_configured = usb_configured_for_hid();
    if (usb_configured && !allow_when_configured) return false;

    auto now = std::chrono::steady_clock::now();
    bool started = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!session->active || session->cleanup_requested || active_session_id_ != session->session_id) {
            return false;
        }
        started = usb_grace_.begin(session->session_id, now);
        usb_grace_.note_release_needed();
        if (dropped_input) usb_grace_.note_dropped_input();
        pressed_input_.clear();
        last_input_activity_ = now;
    }

    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) {
            hid_->close_without_release();
            hid_.reset();
        }
        next_hid_retry_at_ = {};
    }
    set_runtime_hid_available(false);
    led_hid_state(usb_configured ? HidLedState::WriteFailed : HidLedState::UsbNotConfigured, reason);
    if (started) {
        std::cerr << "WARNING: HID recovery grace started for session "
                  << session->session_id << ": " << reason << "\n";
    }
    return true;
}

bool Daemon::drop_input_for_usb_grace(std::shared_ptr<PendingSession> session) {
    auto now = std::chrono::steady_clock::now();
    bool should_drop = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (session && session->active && !session->cleanup_requested && usb_grace_.active_for(session->session_id, now)) {
            usb_grace_.note_dropped_input();
            pressed_input_.clear();
            last_input_activity_ = now;
            should_drop = true;
        }
    }
    if (should_drop) {
        set_runtime_hid_available(false);
        led_hid_state(HidLedState::UsbNotConfigured, "USB is not configured; dropping input during grace");
    }
    return should_drop;
}

bool Daemon::handle_hid_write_failure(
    std::shared_ptr<PendingSession> session,
    const std::string& context,
    const std::exception& exc,
    bool dropped_input) {
    std::string reason = context + ": " + exc.what();
    bool should_reset = should_reset_after_hid_failure(reason, false);
    if (begin_usb_reenumeration_grace(session, reason, dropped_input, true)) {
        if (should_reset) {
            try_gadget_reset_for_grace(session, reason);
        }
        return true;
    }
    mark_hid_failed(reason);
    if (should_reset) {
        perform_gadget_soft_reset(reason);
    }
    return false;
}

bool Daemon::finish_usb_reenumeration_grace(std::shared_ptr<PendingSession> session, const std::string& message) {
    if (!session) return false;
    bool release_needed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (usb_grace_.session_id() != session->session_id) return false;
        release_needed = usb_grace_.release_needed();
    }

    if (release_needed) {
        try {
            std::lock_guard<std::mutex> hid_lock(hid_mutex_);
            if (hid_) hid_->release_all();
        } catch (const std::exception& exc) {
            std::cerr << "WARNING: HID recovery release_all best-effort failed for session "
                      << session->session_id << ": " << exc.what() << "\n";
        } catch (...) {
            std::cerr << "WARNING: HID recovery release_all best-effort failed for session "
                      << session->session_id << "\n";
        }
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (usb_grace_.session_id() == session->session_id) usb_grace_.clear();
        pressed_input_.clear();
        last_input_activity_ = std::chrono::steady_clock::now();
    }
    set_runtime_hid_available(true);
    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) {
            led_hid_success(*hid_);
        } else {
            led_hid_state(HidLedState::Ready);
        }
    }
    std::cerr << "OK: " << message << " for session " << session->session_id << "\n";
    return true;
}

bool Daemon::try_gadget_reset_for_grace(std::shared_ptr<PendingSession> session, const std::string& reason) {
    if (!session) return false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (usb_grace_.session_id() != session->session_id || usb_grace_.gadget_reset_attempted()) return false;
        usb_grace_.note_gadget_reset_attempted();
    }
    if (!perform_gadget_soft_reset(reason)) return false;
    if (!ensure_hid_available(true)) return false;
    return finish_usb_reenumeration_grace(session, "HID recovered after gadget reset");
}

bool Daemon::try_open_hid_writer(std::string* error_out) {
    auto candidate = std::make_unique<HidWriter>(config_.hid.keyboard_path, config_.hid.mouse_path, config_.hid.absolute_mouse_path);
    try {
        candidate->open();
    } catch (const std::exception& exc) {
        if (error_out) *error_out = exc.what();
        return false;
    }

    bool absolute_degraded = candidate->absolute_mouse_degraded();
    std::string absolute_error = candidate->last_absolute_error();
    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        hid_ = std::move(candidate);
        next_hid_retry_at_ = {};
    }
    set_runtime_hid_available(true);
    led_hid_state(
        absolute_degraded ? HidLedState::AbsoluteDegraded : HidLedState::Ready,
        absolute_degraded ? absolute_error : ""
    );
    std::cerr << "OK: HID devices opened\n";
    return true;
}

bool Daemon::ensure_hid_available(bool force) {
    if (config_.discovery_only) return false;

    auto now = std::chrono::steady_clock::now();
    bool existing_absolute_degraded = false;
    std::string existing_absolute_error;
    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_ && !force) {
            existing_absolute_degraded = hid_->absolute_mouse_degraded();
            existing_absolute_error = hid_->last_absolute_error();
            set_runtime_hid_available(true);
            led_hid_state(
                existing_absolute_degraded ? HidLedState::AbsoluteDegraded : HidLedState::Ready,
                existing_absolute_degraded ? existing_absolute_error : ""
            );
            return true;
        }
        if (!force && now < next_hid_retry_at_) {
            set_runtime_hid_available(false);
            return false;
        }
        next_hid_retry_at_ = now + kHidRetryInterval;
    }

    std::string error;
    if (try_open_hid_writer(&error)) return true;

    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        hid_.reset();
        next_hid_retry_at_ = std::chrono::steady_clock::now() + kHidRetryInterval;
    }
    set_runtime_hid_available(false);
    set_runtime_hid_error(std::string("HID open failed: ") + error);
    led_hid_state(HidLedState::NodeUnavailable, std::string("HID open failed: ") + error);
    std::cerr << "WARNING: HID open failed; retrying in 3s: " << error << "\n";
    if (should_reset_after_hid_failure("HID open failed: " + error, force)) {
        return perform_gadget_soft_reset("HID open failed: " + error, force);
    }
    return false;
}

void Daemon::mark_hid_failed(const std::string& reason) {
    set_runtime_hid_error(reason);
    set_runtime_hid_available(false);
    led_hid_error(reason);
    std::lock_guard<std::mutex> hid_lock(hid_mutex_);
    if (hid_) {
        hid_->close_without_release();
        hid_.reset();
    }
    next_hid_retry_at_ = std::chrono::steady_clock::now() + kHidRetryInterval;
}

bool Daemon::should_reset_after_hid_failure(const std::string& reason, bool force) {
    if (config_.discovery_only) return false;
    auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(runtime_mutex_);
    while (!recent_hid_failures_.empty() && now - recent_hid_failures_.front() > kHidFailureWindow) {
        recent_hid_failures_.pop_front();
    }
    recent_hid_failures_.push_back(now);
    if (!force && static_cast<int>(recent_hid_failures_.size()) < kHidFailureResetThreshold) {
        return false;
    }
    if (!force
        && last_gadget_reset_steady_.time_since_epoch().count() != 0
        && now - last_gadget_reset_steady_ < kGadgetResetCooldown) {
        std::cerr << "WARNING: suppressing gadget reset during cooldown after HID failure: " << reason << "\n";
        return false;
    }
    return true;
}

bool Daemon::perform_gadget_soft_reset(const std::string& reason, bool ignore_cooldown) {
    if (config_.discovery_only) return false;
    auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        if (!ignore_cooldown
            && last_gadget_reset_steady_.time_since_epoch().count() != 0
            && now - last_gadget_reset_steady_ < kGadgetResetCooldown) {
            return false;
        }
    }

    std::cerr << "WARNING: performing HID gadget soft reset: " << reason << "\n";
    try {
        release_all(config_);
    } catch (const std::exception& exc) {
        std::cerr << "WARNING: best-effort release before gadget reset failed: " << exc.what() << "\n";
    } catch (...) {
        std::cerr << "WARNING: best-effort release before gadget reset failed\n";
    }

    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) {
            hid_->close_without_release();
            hid_.reset();
        }
        next_hid_retry_at_ = {};
    }

    set_runtime_gadget_reset(reason);
    try {
        gadget_teardown(config_);
    } catch (const std::exception& exc) {
        std::cerr << "WARNING: gadget teardown during soft reset failed: " << exc.what() << "\n";
    } catch (...) {
        std::cerr << "WARNING: gadget teardown during soft reset failed\n";
    }
    try {
        gadget_setup(config_);
    } catch (const std::exception& exc) {
        std::string error = std::string("gadget soft reset failed: ") + exc.what();
        set_runtime_hid_error(error);
        set_runtime_hid_available(false);
        led_hid_state(HidLedState::GadgetUnavailable, error);
        std::cerr << "WARNING: " << error << "\n";
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        next_hid_retry_at_ = std::chrono::steady_clock::now() + kHidRetryInterval;
        return false;
    }

    std::string error;
    if (!try_open_hid_writer(&error)) {
        set_runtime_hid_error(std::string("HID open failed after gadget reset: ") + error);
        set_runtime_hid_available(false);
        led_hid_state(HidLedState::NodeUnavailable, std::string("HID open failed after gadget reset: ") + error);
        std::cerr << "WARNING: HID open failed after gadget reset: " << error << "\n";
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        next_hid_retry_at_ = std::chrono::steady_clock::now() + kHidRetryInterval;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        recent_hid_failures_.clear();
    }
    return true;
}

void Daemon::retry_hid_if_due() {
    bool had_hid = false;
    bool absolute_degraded = false;
    std::string absolute_error;
    {
        std::lock_guard<std::mutex> hid_lock(hid_mutex_);
        if (hid_) {
            hid_->try_reopen_absolute(false);
            had_hid = true;
            absolute_degraded = hid_->absolute_mouse_degraded();
            absolute_error = hid_->last_absolute_error();
        }
    }
    if (had_hid) {
        led_hid_state(
            absolute_degraded ? HidLedState::AbsoluteDegraded : HidLedState::Ready,
            absolute_degraded ? absolute_error : ""
        );
        return;
    }
    ensure_hid_available(false);
}

HidWriter& Daemon::require_hid() {
    if (!hid_) throw std::runtime_error("HID writer is not available; retrying");
    return *hid_;
}

void Daemon::set_led_active_client(bool active) { if (led_) led_->set_active_client(active); }
void Daemon::set_led_network_state(NetworkLedState state) { if (led_) led_->set_network_state(state); }
void Daemon::led_protocol_error(const std::string& reason) { if (led_) led_->latch_protocol_error(reason); }
void Daemon::led_auth_error(const std::string& reason) { if (led_) led_->latch_auth_error(reason); }
void Daemon::led_network_error(const std::string& reason) { if (led_) led_->latch_protocol_error(reason); }
void Daemon::led_hid_error(const std::string& reason) { if (led_) led_->latch_hid_error(reason); }
void Daemon::led_hid_state(HidLedState state, const std::string& reason) { if (led_) led_->set_hid_state(state, reason); }
void Daemon::led_input_received() { if (led_) led_->notify_input_received(); }
void Daemon::led_hid_event_sent(bool hold_active) { if (led_) led_->notify_hid_event_sent(hold_active); }
void Daemon::led_hid_success(const HidWriter& writer) {
    if (!led_) return;
    if (writer.absolute_mouse_degraded()) {
        led_->set_hid_state(HidLedState::AbsoluteDegraded, writer.last_absolute_error());
    } else {
        led_->set_hid_state(HidLedState::Ready);
    }
}

void Daemon::publish_runtime_status(bool daemon_running) {
    bool tcp_connected;
    bool client_connected;
    bool hid_runtime_available;
    bool client_proto_mismatch;
    std::string last_client_connected_at;
    std::string last_client_request_at;
    std::int64_t last_client_request_at_ms;
    std::string last_client_response_at;
    std::int64_t last_client_response_at_ms;
    std::string last_disconnect_reason;
    std::string last_hid_error;
    std::string last_input_watchdog_release_at;
    std::string last_gadget_reset_at;
    std::string last_gadget_reset_reason;
    int accept_worker_count;
    int gadget_reset_count;
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        tcp_connected = runtime_tcp_connected_;
        client_connected = runtime_client_connected_;
        hid_runtime_available = runtime_hid_available_;
        client_proto_mismatch = runtime_client_proto_mismatch_;
        last_client_connected_at = last_client_connected_at_;
        last_client_request_at = last_client_request_at_;
        last_client_request_at_ms = last_client_request_at_ms_;
        last_client_response_at = last_client_response_at_;
        last_client_response_at_ms = last_client_response_at_ms_;
        last_disconnect_reason = last_disconnect_reason_;
        last_hid_error = last_hid_error_;
        last_input_watchdog_release_at = last_input_watchdog_release_at_;
        last_gadget_reset_at = last_gadget_reset_at_;
        last_gadget_reset_reason = last_gadget_reset_reason_;
        accept_worker_count = runtime_accept_worker_count_;
        gadget_reset_count = runtime_gadget_reset_count_;
    }
    try {
        write_runtime_status_file(
            daemon_running,
            tcp_connected,
            client_connected,
            hid_runtime_available,
            client_proto_mismatch,
            last_client_connected_at,
            last_client_request_at,
            last_client_request_at_ms,
            last_client_response_at,
            last_client_response_at_ms,
            last_disconnect_reason,
            last_hid_error,
            last_input_watchdog_release_at,
            last_gadget_reset_at,
            last_gadget_reset_reason,
            gadget_reset_count,
            accept_worker_count
        );
    } catch (const std::exception& exc) {
        std::cerr << "WARNING: failed to publish runtime status: " << exc.what() << "\n";
    }
}

void Daemon::set_runtime_tcp_connected(bool connected) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        runtime_tcp_connected_ = connected;
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_client_connected(bool connected, bool update_timestamp) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        runtime_client_connected_ = connected;
        if (connected && update_timestamp) {
            runtime_client_proto_mismatch_ = false;
            last_client_connected_at_ = iso8601_utc_now();
            last_disconnect_reason_.clear();
            last_hid_error_.clear();
        }
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_hid_available(bool available) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        runtime_hid_available_ = available;
        if (available) {
            last_hid_error_.clear();
        }
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_client_request_activity() {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_client_request_at_ = iso8601_utc_now();
        last_client_request_at_ms_ = epoch_ms();
    }
}

void Daemon::set_runtime_client_response_activity() {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_client_response_at_ = iso8601_utc_now();
        last_client_response_at_ms_ = epoch_ms();
    }
}

void Daemon::set_runtime_disconnect_reason(const std::string& reason) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_disconnect_reason_ = reason;
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_client_proto_mismatch(bool mismatch) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        runtime_client_proto_mismatch_ = mismatch;
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_hid_error(const std::string& reason) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_hid_error_ = reason;
        runtime_hid_available_ = false;
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_input_watchdog_release() {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_input_watchdog_release_at_ = iso8601_utc_now();
    }
    publish_runtime_status(true);
}

void Daemon::set_runtime_accept_worker_count(int count) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        runtime_accept_worker_count_ = std::max(0, count);
    }
}

void Daemon::set_runtime_gadget_reset(const std::string& reason) {
    {
        std::lock_guard<std::mutex> lock(runtime_mutex_);
        last_gadget_reset_steady_ = std::chrono::steady_clock::now();
        last_gadget_reset_at_ = iso8601_utc_now();
        last_gadget_reset_reason_ = reason;
        ++runtime_gadget_reset_count_;
        recent_hid_failures_.clear();
    }
    publish_runtime_status(true);
}

void Daemon::record_keyboard_pressed_state(int modifiers, const std::vector<int>& keys) {
    std::lock_guard<std::mutex> lock(mutex_);
    pressed_input_.keyboard_modifiers = modifiers;
    pressed_input_.keyboard_keys = keys;
    last_input_activity_ = std::chrono::steady_clock::now();
}

void Daemon::record_mouse_pressed_state(int buttons) {
    std::lock_guard<std::mutex> lock(mutex_);
    pressed_input_.mouse_buttons = buttons;
    last_input_activity_ = std::chrono::steady_clock::now();
}

void Daemon::record_absolute_mouse_pressed_state(int buttons) {
    std::lock_guard<std::mutex> lock(mutex_);
    pressed_input_.absolute_mouse_buttons = buttons;
    last_input_activity_ = std::chrono::steady_clock::now();
}

void Daemon::clear_input_pressed_state() {
    std::lock_guard<std::mutex> lock(mutex_);
    pressed_input_.clear();
    last_input_activity_ = std::chrono::steady_clock::now();
}

}  // namespace hidmi
