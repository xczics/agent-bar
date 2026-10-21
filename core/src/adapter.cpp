#include "agentbar/adapter.hpp"

namespace agentbar {

const std::vector<Adapter>& adapters() {
  // Register new adapters here (keep "claude" first: it is the default).
  static const std::vector<Adapter> list = {
      {"claude", "Claude Code", &parse_hook_input},
  };
  return list;
}

const Adapter* find_adapter(std::string_view name) {
  for (const auto& a : adapters()) {
    if (name == a.name) return &a;
  }
  return nullptr;
}

std::optional<HookEvent> parse_with(const Adapter& adapter, std::string_view raw) {
  auto ev = adapter.parse(raw);
  if (ev) ev->agent = adapter.name;
  return ev;
}

}  // namespace agentbar
