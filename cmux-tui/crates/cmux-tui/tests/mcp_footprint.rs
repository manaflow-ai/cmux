//! RAM of one agent's `cmux mcp serve --all-tools`
//! (plans/cmux-next/resource-efficiency-DESIGN.md offender 2,
//! plans/cmux-next/chrome-parity/p07-memory.md task 093). Every agent chat
//! runs its own server for its whole life, so its footprint is paid once per
//! agent: at 110 agents on 2026-10-20 the servers held 2.3 GB (21.6 MB each).
//! With `mcpCatalogHost` the server is a byte-copy relay to one shared host
//! that keeps the app's catalog once. The tests serve a catalog the size of
//! the app's (1051 actions, about 525 offered to MCP) from a fake app socket:
//! the relay lists exactly the tools a server of its own lists, and an idle
//! relay stays under its RAM budget (macOS, `phys_footprint`).
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Footprint allowed for an idle relay after `tools/list`: the slim host
/// binary's own floor, with no runtime and no catalog (the in-process
/// server's budget was 10 MB).
#[cfg(target_os = "macos")]
const RELAY_BUDGET_MB: f64 = 2.0;
const ACTIONS: usize = 1051;
const FEATURE: &str = "mcpCatalogHost";

/// One action shaped like the app's `action.list` entries (all fields the
/// app sends, every other one offered to the CLI and MCP).
fn action(i: usize) -> Value {
    let offered = i.is_multiple_of(2);
    let surface = if offered { "offered" } else { "guiOnly" };
    let mut arguments = Vec::new();
    if i.is_multiple_of(3) {
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
        "destructive": i.is_multiple_of(7), "focuses": i.is_multiple_of(5), "id": format!("actionNumber{i}"),
        "keywords": ["preferences", "options", "config", "window", "layout"],
        "main_menu": "app", "noun": "app", "requires": [], "shortcut": "⌘,", "shortcut_config": "cmd+,",
        "starts_terminal": false,
        "surfaces": {"cli": surface, "context_menu": "noObject", "context_menus": [], "mcp": surface,
                     "palette": "offered"},
        "symbol": "gearshape", "targets": if i.is_multiple_of(4) { json!(["workspace", "pane"]) } else { json!([]) },
        "title": format!("Action number {i}…"), "verb": "settings",
        "unavailable_reason": if i.is_multiple_of(9) { json!("Needs a newer macOS.") } else { Value::Null },
        "waits_for_person": false, "waits_for_result": false,
    })
}

/// An app control socket that answers `action.list` with the catalog and
/// `snapshot.get` with one window that names the request's caller, and
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
                            } else if request["method"] == "snapshot.get" {
                                let windows = json!([request["params"]["caller"]]);
                                json!({"id": request["id"], "ok": true,
                                       "result": {"topology": {"windows": windows}}})
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

/// A test folder with a settings file that turns MCP on and a fake app.
struct Fixture {
    dir: PathBuf,
    done: Arc<AtomicBool>,
    app: Option<std::thread::JoinHandle<()>>,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
        let dir = PathBuf::from(format!("/tmp/cmux-mfp-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cmux-next.json"), r#"{"mcp": {"enabled": true}}"#).unwrap();
        let done = Arc::new(AtomicBool::new(false));
        let app = fake_app(&dir.join("app.sock"), done.clone());
        Self { dir, done, app: Some(app) }
    }

    /// `cmux mcp serve --all-tools` for this app, through the shared host
    /// when `host` is true.
    fn serve(&self, host: bool) -> Child {
        self.serve_as(host, None)
    }

    /// [`Fixture::serve`] for the agent chat `agent` (`CMUX_AGENT_SESSION`).
    fn serve_as(&self, host: bool, agent: Option<&str>) -> Child {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .arg("--app-socket")
            .arg(self.dir.join("app.sock"))
            .args(["mcp", "serve", "--all-tools"])
            .env("HOME", &self.dir)
            .env("TMPDIR", &self.dir)
            .env("XDG_RUNTIME_DIR", &self.dir)
            .env("CMUX_NEXT_CONFIG_FILE", self.dir.join("cmux-next.json"))
            .env("CMUX_TUI_SOCKET", self.dir.join("no-daemon.sock"))
            // The host ends soon after the test's last relay leaves.
            .env("CMUX_MCP_HOST_IDLE_EXIT_MS", "500")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_MCP_TOOLS")
            .env_remove("CMUX_MCP_UPSTREAMS")
            .env_remove("CMUX_DISABLE_FEATURES")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(std::fs::File::create(self.stderr_path(host)).unwrap());
        if let Some(agent) = agent {
            command.env("CMUX_AGENT_SESSION", agent);
        }
        if host {
            command.env("CMUX_ENABLE_FEATURES", FEATURE);
        } else {
            command.env_remove("CMUX_ENABLE_FEATURES");
        }
        command.spawn().unwrap()
    }

    fn stderr_path(&self, host: bool) -> PathBuf {
        self.dir.join(if host { "relay.stderr" } else { "own.stderr" })
    }

    fn stderr(&self, host: bool) -> String {
        std::fs::read_to_string(self.stderr_path(host)).unwrap_or_default()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(app) = self.app.take() {
            let _ = app.join();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Initializes the server and returns its `tools/list` tools, with the
/// open stdin and stdout of the session.
fn list_tools(child: &mut Child) -> (Vec<Value>, ChildStdin, BufReader<ChildStdout>) {
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
    (tools, stdin, reader)
}

fn app_tools(tools: &[Value]) -> usize {
    tools.iter().filter(|tool| tool["name"].as_str().is_some_and(|n| n.starts_with("app_"))).count()
}

/// The command line of process `pid` (`ps`, on macOS and Linux).
fn command_line(pid: u32) -> String {
    let output = Command::new("ps").args(["-o", "args=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[test]
fn the_relay_lists_the_tools_a_server_of_its_own_lists() {
    let fixture = Fixture::new();
    let mut own = fixture.serve(false);
    let (expected, stdin, _) = list_tools(&mut own);
    drop(stdin);
    let _ = own.wait();
    assert!(app_tools(&expected) >= ACTIONS / 2 - 5, "the catalog's tools were not listed");

    let mut relay = fixture.serve(true);
    let (listed, stdin, _) = list_tools(&mut relay);
    assert!(
        command_line(relay.id()).contains("__mcp-relay"),
        "the agent's server did not become the relay: {}\n{}",
        command_line(relay.id()),
        fixture.stderr(true)
    );
    assert_eq!(listed.len(), expected.len(), "the relay lists another number of tools");
    assert_eq!(listed, expected, "the relay lists other tools");

    // A second agent reaches the same host and lists the same tools.
    let mut second = fixture.serve(true);
    let (again, second_stdin, _) = list_tools(&mut second);
    assert_eq!(again, expected);
    let hosts = std::fs::read_dir(fixture.dir.join(format!("cmux-tui-{}", uid())))
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    name.starts_with("mcp-") && name.ends_with(".sock")
                })
                .count()
        })
        .unwrap_or(0);
    assert_eq!(hosts, 1, "two agents of one build must share one host");
    drop(second_stdin);
    drop(stdin);
    let _ = second.wait();
    let _ = relay.wait();
}

/// Calls `tool` with no arguments and returns its structured result.
fn call(stdin: &mut ChildStdin, reader: &mut BufReader<ChildStdout>, tool: &str) -> Value {
    let request = json!({"jsonrpc": "2.0", "id": "call", "method": "tools/call",
                         "params": {"name": tool, "arguments": {}}});
    writeln!(stdin, "{request}").unwrap();
    stdin.flush().unwrap();
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the server closed stdout");
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        if message["id"] == "call" {
            return message["result"]["structuredContent"].clone();
        }
    }
}

#[test]
fn each_agent_calls_through_the_shared_host_as_itself() {
    let fixture = Fixture::new();
    let mut one = fixture.serve_as(true, Some("agent-one"));
    let mut two = fixture.serve_as(true, Some("agent-two"));
    let (_, mut one_in, mut one_out) = list_tools(&mut one);
    let (_, mut two_in, mut two_out) = list_tools(&mut two);
    assert!(command_line(one.id()).contains("__mcp-relay"), "{}", fixture.stderr(true));
    assert!(command_line(two.id()).contains("__mcp-relay"), "{}", fixture.stderr(true));
    // The app sees each call's caller: the agent whose relay sent it.
    for _ in 0..3 {
        let first = call(&mut one_in, &mut one_out, "window_list");
        let second = call(&mut two_in, &mut two_out, "window_list");
        assert_eq!(first["items"], json!([{"agent_session": "agent-one"}]));
        assert_eq!(second["items"], json!([{"agent_session": "agent-two"}]));
    }
    drop(one_in);
    drop(two_in);
    let _ = one.wait();
    let _ = two.wait();
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
#[test]
fn an_idle_relay_stays_under_its_ram_budget() {
    let fixture = Fixture::new();
    let mut relay = fixture.serve(true);
    let (tools, stdin, _) = list_tools(&mut relay);
    assert!(app_tools(&tools) >= ACTIONS / 2 - 5, "the catalog's tools were not listed");
    assert!(command_line(relay.id()).contains("__mcp-relay"));
    // The relay is idle now, as an agent's is between its calls.
    std::thread::sleep(Duration::from_secs(1));
    let footprint = footprint_mb(relay.id());
    eprintln!("MCP-FOOTPRINT idle relay: {footprint:.2} MB ({} app tools)", app_tools(&tools));
    drop(stdin);
    let _ = relay.wait();
    assert!(
        footprint <= RELAY_BUDGET_MB,
        "an idle `cmux mcp serve --all-tools` relay holds {footprint:.2} MB, over its {RELAY_BUDGET_MB} MB budget"
    );
}

fn uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { libc::getuid() }
}
