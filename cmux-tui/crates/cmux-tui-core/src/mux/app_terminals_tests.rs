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
    let surface = mux.spawn_backend_terminal(side).unwrap();
    Fixture { mux, channels, lines, surface }
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
