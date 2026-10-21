// Merging our hook entries into Claude Code's settings.json.
#pragma once

#include <string>
#include <string_view>

#include "agentbar/status.hpp"

namespace agentbar {

inline constexpr const char* kHookEvents[] = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "Notification", "Stop",             "SessionEnd",
};

// True for commands pointing at agent-status-hook (any path, quoted or not) or
// at the Python prototype status_hook.py, which install replaces.
bool is_our_hook_command(std::string_view command);

// Wraps the path in double quotes when it contains characters a shell would split on.
std::string hook_command_for_path(const std::string& path);

// Ensures every event in kHookEvents has exactly one entry running `command`
// (tool events with matcher "*"). Other hooks are left untouched.
// Returns true when `settings` changed. `settings` must be an object.
bool merge_hooks(json& settings, const std::string& command);

// True when every event in kHookEvents has an entry running agent-status-hook.
bool hooks_complete(const json& settings);

// Removes all of our entries, pruning groups/events/"hooks" that become empty.
bool remove_hooks(json& settings);

}  // namespace agentbar
