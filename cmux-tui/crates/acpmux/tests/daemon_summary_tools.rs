//! Reproducible list benchmark; run the identical file on base and head on Linux CI:
//! `cargo test -p acpmux --test daemon_summary_tools -- --ignored --nocapture`
//! Each endpoint gets a fresh daemon and Python JSON consumer. The consumer holds
//! one complete wire reply and its parsed tree. Its RSS is NOT browser/page RSS.
//! Output: one `acpmux-summary-tools: {JSON}` record per endpoint, all sizes in bytes.
//! Set ACPMUX_SUMMARY_TOOLS_OUTPUT to a new directory to retain both wire replies
//! for scripts/gallery-matrix/summary-tools-memory.mjs (actual Chromium page RSS).
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Synthetic artifact destination; contains no account credentials.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_SUMMARY_TOOLS_OUTPUT"]);

use serde_json::json;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};

const SESSIONS: usize = 3_000;
const TOOLS: usize = 66;
const SEED: u64 = 0x5eed_3000;

struct Scratch(std::path::PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon(Child);
impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: this is the test's own child, never a supervised daemon.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

fn private_dir(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn write_private(path: &Path, value: String) {
    std::fs::write(path, value).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn seed(home: &Path) {
    private_dir(home);
    private_dir(&home.join("sessions"));
    let names = [
        "browser",
        "github",
        "slack",
        "linear",
        "notion",
        "filesystem",
        "memory",
        "search",
        "postgres",
        "calendar",
        "docs",
        "terminal",
    ];
    let mut random = SEED;
    for i in 0..SESSIONS {
        let id = format!("01a16c00-0000-7000-8000-{i:012x}");
        let dir = home.join("sessions").join(&id);
        private_dir(&dir);
        private_dir(&dir.join("events"));
        let rows: Vec<_> = (0..TOOLS)
            .map(|n| {
                random ^= random << 13;
                random ^= random >> 7;
                random ^= random << 17;
                let kind = match n {
                    0..6 => "cmux",
                    6..18 => "mcp",
                    18..54 => "skill",
                    _ => "plugin",
                };
                let name = format!("{}-{}-{n}", names[n % names.len()], kind);
                let enabled = !random.is_multiple_of(11);
                let mut row = json!({"id": format!("{kind}:{name}"), "name": name,
                "kind": kind, "source": if kind == "cmux" { "cmux" } else { "claude" },
                "enabled": enabled, "canToggle": kind == "mcp"});
                if kind == "mcp" {
                    row["status"] = json!(if !enabled {
                        "disabled"
                    } else if random.is_multiple_of(13) {
                        "needs-auth"
                    } else {
                        "connected"
                    });
                }
                row
            })
            .collect();
        let at = 1_792_000_000_000u64 + i as u64;
        let meta = json!({"schema": "acpmux.session.v1", "id": id,
            "name": format!("review-session-{i}"), "harness": "claude", "family": "claude",
            "cwd": "/tmp/project", "status": if i % 3 == 0 { "closed" } else { "idle" },
            "createdAt": at, "updatedAt": at, "lastSeq": 1, "eventCount": 1,
            "title": format!("Review the {} integration #{i}", names[i % names.len()]),
            "lastPrompt": "Review the implementation, verify edge cases, and report the result.",
            "preview": "Verified the request path and checked the regression coverage.",
            "tools": {"rows": rows, "mutable": true}});
        let parsed: acpmux::store::SessionMeta = serde_json::from_value(meta.clone()).unwrap();
        assert_eq!(
            parsed.tools.rows.len(),
            TOOLS,
            "seeded tool inventory must survive metadata decode"
        );
        write_private(&dir.join("session.json"), meta.to_string());
        // Closed sessions without an event log are purged tombstones. Keep a real
        // record so this fixture measures retained history, not an open-only list.
        write_private(
            &dir.join("events/000001.ndjson"),
            format!(
                "{}\n",
                json!({
                    "seq": 1, "at": at, "dir": "mux", "kind": "created", "msg": {"sessionId": id}
                })
            ),
        );
    }
}

fn start(scratch: &Path, home: &Path, socket: &Path) -> Daemon {
    let child = daemon_env::acpmux(scratch)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("MALLOC_ARENA_MAX", "2")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut daemon = Daemon(child);
    let ready =
        BufReader::new(daemon.0.stdout.take().unwrap()).lines().map_while(Result::ok).any(|line| {
            serde_json::from_str::<serde_json::Value>(&line).is_ok_and(|v| v["ready"] == true)
        });
    assert!(ready, "daemon exited before readiness");
    daemon
}

// A separate consumer avoids counting the Rust fixture generator's retained heap.
// /proc VmHWM is reset before each consumer/request (no polling).
const CONSUMER: &str = r#"
import json, os, platform, socket, sys, time
path, daemon, method, count, tools, seed, export = sys.argv[1:]
count, tools = int(count), int(tools)
def memory(pid):
    with open('/proc/%s/status' % pid) as f:
        fields = dict(line.split(':', 1) for line in f if ':' in line)
    return {key: int(fields[key].split()[0]) * 1024 for key in ('VmRSS', 'VmHWM')}
def reset(pid):
    with open('/proc/%s/clear_refs' % pid, 'w') as f:
        f.write('5')
client = os.getpid()
with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(120)
    sock.connect(path)
    reader = sock.makefile('rb')
    request = {'jsonrpc': '2.0', 'id': 1, 'method': method,
               'params': {'enabled': True} if method == '_acpmux/watch' else {}}
    daemon_before, client_before = memory(daemon), memory(client)
    reset(client)
    started = time.perf_counter()
    sock.sendall(json.dumps(request).encode() + b'\n')
    wire = reader.readline()
    received = time.perf_counter()
    reply = json.loads(wire)
    parsed = time.perf_counter()
    daemon_after, client_after = memory(daemon), memory(client)
    assert reply.get('id') == 1 and 'error' not in reply, str(reply)[:1000]
    rows = reply['result']['sessions']
    assert len(rows) == count, (len(rows), count)
    assert {r['sessionId'] for r in rows} == {
        '01a16c00-0000-7000-8000-%012x' % i for i in range(count)}
    closed = sum(r['status'] == 'closed' for r in rows)
    assert closed == count // 3, closed
    # Record either version with the same harness; tool_inventory tests the compact contract.
    assert all(len(r.get('tools', [])) in (0, tools) for r in rows)
    sock.sendall(json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': '_acpmux/info',
                             'params': {'sessionId': rows[0]['sessionId']}}).encode() + b'\n')
    info = json.loads(reader.readline())
    assert info.get('id') == 2 and 'error' not in info, str(info)[:1000]
    assert len(info['result'].get('tools', [])) == tools
    assert info['result'].get('toolsMutable') is True
    report = {'fixture': 'summary-tools-v1', 'seed': int(seed), 'sessions': count,
        'closed_sessions': closed, 'open_sessions': count - closed,
        'seeded_tool_rows_per_session': tools, 'method': method,
        'wire_reply_bytes_including_newline': len(wire),
        'summary_tool_rows': sum(len(r.get('tools', [])) for r in rows),
        'summaries_with_tools_mutable': sum('toolsMutable' in r for r in rows),
        'info_tool_rows': len(info['result'].get('tools', [])),
        'receive_ms': (received - started) * 1000, 'parse_ms': (parsed - received) * 1000,
        'memory_source': 'Linux /proc VmRSS and reset VmHWM; bytes',
        'consumer': 'CPython JSON consumer holding raw reply and parsed tree; NOT browser/page RSS',
        'python': platform.python_version(), 'platform': platform.platform()}
    for name, before, after in [('daemon', daemon_before, daemon_after),
                               ('json_consumer', client_before, client_after)]:
        report[name + '_rss_before_bytes'] = before['VmRSS']
        report[name + '_rss_after_bytes'] = after['VmRSS']
        report[name + '_peak_rss_bytes'] = after['VmHWM']
        report[name + '_peak_growth_bytes'] = max(0, after['VmHWM'] - before['VmRSS'])
    print('acpmux-summary-tools: ' + json.dumps(report, sort_keys=True))
    if export:
        with open(export, 'xb') as f:
            f.write(wire)
"#;

#[test]
#[ignore = "3,000-session performance harness; run explicitly on the same Linux worker before/after"]
fn seeded_summary_tools_wire_and_memory() {
    let path = std::env::temp_dir().join(format!("amx-summary-tools-{}", std::process::id()));
    // create_dir refuses a stale directory instead of deleting someone else's data.
    std::fs::create_dir(&path).unwrap();
    let scratch = Scratch(path);
    let home = scratch.0.join("state");
    seed(&home);
    let export = std::env::var_os("ACPMUX_SUMMARY_TOOLS_OUTPUT").map(std::path::PathBuf::from);
    if let Some(dir) = &export {
        std::fs::create_dir(dir).expect("artifact directory must not already exist");
    }
    for (i, method) in ["_acpmux/sessions", "_acpmux/watch"].iter().enumerate() {
        let socket = scratch.0.join(format!("s{i}.sock"));
        let daemon = start(&scratch.0, &home, &socket);
        // Reset from the daemon's parent: Linux ptrace policy may refuse a sibling
        // Python process writing clear_refs, even though it can read RSS.
        std::fs::write(format!("/proc/{}/clear_refs", daemon.0.id()), "5").unwrap();
        let mut consumer = Command::new("python3");
        daemon_env::apply(&mut consumer, &scratch.0, daemon_env::Agents::Deny, &[]);
        let output = consumer
            .args(["-c", CONSUMER])
            .arg(&socket)
            .args([
                daemon.0.id().to_string(),
                method.to_string(),
                SESSIONS.to_string(),
                TOOLS.to_string(),
                SEED.to_string(),
            ])
            .arg(
                export
                    .as_ref()
                    .map(|dir| dir.join(format!("{}.json", method.trim_start_matches("_acpmux/"))))
                    .unwrap_or_default(),
            )
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "consumer failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        print!("{}", String::from_utf8_lossy(&output.stdout));
        drop(daemon);
    }
}
