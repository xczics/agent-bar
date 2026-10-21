// agent-status/bar.ini: window position and thresholds.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include "agentbar/status.hpp"

namespace agentbar {

struct BarConfig {
  bool has_position = false;
  double x = 0;    // window left edge, screen points
  double top = 0;  // window top edge (platform coordinates)
  double stale_minutes = 10;
  double expire_hours = 12;
  bool compact = true;      // lights-only view; click to expand
  bool show_names = true;   // compact: short project name above each light
  bool show_status = true;  // compact: short status below each light
  bool all_spaces = false;  // on every desktop (fixed in Mission Control) vs. one movable desktop
  // Colours per display state (0xRRGGBB), indexed by DisplayState.
  std::uint32_t colors[5] = {
      default_color(DisplayState::Waiting), default_color(DisplayState::Replied),
      default_color(DisplayState::Busy), default_color(DisplayState::Stale),
      default_color(DisplayState::Idle)};

  std::uint32_t color(DisplayState d) const { return colors[static_cast<int>(d)]; }
  void set_color(DisplayState d, std::uint32_t rgb) { colors[static_cast<int>(d)] = rgb & 0xffffff; }

  double stale_after_seconds() const { return stale_minutes * 60; }
  double expire_after_seconds() const { return expire_hours * 3600; }
};

// Lenient key=value parser; unknown keys, comments (# ;) and bad values are ignored.
BarConfig parse_bar_ini(std::string_view text);
std::string format_bar_ini(const BarConfig& c);

}  // namespace agentbar
