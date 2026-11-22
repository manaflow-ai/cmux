//! A byte-backend terminal runs on the session host's local runtime: app
//! output reaches the parser with credit back, input and resize go to the
//! app, the app's end ends the terminal, and a host close tells the app.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::SurfaceOptions;
use crate::mux::Mux;
use crate::terminal_backend::channel::ChannelTable;
use crate::terminal_backend::pty::BackendSide;
use crate::terminal_backend::terminals::TerminalMeta;
use crate::terminal_backend::{
    BackendId, DEFAULT_WINDOW_BYTES, End, ExitStatus, Frame, FrameBody, LocalId,
};

struct Fixture {
    mux: Arc<Mux>,
    channels: Arc<ChannelTable<TerminalMeta>>,
    lines: Arc<Mutex<Vec<Value>>>,
    surface: crate::SurfaceId,
    terminal_id: crate::resource::TerminalPublicId,
}

fn fixture(name: &str) -> Fixture {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    let channels = Arc::new(ChannelTable::new("term"));
    let meta = TerminalMeta {
        id: BackendId::app("cmux/ssh", &LocalId::new("ssh").unwrap()),
        target: "conn_1".into(),
        run_key: None,
    };
    let terminal = channels.insert("cmux/ssh", meta, DEFAULT_WINDOW_BYTES, true);
    let lines = Arc::new(Mutex::new(Vec::new()));
    let sink = lines.clone();
    let side = BackendSide {
        channels: channels.clone(),
        terminal,
        send: Arc::new(move |line| sink.lock().unwrap().push(line)),
    };
    let created = mux.spawn_backend_terminal(side).unwrap();
    Fixture { mux, channels, lines, surface: created.surface, terminal_id: created.terminal_id }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.mux.shutdown();
    }
}

fn until(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

impl Fixture {
    fn app_sends(&self, body: FrameBody) {
        let frame = Frame { channel: "term-1".into(), body };
        self.channels.receive_from_app("cmux/ssh", frame).unwrap();
    }

    fn text(&self) -> String {
        let surface = self.mux.surface(self.surface).expect("the surface");
        surface.try_with_terminal(|t| t.viewport_text().unwrap()).unwrap()
    }

    fn app_got(&self, what: &str, pred: impl Fn(&Value) -> bool) {
        until(what, || self.lines.lock().unwrap().iter().any(&pred));
    }
}

#[test]
fn app_output_reaches_the_parser_and_input_and_resize_reach_the_app() {
    let f = fixture("backend-terminal-io");
    f.app_sends(FrameBody::Data { offset: 11, bytes: b"hello there".to_vec() });
    until("the output on screen", || f.text().contains("hello there"));
    f.app_got("output credit", |l| {
        l["t"] == "credit" && l["direction"] == "out" && l["bytes"] == 11
    });
    let surface = f.mux.surface(f.surface).unwrap();
    surface.write_bytes(b"ls\r").unwrap();
    f.app_got("input data", |l| {
        l == &json!({ "t": "data", "channel": "term-1", "offset": 3, "bytes": "bHMN" })
    });
    surface.resize(100, 30).unwrap();
    f.app_got("resize", |l| {
        l["op"] == "cmux.terminal.backend.resize"
            && l["data"]["cols"] == 100
            && l["data"]["rows"] == 30
    });
}

#[test]
fn the_apps_exit_ends_the_terminal_after_its_last_output() {
    let f = fixture("backend-terminal-exit");
    let surface = f.mux.surface(f.surface).unwrap();
    f.app_sends(FrameBody::Data { offset: 4, bytes: b"bye!".to_vec() });
    f.app_sends(FrameBody::End(End::Exit(ExitStatus { code: Some(3), ..ExitStatus::default() })));
    until("the terminal ends", || surface.is_dead());
    let text = surface.try_with_terminal(|t| t.viewport_text().unwrap()).unwrap();
    assert!(text.contains("bye!"), "the last output shows before the end: {text:?}");
}

#[test]
fn a_host_close_removes_the_terminal_and_tells_the_app() {
    let f = fixture("backend-terminal-close");
    f.mux.close_backend_terminal(f.surface);
    assert!(f.mux.surface(f.surface).is_none());
    f.app_got("close", |l| {
        l == &json!({ "t": "host.event", "op": "cmux.terminal.backend.close", "data": { "terminal": "term-1" } })
    });
    assert!(f.channels.get("term-1").is_none());
}

// MARK: first view (terminal.project, over the resource protocol)

impl Fixture {
    fn request(&self, operation: &str, params: Value, key: &str) -> Value {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let envelope = json!({
            "protocol": "cmux.protocol/2", "type": "request", "id": key,
            "operation": operation, "params": params, "idempotency_key": key,
        });
        crate::resource_router::handle_resource_message(&self.mux, &envelope.to_string()).unwrap()
    }

    /// A live pane's workspace, screen and pane ids (a new workspace with
    /// one terminal tab).
    fn pane(&self, key: &str) -> [String; 3] {
        let created = self.request(
            "workspace.create",
            json!({ "initial_content": "terminal", "name": key }),
            key,
        );
        let value = &created["result"]["value"];
        let id =
            |field: &str| value[field].as_str().unwrap_or_else(|| panic!("{created}")).to_owned();
        [id("workspace_id"), id("screen_id"), id("pane_id")]
    }

    fn project(&self, destination: &[String; 3], key: &str) -> Value {
        let [workspace, screen, pane] = destination;
        self.request(
            "terminal.project",
            json!({
                "terminal": self.terminal_id.to_string(),
                "destination_workspace": workspace, "destination_screen": screen,
                "destination_pane": pane, "index": 0,
            }),
            key,
        )
    }

    fn records(&self) -> usize {
        let registry = self.mux.workspace_registry.lock().unwrap();
        registry.terminal_snapshot().unwrap().terminals.len()
    }

    fn identity(&self) -> Option<crate::terminal_host_runtime::TerminalHostIdentity> {
        let surface = self.mux.surface(self.surface)?;
        self.mux.resource_terminal_host_identity(&surface)
    }
}

fn ok(response: &Value) -> bool {
    response["ok"] == true
}

#[test]
fn other_topology_commits_work_while_an_unviewed_app_terminal_exists() {
    let f = fixture("backend-terminal-other-commits");
    let [_, _, pane] = f.pane("ws-1");
    assert!(pane.starts_with("pane_"), "{pane}");
}

#[test]
fn the_first_view_writes_the_durable_record_and_a_second_view_reuses_it() {
    let f = fixture("backend-terminal-first-view");
    let pane = f.pane("ws-1");
    let before = f.records();
    assert!(!f.mux.backend_terminal_viewed(f.surface));
    let first = f.project(&pane, "p-1");
    assert!(ok(&first), "{first}");
    assert!(f.mux.backend_terminal_viewed(f.surface));
    assert_eq!(f.records(), before + 1, "one record, written by the first view");
    let identity = f.identity().expect("a durable identity");
    {
        let registry = f.mux.workspace_registry.lock().unwrap();
        let record = registry.terminal_record(&identity.terminal_id).unwrap().unwrap();
        assert_eq!(record.incarnation.as_deref(), Some(identity.incarnation.as_str()));
    }
    let second = f.project(&pane, "p-2");
    assert!(ok(&second), "{second}");
    assert_eq!(f.records(), before + 1, "a second view does not register again");
    assert_eq!(f.identity(), Some(identity));
    // A viewed terminal is never closed as unplaced.
    f.mux.close_backend_terminal(f.surface);
    assert!(f.mux.surface(f.surface).is_some());
}

#[test]
fn a_failed_first_view_leaves_no_record() {
    let f = fixture("backend-terminal-failed-view");
    let [workspace, screen, _] = f.pane("ws-1");
    let missing = "pane_00000000000000000000000000000000".to_owned();
    let before = f.records();
    let failed = f.project(&[workspace, screen, missing], "p-1");
    assert!(!ok(&failed), "{failed}");
    assert_eq!(f.records(), before);
    assert!(!f.mux.backend_terminal_viewed(f.surface));
}

#[test]
fn a_never_viewed_terminal_closes_and_leaves_the_catalog() {
    let f = fixture("backend-terminal-unviewed-close");
    f.mux.close_backend_terminal(f.surface);
    assert!(f.mux.surface(f.surface).is_none());
    let pane = f.pane("ws-1");
    assert!(!ok(&f.project(&pane, "p-1")), "a closed terminal cannot be projected");
}
