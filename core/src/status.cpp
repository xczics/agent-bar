#include "agentbar/status.hpp"

#include <algorithm>
#include <cmath>
#include <tuple>

namespace agentbar {

namespace {

std::string get_string(const json& j, const char* key) {
  auto it = j.find(key);
  if (it != j.end() && it->is_string()) return it->get<std::string>();
  return {};
}

bool get_bool(const json& j, const char* key, bool fallback) {
  auto it = j.find(key);
  if (it != j.end() && it->is_boolean()) return it->get<bool>();
  return fallback;
}

double get_number(const json& j, const char* key, double fallback) {
  auto it = j.find(key);
  if (it != j.end() && it->is_number()) return it->get<double>();
  return fallback;
}

}  // namespace

std::optional<HookEvent> parse_hook_input(std::string_view raw) {
  try {
    json j = json::parse(raw.begin(), raw.end(), nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded() || !j.is_object()) return std::nullopt;
    HookEvent ev;
    ev.session_id = get_string(j, "session_id");
    ev.event = get_string(j, "hook_event_name");
    if (ev.session_id.empty() || ev.event.empty()) return std::nullopt;
    ev.cwd = get_string(j, "cwd");
    ev.tool_name = get_string(j, "tool_name");
    ev.prompt = get_string(j, "prompt");
    ev.message = get_string(j, "message");
    // Claude Code adds agent_id / agent_type to hooks fired inside a subagent.
    ev.subagent = !get_string(j, "agent_id").empty();
    return ev;
  } catch (...) {
    return std::nullopt;
  }
}

bool is_valid_session_id(std::string_view id) {
  if (id.empty() || id.size() > 128) return false;
  return std::all_of(id.begin(), id.end(), [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '-' || c == '_';
  });
}

std::string utf8_truncate(std::string_view s, std::size_t max_chars, bool* truncated) {
  std::size_t chars = 0;
  for (std::size_t i = 0; i < s.size(); ++i) {
    // Count lead bytes only; continuation bytes are 10xxxxxx.
    if ((static_cast<unsigned char>(s[i]) & 0xC0) != 0x80) {
      if (chars == max_chars) {
        if (truncated) *truncated = true;
        return std::string(s.substr(0, i));
      }
      ++chars;
    }
  }
  if (truncated) *truncated = false;
  return std::string(s);
}

namespace {

// Text between <tag> and </tag>, or empty.
std::string_view tag_text(std::string_view s, std::string_view tag) {
  const std::string open = "<" + std::string(tag) + ">";
  const std::string close = "</" + std::string(tag) + ">";
  auto a = s.find(open);
  if (a == std::string_view::npos) return {};
  a += open.size();
  auto b = s.find(close, a);
  return b == std::string_view::npos ? std::string_view{} : s.substr(a, b - a);
}

}  // namespace

std::string describe_prompt(std::string_view prompt) {
  std::string_view p = prompt;
  while (!p.empty() && (p.front() == ' ' || p.front() == '\n' || p.front() == '\r' || p.front() == '\t'))
    p.remove_prefix(1);
  if (p.substr(0, 19) != "<task-notification>") return std::string(prompt);

  const std::string_view status = tag_text(p, "status");
  std::string out = status == "completed"                     ? "后台任务完成"
                    : status == "failed"                      ? "后台任务失败"
                    : status == "killed" || status == "stopped" ? "后台任务已停止"
                                                              : "后台任务通知";
  // The summary quotes the task's description: Background command "Desc" completed …
  const std::string_view summary = tag_text(p, "summary");
  auto q1 = summary.find('"');
  auto q2 = q1 == std::string_view::npos ? q1 : summary.find('"', q1 + 1);
  if (q2 != std::string_view::npos && q2 > q1 + 1) {
    out += "：";
    out += summary.substr(q1 + 1, q2 - q1 - 1);
  }
  return out;
}

std::string flatten_whitespace(std::string_view s) {
  std::string out(s);
  for (char& c : out) {
    if (c == '\n' || c == '\r' || c == '\t') c = ' ';
  }
  return out;
}

std::string project_name(std::string_view cwd) {
  while (cwd.size() > 1 && (cwd.back() == '/' || cwd.back() == '\\')) cwd.remove_suffix(1);
  auto pos = cwd.find_last_of("/\\");
  if (pos == std::string_view::npos) return std::string(cwd);
  if (pos + 1 == cwd.size()) return std::string(cwd);  // "/" itself
  return std::string(cwd.substr(pos + 1));
}

Transition apply_event(const json* old, const HookEvent& ev, double now) {
  Transition t;
  const std::string& e = ev.event;
  // Only the main agent's state is shown. A subagent's events are a heartbeat:
  // they refresh `updated` so a main agent waiting on a long subagent is not
  // flagged stale, but change nothing else (state, detail, cwd). A subagent's
  // permission request still blocks the whole session, so Notification is kept.
  if (ev.subagent && e != "Notification") {
    if (!old || !old->is_object()) return t;
    t.action = Action::Write;
    t.doc = *old;
    t.doc["updated"] = now;
    return t;
  }
  if (e == "SessionEnd") {
    t.action = Action::Delete;
    return t;
  }

  json doc = (old && old->is_object()) ? *old : json::object();
  const std::string old_state = get_string(doc, "state");
  const std::string old_detail = get_string(doc, "detail");
  const bool old_unread = get_bool(doc, "unread", false);

  std::string state;
  std::string detail;
  bool unread = false;
  if (e == "SessionStart") {
    state = "idle";
  } else if (e == "UserPromptSubmit") {
    state = "busy";
    detail = utf8_truncate(flatten_whitespace(describe_prompt(ev.prompt)), kPromptDetailChars);
  } else if (e == "PreToolUse") {
    state = "busy";
    detail = ev.tool_name;
  } else if (e == "PostToolUse") {
    state = "busy";
    detail = old_detail;
  } else if (e == "Notification") {
    if (old_state == "replied") {
      // The "still waiting for input" reminder after a reply must not turn
      // "replied" into "waiting" nor reset read state.
      state = "replied";
      unread = old_unread;
      detail = old_detail;
    } else {
      state = "waiting";
      unread = true;
      detail = utf8_truncate(flatten_whitespace(ev.message), kMessageDetailChars);
    }
  } else if (e == "Stop") {
    state = "replied";
    unread = true;
  } else {
    return t;  // events we don't track
  }

  const bool same_state = (state == old_state);
  const double since = same_state ? get_number(doc, "since", now) : now;

  // Assignment order defines key order for new files; existing keys keep their place.
  doc["v"] = kProtocolVersion;
  doc["session_id"] = ev.session_id;
  if (!ev.agent.empty()) doc["agent"] = ev.agent;
  // First cwd wins: subagents share the session_id but may run in a worktree.
  if (get_string(doc, "cwd").empty() && !ev.cwd.empty()) {
    doc["project"] = project_name(ev.cwd);
    doc["cwd"] = ev.cwd;
  } else {
    if (!doc.contains("project")) doc["project"] = project_name(get_string(doc, "cwd"));
    if (!doc.contains("cwd")) doc["cwd"] = "";
  }
  doc["state"] = state;
  doc["detail"] = detail;
  doc["unread"] = unread;
  doc["since"] = since;
  doc["updated"] = now;

  t.action = Action::Write;
  t.doc = std::move(doc);
  return t;
}

std::optional<RegisteredSession> parse_registry_entry(std::string_view raw) {
  try {
    json j = json::parse(raw.begin(), raw.end(), nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded() || !j.is_object()) return std::nullopt;
    RegisteredSession r;
    auto pid = j.find("pid");
    if (pid == j.end() || !pid->is_number_integer()) return std::nullopt;
    r.pid = pid->get<long>();
    r.session_id = get_string(j, "sessionId");
    r.cwd = get_string(j, "cwd");
    r.status = get_string(j, "status");
    if (r.pid <= 0 || !is_valid_session_id(r.session_id)) return std::nullopt;
    return r;
  } catch (...) {
    return std::nullopt;
  }
}

json discovered_session_doc(const RegisteredSession& r, double now) {
  HookEvent ev;
  ev.agent = "claude";  // the registry is Claude Code's
  ev.session_id = r.session_id;
  ev.cwd = r.cwd;
  ev.event = r.status == "busy" ? "PostToolUse" : "SessionStart";  // busy with empty detail, or idle
  return apply_event(nullptr, ev, now).doc;
}

std::optional<Session> session_from_json(const json& j, std::string_view id) {
  if (!j.is_object()) return std::nullopt;
  Session s;
  s.id = std::string(id);
  s.cwd = get_string(j, "cwd");
  s.agent = get_string(j, "agent");
  s.project = get_string(j, "project");
  if (s.project.empty()) s.project = s.cwd.empty() ? s.id : project_name(s.cwd);
  s.state = get_string(j, "state");
  s.detail = get_string(j, "detail");
  s.unread = get_bool(j, "unread", false);
  s.updated = get_number(j, "updated", 0);
  s.since = get_number(j, "since", s.updated);
  return s;
}

DisplayState display_state(const Session& s, double now, double stale_after) {
  if (s.state == "waiting") return DisplayState::Waiting;
  // A reply you have already read is your turn now, not something to flag:
  // show it like idle. (A read "waiting" stays red: the agent is still blocked.)
  if (s.state == "replied") return s.unread ? DisplayState::Replied : DisplayState::Idle;
  if (s.state == "busy") {
    return (now - s.updated > stale_after) ? DisplayState::Stale : DisplayState::Busy;
  }
  return DisplayState::Idle;  // "idle" and anything unknown
}

int display_rank(DisplayState d) { return static_cast<int>(d); }

const char* display_label(DisplayState d) {
  switch (d) {
    case DisplayState::Waiting: return "等你确认";
    case DisplayState::Replied: return "已回复";
    case DisplayState::Busy: return "运行中";
    case DisplayState::Stale: return "无响应?";
    case DisplayState::Idle: return "空闲";
  }
  return "";
}

const char* display_short_label(DisplayState d) {
  switch (d) {
    case DisplayState::Waiting: return "确认";
    case DisplayState::Replied: return "回复";
    case DisplayState::Busy: return "运行";
    case DisplayState::Stale: return "无响应";
    case DisplayState::Idle: return "空闲";
  }
  return "";
}

std::uint32_t default_color(DisplayState d) {
  switch (d) {
    case DisplayState::Waiting: return 0xe5484d;  // red
    case DisplayState::Replied: return 0xffc53d;  // yellow
    case DisplayState::Busy: return 0x30a46c;     // green
    case DisplayState::Stale: return 0x8b8d98;    // gray
    case DisplayState::Idle: return 0x46644f;     // green, switched off
  }
  return 0x8b8d98;
}

const char* display_key(DisplayState d) {
  switch (d) {
    case DisplayState::Waiting: return "waiting";
    case DisplayState::Replied: return "replied";
    case DisplayState::Busy: return "busy";
    case DisplayState::Stale: return "stale";
    case DisplayState::Idle: return "idle";
  }
  return "";
}

void sort_sessions(std::vector<Session>& sessions, double now, double stale_after) {
  auto key = [&](const Session& s) {
    return std::make_tuple(s.unread ? 0 : 1, display_rank(display_state(s, now, stale_after)),
                           -s.updated);
  };
  std::stable_sort(sessions.begin(), sessions.end(), [&](const Session& a, const Session& b) {
    auto ka = key(a), kb = key(b);
    if (ka != kb) return ka < kb;
    return a.id < b.id;
  });
}

std::string format_elapsed(double seconds) {
  if (!(seconds > 0)) seconds = 0;  // also catches NaN
  auto n = static_cast<long long>(std::floor(seconds));
  if (n < 60) return std::to_string(n) + "s";
  if (n < 3600) return std::to_string(n / 60) + "m";
  if (n < 86400) return std::to_string(n / 3600) + "h";
  return std::to_string(n / 86400) + "d";
}

std::string display_detail(std::string_view detail) {
  bool cut = false;
  std::string out = utf8_truncate(detail, kDisplayDetailChars, &cut);
  if (cut) out += "…";
  return out;
}

std::string title_text(const std::vector<Session>& sessions, double now, double stale_after) {
  int running = 0, unread = 0;
  for (const auto& s : sessions) {
    if (display_state(s, now, stale_after) == DisplayState::Busy) ++running;
    if (s.unread) ++unread;
  }
  return "Agents  " + std::to_string(running) + " 运行  " + std::to_string(unread) + " 未读";
}

LightGrid light_grid(std::size_t sessions, int per_row, int max_rows) {
  LightGrid g;
  const std::size_t cap = static_cast<std::size_t>(per_row) * static_cast<std::size_t>(max_rows);
  std::size_t cells = sessions;
  if (sessions > cap) {
    g.lights = static_cast<int>(cap) - 1;
    g.overflow = static_cast<int>(sessions - g.lights);
    cells = cap;
  } else {
    g.lights = static_cast<int>(sessions);
  }
  const int n = static_cast<int>(cells);
  g.cols = n == 0 ? 0 : (n < per_row ? n : per_row);
  g.rows = n == 0 ? 0 : (n + per_row - 1) / per_row;
  return g;
}

namespace {

// Splits UTF-8 into code points (as byte strings).
std::vector<std::string> utf8_chars(std::string_view s) {
  std::vector<std::string> out;
  for (std::size_t i = 0; i < s.size();) {
    std::size_t j = i + 1;
    while (j < s.size() && (static_cast<unsigned char>(s[j]) & 0xC0) == 0x80) ++j;
    out.emplace_back(s.substr(i, j - i));
    i = j;
  }
  return out;
}

int columns(const std::string& ch) { return ch.size() > 1 ? 2 : 1; }  // non-ASCII as wide

}  // namespace

std::string short_name(std::string_view project) {
  constexpr int kMaxColumns = 6;
  const auto chars = utf8_chars(project);
  int width = 0;
  for (const auto& c : chars) width += columns(c);
  if (width <= kMaxColumns) return std::string(project);

  // Initials of words split on separators.
  std::string initials;
  bool at_start = true;
  int words = 0;
  for (const auto& c : chars) {
    const bool sep = c == "-" || c == "_" || c == " " || c == ".";
    if (sep) {
      at_start = true;
      continue;
    }
    if (at_start) {
      ++words;
      if (words <= 4) {
        std::string up = c;
        if (up.size() == 1 && up[0] >= 'a' && up[0] <= 'z') up[0] = static_cast<char>(up[0] - 'a' + 'A');
        initials += up;
      }
      at_start = false;
    }
  }
  if (words >= 2) return initials;

  std::string out;
  int used = 0;
  for (const auto& c : chars) {
    if (used + columns(c) > kMaxColumns - 1) break;
    out += c;
    used += columns(c);
  }
  return out + "…";
}

std::string status_text(const Session& s, double now, double stale_after) {
  return std::string(display_label(display_state(s, now, stale_after))) + " · " +
         format_elapsed(now - s.since);
}

}  // namespace agentbar
