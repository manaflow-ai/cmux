//! RAM budget of one agent's `cmux mcp serve --all-tools`
//! (plans/cmux-next/resource-efficiency-DESIGN.md). Every agent chat runs its
//! own server for its whole life, so its footprint is paid once per agent: at
//! 110 agents on 2026-10-20 the servers held 2.3 GB (21.6 MB each). The test
//! serves a catalog the size of the app's (1051 actions, about 490 offered to
//! MCP) from a fake app socket, lists the tools, and reads the server's
//! physical footprint while it idles.
#![cfg(target_os = "macos")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Footprint allowed for an idle server after `tools/list`. The binary's own
/// floor is about 4.6 MB (`acpmux secret-mcp`, the same binary, holds no
/// catalog); the catalog's tools need well under 2 MB.
const BUDGET_MB: f64 = 10.0;
const ACTIONS: usize = 1051;

/// One action shaped like the app's `action.list` entries (all fields the
/// app sends, every other one offered to the CLI and MCP).
fn action(i: usize) -> Value {
    let offered = i % 2 == 0;
    let surface = if offered { "offered" } else { "guiOnly" };
    let mut arguments = Vec::new();
    if i % 3 == 0 {
        arguments.push(json!({"kind": "enum", "name": "section", "required": false, "title": "Section",
            "choices": (0..11).map(|c| json!({"title": format!("Choice {c}"), "value": format!("choice{c}")})).collect::<Vec<_>>()}));
        arguments.push(
            json!({"kind": "string", "name": "setting", "required": false, "title": "Setting"}),
        );
    }
    json!({
        "arguments": arguments, "available": true, "bound": true,
        "category": format!("category{}", i % 20), "category_title": format!("Category {}", i % 20),
        "cli": offered, "cli_name": format!("app action-number-{i}"), "debug_only": false,
        "destructive": i % 7 == 0, "focuses": i % 5 == 0, "id": format!("actionNumber{i}"),
        "keywords": ["preferences", "options", "config", "window", "layout"],
        "main_menu": "app", "noun": "app", "requires": [], "shortcut": "⌘,", "shortcut_config": "cmd+,",
        "starts_terminal": false,
        "surfaces": {"cli": surface, "context_menu": "noObject", "context_menus": [], "mcp": surface,
                     "palette": "offered"},
        "symbol": "gearshape", "targets": if i % 4 == 0 { json!(["workspace", "pane"]) } else { json!([]) },
        "title": format!("Action number {i}…"), "verb": "settings",
        "unavailable_reason": if i % 9 == 0 { json!("Needs a newer macOS.") } else { Value::Null },
        "waits_for_person": false, "waits_for_result": false,
    })
}

fn footprint_mb(pid: u32) -> f64 {
    #[repr(C)]
    struct RusageV2 {
        uuid: [u8; 16],
        times: [u64; 7],
        phys_footprint: u64,
        rest: [u64; 12],
    }
    unsafe extern "C" {
        fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut std::ffi::c_void) -> i32;
    }
    let mut usage = RusageV2 { uuid: [0; 16], times: [0; 7], phys_footprint: 0, rest: [0; 12] };
    // SAFETY: the buffer has rusage_info_v2's layout (flavor 2).
    let status = unsafe { proc_pid_rusage(pid as i32, 2, (&raw mut usage).cast()) };
    assert_eq!(status, 0, "proc_pid_rusage({pid})");
    usage.phys_footprint as f64 / 1_048_576.0
}

/// An app control socket that answers `action.list` with the catalog and
/// refuses everything else (the server's action watcher backs off).
fn fake_app(socket: &Path, done: Arc<AtomicBool>) -> std::thread::JoinHandle<()> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let list = json!({"actions": (0..ACTIONS).map(action).collect::<Vec<_>>(), "count": ACTIONS,
                      "categories": []});
    std::thread::spawn(move || {
        while !done.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let list = list.clone();
                    std::thread::spawn(move || {
                        stream.set_nonblocking(false).unwrap();
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut writer = stream;
                        let mut line = String::new();
                        while reader.read_line(&mut line).unwrap_or(0) > 0 {
                            let request: Value = serde_json::from_str(&line).unwrap();
                            line.clear();
                            let response = if request["method"] == "action.list" {
                                json!({"id": request["id"], "ok": true, "result": list})
                            } else {
                                json!({"id": request["id"], "ok": false, "error": {
                                    "code": "unavailable", "message": "not in this fake app", "data": {}}})
                            };
                            if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err()
                            {
                                break;
                            }
                        }
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    // test fake: accept loop of a nonblocking listener until the test ends
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept: {error}"),
            }
        }
    })
}

#[test]
fn an_idle_all_tools_server_stays_under_its_ram_budget() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let dir = PathBuf::from(format!("/tmp/cmux-mfp-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let done = Arc::new(AtomicBool::new(false));
    let app = fake_app(&dir.join("app.sock"), done.clone());

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(dir.join("app.sock"))
        .args(["mcp", "serve", "--all-tools"])
        .env("HOME", &dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("CMUX_TUI_SOCKET", dir.join("no-daemon.sock"))
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_MCP_TOOLS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "footprint", "version": "1"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": "list", "method": "tools/list"}),
    ] {
        writeln!(stdin, "{message}").unwrap();
    }
    stdin.flush().unwrap();
    let mut reader = BufReader::new(child.stdout.take().unwrap());
    let tools = loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the server closed stdout");
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        if message["id"] == "list" {
            break message["result"]["tools"].as_array().cloned().unwrap_or_default();
        }
    };
    let app_tools = tools
        .iter()
        .filter(|tool| tool["name"].as_str().is_some_and(|n| n.starts_with("app_")))
        .count();
    assert!(app_tools >= ACTIONS / 2 - 5, "the catalog's tools were not listed: {app_tools}");
    // The server is idle now, as an agent's is between its calls.
    std::thread::sleep(Duration::from_secs(1));
    let footprint = footprint_mb(child.id());
    eprintln!("MCP-FOOTPRINT idle all-tools server: {footprint:.1} MB ({app_tools} app tools)");
    drop(stdin);
    let _ = child.wait();
    done.store(true, Ordering::Relaxed);
    let _ = app.join();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        footprint <= BUDGET_MB,
        "an idle `cmux mcp serve --all-tools` holds {footprint:.1} MB, over its {BUDGET_MB} MB budget"
    );
}
