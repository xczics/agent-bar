#include "agentbar/store.hpp"

#ifdef _WIN32
#error "Windows store not implemented yet (see Handoff.md)"
#endif

#include <dirent.h>
#include <fcntl.h>
#include <pwd.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <thread>

namespace agentbar::store {

namespace {

bool ends_with(const std::string& s, const char* suffix) {
  std::string_view suf(suffix);
  return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

std::string home_dir() {
  if (const char* h = std::getenv("HOME"); h && *h) return h;
  if (const passwd* pw = getpwuid(getuid()); pw && pw->pw_dir) return pw->pw_dir;
  return ".";
}

// Runs fn(json&) on the session under its lock; writes back if fn returns true.
template <typename Fn>
bool update_locked(const std::string& dir, const std::string& id, Fn fn) {
  if (!is_valid_session_id(id)) return false;
  FileLock lock(lock_path(dir, id), kLockTimeoutMs);
  if (!lock.locked()) return false;
  const std::string path = session_path(dir, id);
  auto doc = read_json(path);
  if (!doc || !doc->is_object()) return false;
  if (!fn(*doc)) return false;
  return write_file_atomic(path, dump_json(*doc));
}

}  // namespace

std::string status_dir() {
  if (const char* d = std::getenv("AGENT_STATUS_DIR"); d && *d) return d;
  return home_dir() + "/.claude/agent-status";
}

bool ensure_dir(const std::string& dir) {
  if (dir.empty()) return false;
  struct stat st {};
  if (stat(dir.c_str(), &st) == 0) return S_ISDIR(st.st_mode);
  auto slash = dir.find_last_of('/');
  if (slash != std::string::npos && slash > 0) ensure_dir(dir.substr(0, slash));
  return mkdir(dir.c_str(), 0700) == 0 || errno == EEXIST;
}

std::string session_path(const std::string& dir, const std::string& id) {
  return dir + "/" + id + ".json";
}

std::string lock_path(const std::string& dir, const std::string& id) {
  return dir + "/" + id + ".lock";
}

double now_seconds() {
  using namespace std::chrono;
  return duration<double>(system_clock::now().time_since_epoch()).count();
}

FileLock::FileLock(const std::string& path, int timeout_ms) {
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (true) {
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
      fd_ = fd;
      return;
    }
    if (errno != EWOULDBLOCK && errno != EINTR) break;
    if (std::chrono::steady_clock::now() >= deadline) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  close(fd);
}

FileLock::~FileLock() {
  if (fd_ >= 0) {
    flock(fd_, LOCK_UN);
    close(fd_);
  }
}

std::optional<std::string> read_file(const std::string& path) {
  int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return std::nullopt;
  std::string out;
  char buf[8192];
  while (true) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n > 0) {
      out.append(buf, static_cast<std::size_t>(n));
      if (out.size() > (1u << 20)) break;  // status files are tiny; refuse giant ones
    } else if (n == 0) {
      break;
    } else if (errno != EINTR) {
      close(fd);
      return std::nullopt;
    }
  }
  close(fd);
  return out;
}

bool write_file_atomic(const std::string& path, const std::string& content) {
  const std::string tmp = path + "." + std::to_string(getpid()) + ".tmp";
  int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) return false;
  const char* p = content.data();
  std::size_t left = content.size();
  while (left > 0) {
    ssize_t n = write(fd, p, left);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      unlink(tmp.c_str());
      return false;
    }
    p += n;
    left -= static_cast<std::size_t>(n);
  }
  if (close(fd) != 0 || rename(tmp.c_str(), path.c_str()) != 0) {
    unlink(tmp.c_str());
    return false;
  }
  return true;
}

std::optional<json> read_json(const std::string& path) {
  auto text = read_file(path);
  if (!text) return std::nullopt;
  try {
    json j = json::parse(*text, nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded()) return std::nullopt;
    return j;
  } catch (...) {
    return std::nullopt;
  }
}

std::string dump_json(const json& j) {
  try {
    return j.dump(2, ' ', false, nlohmann::detail::error_handler_t::replace) + "\n";
  } catch (...) {
    return "{}\n";
  }
}

EventResult handle_event(const std::string& dir, const HookEvent& ev, double now) {
  if (!is_valid_session_id(ev.session_id)) return EventResult::InvalidId;
  ensure_dir(dir);
  const std::string path = session_path(dir, ev.session_id);
  const std::string lpath = lock_path(dir, ev.session_id);
  FileLock lock(lpath, kLockTimeoutMs);
  if (!lock.locked()) return EventResult::LockTimeout;

  auto old = read_json(path);
  Transition t = apply_event(old ? &*old : nullptr, ev, now);
  switch (t.action) {
    case Action::Ignore:
      return EventResult::Ignored;
    case Action::Delete:
      unlink(path.c_str());
      // Removing the lock file while holding it is safe enough here: the
      // session is over, so late events only recreate a short-lived file.
      unlink(lpath.c_str());
      return EventResult::Deleted;
    case Action::Write:
      return write_file_atomic(path, dump_json(t.doc)) ? EventResult::Written
                                                       : EventResult::WriteFailed;
  }
  return EventResult::Ignored;
}

std::vector<Session> scan(const std::string& dir) {
  std::vector<Session> out;
  DIR* d = opendir(dir.c_str());
  if (!d) return out;
  while (dirent* e = readdir(d)) {
    std::string name = e->d_name;
    if (!ends_with(name, ".json")) continue;  // skips *.tmp, *.lock, bar.ini, hook.log
    std::string id = name.substr(0, name.size() - 5);
    if (!is_valid_session_id(id)) continue;
    auto doc = read_json(dir + "/" + name);
    if (!doc) continue;
    if (auto s = session_from_json(*doc, id)) out.push_back(std::move(*s));
  }
  closedir(d);
  return out;
}

bool mark_read(const std::string& dir, const std::string& id) {
  return update_locked(dir, id, [](json& doc) {
    auto it = doc.find("unread");
    if (it != doc.end() && it->is_boolean() && !it->get<bool>()) return false;
    doc["unread"] = false;
    return true;
  });
}

int mark_all_read(const std::string& dir) {
  int n = 0;
  for (const auto& s : scan(dir)) {
    if (s.unread && mark_read(dir, s.id)) ++n;
  }
  return n;
}

bool remove_session(const std::string& dir, const std::string& id) {
  return remove_session_if(dir, id, [](const Session&) { return true; });
}

bool remove_session_if(const std::string& dir, const std::string& id,
                       const std::function<bool(const Session&)>& pred) {
  if (!is_valid_session_id(id)) return false;
  const std::string lpath = lock_path(dir, id);
  FileLock lock(lpath, kLockTimeoutMs);
  if (!lock.locked()) return false;
  const std::string path = session_path(dir, id);
  // Re-check under the lock: the hook may have updated the session since scan().
  auto doc = read_json(path);
  if (doc) {
    auto s = session_from_json(*doc, id);
    if (s && !pred(*s)) return false;
  }
  bool ok = unlink(path.c_str()) == 0;
  unlink(lpath.c_str());
  return ok;
}

int cleanup_expired(const std::string& dir, double now, double max_age) {
  auto expired = [&](const Session& s) { return now - s.updated > max_age; };
  int n = 0;
  for (const auto& s : scan(dir)) {
    if (expired(s) && remove_session_if(dir, s.id, expired)) ++n;
  }
  return n;
}

int cleanup_idle_and_stale(const std::string& dir, double now, double stale_after) {
  auto inactive = [&](const Session& s) {
    auto d = display_state(s, now, stale_after);
    return d == DisplayState::Idle || d == DisplayState::Stale;
  };
  int n = 0;
  for (const auto& s : scan(dir)) {
    if (inactive(s) && remove_session_if(dir, s.id, inactive)) ++n;
  }
  return n;
}

}  // namespace agentbar::store
