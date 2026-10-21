// The status directory: locking, atomic writes, scanning. Shared by the hook
// and the bar so both sides use the same lock and write discipline.
#pragma once

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "agentbar/status.hpp"

namespace agentbar::store {

// $AGENT_STATUS_DIR if set (used by tests), else ~/.claude/agent-status.
std::string status_dir();
bool ensure_dir(const std::string& dir);  // mkdir -p, mode 0700

std::string session_path(const std::string& dir, const std::string& id);  // <id>.json
std::string lock_path(const std::string& dir, const std::string& id);     // <id>.lock

double now_seconds();

// Exclusive advisory lock on a lock file (flock). Waits up to timeout_ms.
class FileLock {
 public:
  FileLock(const std::string& path, int timeout_ms);
  ~FileLock();
  FileLock(const FileLock&) = delete;
  FileLock& operator=(const FileLock&) = delete;
  bool locked() const { return fd_ >= 0; }

 private:
  int fd_ = -1;
};

inline constexpr int kLockTimeoutMs = 50;

std::optional<std::string> read_file(const std::string& path);
// Writes to "<path>.<pid>.tmp" then renames over path.
bool write_file_atomic(const std::string& path, const std::string& content);
std::optional<json> read_json(const std::string& path);
std::string dump_json(const json& j);  // pretty, invalid UTF-8 replaced, never throws

enum class EventResult { Written, Deleted, Ignored, LockTimeout, WriteFailed, InvalidId };

// Lock + read + apply_event + write/delete for one hook event.
EventResult handle_event(const std::string& dir, const HookEvent& ev, double now);

// All parseable sessions in dir (unsorted). Bad files are skipped.
std::vector<Session> scan(const std::string& dir);

// Sets unread=false under the session lock. Returns true if the file changed.
bool mark_read(const std::string& dir, const std::string& id);
int mark_all_read(const std::string& dir);

// Deletes a session file (and its lock file).
bool remove_session(const std::string& dir, const std::string& id);
// Deletes it only if pred still holds for the content read under the lock.
bool remove_session_if(const std::string& dir, const std::string& id,
                       const std::function<bool(const Session&)>& pred);

// Removes sessions whose `updated` is older than max_age seconds.
int cleanup_expired(const std::string& dir, double now, double max_age);
// Removes sessions currently displayed as idle or stale.
int cleanup_idle_and_stale(const std::string& dir, double now, double stale_after);

}  // namespace agentbar::store
