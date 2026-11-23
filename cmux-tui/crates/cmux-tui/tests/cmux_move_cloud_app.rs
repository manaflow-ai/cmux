//! `cmux move SESSION --to cloud`, then `cmux move SESSION --to here`, end to end through the real
//! CLI against a stand-in for the app. The move itself is the app's (`CloudMove.swift` and
//! `CloudBringBack.swift` run `cmux link seed push` and `cmux link agent move`, which
//! `cloud_move_journey.rs` and `bring_back_journey.rs` drive between two real daemons); this
//! checks the verb runs exactly that one action, onto the machine the account has, and answers once
//! the app shows the chat there, then back here.
//!
//! The stand-in app answers `snapshot.get` with a topology whose chat tab is in this Mac's workspace
//! or in Cloud machine `vm-1`'s, `cloud list-machines` with the account's machines, and moves the
//! tab on `cloud move` (seconds after it answers, as a move that outlives the app's 40 s wait does)
//! and on `cloud bring-back`.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const SESSION: &str = "sess-journey-0001";

#[derive(Default)]
struct State {
    on_cloud: bool,
    signed_in: bool,
    machines: Vec<Value>,
    runs: Vec<Value>,
}

fn topology(on_cloud: bool) -> Value {
    let chat = |id: &str| json!([{"id": id, "kind": "conversation", "agent_session": SESSION}]);
    let (mac, vm) =
        if on_cloud { (json!([]), chat("tab-on-vm")) } else { (chat("tab-on-mac"), json!([])) };
    json!({
        "workspaces": [
            {"id": "ws-mac", "machine": "local", "tabs": mac},
            {"id": "ws-vm", "machine": "vm-1", "tabs": vm}
        ],
        "sessions": [{"id": "s-vm", "machine": "vm-1", "transport": "cloud"}]
    })
}

fn answer(state: &Arc<Mutex<State>>, request: &Value) -> Value {
    let params = &request["params"];
    let mut st = state.lock().unwrap();
    match request["method"].as_str() {
        Some("snapshot.get") => json!({"topology": topology(st.on_cloud)}),
        Some("action.run") => {
            st.runs.push(params.clone());
            match params["action"].as_str() {
                Some("cloud list-machines") => json!({"ran": true, "result": {
                    "account": {"signed_in": st.signed_in}, "loaded": true, "machines": st.machines}}),
                Some("cloud move") => {
                    assert_eq!(params["target"], "tab:tab-on-mac", "{params}");
                    let state = state.clone();
                    // The app's move goes on past its answer.
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_secs(3));
                        state.lock().unwrap().on_cloud = true;
                    });
                    json!({"ran": true, "result": {"started": true}})
                }
                Some("cloud bring-back") => {
                    assert_eq!(params["target"], "tab:tab-on-vm", "{params}");
                    st.on_cloud = false;
                    json!({"ran": true, "result": {"done": true}})
                }
                other => panic!("unexpected action {other:?}"),
            }
        }
        _ => json!({"pong": true}),
    }
}

struct App {
    dir: PathBuf,
    socket: PathBuf,
    state: Arc<Mutex<State>>,
    done: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl App {
    fn start(machines: Vec<Value>, signed_in: bool) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir =
            Path::new("/tmp").join(format!("cmux-move-cloud-{}-{stamp}-{n}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let socket = dir.join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let state = Arc::new(Mutex::new(State { signed_in, machines, ..State::default() }));
        let done = Arc::new(AtomicBool::new(false));
        let thread = {
            let (state, done) = (state.clone(), done.clone());
            std::thread::spawn(move || {
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let state = state.clone();
                            std::thread::spawn(move || {
                                stream.set_nonblocking(false).unwrap();
                                stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
                                let mut reader = BufReader::new(stream.try_clone().unwrap());
                                let mut writer = stream;
                                let mut line = String::new();
                                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                                    let request: Value = serde_json::from_str(&line).unwrap();
                                    line.clear();
                                    let result = answer(&state, &request);
                                    let response =
                                        json!({"id": request["id"], "ok": true, "result": result});
                                    if writeln!(writer, "{response}").is_err() {
                                        break;
                                    }
                                }
                            });
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            if done.load(Ordering::Relaxed) {
                                break;
                            }
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        Err(error) => panic!("app accept: {error}"),
                    }
                }
            })
        };
        Self { dir, socket, state, done, thread: Some(thread) }
    }

    fn cmux(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--app-socket")
            .arg(&self.socket)
            .args(args)
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    /// The `action.run` actions the app was asked for, in order.
    fn actions(&self) -> Vec<String> {
        let state = self.state.lock().unwrap();
        state.runs.iter().map(|run| run["action"].as_str().unwrap_or_default().to_owned()).collect()
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn json_out(output: &Output) -> Value {
    assert!(output.status.success(), "{}", text(output));
    serde_json::from_slice(&output.stdout).unwrap_or_else(|e| panic!("{e}: {}", text(output)))
}

fn one_machine() -> Vec<Value> {
    vec![json!({"machine_id": "vm-1", "title": "brave-otter", "status": "running"})]
}

#[test]
fn move_to_cloud_then_here_runs_the_apps_move_and_the_chat_goes_and_returns() {
    let app = App::start(one_machine(), true);

    // Dry run: the path and the machine, and nothing moves.
    let dry = json_out(&app.cmux(&["--json", "move", SESSION, "--to", "cloud", "--dry-run"]));
    let planned = &dry["moves"][0];
    assert_eq!(planned["path"], "cloud_move", "{dry}");
    assert_eq!(planned["machine_id"], "vm-1", "{dry}");
    assert_eq!(
        planned["command"],
        "cmux cloud move --target tab:tab-on-mac --machine machine:vm-1"
    );
    assert!(!app.actions().contains(&"cloud move".to_owned()), "{:?}", app.actions());
    let human = app.cmux(&["move", SESSION, "--to", "cloud", "--dry-run"]);
    assert!(
        text(&human).contains("would move to Cloud machine brave-otter (vm-1)"),
        "{}",
        text(&human)
    );

    // To Cloud: the app's Move to Cloud onto the one machine, answered once the chat is there.
    let moved = json_out(&app.cmux(&["--json", "move", SESSION, "--to", "cloud", "--timings"]));
    assert_eq!(moved["moves"][0]["path"], "cloud_move", "{moved}");
    assert!(moved["moves"][0]["timings"]["arrived_ms"].as_u64().unwrap() >= 2_000, "{moved}");
    assert!(app.state.lock().unwrap().on_cloud, "the chat shows on the machine");
    {
        let state = app.state.lock().unwrap();
        let run = state.runs.iter().find(|run| run["action"] == "cloud move").unwrap();
        assert_eq!(run["args"]["machine"], "machine:vm-1", "{run}");
        assert_eq!(run["cli"], true, "{run}");
    }

    // A second `--to cloud` says it is there already and how to bring it back.
    let again = app.cmux(&["move", SESSION, "--to", "cloud"]);
    assert!(!again.status.success());
    assert!(text(&again).contains("--to here"), "{}", text(&again));

    // Back here: `teleport` is the same verb; the app's Bring Back Local.
    let back = json_out(&app.cmux(&["--json", "teleport", SESSION, "--to", "here"]));
    assert_eq!(back["moves"][0]["path"], "bring_back", "{back}");
    assert_eq!(back["moves"][0]["machine"], "brave-otter", "{back}");
    assert!(!app.state.lock().unwrap().on_cloud, "the chat is back on this Mac");
    let actions = app.actions();
    assert_eq!(actions.iter().filter(|a| *a == "cloud move").count(), 1, "{actions:?}");
    assert_eq!(actions.iter().filter(|a| *a == "cloud bring-back").count(), 1, "{actions:?}");
}

#[test]
fn several_machines_none_or_signed_out_each_say_the_next_step_and_move_nothing() {
    let two = vec![
        json!({"machine_id": "vm-1", "title": "brave-otter"}),
        json!({"machine_id": "vm-2", "title": "calm-heron"}),
    ];
    let app = App::start(two, true);
    let several = app.cmux(&["move", SESSION, "--to", "cloud"]);
    assert!(!several.status.success());
    let said = text(&several);
    assert!(said.contains("brave-otter (vm-1)") && said.contains("calm-heron (vm-2)"), "{said}");
    assert!(said.contains("--to NAME"), "{said}");
    // Naming one moves onto it.
    let named =
        json_out(&app.cmux(&["--json", "move", SESSION, "--to", "calm-heron", "--dry-run"]));
    assert_eq!(named["moves"][0]["machine_id"], "vm-2", "{named}");
    assert!(!app.actions().contains(&"cloud move".to_owned()));

    let none = App::start(vec![], true);
    let said = text(&none.cmux(&["move", SESSION, "--to", "cloud"]));
    assert!(said.contains("cmux setup cloud-machine"), "{said}");

    let out = App::start(one_machine(), false);
    let said = text(&out.cmux(&["move", SESSION, "--to", "cloud"]));
    assert!(said.contains("cmux login"), "{said}");
    for app in [&none, &out] {
        assert!(!app.actions().contains(&"cloud move".to_owned()), "{:?}", app.actions());
    }
}
