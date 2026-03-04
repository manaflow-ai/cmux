# Review Round 2 — 2026-03-05

## Context
- **Branch**: linux-port
- **Diff stat**: 7 files changed, +104/-41 (Round 1 fixes)
- **Language**: Rust + GTK4/libadwaita, tokio async runtime
- **Severity filter**: high (critical + high)

## Reviewer Results

### Security & Memory Safety (opus)
```jsonl
{"severity":"high","file":"cmux/src/socket/server.rs","line":22,"title":"XDG_RUNTIME_DIR path injection","description":"socket_path() uses XDG_RUNTIME_DIR without validation. Attacker controlling env can redirect socket.","fix_suggestion":"Validate directory ownership (uid) and mode (not group/world writable)"}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":39,"title":"TOCTOU between remove_file and bind on /tmp fallback","description":"Still exists for /tmp fallback path, but mitigated by XDG_RUNTIME_DIR preference."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":75,"title":"Semaphore acquired after task spawn","description":"Tasks spawned before permit acquisition allows unbounded task creation during floods."}
{"severity":"medium","file":"ghostty-gtk/src/callbacks.rs","line":101,"title":"Fat pointer null check limitation","description":"is_null() on dyn Trait only checks data pointer, not vtable. Acceptable defense-in-depth."}
{"severity":"medium","file":"cmux-cli/src/main.rs","line":262,"title":"CLI read_line unbounded","description":"read_line reads full response before MAX_RESPONSE_LEN check."}
```

### Logic & Correctness (opus)
```jsonl
{"severity":"high","file":"cmux-cli/src/main.rs","line":262,"title":"read_line unbounded before size check","description":"BufReader::read_line allocates unbounded memory before the MAX_RESPONSE_LEN check.","fix_suggestion":"Use take() adapter to limit reads"}
{"severity":"medium","file":"cmux/src/model/workspace.rs","line":224,"title":"Drain eviction removes 25% not 1 entry","description":"Doc says 'evicting oldest if at capacity' but actually removes 25%. Minor doc mismatch."}
{"severity":"medium","file":"cmux/src/notifications.rs","line":65,"title":"Eviction drops unread notifications silently","description":"Previously returned UUIDs become invalid after eviction. mark_read() silently no-ops."}
{"severity":"medium","file":"ghostty-gtk/src/callbacks.rs","line":103,"title":"Fat pointer null check can't detect use-after-free","description":"Defensive but limited. Dangling non-null pointer would pass the check."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":76,"title":"Semaphore after accept means connections queue in kernel backlog","description":"Authenticated but waiting connections consume resources."}
```

### Performance & Design (opus)
```jsonl
{"severity":"medium","file":"cmux/src/model/workspace.rs","line":225,"title":"Vec drain O(n) due to element shifting","description":"VecDeque would avoid memmove for front eviction."}
{"severity":"medium","file":"cmux/src/notifications.rs","line":66,"title":"Same Vec drain O(n) issue","description":"Same pattern, same optimization opportunity."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":160,"title":"spawn_blocking overhead for lightweight dispatch","description":"Mutex holds are sub-microsecond, spawn_blocking adds allocation + scheduling overhead."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":168,"title":"Multiple write syscalls per response","description":"Three writes where one buffered write would suffice."}
{"severity":"medium","file":"cmux/src/socket/server.rs","line":53,"title":"No per-client read/write timeout","description":"Stalled clients hold semaphore permits indefinitely."}
{"severity":"medium","file":"cmux-cli/src/main.rs","line":12,"title":"Duplicated socket_path logic","description":"Server and CLI define socket path independently."}
```

## Aggregated Issues (after dedup + cross-validation)

| # | Severity | File | Line | Title | Reviewers | Status |
|---|----------|------|------|-------|-----------|--------|
| 1 | HIGH (cv) | cmux-cli | 262 | CLI read_line unbounded | Sec+Logic (2/3) | Fixed |
| 2 | HIGH (cv) | server.rs | 75 | Semaphore after spawn | Sec+Logic+Perf (3/3) | Fixed |
| 3 | HIGH | server.rs | 22 | XDG_RUNTIME_DIR path injection | Sec (1/3) | Fixed |

## Fixes Applied
1. CLI: Added `(&stream).take(MAX_RESPONSE_LEN + 1)` to bound read_line
2. server.rs: Moved `semaphore.clone().acquire_owned().await` before `tokio::spawn`
3. server.rs: Added XDG_RUNTIME_DIR validation (is_absolute, uid ownership, mode 0o022 check)

## Build Verification
- `cargo check`: pass
- `cargo test`: pass (12 tests)
