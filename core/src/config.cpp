#include "agentbar/config.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <sstream>

namespace agentbar {

namespace {

std::string_view trim(std::string_view s) {
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r')) s.remove_suffix(1);
  return s;
}

bool parse_double(std::string_view v, double* out) {
  std::string tmp(v);
  char* end = nullptr;
  double d = std::strtod(tmp.c_str(), &end);
  if (tmp.empty() || end != tmp.c_str() + tmp.size() || !std::isfinite(d)) return false;
  *out = d;
  return true;
}

// "#rrggbb" or "rrggbb".
bool parse_hex_color(std::string_view v, std::uint32_t* out) {
  if (!v.empty() && v[0] == '#') v.remove_prefix(1);
  if (v.size() != 6) return false;
  std::uint32_t rgb = 0;
  for (char ch : v) {
    int d;
    if (ch >= '0' && ch <= '9') d = ch - '0';
    else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
    else return false;
    rgb = (rgb << 4) | static_cast<std::uint32_t>(d);
  }
  *out = rgb;
  return true;
}

}  // namespace

BarConfig parse_bar_ini(std::string_view text) {
  BarConfig c;
  bool has_x = false, has_top = false;
  while (!text.empty()) {
    auto nl = text.find('\n');
    std::string_view line = trim(text.substr(0, nl));
    text = (nl == std::string_view::npos) ? std::string_view{} : text.substr(nl + 1);
    if (line.empty() || line[0] == '#' || line[0] == ';' || line[0] == '[') continue;
    auto eq = line.find('=');
    if (eq == std::string_view::npos) continue;
    std::string_view key = trim(line.substr(0, eq));
    std::string_view value = trim(line.substr(eq + 1));
    if (key.substr(0, 6) == "color_") {
      std::uint32_t rgb = 0;
      if (!parse_hex_color(value, &rgb)) continue;
      for (DisplayState d : kAllDisplayStates) {
        if (key.substr(6) == display_key(d)) c.set_color(d, rgb);
      }
      continue;
    }
    double v = 0;
    if (!parse_double(value, &v)) continue;
    if (key == "x") {
      c.x = v;
      has_x = true;
    } else if (key == "top") {
      c.top = v;
      has_top = true;
    } else if (key == "stale_minutes" && v > 0) {
      c.stale_minutes = v;
    } else if (key == "expire_hours" && v > 0) {
      c.expire_hours = v;
    } else if (key == "compact") {
      c.compact = v != 0;
    } else if (key == "show_names") {
      c.show_names = v != 0;
    } else if (key == "show_status") {
      c.show_status = v != 0;
    }
  }
  c.has_position = has_x && has_top;
  return c;
}

std::string format_bar_ini(const BarConfig& c) {
  std::ostringstream o;
  o << "# agent-bar settings\n";
  if (c.has_position) {
    o << "x=" << c.x << "\n";
    o << "top=" << c.top << "\n";
  }
  o << "stale_minutes=" << c.stale_minutes << "\n";
  o << "expire_hours=" << c.expire_hours << "\n";
  o << "compact=" << (c.compact ? 1 : 0) << "\n";
  o << "show_names=" << (c.show_names ? 1 : 0) << "\n";
  o << "show_status=" << (c.show_status ? 1 : 0) << "\n";
  for (DisplayState d : kAllDisplayStates) {
    char hex[8];
    std::snprintf(hex, sizeof hex, "#%06x", static_cast<unsigned>(c.color(d)));
    o << "color_" << display_key(d) << "=" << hex << "\n";
  }
  return o.str();
}

}  // namespace agentbar
