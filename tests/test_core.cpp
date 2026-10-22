// Unit tests for core/. Deliberately dependency-free: a tiny CHECK macro and a
// registry of test functions. Run: ./build/bin/core_tests
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

#include "agentbar/adapter.hpp"
#include "agentbar/config.hpp"
#include "agentbar/settings.hpp"
#include "agentbar/status.hpp"
#include "agentbar/store.hpp"

using namespace agentbar;

namespace {

int g_failures = 0;
std::vector<std::pair<const char*, std::function<void()>>>& registry() {
  static std::vector<std::pair<const char*, std::function<void()>>> r;
  return r;
}
struct Register {
  Register(const char* name, std::function<void()> fn) { registry().emplace_back(name, fn); }
};

#define TEST(name)                                  \
  static void name();                               \
  static Register reg_##name(#name, name);          \
  static void name()

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      ++g_failures;                                                          \
      std::fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                        \
  } while (0)

#define CHECK_EQ(a, b)                                                                     \
  do {                                                                                     \
    auto _a = (a);                                                                         \
    auto _b = (b);                                                                         \
    if (!(_a == _b)) {                                                                     \
      ++g_failures;                                                                        \
      std::fprintf(stderr, "  FAIL %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b);        \
    }                                                                                      \
  } while (0)

HookEvent ev(const char* event, const char* extra_field = nullptr, const char* value = "") {
  HookEvent e;
  e.session_id = "s1";
  e.event = event;
  e.cwd = "/Users/me/code/my-app";
  if (extra_field) {
    std::string f = extra_field;
    if (f == "prompt") e.prompt = value;
    if (f == "tool_name") e.tool_name = value;
    if (f == "message") e.message = value;
  }
  return e;
}

json doc_with(const char* state, bool unread, const char* detail, double since = 100) {
  return json{{"v", 1},          {"session_id", "s1"}, {"project", "my-app"},
              {"cwd", "/x/my-app"}, {"state", state},   {"detail", detail},
              {"unread", unread},  {"since", since},    {"updated", since}};
}

std::string make_temp_dir() {
  char tmpl[] = "/tmp/agentbar-test-XXXXXX";
  const char* d = mkdtemp(tmpl);
  return d ? d : "/tmp";
}

}  // namespace

// ---------- hook input ----------

TEST(parse_hook_input_valid) {
  auto e = parse_hook_input(
      R"({"session_id":"abc","hook_event_name":"PreToolUse","cwd":"/a/b","tool_name":"Bash","extra":1})");
  CHECK(e.has_value());
  CHECK_EQ(e->session_id, std::string("abc"));
  CHECK_EQ(e->event, std::string("PreToolUse"));
  CHECK_EQ(e->tool_name, std::string("Bash"));
}

TEST(parse_hook_input_invalid) {
  CHECK(!parse_hook_input(""));
  CHECK(!parse_hook_input("not json"));
  CHECK(!parse_hook_input("[1,2]"));
  CHECK(!parse_hook_input(R"({"hook_event_name":"Stop"})"));
  CHECK(!parse_hook_input(R"({"session_id":"a"})"));
  CHECK(!parse_hook_input(R"({"session_id":5,"hook_event_name":"Stop"})"));
}

TEST(adapters_registry) {
  const Adapter* claude = find_adapter("claude");
  CHECK(claude != nullptr);
  CHECK_EQ(std::string(adapters().front().name), std::string(kDefaultAdapter));
  CHECK(find_adapter("nope") == nullptr);
  for (const auto& a : adapters()) {
    CHECK(is_valid_session_id(a.name));  // usable as a CLI value and file field
    CHECK(!a.parse("not json"));          // every adapter must reject garbage quietly
  }
  auto e = parse_with(*claude, R"({"session_id":"s","hook_event_name":"Stop","cwd":"/a/b"})");
  CHECK(e.has_value());
  CHECK_EQ(e->agent, std::string("claude"));
  auto t = apply_event(nullptr, *e, 1);
  CHECK_EQ(t.doc["agent"].get<std::string>(), std::string("claude"));
  CHECK_EQ(session_from_json(t.doc, "s")->agent, std::string("claude"));
  HookEvent bare;  // no agent: field is not written (keeps old files byte-compatible)
  bare.session_id = "s";
  bare.event = "Stop";
  CHECK(!apply_event(nullptr, bare, 1).doc.contains("agent"));
}

TEST(session_id_validation) {
  CHECK(is_valid_session_id("abc-DEF_123"));
  CHECK(is_valid_session_id("3f2a1b7c-0000-4000-8000-1234567890ab"));
  CHECK(!is_valid_session_id(""));
  CHECK(!is_valid_session_id("../etc"));
  CHECK(!is_valid_session_id("a/b"));
  CHECK(!is_valid_session_id("a.b"));
  CHECK(!is_valid_session_id("a b"));
  CHECK(!is_valid_session_id(std::string(129, 'a')));
}

TEST(utf8_truncation) {
  bool cut = false;
  CHECK_EQ(utf8_truncate("hello", 3, &cut), std::string("hel"));
  CHECK(cut);
  CHECK_EQ(utf8_truncate("hello", 5, &cut), std::string("hello"));
  CHECK(!cut);
  CHECK_EQ(utf8_truncate("你好世界", 2), std::string("你好"));
  CHECK_EQ(utf8_truncate("a😀b", 2), std::string("a😀"));
  CHECK_EQ(utf8_truncate("", 3), std::string(""));
  std::string sixty_one(61, 'x');
  CHECK_EQ(utf8_truncate(sixty_one, 60).size(), std::size_t(60));
}

TEST(project_names) {
  CHECK_EQ(project_name("/Users/me/code/my-app"), std::string("my-app"));
  CHECK_EQ(project_name("/Users/me/code/my-app/"), std::string("my-app"));
  CHECK_EQ(project_name("C:\\work\\proj"), std::string("proj"));
  CHECK_EQ(project_name("proj"), std::string("proj"));
  CHECK_EQ(project_name("/"), std::string("/"));
}

// ---------- state machine: one test per row of the mapping table ----------

TEST(map_session_start) {
  auto t = apply_event(nullptr, ev("SessionStart"), 1000);
  CHECK(t.action == Action::Write);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("idle"));
  CHECK_EQ(t.doc["unread"].get<bool>(), false);
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string(""));
  CHECK_EQ(t.doc["project"].get<std::string>(), std::string("my-app"));
  CHECK_EQ(t.doc["cwd"].get<std::string>(), std::string("/Users/me/code/my-app"));
  CHECK_EQ(t.doc["v"].get<int>(), 1);
  CHECK_EQ(t.doc["session_id"].get<std::string>(), std::string("s1"));
  CHECK_EQ(t.doc["since"].get<double>(), 1000.0);
  CHECK_EQ(t.doc["updated"].get<double>(), 1000.0);
}

TEST(map_user_prompt_submit) {
  json old = doc_with("replied", true, "x");
  std::string prompt = "line1\nline2\r\n" + std::string(100, 'z');
  auto t = apply_event(&old, ev("UserPromptSubmit", "prompt", prompt.c_str()), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(t.doc["unread"].get<bool>(), false);
  auto detail = t.doc["detail"].get<std::string>();
  CHECK_EQ(detail.substr(0, 13), std::string("line1 line2  "));
  CHECK_EQ(detail.size(), std::size_t(60));
}

TEST(map_user_prompt_multibyte) {
  std::string prompt;
  for (int i = 0; i < 70; ++i) prompt += "字";
  auto t = apply_event(nullptr, ev("UserPromptSubmit", "prompt", prompt.c_str()), 1);
  CHECK_EQ(t.doc["detail"].get<std::string>().size(), std::size_t(60 * 3));
}

TEST(task_notification_prompts) {
  const char* done =
      "<task-notification>\n<task-id>bffmgz8qe</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n"
      "<output-file>/tmp/x.output</output-file>\n<status>completed</status>\n"
      "<summary>Background command \"Run tests\" completed (exit code 0)</summary>\n</task-notification>";
  CHECK_EQ(describe_prompt(done), std::string("后台任务完成：Run tests"));
  CHECK_EQ(describe_prompt("<task-notification><status>failed</status></task-notification>"),
           std::string("后台任务失败"));
  CHECK_EQ(describe_prompt("\n<task-notification><status>killed</status><summary>no quotes</summary>"),
           std::string("后台任务已停止"));
  CHECK_EQ(describe_prompt("<task-notification><status>weird</status>"), std::string("后台任务通知"));
  CHECK_EQ(describe_prompt("fix the <task-notification> parser"), std::string("fix the <task-notification> parser"));
  CHECK_EQ(describe_prompt(""), std::string(""));
  auto t = apply_event(nullptr, ev("UserPromptSubmit", "prompt", done), 1);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string("后台任务完成：Run tests"));
}

TEST(subagent_events) {
  auto main_ev = parse_hook_input(
      R"({"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/x/wargame","tool_name":"Agent"})");
  CHECK(main_ev && !main_ev->subagent);
  auto sub = parse_hook_input(
      R"({"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/x/wargame/.claude/worktrees/agent-ae31",)"
      R"("tool_name":"Bash","agent_id":"ae31","agent_type":"general-purpose"})");
  CHECK(sub && sub->subagent);

  auto t = apply_event(nullptr, *main_ev, 1);
  // A subagent's events are a heartbeat: only `updated` moves.
  auto hb = apply_event(&t.doc, *sub, 900);
  CHECK(hb.action == Action::Write);
  CHECK_EQ(hb.doc["updated"].get<double>(), 900.0);
  CHECK_EQ(hb.doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(hb.doc["detail"].get<std::string>(), std::string("Agent"));
  CHECK_EQ(hb.doc["since"].get<double>(), 1.0);
  CHECK_EQ(hb.doc["project"].get<std::string>(), std::string("wargame"));
  auto s = session_from_json(hb.doc, "s1");
  CHECK(display_state(*s, 1000, 600) == DisplayState::Busy);  // long subagent run: not stale

  HookEvent sub_stop = *sub;
  sub_stop.event = "Stop";
  CHECK_EQ(apply_event(&t.doc, sub_stop, 2).doc["state"].get<std::string>(), std::string("busy"));
  HookEvent sub_end = *sub;
  sub_end.event = "SessionEnd";
  CHECK(apply_event(&t.doc, sub_end, 2).action == Action::Write);  // must not delete the main light
  CHECK(apply_event(nullptr, *sub, 2).action == Action::Ignore);    // never creates a light by itself

  HookEvent sub_perm = *sub;  // a subagent's permission request blocks the session
  sub_perm.event = "Notification";
  sub_perm.message = "Claude needs your permission to use Bash";
  auto w = apply_event(&t.doc, sub_perm, 3);
  CHECK_EQ(w.doc["state"].get<std::string>(), std::string("waiting"));
  CHECK_EQ(w.doc["project"].get<std::string>(), std::string("wargame"));
  CHECK_EQ(w.doc["cwd"].get<std::string>(), std::string("/x/wargame"));
}

TEST(cwd_is_sticky) {
  json old = doc_with("busy", false, "Bash");  // cwd /x/my-app
  HookEvent e = ev("PreToolUse", "tool_name", "Read");
  e.cwd = "/x/my-app/.claude/worktrees/agent-1";
  auto t = apply_event(&old, e, 5);
  CHECK_EQ(t.doc["cwd"].get<std::string>(), std::string("/x/my-app"));
  CHECK_EQ(t.doc["project"].get<std::string>(), std::string("my-app"));
  json no_cwd = doc_with("busy", false, "Bash");
  no_cwd["cwd"] = "";
  auto t2 = apply_event(&no_cwd, e, 5);  // empty cwd gets filled
  CHECK_EQ(t2.doc["cwd"].get<std::string>(), std::string("/x/my-app/.claude/worktrees/agent-1"));
}

TEST(map_pre_tool_use) {
  json old = doc_with("busy", false, "prompt text");
  auto t = apply_event(&old, ev("PreToolUse", "tool_name", "Bash"), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string("Bash"));
  CHECK_EQ(t.doc["unread"].get<bool>(), false);
}

TEST(map_post_tool_use_keeps_detail) {
  json old = doc_with("busy", false, "Edit");
  auto t = apply_event(&old, ev("PostToolUse", "tool_name", "Edit"), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string("Edit"));
  CHECK_EQ(t.doc["unread"].get<bool>(), false);
}

TEST(map_notification_to_waiting) {
  json old = doc_with("busy", false, "Bash");
  auto t = apply_event(&old, ev("Notification", "message", "Claude needs your permission"), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("waiting"));
  CHECK_EQ(t.doc["unread"].get<bool>(), true);
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string("Claude needs your permission"));
}

TEST(map_notification_after_replied_keeps_state) {
  json old = doc_with("replied", false, "", 500);
  auto t = apply_event(&old, ev("Notification", "message", "Claude is waiting for your input"), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("replied"));
  CHECK_EQ(t.doc["unread"].get<bool>(), false);  // read state not reset
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string(""));
  CHECK_EQ(t.doc["since"].get<double>(), 500.0);
  CHECK_EQ(t.doc["updated"].get<double>(), 1000.0);

  json old_unread = doc_with("replied", true, "");
  auto t2 = apply_event(&old_unread, ev("Notification", "message", "x"), 1000);
  CHECK_EQ(t2.doc["unread"].get<bool>(), true);
}

TEST(map_stop) {
  json old = doc_with("busy", false, "Bash");
  auto t = apply_event(&old, ev("Stop"), 1000);
  CHECK_EQ(t.doc["state"].get<std::string>(), std::string("replied"));
  CHECK_EQ(t.doc["unread"].get<bool>(), true);
  CHECK_EQ(t.doc["detail"].get<std::string>(), std::string(""));
}

TEST(map_session_end_deletes) {
  json old = doc_with("busy", false, "Bash");
  CHECK(apply_event(&old, ev("SessionEnd"), 1000).action == Action::Delete);
  CHECK(apply_event(nullptr, ev("SessionEnd"), 1000).action == Action::Delete);
}

TEST(map_unknown_event_ignored) {
  CHECK(apply_event(nullptr, ev("PreCompact"), 1000).action == Action::Ignore);
}

TEST(since_rules) {
  json old = doc_with("busy", false, "Bash", 100);
  auto same = apply_event(&old, ev("PreToolUse", "tool_name", "Read"), 1000);
  CHECK_EQ(same.doc["since"].get<double>(), 100.0);  // state unchanged
  auto changed = apply_event(&old, ev("Stop"), 1000);
  CHECK_EQ(changed.doc["since"].get<double>(), 1000.0);
}

TEST(unknown_fields_preserved) {
  json old = doc_with("busy", false, "Bash");
  old["future_field"] = {{"a", 1}};
  auto t = apply_event(&old, ev("Stop"), 1000);
  CHECK(t.doc.contains("future_field"));
  CHECK_EQ(t.doc["future_field"]["a"].get<int>(), 1);
}

TEST(missing_cwd_keeps_old_project) {
  json old = doc_with("busy", false, "Bash");
  HookEvent e = ev("Stop");
  e.cwd.clear();
  auto t = apply_event(&old, e, 1000);
  CHECK_EQ(t.doc["project"].get<std::string>(), std::string("my-app"));
}

// ---------- display ----------

TEST(display_states) {
  Session s;
  s.updated = 1000;
  s.state = "waiting";
  CHECK(display_state(s, 1000, 600) == DisplayState::Waiting);
  s.state = "replied";
  s.unread = true;
  CHECK(display_state(s, 1000, 600) == DisplayState::Replied);
  s.unread = false;  // read reply: your turn, shown like idle
  CHECK(display_state(s, 1000, 600) == DisplayState::Idle);
  s.state = "waiting";  // read permission request: still blocked, stays red
  CHECK(display_state(s, 1000, 600) == DisplayState::Waiting);
  s.state = "busy";
  CHECK(display_state(s, 1500, 600) == DisplayState::Busy);
  CHECK(display_state(s, 1601, 600) == DisplayState::Stale);
  s.state = "idle";
  CHECK(display_state(s, 99999, 600) == DisplayState::Idle);
  s.state = "garbage";
  CHECK(display_state(s, 1000, 600) == DisplayState::Idle);
  CHECK_EQ(std::string(display_label(DisplayState::Stale)), std::string("无响应?"));
  CHECK_EQ(default_color(DisplayState::Waiting), 0xe5484du);
  CHECK_EQ(default_color(DisplayState::Busy), 0x30a46cu);      // running = green
  CHECK_EQ(default_color(DisplayState::Replied), 0xffc53du);   // replied = yellow
  CHECK(default_color(DisplayState::Idle) != default_color(DisplayState::Busy));
}

TEST(sorting) {
  auto mk = [](const char* id, const char* state, bool unread, double updated) {
    Session s;
    s.id = id;
    s.state = state;
    s.unread = unread;
    s.updated = updated;
    return s;
  };
  double now = 10000;
  std::vector<Session> v = {
      mk("idle", "idle", false, 9990),
      mk("stale", "busy", false, 100),
      mk("busy_old", "busy", false, 9000),
      mk("busy_new", "busy", false, 9500),
      mk("replied_read", "replied", false, 9999),
      mk("waiting_read", "waiting", false, 1),
      mk("replied_unread", "replied", true, 9999),
      mk("waiting_unread", "waiting", true, 5),
  };
  sort_sessions(v, now, 600);
  std::vector<std::string> ids;
  for (auto& s : v) ids.push_back(s.id);
  std::vector<std::string> want = {"waiting_unread", "replied_unread", "waiting_read",
                                   "busy_new",       "busy_old",       "stale",
                                   "replied_read",   "idle"};  // read reply sorts as idle
  CHECK(ids == want);
}

TEST(elapsed_format) {
  CHECK_EQ(format_elapsed(0), std::string("0s"));
  CHECK_EQ(format_elapsed(-5), std::string("0s"));
  CHECK_EQ(format_elapsed(59.9), std::string("59s"));
  CHECK_EQ(format_elapsed(60), std::string("1m"));
  CHECK_EQ(format_elapsed(3599), std::string("59m"));
  CHECK_EQ(format_elapsed(3600), std::string("1h"));
  CHECK_EQ(format_elapsed(86400 * 3), std::string("3d"));
}

TEST(detail_and_texts) {
  CHECK_EQ(display_detail("short"), std::string("short"));
  CHECK_EQ(display_detail(std::string(49, 'a')), std::string(48, 'a') + "…");
  Session s;
  s.state = "busy";
  s.since = 1000 - 180;
  s.updated = 1000;
  s.unread = true;
  CHECK_EQ(status_text(s, 1000, 600), std::string("运行中 · 3m"));
  CHECK_EQ(title_text({s}, 1000, 600), std::string("Agents  1 运行  1 未读"));
}

TEST(session_from_json_defaults) {
  auto s = session_from_json(json{{"state", "busy"}, {"cwd", "/a/proj"}, {"updated", 5}}, "id1");
  CHECK(s.has_value());
  CHECK_EQ(s->project, std::string("proj"));
  CHECK_EQ(s->since, 5.0);
  CHECK(!session_from_json(json::array(), "x"));
}

TEST(light_grid_layout) {
  auto g = light_grid(0);
  CHECK(g.lights == 0 && g.overflow == 0 && g.cols == 0 && g.rows == 0);
  g = light_grid(4);
  CHECK(g.lights == 4 && g.overflow == 0 && g.cols == 4 && g.rows == 1);
  g = light_grid(6);
  CHECK(g.cols == 6 && g.rows == 1);
  g = light_grid(7);
  CHECK(g.lights == 7 && g.cols == 6 && g.rows == 2);
  g = light_grid(18);
  CHECK(g.lights == 18 && g.overflow == 0 && g.rows == 3);
  g = light_grid(19);
  CHECK(g.lights == 17 && g.overflow == 2 && g.cols == 6 && g.rows == 3);
  g = light_grid(40);
  CHECK(g.lights == 17 && g.overflow == 23);
}

TEST(short_names) {
  CHECK_EQ(short_name("notes"), std::string("notes"));
  CHECK_EQ(short_name("webapp"), std::string("webapp"));
  CHECK_EQ(short_name("agent-bar"), std::string("AB"));
  CHECK_EQ(short_name("my_cool.project"), std::string("MCP"));
  CHECK_EQ(short_name("wargame"), std::string("warga…"));
  CHECK_EQ(short_name("项目"), std::string("项目"));
  CHECK_EQ(short_name("前端项目"), std::string("前端…"));
  CHECK_EQ(short_name(""), std::string(""));
  CHECK_EQ(std::string(display_short_label(DisplayState::Waiting)), std::string("确认"));
}

// ---------- config ----------

TEST(bar_ini_roundtrip) {
  BarConfig c = parse_bar_ini("# c\nx=120.5\ntop = 800\nstale_minutes=3\nexpire_hours=-1\nbad\nfoo=1\n");
  CHECK(c.has_position);
  CHECK_EQ(c.x, 120.5);
  CHECK_EQ(c.top, 800.0);
  CHECK_EQ(c.stale_minutes, 3.0);
  CHECK_EQ(c.expire_hours, 12.0);  // invalid value ignored
  BarConfig back = parse_bar_ini(format_bar_ini(c));
  CHECK_EQ(back.x, c.x);
  CHECK_EQ(back.top, c.top);
  CHECK_EQ(back.stale_minutes, c.stale_minutes);
  CHECK(!parse_bar_ini("x=1\n").has_position);
  CHECK(parse_bar_ini("").compact);
  CHECK(!parse_bar_ini("compact=0\n").compact);
  BarConfig off;
  off.compact = false;
  CHECK(!parse_bar_ini(format_bar_ini(off)).compact);
  BarConfig bare = parse_bar_ini("show_names=0\nshow_status=0\n");
  CHECK(!bare.show_names && !bare.show_status);
  CHECK(!BarConfig{}.all_spaces);  // default: one desktop, draggable in Mission Control
  CHECK(parse_bar_ini("all_spaces=1\n").all_spaces);
  BarConfig every;
  every.all_spaces = true;
  CHECK(parse_bar_ini(format_bar_ini(every)).all_spaces);
  CHECK(parse_bar_ini(format_bar_ini(BarConfig{})).show_names);
}

TEST(bar_ini_colors) {
  BarConfig c = parse_bar_ini("color_busy=#112233\ncolor_idle=AABBCC\ncolor_waiting=#zzzzzz\ncolor_nope=#000000\n");
  CHECK_EQ(c.color(DisplayState::Busy), 0x112233u);
  CHECK_EQ(c.color(DisplayState::Idle), 0xaabbccu);
  CHECK_EQ(c.color(DisplayState::Waiting), default_color(DisplayState::Waiting));  // invalid ignored
  BarConfig back = parse_bar_ini(format_bar_ini(c));
  for (DisplayState d : kAllDisplayStates) CHECK_EQ(back.color(d), c.color(d));
}

// ---------- settings.json merge ----------

TEST(settings_merge_into_empty) {
  json s = json::object();
  CHECK(merge_hooks(s, "/h/.claude/bin/agent-status-hook"));
  for (const char* e : kHookEvents) {
    CHECK(s["hooks"][e].is_array());
    CHECK_EQ(s["hooks"][e].size(), std::size_t(1));
  }
  CHECK_EQ(s["hooks"]["PreToolUse"][0]["matcher"].get<std::string>(), std::string("*"));
  CHECK(!s["hooks"]["Stop"][0].contains("matcher"));
  CHECK(!merge_hooks(s, "/h/.claude/bin/agent-status-hook"));  // idempotent
}

TEST(settings_merge_preserves_user_hooks) {
  json s = json::parse(R"({
    "model": "opus",
    "hooks": {
      "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-linter"}]}],
      "Stop": [{"hooks": [{"type": "command", "command": "python3 ~/status_hook.py"},
                          {"type": "command", "command": "say done"}]}]
    }
  })");
  CHECK(merge_hooks(s, "/new/agent-status-hook"));
  CHECK_EQ(s["model"].get<std::string>(), std::string("opus"));
  CHECK_EQ(s["hooks"]["PreToolUse"].size(), std::size_t(2));
  CHECK_EQ(s["hooks"]["PreToolUse"][0]["hooks"][0]["command"].get<std::string>(),
           std::string("my-linter"));
  // Python prototype replaced, the other Stop hook kept.
  CHECK_EQ(s["hooks"]["Stop"].size(), std::size_t(2));
  CHECK_EQ(s["hooks"]["Stop"][0]["hooks"].size(), std::size_t(1));
  CHECK_EQ(s["hooks"]["Stop"][0]["hooks"][0]["command"].get<std::string>(), std::string("say done"));
  CHECK_EQ(s["hooks"]["Stop"][1]["hooks"][0]["command"].get<std::string>(),
           std::string("/new/agent-status-hook"));
}

TEST(settings_merge_updates_old_path) {
  json s = json::object();
  merge_hooks(s, "/old/agent-status-hook");
  CHECK(merge_hooks(s, "/new/agent-status-hook"));
  CHECK_EQ(s["hooks"]["Stop"].size(), std::size_t(1));
  CHECK_EQ(s["hooks"]["Stop"][0]["hooks"][0]["command"].get<std::string>(),
           std::string("/new/agent-status-hook"));
}

TEST(settings_remove) {
  json s = json::parse(R"({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}})");
  merge_hooks(s, "/x/agent-status-hook");
  CHECK(remove_hooks(s));
  CHECK_EQ(s["hooks"].size(), std::size_t(1));
  CHECK_EQ(s["hooks"]["Stop"][0]["hooks"][0]["command"].get<std::string>(), std::string("say done"));
  json only_ours = json::object();
  merge_hooks(only_ours, "/x/agent-status-hook");
  CHECK(remove_hooks(only_ours));
  CHECK(!only_ours.contains("hooks"));
  CHECK(!remove_hooks(only_ours));
}

TEST(command_matching_and_quoting) {
  CHECK(is_our_hook_command("/Users/a/.claude/bin/agent-status-hook"));
  CHECK(is_our_hook_command("\"/Users/a b/.claude/bin/agent-status-hook\""));
  CHECK(is_our_hook_command("C:\\Users\\a\\.claude\\bin\\agent-status-hook.exe"));
  CHECK(is_our_hook_command("python3 /x/status_hook.py"));
  CHECK(!is_our_hook_command("/x/agent-status-hook-other"));
  CHECK(!is_our_hook_command("my-linter"));
  CHECK_EQ(hook_command_for_path("/a/b"), std::string("/a/b"));
  CHECK_EQ(hook_command_for_path("/a b/c"), std::string("\"/a b/c\""));
}

// ---------- store (real files in a temp dir) ----------

TEST(store_event_roundtrip) {
  std::string dir = make_temp_dir();
  HookEvent e = ev("UserPromptSubmit", "prompt", "hi");
  CHECK(store::handle_event(dir, e, 1000) == store::EventResult::Written);
  auto sessions = store::scan(dir);
  CHECK_EQ(sessions.size(), std::size_t(1));
  CHECK_EQ(sessions[0].state, std::string("busy"));

  CHECK(store::handle_event(dir, ev("Stop"), 1010) == store::EventResult::Written);
  CHECK(store::scan(dir)[0].unread);
  CHECK(store::mark_read(dir, "s1"));
  CHECK(!store::mark_read(dir, "s1"));  // already read: no write
  CHECK(!store::scan(dir)[0].unread);
  auto doc = store::read_json(store::session_path(dir, "s1"));
  CHECK_EQ((*doc)["updated"].get<double>(), 1010.0);  // bar only touches unread

  CHECK(store::handle_event(dir, ev("SessionEnd"), 1020) == store::EventResult::Deleted);
  CHECK(store::scan(dir).empty());
  CHECK(access(store::session_path(dir, "s1").c_str(), F_OK) != 0);

  HookEvent bad = ev("Stop");
  bad.session_id = "../evil";
  CHECK(store::handle_event(dir, bad, 1) == store::EventResult::InvalidId);
  rmdir(dir.c_str());
}

TEST(store_scan_skips_bad_files) {
  std::string dir = make_temp_dir();
  store::write_file_atomic(dir + "/good.json", R"({"state":"waiting","unread":true,"updated":1})");
  store::write_file_atomic(dir + "/broken.json", "{not json");
  store::write_file_atomic(dir + "/x.json.123.tmp", R"({"state":"busy"})");
  store::write_file_atomic(dir + "/bad.id.json", R"({"state":"busy"})");
  store::write_file_atomic(dir + "/bar.ini", "x=1");
  auto sessions = store::scan(dir);
  CHECK_EQ(sessions.size(), std::size_t(1));
  CHECK_EQ(sessions[0].id, std::string("good"));
  std::system(("rm -rf '" + dir + "'").c_str());
}

TEST(store_cleanup) {
  std::string dir = make_temp_dir();
  auto put = [&](const char* id, const char* state, double updated) {
    json j = {{"state", state}, {"updated", updated}, {"since", updated}};
    store::write_file_atomic(store::session_path(dir, id), store::dump_json(j));
  };
  double now = 100000;
  put("old", "replied", now - 13 * 3600);
  put("idle", "idle", now - 10);
  put("stale", "busy", now - 700);
  put("busy", "busy", now - 10);
  put("waiting", "waiting", now - 10);
  CHECK_EQ(store::cleanup_expired(dir, now, 12 * 3600), 1);
  CHECK_EQ(store::cleanup_idle_and_stale(dir, now, 600), 2);
  auto left = store::scan(dir);
  CHECK_EQ(left.size(), std::size_t(2));
  std::system(("rm -rf '" + dir + "'").c_str());
}

TEST(registry_parsing) {
  auto r = parse_registry_entry(
      R"({"pid":61699,"sessionId":"99748ab4-3860","cwd":"/x/wargame","status":"idle","kind":"interactive"})");
  CHECK(r.has_value());
  CHECK_EQ(r->pid, 61699L);
  CHECK_EQ(r->session_id, std::string("99748ab4-3860"));
  CHECK(!parse_registry_entry(R"({"pid":"1","sessionId":"a"})"));
  CHECK(!parse_registry_entry(R"({"pid":1,"sessionId":"../x"})"));
  CHECK(!parse_registry_entry("garbage"));
  RegisteredSession busy{1, "b", "/x/proj", "busy"};
  json doc = discovered_session_doc(busy, 50);
  CHECK_EQ(doc["state"].get<std::string>(), std::string("busy"));
  CHECK_EQ(doc["project"].get<std::string>(), std::string("proj"));
  CHECK_EQ(doc["unread"].get<bool>(), false);
  RegisteredSession idle{1, "i", "/x/proj", "idle"};
  CHECK_EQ(discovered_session_doc(idle, 50)["state"].get<std::string>(), std::string("idle"));
}

TEST(store_discover_sessions) {
  std::string dir = make_temp_dir();
  std::string reg = make_temp_dir();
  store::write_file_atomic(reg + "/100.json", R"({"pid":100,"sessionId":"live1","cwd":"/a/one","status":"busy"})");
  store::write_file_atomic(reg + "/200.json", R"({"pid":200,"sessionId":"dead1","cwd":"/a/two","status":"idle"})");
  store::write_file_atomic(reg + "/300.json", R"({"pid":300,"sessionId":"known","cwd":"/a/three","status":"idle"})");
  store::write_file_atomic(reg + "/300.abc.key", "secret");
  store::handle_event(dir, ev("Stop"), 1);  // s1 unrelated
  HookEvent known = ev("Stop");
  known.session_id = "known";
  store::handle_event(dir, known, 1);
  auto alive = [](long pid) { return pid != 200; };
  CHECK_EQ(store::discover_sessions(dir, reg, 1000, alive), 1);
  auto doc = store::read_json(store::session_path(dir, "live1"));
  CHECK(doc.has_value());
  CHECK_EQ((*doc)["state"].get<std::string>(), std::string("busy"));
  CHECK(!store::read_json(store::session_path(dir, "dead1")));
  CHECK_EQ((*store::read_json(store::session_path(dir, "known")))["state"].get<std::string>(),
           std::string("replied"));  // existing file untouched
  CHECK_EQ(store::discover_sessions(dir, reg, 1001, alive), 0);  // idempotent
  CHECK_EQ(store::discover_sessions(dir, "/nonexistent-dir", 1, alive), 0);
  std::system(("rm -rf '" + dir + "' '" + reg + "'").c_str());
}

TEST(find_own_session_by_ancestry) {
  std::string reg = make_temp_dir();
  store::write_file_atomic(reg + "/50.json", R"({"pid":50,"sessionId":"mine","cwd":"/a/me","status":"busy"})");
  store::write_file_atomic(reg + "/60.json", R"({"pid":60,"sessionId":"other","cwd":"/a/o","status":"idle"})");
  // process tree: 99 (shell) -> 70 (bash) -> 50 (claude) -> 1
  auto parent = [](long p) -> long { return p == 99 ? 70 : p == 70 ? 50 : p == 50 ? 1 : 0; };
  auto r = store::find_session_for_process(reg, 99, parent);
  CHECK(r.has_value());
  CHECK_EQ(r->session_id, std::string("mine"));
  CHECK(!store::find_session_for_process(reg, 12345, parent));
  CHECK(store::parent_pid(static_cast<long>(getpid())) == static_cast<long>(getppid()));

  std::string dir = make_temp_dir();
  CHECK(store::register_session(dir, *r, 10));
  CHECK(!store::register_session(dir, *r, 11));  // never overwrites
  std::system(("rm -rf '" + dir + "' '" + reg + "'").c_str());
}

TEST(hooks_complete_check) {
  json s = json::object();
  CHECK(!hooks_complete(s));
  merge_hooks(s, "/x/agent-status-hook");
  CHECK(hooks_complete(s));
  s["hooks"].erase("Stop");
  CHECK(!hooks_complete(s));
}

TEST(store_lock_timeout) {
  std::string dir = make_temp_dir();
  std::string lp = store::lock_path(dir, "s1");
  store::FileLock held(lp, 50);
  CHECK(held.locked());
  // flock locks are per open file description, so a second open in the same
  // process contends like another process would.
  store::FileLock second(lp, 20);
  CHECK(!second.locked());
  CHECK(store::handle_event(dir, ev("Stop"), 1) == store::EventResult::LockTimeout);
  std::system(("rm -rf '" + dir + "'").c_str());
}

int main() {
  for (auto& [name, fn] : registry()) {
    int before = g_failures;
    fn();
    std::printf("%s %s\n", g_failures == before ? "ok  " : "FAIL", name);
  }
  std::printf("\n%zu tests, %d failed checks\n", registry().size(), g_failures);
  return g_failures == 0 ? 0 : 1;
}
