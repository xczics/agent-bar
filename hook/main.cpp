// agent-status-hook: called by Claude Code hooks with a JSON payload on stdin.
// Updates ~/.claude/agent-status/<session_id>.json and exits.
//
// Hard rules (see docs/design.md): always exit 0 in hook mode, never print to
// stdout, never throw out of main. Exit code 2 or JSON on stdout would be read
// by Claude Code as instructions.
//
// When run with arguments it is a small admin CLI used by scripts/install.sh;
// Claude Code never passes arguments.

#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

#include "agentbar/adapter.hpp"
#include "agentbar/settings.hpp"
#include "agentbar/status.hpp"
#include "agentbar/store.hpp"

using namespace agentbar;

namespace {

const char* result_name(store::EventResult r) {
  switch (r) {
    case store::EventResult::Written: return "written";
    case store::EventResult::Deleted: return "deleted";
    case store::EventResult::Ignored: return "ignored";
    case store::EventResult::LockTimeout: return "lock-timeout";
    case store::EventResult::WriteFailed: return "write-failed";
    case store::EventResult::InvalidId: return "invalid-id";
  }
  return "?";
}

void debug_log(const std::string& dir, const std::string& line) {
  const char* dbg = std::getenv("AGENT_STATUS_DEBUG");
  if (!dbg || std::strcmp(dbg, "1") != 0) return;
  store::ensure_dir(dir);
  if (FILE* f = std::fopen((dir + "/hook.log").c_str(), "a")) {
    std::fprintf(f, "%.3f %s\n", store::now_seconds(), line.c_str());
    std::fclose(f);
  }
}

std::string read_stdin() {
  std::string out;
  char buf[16384];
  while (true) {
    std::size_t n = std::fread(buf, 1, sizeof buf, stdin);
    out.append(buf, n);
    if (n < sizeof buf || out.size() > (8u << 20)) break;
  }
  return out;
}

void run_hook(std::string_view agent) {
  const std::string dir = store::status_dir();
  const Adapter* adapter = find_adapter(agent);
  if (!adapter) {
    debug_log(dir, "unknown agent '" + std::string(agent) + "'");
    return;
  }
  if (isatty(STDIN_FILENO)) return;  // run by hand without input
  const std::string input = read_stdin();
  auto ev = parse_with(*adapter, input);
  if (!ev) {
    debug_log(dir, std::string(adapter->name) + ": invalid input (" + std::to_string(input.size()) + " bytes)");
    return;
  }
  auto r = store::handle_event(dir, *ev, store::now_seconds());
  debug_log(dir, ev->agent + " " + ev->event + " " + (is_valid_session_id(ev->session_id) ? ev->session_id : "<bad-id>") +
                     " " + result_name(r));
}

// ---- admin CLI ----

int usage() {
  std::fprintf(stderr,
               "agent-status-hook %s\n"
               "Hook mode (no arguments, or --agent <name>): reads the agent's hook payload on stdin.\n"
               "  agent-status-hook                   Claude Code\n"
               "  agent-status-hook --agent <name>    another agent (see docs/development.md)\n"
               "Admin commands:\n"
               "  agent-status-hook --version\n"
               "  agent-status-hook emit --session-id <id> --event <Event> [--cwd <dir>] [--agent <name>]\n"
               "                    [--tool <name>] [--prompt <text>] [--message <text>]\n"
               "      report one event without building JSON (for adapters of other agents);\n"
               "      Event: SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SessionEnd\n"
               "  agent-status-hook install-hooks   --settings <settings.json> --command <hook path>\n"
               "  agent-status-hook uninstall-hooks --settings <settings.json>\n",
               AGENTBAR_VERSION);
  return 64;
}

int edit_settings(int argc, char** argv, bool install) {
  std::string settings_path, command_path;
  for (int i = 2; i + 1 < argc; i += 2) {
    if (std::strcmp(argv[i], "--settings") == 0) settings_path = argv[i + 1];
    else if (std::strcmp(argv[i], "--command") == 0) command_path = argv[i + 1];
    else return usage();
  }
  if (settings_path.empty() || (install && command_path.empty())) return usage();

  json settings = json::object();
  if (auto text = store::read_file(settings_path)) {
    settings = json::parse(*text, nullptr, false);
    if (settings.is_discarded() || !settings.is_object()) {
      std::fprintf(stderr, "error: %s is not a JSON object; not modified\n", settings_path.c_str());
      return 1;
    }
  } else if (!install) {
    std::printf("%s does not exist; nothing to remove\n", settings_path.c_str());
    return 0;
  }

  bool changed = install ? merge_hooks(settings, hook_command_for_path(command_path))
                         : remove_hooks(settings);
  if (!changed) {
    std::printf("%s already up to date\n", settings_path.c_str());
    return 0;
  }
  if (!store::write_file_atomic(settings_path, store::dump_json(settings))) {
    std::fprintf(stderr, "error: cannot write %s\n", settings_path.c_str());
    return 1;
  }
  std::printf("%s %s\n", install ? "hooks installed into" : "hooks removed from",
              settings_path.c_str());
  return 0;
}

// `emit`: the same state machine as hook mode, fed from flags instead of stdin.
int emit(int argc, char** argv) {
  HookEvent ev;
  for (int i = 2; i + 1 < argc; i += 2) {
    const char* k = argv[i];
    const char* v = argv[i + 1];
    if (std::strcmp(k, "--session-id") == 0) ev.session_id = v;
    else if (std::strcmp(k, "--event") == 0) ev.event = v;
    else if (std::strcmp(k, "--cwd") == 0) ev.cwd = v;
    else if (std::strcmp(k, "--tool") == 0) ev.tool_name = v;
    else if (std::strcmp(k, "--prompt") == 0) ev.prompt = v;
    else if (std::strcmp(k, "--message") == 0) ev.message = v;
    else if (std::strcmp(k, "--agent") == 0) ev.agent = v;
    else return usage();
  }
  if ((argc - 2) % 2 != 0 || ev.session_id.empty() || ev.event.empty()) return usage();
  if (!is_valid_session_id(ev.session_id)) {
    std::fprintf(stderr, "error: --session-id may only contain letters, digits, '-' and '_'\n");
    return 1;
  }
  const auto r = store::handle_event(store::status_dir(), ev, store::now_seconds());
  if (r == store::EventResult::Ignored) {
    std::fprintf(stderr, "error: unknown event %s\n", ev.event.c_str());
    return 1;
  }
  if (r == store::EventResult::LockTimeout || r == store::EventResult::WriteFailed) {
    std::fprintf(stderr, "error: %s\n", result_name(r));
    return 1;
  }
  return 0;
}

int run_cli(int argc, char** argv) {
  if (std::strcmp(argv[1], "--version") == 0) {
    std::printf("agent-status-hook %s\n", AGENTBAR_VERSION);
    return 0;
  }
  if (std::strcmp(argv[1], "emit") == 0) return emit(argc, argv);
  if (std::strcmp(argv[1], "install-hooks") == 0) return edit_settings(argc, argv, true);
  if (std::strcmp(argv[1], "uninstall-hooks") == 0) return edit_settings(argc, argv, false);
  return usage();
}

}  // namespace

int main(int argc, char** argv) {
  // Hook mode for a non-default adapter: `agent-status-hook --agent <name>`.
  // Same hard rules as the default hook mode: exit 0, no stdout.
  if (argc == 3 && std::strcmp(argv[1], "--agent") == 0) {
    try {
      run_hook(argv[2]);
    } catch (...) {
    }
    return 0;
  }
  if (argc > 1) {
    try {
      return run_cli(argc, argv);
    } catch (const std::exception& e) {
      std::fprintf(stderr, "error: %s\n", e.what());
      return 1;
    }
  }
  try {
    run_hook(kDefaultAdapter);
  } catch (...) {
  }
  return 0;
}
