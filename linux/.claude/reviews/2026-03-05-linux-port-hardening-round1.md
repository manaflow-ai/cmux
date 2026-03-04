# Review Round 1 — 2026-03-05

## Context
- **Branch**: linux-port
- **Diff stat**: 38 files changed, 5764 insertions (full linux/ directory)
- **Language**: Rust + GTK4/libadwaita, tokio async runtime
- **Severity filter**: high (critical + high)

## Reviewer Results

### Security & Memory Safety (opus)
```jsonl
{"severity":"critical","file":"cmux/src/model/workspace.rs","line":221,"title":"Unbounded log_entries growth","description":"append_log() pushes to Vec without limit. A malicious or chatty agent can OOM the process.","fix_suggestion":"Add MAX_LOG_ENTRIES cap with drain eviction"}
{"severity":"high","file":"cmux/src/notifications.rs","line":61,"title":"Unbounded notifications growth","description":"NotificationStore.add() has no cap on stored notifications.","fix_suggestion":"Add MAX_NOTIFICATIONS cap"}
{"severity":"high","file":"cmux/src/socket/server.rs","line":15,"title":"Socket at predictable /tmp path with TOCTOU","description":"remove_file + bind has a race window. /tmp is world-writable.","fix_suggestion":"Use XDG_RUNTIME_DIR with /tmp fallback"}
{"severity":"high","file":"ghostty-gtk/src/callbacks.rs","line":97,"title":"handler_from_userdata dereferences without null check","description":"Two raw pointer dereferences without null guards. Null userdata = segfault.","fix_suggestion":"Return Option, check null at both levels"}
{"severity":"high","file":"cmux/src/socket/server.rs","line":59,"title":"No concurrent connection limit","description":"Unbounded tokio::spawn per connection allows resource exhaustion.","fix_suggestion":"Add tokio::sync::Semaphore"}
{"severity":"high","file":"cmux/src/socket/auth.rs","line":21,"title":"PID i32 to u32 truncation","description":"cred.pid() returns i32, cast with 'as u32' wraps negative values.","fix_suggestion":"Use u32::try_from().ok().unwrap_or(0)"}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":92,"title":"fill_buf has no idle timeout","description":"Client that connects but never sends data holds connection open forever."}
{"severity":"medium","file":"ghostty-gtk/src/surface.rs","line":173,"title":"GtkGLArea pointer without refcount","description":"self.as_ptr() stored in FFI config without preventing GObject ref drop."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":15,"title":"Socket permissions set after bind","description":"Brief window between bind and chmod where socket is world-accessible."}
{"severity":"medium","file":"cmux/src/session/snapshot.rs","line":171,"title":"No NaN/Inf check on divider_position","description":"Deserialized f64 could be NaN/Inf, causing layout issues."}
{"severity":"medium","file":"cmux-cli/src/main.rs","line":262,"title":"CLI read_line is unbounded","description":"Client-side response read has no size limit before MAX_RESPONSE_LEN check."}
```

### Logic & Correctness (opus)
```jsonl
{"severity":"critical","file":"cmux/src/model/workspace.rs","line":221,"title":"Unbounded log_entries Vec","description":"append_log pushes without limit, no eviction strategy.","fix_suggestion":"Cap at 1000 entries with oldest eviction"}
{"severity":"high","file":"cmux/src/notifications.rs","line":61,"title":"Unbounded notification store","description":"No cap on notifications Vec.","fix_suggestion":"Add MAX_NOTIFICATIONS"}
{"severity":"high","file":"cmux/src/socket/server.rs","line":140,"title":"Blocking Mutex::lock in async context","description":"v2::dispatch acquires std::sync::Mutex on tokio worker thread.","fix_suggestion":"Use tokio::task::spawn_blocking"}
{"severity":"high","file":"cmux/src/app.rs","line":100,"title":"activate() creates duplicate windows","description":"Every activation creates a new window instead of presenting existing one.","fix_suggestion":"Check app.active_window() first"}
{"severity":"high","file":"cmux-cli/src/main.rs","line":262,"title":"CLI read_line unbounded","description":"read_line reads into unbounded String before size check.","fix_suggestion":"Use take() adapter or bounded read loop"}
{"severity":"medium","file":"cmux/src/model/tab_manager.rs","line":150,"title":"selected_index unchanged when removing selected workspace","description":"When sel == index and not last, selected stays pointing to next item."}
{"severity":"medium","file":"cmux/src/socket/v2.rs","line":194,"title":"u64 as usize lossy on 32-bit","description":"Index conversion could truncate on 32-bit platforms."}
{"severity":"medium","file":"cmux/src/ui/split_view.rs","line":79,"title":"No fallback when all panel IDs fail to resolve","description":"If no panels resolve in multi-panel pane, stack has no children."}
{"severity":"medium","file":"cmux/src/session/snapshot.rs","line":171,"title":"divider_position not clamped","description":"Deserialized value could be outside 0..1 range."}
{"severity":"medium","file":"ghostty-gtk/src/surface.rs","line":60,"title":"dispose doesn't call parent_dispose","description":"GObject cleanup chain may be incomplete."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":59,"title":"No connection limit","description":"Unbounded task spawning per connection."}
{"severity":"medium","file":"cmux/src/socket/auth.rs","line":21,"title":"PID type truncation","description":"i32 to u32 cast wraps negative values."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":15,"title":"Predictable socket path in /tmp","description":"TOCTOU race and symlink attacks possible."}
```

### Performance & Design (opus)
```jsonl
{"severity":"critical","file":"cmux/src/model/workspace.rs","line":221,"title":"Unbounded log_entries","description":"No cap on log entries causes memory growth proportional to agent activity.","fix_suggestion":"Ring buffer or VecDeque with cap"}
{"severity":"high","file":"cmux/src/notifications.rs","line":61,"title":"Unbounded notification storage","description":"Notifications Vec grows without limit.","fix_suggestion":"Cap at 500 with eviction"}
{"severity":"high","file":"cmux/src/socket/server.rs","line":140,"title":"Blocking Mutex in async task","description":"std::sync::Mutex::lock blocks tokio worker. Use spawn_blocking or tokio::sync::Mutex.","fix_suggestion":"spawn_blocking for dispatch call"}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":15,"title":"Hardcoded /tmp socket path","description":"Should use XDG_RUNTIME_DIR for proper Unix socket placement."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":59,"title":"No concurrent connection limit","description":"Each connection spawns an unbounded task."}
{"severity":"medium","file":"cmux/src/model/workspace.rs","line":221,"title":"Vec drain O(n) for eviction","description":"Vec::drain from front requires memmove. VecDeque would be O(1)."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":143,"title":"Multiple write syscalls per response","description":"Three separate write_all + flush could be one buffered write."}
{"severity":"medium","file":"cmux-cli/src/main.rs","line":20,"title":"Duplicated socket path logic","description":"CLI and server define socket path independently."}
{"severity":"medium","file":"cmux/src/socket/auth.rs","line":21,"title":"PID type safety","description":"i32→u32 cast could wrap."}
```

## Aggregated Issues (after dedup + cross-validation)

| # | Severity | File | Line | Title | Reviewers | Status |
|---|----------|------|------|-------|-----------|--------|
| 1 | CRITICAL | workspace.rs | 221 | Unbounded log_entries | Sec+Logic+Perf (3/3) | Fixed |
| 2 | HIGH | notifications.rs | 61 | Unbounded notifications | Sec+Logic+Perf (3/3) | Fixed |
| 3 | HIGH | server.rs | 15 | Socket TOCTOU + /tmp path | Sec+Logic+Perf (2/3) | Fixed |
| 4 | HIGH | callbacks.rs | 97 | handler_from_userdata null deref | Sec (1/3) | Fixed |
| 5 | HIGH | server.rs | 140 | Blocking Mutex in async | Logic+Perf (2/3) | Fixed |
| 6 | HIGH | server.rs | 59 | No concurrent connection limit | Sec+Logic+Perf (3/3) | Fixed |
| 7 | HIGH | auth.rs | 21 | PID i32→u32 truncation | Sec+Logic+Perf (3/3) | Fixed |
| 8 | HIGH | cmux-cli | 262 | CLI response unbounded read_line | Sec+Logic (2/3) | Deferred to R2 |
| 9 | HIGH | app.rs | 100 | activate() creates duplicate windows | Logic (1/3) | Fixed |
| 10 | HIGH | surface.rs | 173 | GtkGLArea ptr without refcount | Sec (1/3) | Skipped (FP) |
| 11 | HIGH | tab_manager.rs | 150 | selected_index on remove | Logic (1/3) | Skipped (FP) |

## Fixes Applied
1. workspace.rs: Added `MAX_LOG_ENTRIES = 1000` with 25% drain eviction
2. notifications.rs: Added `MAX_NOTIFICATIONS = 500` with 25% drain eviction
3. server.rs: Replaced `/tmp/cmux.sock` with `XDG_RUNTIME_DIR` fallback via `socket_path()`
4. callbacks.rs: `handler_from_userdata` returns `Option`, all trampolines use `if let Some(handler)`
5. server.rs: Added `spawn_blocking` for `v2::dispatch`
6. server.rs: Added `Semaphore(64)` for connection limiting
7. auth.rs: Changed `as u32` to `u32::try_from().ok().unwrap_or(0)`
8. app.rs: Added `active_window()` check to prevent duplicate windows
9. cmux-cli: Updated `default_socket_path()` to match server's XDG_RUNTIME_DIR logic

## Build Verification
- `cargo check`: pass
- `cargo test`: pass (12 tests)
