// Platform-independent status logic: the hook event -> state machine, session
// parsing, display derivation and ordering. No file system access here.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace agentbar {

// ordered_json keeps key order of existing files, so unknown fields survive in place.
using json = nlohmann::ordered_json;

inline constexpr int kProtocolVersion = 1;
inline constexpr std::size_t kPromptDetailChars = 60;
inline constexpr std::size_t kMessageDetailChars = 200;
inline constexpr std::size_t kDisplayDetailChars = 48;

// A normalized hook event. `event` is one of SessionStart, UserPromptSubmit,
// PreToolUse, PostToolUse, Notification, Stop, SessionEnd (Claude Code's names
// are the internal vocabulary; adapters map other agents onto them).
struct HookEvent {
  std::string agent;  // adapter name, e.g. "claude"; empty = not recorded
  std::string session_id;
  std::string event;  // hook_event_name
  std::string cwd;
  std::string tool_name;
  std::string prompt;
  std::string message;
  // Fired inside a subagent (Task/Agent tool) of this session. Subagents share
  // the parent's session_id but run elsewhere (e.g. a worktree); only the main
  // agent's state is shown, so apply_event ignores these except Notification.
  bool subagent = false;
};

// Parses Claude Code's hook stdin JSON (the "claude" adapter). Returns nullopt
// for invalid JSON, a non-object, or a missing session_id / hook_event_name.
// Never throws.
std::optional<HookEvent> parse_hook_input(std::string_view raw);

// Only [A-Za-z0-9_-], non-empty, at most 128 bytes.
bool is_valid_session_id(std::string_view id);

// Truncates to at most max_chars Unicode code points without splitting a
// multi-byte sequence. Sets *truncated when anything was cut.
std::string utf8_truncate(std::string_view s, std::size_t max_chars, bool* truncated = nullptr);

// Detail text for a UserPromptSubmit. Claude Code delivers background-task
// results as a synthetic prompt "<task-notification>…<status>completed</status>
// <summary>Background command "Desc" completed …</summary>…"; those become
// "后台任务完成：Desc" (失败 / 已停止). Other prompts are returned unchanged.
std::string describe_prompt(std::string_view prompt);

// Replaces \r, \n and \t with spaces.
std::string flatten_whitespace(std::string_view s);

// Last path component of cwd ("/a/b/" -> "b"); handles both / and \.
std::string project_name(std::string_view cwd);

enum class Action { Ignore, Write, Delete };

struct Transition {
  Action action = Action::Ignore;
  json doc;  // the new file content when action == Write
};

// The state machine from docs/design.md. `old` is the current file content or
// nullptr when the file does not exist (or is unreadable).
// The session's cwd/project is the first one recorded; later events (e.g. a
// subagent working in a worktree) never rename it. Subagent events only refresh
// `updated` (a heartbeat against stale), except Notification, which blocks the
// whole session and is applied normally.
Transition apply_event(const json* old, const HookEvent& ev, double now);

// An entry of Claude Code's own session registry (~/.claude/sessions/<pid>.json).
// Undocumented format, read best-effort: {"pid", "sessionId", "cwd", "status"}.
struct RegisteredSession {
  long pid = 0;
  std::string session_id;
  std::string cwd;
  std::string status;  // "busy", "idle", ...
};
std::optional<RegisteredSession> parse_registry_entry(std::string_view raw);

// Initial status file for a running session we have not seen any hook event
// from (e.g. it predates the hook install). busy -> busy, anything else -> idle.
json discovered_session_doc(const RegisteredSession& r, double now);

// ---- reading side (agent-bar) ----

enum class DisplayState { Waiting, Replied, Busy, Stale, Idle };

struct Session {
  std::string id;
  std::string agent;  // "" for files written before the field existed
  std::string project;
  std::string cwd;
  std::string state;
  std::string detail;
  bool unread = false;
  double since = 0;
  double updated = 0;
};

// Builds a Session from a status file. `id` is the file stem (authoritative).
// Returns nullopt if the document is not an object. Missing fields get defaults.
std::optional<Session> session_from_json(const json& j, std::string_view id);

// replied + read is shown as Idle; busy without events for stale_after is Stale.
DisplayState display_state(const Session& s, double now, double stale_after);
int display_rank(DisplayState d);  // waiting=0 ... idle=4
const char* display_label(DisplayState d);
const char* display_short_label(DisplayState d);  // compact mode: "确认", "运行", ...
// Default palette (0xRRGGBB); users can override it in bar.ini / settings.
// busy = green, idle = dimmed green, replied = yellow, waiting = red, stale = gray.
std::uint32_t default_color(DisplayState d);
inline constexpr DisplayState kAllDisplayStates[] = {DisplayState::Waiting, DisplayState::Replied,
                                                     DisplayState::Busy, DisplayState::Stale,
                                                     DisplayState::Idle};
const char* display_key(DisplayState d);  // "waiting", "replied", "busy", "stale", "idle"

// Unread first, then waiting > replied > busy > stale > idle, then updated desc.
void sort_sessions(std::vector<Session>& sessions, double now, double stale_after);

// "12s", "3m", "2h", "4d".
std::string format_elapsed(double seconds);

// Detail for display: truncated to kDisplayDetailChars plus "…".
std::string display_detail(std::string_view detail);

// "Agents  N 运行  M 未读"
std::string title_text(const std::vector<Session>& sessions, double now, double stale_after);

// Compact mode: one light per session, up to kLightsPerRow per row and
// kMaxLightRows rows. When sessions don't fit, the last cell becomes "+N".
inline constexpr int kLightsPerRow = 6;
inline constexpr int kMaxLightRows = 3;

struct LightGrid {
  int lights = 0;    // sessions drawn as lights (the first `lights` in sort order)
  int overflow = 0;  // sessions behind the "+N" cell (0 = no such cell)
  int cols = 0;
  int rows = 0;
};
LightGrid light_grid(std::size_t sessions, int per_row = kLightsPerRow, int max_rows = kMaxLightRows);

// Short tag for a project shown above its light: names up to 6 columns stay
// as-is; multi-word names (-, _, space, .) become initials ("agent-bar" -> "AB");
// otherwise the first 5 columns plus "…". CJK characters count as 2 columns.
std::string short_name(std::string_view project);

// "运行中 · 3m"
std::string status_text(const Session& s, double now, double stale_after);

}  // namespace agentbar
