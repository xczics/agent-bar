// Where the floating window goes, given the screens currently attached.
// Pure geometry so it can be unit-tested; coordinates are Cocoa's (origin at
// the bottom-left of the main screen, y up).
#pragma once

#include <vector>

#include "agentbar/config.hpp"

namespace agentbar {

struct ScreenRect {
  double x = 0, y = 0, w = 0, h = 0;
  double max_x() const { return x + w; }
  double max_y() const { return y + h; }
  bool contains(double px, double py) const { return px >= x && px < max_x() && py >= y && py < max_y(); }
};

inline constexpr double kScreenMargin = 20;

// Frame for a w x h window: the saved top-left (cfg.x, cfg.top) when that spot
// is on one of `screens` (their full frames); otherwise the top-right corner
// of `main_visible` (the main screen minus menu bar and Dock). Never writes the
// saved position, so a display that comes back gets its window back.
ScreenRect place_window(const BarConfig& cfg, double w, double h, const std::vector<ScreenRect>& screens,
                  const ScreenRect& main_visible);

// True when at least `min_visible` points of the window's width and height
// overlap some screen.
bool frame_on_screen(const ScreenRect& frame, const std::vector<ScreenRect>& screens, double min_visible = 20);

}  // namespace agentbar
