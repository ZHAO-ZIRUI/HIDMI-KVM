#include "hidmi_internal.hpp"

namespace fs = std::filesystem;

namespace hidmi {
using namespace internal;

Json::Json() : value_(nullptr) {}
Json::Json(std::nullptr_t) : value_(nullptr) {}
Json::Json(bool v) : value_(v) {}
Json::Json(int v) : value_(static_cast<int64_t>(v)) {}
Json::Json(int64_t v) : value_(v) {}
Json::Json(double v) : value_(v) {}
Json::Json(const char* v) : value_(std::string(v)) {}
Json::Json(std::string v) : value_(std::move(v)) {}
Json::Json(array v) : value_(std::move(v)) {}
Json::Json(object v) : value_(std::move(v)) {}
bool Json::is_null() const { return std::holds_alternative<std::nullptr_t>(value_); }
const Json::value& Json::raw() const { return value_; }
Json::value& Json::raw() { return value_; }
const Json::object& Json::as_object() const { return std::get<object>(value_); }
const Json::array& Json::as_array() const { return std::get<array>(value_); }
std::string Json::as_string(const std::string& fallback) const {
    if (auto value = std::get_if<std::string>(&value_)) {
        return *value;
    }
    return fallback;
}
std::optional<int64_t> Json::as_int() const {
    if (auto value = std::get_if<int64_t>(&value_)) {
        return *value;
    }
    if (auto value = std::get_if<double>(&value_)) {
        auto as_int = static_cast<int64_t>(*value);
        if (static_cast<double>(as_int) == *value) {
            return as_int;
        }
    }
    return std::nullopt;
}
bool Json::as_bool(bool fallback) const {
    if (auto value = std::get_if<bool>(&value_)) {
        return *value;
    }
    return fallback;
}

class JsonParser {
public:
    explicit JsonParser(std::string text) : text_(std::move(text)) {}
    Json parse() {
        skip_ws();
        Json value = parse_value();
        skip_ws();
        if (pos_ != text_.size()) {
            throw ProtocolError("invalid JSON: trailing data");
        }
        return value;
    }

private:
    std::string text_;
    std::size_t pos_ = 0;

    void skip_ws() {
        while (pos_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[pos_]))) {
            ++pos_;
        }
    }
    char peek() const {
        if (pos_ >= text_.size()) {
            throw ProtocolError("invalid JSON: unexpected end");
        }
        return text_[pos_];
    }
    bool consume(char expected) {
        skip_ws();
        if (pos_ < text_.size() && text_[pos_] == expected) {
            ++pos_;
            return true;
        }
        return false;
    }
    Json parse_value() {
        skip_ws();
        char c = peek();
        if (c == '"') return Json(parse_string());
        if (c == '{') return Json(parse_object());
        if (c == '[') return Json(parse_array());
        if (starts_with(text_.substr(pos_), "true")) { pos_ += 4; return Json(true); }
        if (starts_with(text_.substr(pos_), "false")) { pos_ += 5; return Json(false); }
        if (starts_with(text_.substr(pos_), "null")) { pos_ += 4; return Json(nullptr); }
        return parse_number();
    }
    std::string parse_string() {
        if (peek() != '"') {
            throw ProtocolError("invalid JSON: expected string");
        }
        ++pos_;
        std::string out;
        while (pos_ < text_.size()) {
            char c = text_[pos_++];
            if (c == '"') {
                return out;
            }
            if (c == '\\') {
                if (pos_ >= text_.size()) {
                    throw ProtocolError("invalid JSON: bad escape");
                }
                char n = text_[pos_++];
                switch (n) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    default: throw ProtocolError("invalid JSON: unsupported escape");
                }
            } else {
                out.push_back(c);
            }
        }
        throw ProtocolError("invalid JSON: unterminated string");
    }
    Json::object parse_object() {
        if (!consume('{')) {
            throw ProtocolError("invalid JSON: expected object");
        }
        Json::object object;
        skip_ws();
        if (consume('}')) {
            return object;
        }
        while (true) {
            skip_ws();
            std::string key = parse_string();
            if (!consume(':')) {
                throw ProtocolError("invalid JSON: expected ':'");
            }
            object[key] = parse_value();
            if (consume('}')) {
                return object;
            }
            if (!consume(',')) {
                throw ProtocolError("invalid JSON: expected ','");
            }
        }
    }
    Json::array parse_array() {
        if (!consume('[')) {
            throw ProtocolError("invalid JSON: expected array");
        }
        Json::array array;
        skip_ws();
        if (consume(']')) {
            return array;
        }
        while (true) {
            array.push_back(parse_value());
            if (consume(']')) {
                return array;
            }
            if (!consume(',')) {
                throw ProtocolError("invalid JSON: expected ','");
            }
        }
    }
    Json parse_number() {
        std::size_t start = pos_;
        if (text_[pos_] == '-') {
            ++pos_;
        }
        while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
            ++pos_;
        }
        bool is_float = false;
        if (pos_ < text_.size() && text_[pos_] == '.') {
            is_float = true;
            ++pos_;
            while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
                ++pos_;
            }
        }
        if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            is_float = true;
            ++pos_;
            if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
                ++pos_;
            }
            while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
                ++pos_;
            }
        }
        std::string token = text_.substr(start, pos_ - start);
        if (token.empty() || token == "-") {
            throw ProtocolError("invalid JSON: expected number");
        }
        if (is_float) {
            return Json(std::stod(token));
        }
        return Json(static_cast<int64_t>(std::stoll(token)));
    }
};

Json parse_json(const std::string& text) {
    return JsonParser(text).parse();
}

Message parse_json_object(const std::string& text) {
    Json json = parse_json(text);
    if (!std::holds_alternative<Json::object>(json.raw())) {
        throw ProtocolError("message must be a JSON object");
    }
    return json.as_object();
}

std::string dumps_json(const Json& json) {
    const auto& raw = json.raw();
    if (std::holds_alternative<std::nullptr_t>(raw)) return "null";
    if (auto value = std::get_if<bool>(&raw)) return *value ? "true" : "false";
    if (auto value = std::get_if<int64_t>(&raw)) return std::to_string(*value);
    if (auto value = std::get_if<double>(&raw)) {
        std::ostringstream out;
        out << *value;
        return out.str();
    }
    if (auto value = std::get_if<std::string>(&raw)) return json_escape(*value);
    if (auto value = std::get_if<Json::array>(&raw)) {
        std::string out = "[";
        for (std::size_t i = 0; i < value->size(); ++i) {
            if (i) out += ",";
            out += dumps_json((*value)[i]);
        }
        return out + "]";
    }
    const auto& object = std::get<Json::object>(raw);
    std::string out = "{";
    bool first = true;
    for (const auto& [key, value] : object) {
        if (!first) out += ",";
        first = false;
        out += json_escape(key);
        out += ":";
        out += dumps_json(value);
    }
    return out + "}";
}

}  // namespace hidmi
