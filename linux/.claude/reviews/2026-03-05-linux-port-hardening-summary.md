# Review Loop Summary — 2026-03-05

## Overview
- **Branch**: linux-port
- **Rounds**: 3/5
- **Status**: Converged (Round 3: Security 0, Logic 1 (fixed), Performance 0)
- **Reviewers**: Security(opus) + Logic(opus) + Performance(opus)
- **Severity threshold**: high (critical + high)

## Issues by Round

| Round | Reviewers | Found | Fixed | Skipped | Cross-validated |
|-------|-----------|-------|-------|---------|-----------------|
| 1     | 3         | 33    | 9     | 2 (FP)  | 5               |
| 2     | 3         | 16    | 3     | 0       | 2               |
| 3     | 3         | 1     | 1     | 0       | 0               |
| **Total** |       | **50** | **13** | **2** | **7**          |

## Cross-validated Issues (multiple reviewers independently flagged)

These issues were found by 2+ independent reviewers, indicating high confidence:

1. **workspace.rs:221** Unbounded log_entries — OOM risk (Security + Logic + Performance: 3/3)
2. **notifications.rs:61** Unbounded notifications — OOM risk (Security + Logic + Performance: 3/3)
3. **server.rs:59** No concurrent connection limit (Security + Logic + Performance: 3/3)
4. **auth.rs:21** PID i32→u32 truncation (Security + Logic + Performance: 3/3)
5. **server.rs:140** Blocking Mutex::lock in async context (Logic + Performance: 2/3)
6. **server.rs:15** Socket TOCTOU + predictable /tmp path (Security + Logic: 2/3)
7. **cmux-cli:262** CLI response unbounded read_line (Security + Logic: 2/3)
8. **server.rs:75** Semaphore acquired after spawn (Security + Logic + Performance: 3/3, Round 2)
9. **server.rs:22** XDG_RUNTIME_DIR validation missing (Security + Logic: 2/3, Round 2+3)

## All Fixes Applied

### Round 1 (9 fixes)
1. `workspace.rs`: MAX_LOG_ENTRIES=1000 with 25% drain eviction
2. `notifications.rs`: MAX_NOTIFICATIONS=500 with 25% drain eviction
3. `server.rs`: XDG_RUNTIME_DIR socket path with /tmp fallback
4. `callbacks.rs`: handler_from_userdata returns Option, all trampolines null-guarded
5. `server.rs`: spawn_blocking for v2::dispatch (Mutex off async runtime)
6. `server.rs`: Semaphore(64) for connection limiting
7. `auth.rs`: u32::try_from for safe PID conversion
8. `app.rs`: active_window() check prevents duplicate windows on re-activation
9. `cmux-cli`: default_socket_path() matches server's XDG_RUNTIME_DIR logic

### Round 2 (3 fixes)
10. `cmux-cli`: take(MAX_RESPONSE_LEN+1) bounds read_line
11. `server.rs`: acquire_owned() before tokio::spawn (bounds tasks + connections)
12. `server.rs`: XDG_RUNTIME_DIR validation (uid ownership, mode 0o022 check)

### Round 3 (1 fix)
13. `cmux-cli`: Duplicated server's XDG_RUNTIME_DIR validation logic + added libc dependency

## Remaining Medium Issues (deferred)
- Vec drain O(n) → VecDeque optimization (workspace.rs, notifications.rs)
- Per-client read timeout for stalled connections (server.rs)
- spawn_blocking overhead for lightweight Mutex ops (server.rs)
- Multiple write syscalls per response (server.rs)
- Socket path logic duplication → shared crate extraction (server.rs, cmux-cli)
- Fat pointer null check limitation in FFI callbacks (callbacks.rs)

## Changes Made
```
 linux/cmux-cli/Cargo.toml          |  1 +
 linux/cmux-cli/src/main.rs         | 30 +++++++++++----
 linux/cmux/src/app.rs              |  7 +++-
 linux/cmux/src/model/workspace.rs  |  9 ++++-
 linux/cmux/src/notifications.rs    |  8 ++++
 linux/cmux/src/socket/auth.rs      |  2 +-
 linux/cmux/src/socket/server.rs    | 59 +++++++++++++++++++++++------
 linux/ghostty-gtk/src/callbacks.rs | 63 ++++++++++++++++++++----------
 8 files changed, 135 insertions(+), 44 deletions(-)
```
