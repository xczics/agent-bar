#include "agentbar/settings.hpp"

namespace agentbar {

namespace {

bool is_tool_event(std::string_view event) {
  return event == "PreToolUse" || event == "PostToolUse";
}

bool is_our_entry(const json& h) {
  return h.is_object() && h.contains("command") && h["command"].is_string() &&
         is_our_hook_command(h["command"].get<std::string>());
}

// Removes our entries from one event array; drops groups that become empty.
bool prune_event(json& groups) {
  bool changed = false;
  for (auto g = groups.begin(); g != groups.end();) {
    if (g->is_object() && g->contains("hooks") && (*g)["hooks"].is_array()) {
      json& hooks = (*g)["hooks"];
      bool removed_here = false;
      for (auto h = hooks.begin(); h != hooks.end();) {
        if (is_our_entry(*h)) {
          h = hooks.erase(h);
          removed_here = true;
        } else {
          ++h;
        }
      }
      changed |= removed_here;
      if (hooks.empty() && removed_here) {
        g = groups.erase(g);
        continue;
      }
    }
    ++g;
  }
  return changed;
}

// True when the event holds exactly one of our entries and it is already in the
// desired shape, so a re-run of install leaves the file byte-identical.
bool already_installed(const json& groups, const std::string& command, bool need_star) {
  int ours = 0, exact = 0;
  for (const auto& g : groups) {
    if (!g.is_object() || !g.contains("hooks") || !g["hooks"].is_array()) continue;
    for (const auto& h : g["hooks"]) {
      if (!is_our_entry(h)) continue;
      ++ours;
      const bool matcher_ok =
          !need_star || (g.contains("matcher") && g["matcher"].is_string() &&
                         g["matcher"].get<std::string>() == "*");
      if (h["command"].get<std::string>() == command && matcher_ok) ++exact;
    }
  }
  return ours == 1 && exact == 1;
}

}  // namespace

bool is_our_hook_command(std::string_view command) {
  if (command.find("status_hook.py") != std::string_view::npos) return true;
  while (!command.empty() && (command.back() == ' ' || command.back() == '"' || command.back() == '\''))
    command.remove_suffix(1);
  while (!command.empty() && (command.front() == ' ' || command.front() == '"' || command.front() == '\''))
    command.remove_prefix(1);
  auto pos = command.find_last_of("/\\");
  std::string_view base = (pos == std::string_view::npos) ? command : command.substr(pos + 1);
  return base == "agent-status-hook" || base == "agent-status-hook.exe";
}

std::string hook_command_for_path(const std::string& path) {
  if (path.find_first_of(" \t'\"$`\\&;()<>|*?[]#~") == std::string::npos) return path;
  std::string out = "\"";
  for (char c : path) {
    if (c == '"' || c == '\\' || c == '$' || c == '`') out += '\\';
    out += c;
  }
  out += '"';
  return out;
}

bool merge_hooks(json& settings, const std::string& command) {
  if (!settings.is_object()) return false;
  bool changed = false;
  if (!settings.contains("hooks") || !settings["hooks"].is_object()) {
    settings["hooks"] = json::object();
    changed = true;
  }
  json& hooks = settings["hooks"];
  for (const char* event : kHookEvents) {
    if (!hooks.contains(event) || !hooks[event].is_array()) {
      if (hooks.contains(event)) continue;  // malformed user value: leave it alone
      hooks[event] = json::array();
    }
    json& groups = hooks[event];
    if (already_installed(groups, command, is_tool_event(event))) continue;
    prune_event(groups);
    json group = json::object();
    if (is_tool_event(event)) group["matcher"] = "*";
    group["hooks"] = json::array({json{{"type", "command"}, {"command", command}}});
    groups.push_back(std::move(group));
    changed = true;
  }
  return changed;
}

bool remove_hooks(json& settings) {
  if (!settings.is_object() || !settings.contains("hooks") || !settings["hooks"].is_object())
    return false;
  json& hooks = settings["hooks"];
  bool changed = false;
  for (const char* event : kHookEvents) {
    if (!hooks.contains(event) || !hooks[event].is_array()) continue;
    if (prune_event(hooks[event])) {
      changed = true;
      if (hooks[event].empty()) hooks.erase(event);
    }
  }
  if (changed && hooks.empty()) settings.erase("hooks");
  return changed;
}

}  // namespace agentbar
