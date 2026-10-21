// Adapters turn one agent's native hook payload into agent-bar's normalized
// HookEvent (the seven Claude Code event names are the internal vocabulary).
// To support another agent, add an adapter here; see docs/development.md.
#pragma once

#include <optional>
#include <string_view>
#include <vector>

#include "agentbar/status.hpp"

namespace agentbar {

struct Adapter {
  const char* name;          // CLI/state-file id: `agent-status-hook --agent <name>`, "agent" field
  const char* display_name;  // human readable, e.g. "Claude Code"
  // Parses one hook invocation's stdin. Returns nullopt to ignore the input.
  // Must not throw. The returned event's `agent` is set by parse_with().
  std::optional<HookEvent> (*parse)(std::string_view raw);
};

const std::vector<Adapter>& adapters();
const Adapter* find_adapter(std::string_view name);
inline constexpr const char* kDefaultAdapter = "claude";

// Runs adapter.parse and stamps the event with the adapter's name.
std::optional<HookEvent> parse_with(const Adapter& adapter, std::string_view raw);

}  // namespace agentbar
