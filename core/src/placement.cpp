#include "agentbar/placement.hpp"

#include <algorithm>

namespace agentbar {

ScreenRect place_window(const BarConfig& cfg, double w, double h, const std::vector<ScreenRect>& screens,
                  const ScreenRect& main_visible) {
  if (cfg.has_position) {
    // Probe a point just inside the top-left corner of the saved position.
    const double px = cfg.x + 10, py = cfg.top - 10;
    for (const ScreenRect& s : screens) {
      if (s.contains(px, py)) return {cfg.x, cfg.top - h, w, h};
    }
  }
  return {main_visible.max_x() - w - kScreenMargin, main_visible.max_y() - h - kScreenMargin, w, h};
}

bool frame_on_screen(const ScreenRect& frame, const std::vector<ScreenRect>& screens, double min_visible) {
  for (const ScreenRect& s : screens) {
    const double ow = std::min(frame.max_x(), s.max_x()) - std::max(frame.x, s.x);
    const double oh = std::min(frame.max_y(), s.max_y()) - std::max(frame.y, s.y);
    if (ow >= std::min(min_visible, frame.w) && oh >= std::min(min_visible, frame.h)) return true;
  }
  return false;
}

}  // namespace agentbar
