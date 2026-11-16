//! `agent-cli-hybrid-v1` over the raw command path: a viewer that declared it gets an agent
//! CLI terminal as `agent-cli-frame` cell deltas, which rebuild the terminal's screen, and
//! resumes after a drop from its last frame; every other attach is unchanged.

use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::stream::Frame;
use cmux_agent_cli_render::vt;
use serde_json::{Value, json};

use super::agent_cli_hybrid::is_parked;
use super::tests::captured_writer;
use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use crate::{Mux, Surface, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

/// A terminal whose program prints nothing; `agent` is the agent its hook reports.
fn terminal(name: &str, agent: Option<&str>) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec sleep 600".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test(name, options);
    let surface = mux.new_workspace(None, None).unwrap();
    if let Some(agent) = agent {
        mux.note_running_agent_for_test(surface.terminal_public_id().expect("a terminal"), agent);
    }
    (mux, surface)
}

struct Viewer {
    client: u64,
    outbound: Arc<BoundedOutbound>,
    _writer: MessageWriter,
}

fn viewer(mux: &Arc<Mux>, capability: bool) -> Viewer {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if capability {
        handle_command(
            mux,
            client,
            command(json!({
                "cmd": "set-client-info", "name": "hybrid test",
                "capabilities": ["agent-cli-hybrid-v1"],
            })),
            &writer,
        )
        .unwrap();
    }
    Viewer { client, outbound, _writer: writer }
}

impl Viewer {
    fn attach(&self, mux: &Arc<Mux>, surface: &Surface, extra: Value) {
        let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
        for (key, value) in extra.as_object().expect("fields") {
            request[key] = value.clone();
        }
        handle_command(mux, self.client, command(request), &self._writer).unwrap();
    }

    /// The next event named `name` within 5 s, the events before it skipped and collected.
    fn next(&self, name: &str, skipped: &mut Vec<String>) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(message) = self.outbound.try_pop() {
                let value: Value = serde_json::from_str(&message).expect("outbound JSON");
                if value["event"] == name {
                    return value;
                }
                skipped.push(value["event"].as_str().unwrap_or("").to_owned());
                continue;
            }
            assert!(Instant::now() < deadline, "no {name} event; got {skipped:?}");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

/// A phone's terminal, drawing frames as the iPhone does.
struct Phone {
    term: ghostty_vt::Terminal,
    rows: u16,
}

impl Phone {
    fn new(first: &Value) -> Phone {
        let (cols, rows) = (first["cols"].as_u64().unwrap(), first["rows"].as_u64().unwrap());
        let term = ghostty_vt::Terminal::new(
            u16::try_from(cols).unwrap(),
            u16::try_from(rows).unwrap(),
            1 << 20,
            ghostty_vt::Callbacks::default(),
        )
        .unwrap();
        Phone { term, rows: u16::try_from(rows).unwrap() }
    }

    fn apply(&mut self, event: &Value) {
        let frame = Frame {
            frame: event["frame"].as_u64().unwrap(),
            base: event["base"].as_u64(),
            data: base64::engine::general_purpose::STANDARD
                .decode(event["data"].as_str().unwrap())
                .unwrap(),
        };
        let cursor = vt::Cursor {
            x: u16::try_from(event["cursor_x"].as_u64().unwrap()).unwrap(),
            y: u16::try_from(event["cursor_y"].as_u64().unwrap()).unwrap(),
            visible: event["cursor_visible"].as_bool().unwrap(),
        };
        self.term.vt_write(&vt::frame_bytes(&frame, self.rows, cursor).unwrap());
    }

    fn text(&mut self) -> String {
        self.term.viewport_text().unwrap()
    }
}

fn screen_text(surface: &Surface) -> String {
    surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap()
}

#[test]
fn the_capability_is_advertised() {
    let (mux, _surface) = terminal("hybrid-identify", None);
    let viewer = viewer(&mux, false);
    let identity =
        handle_command(&mux, viewer.client, command(json!({"cmd": "identify"})), &viewer._writer)
            .unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == "agent-cli-hybrid-v1"), "{identity}");
}

#[test]
fn an_agent_cli_terminal_reaches_a_hybrid_viewer_as_cell_deltas() {
    let (mux, surface) = terminal("hybrid-claude", Some("claude"));
    surface.inject_output_for_test(b"\x1b[38;5;174m\xe2\x9c\xbb\x1b[0m Claude Code\r\n> ");
    let viewer = viewer(&mux, true);
    viewer.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let first = viewer.next("agent-cli-frame", &mut skipped);
    assert!(skipped.iter().any(|event| event == "colors-changed"), "the colors: {skipped:?}");
    assert!(!skipped.iter().any(|event| event == "vt-state"), "no vt-state: {skipped:?}");
    assert_eq!(first["base"], Value::Null, "a keyframe");
    let mut phone = Phone::new(&first);
    phone.apply(&first);
    assert_eq!(phone.text(), screen_text(&surface));

    surface.inject_output_for_test(b"\x1b[1mhello\x1b[0m world");
    let next = viewer.next("agent-cli-frame", &mut skipped);
    assert_eq!(next["base"], first["frame"]);
    assert_eq!(next["stream"], first["stream"]);
    phone.apply(&next);
    assert_eq!(phone.text(), screen_text(&surface));
    assert!(!skipped.iter().any(|event| event == "output"), "no PTY bytes: {skipped:?}");
    disconnect_client(&mux, viewer.client, false);
}

#[test]
fn a_dropped_viewer_resumes_from_its_last_frame_without_a_keyframe() {
    let (mux, surface) = terminal("hybrid-resume", Some("codex"));
    surface.inject_output_for_test(b"codex> one\r\n");
    let first_viewer = viewer(&mux, true);
    first_viewer.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let first = first_viewer.next("agent-cli-frame", &mut skipped);
    let mut phone = Phone::new(&first);
    phone.apply(&first);
    let stream = first["stream"].as_str().unwrap().to_owned();
    disconnect_client(&mux, first_viewer.client, false);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !is_parked(&stream) {
        assert!(Instant::now() < deadline, "the stream was not kept");
        std::thread::sleep(Duration::from_millis(2));
    }

    // Written while the phone was away.
    surface.inject_output_for_test(b"codex> two\r\n");
    let back = viewer(&mux, true);
    back.attach(&mux, &surface, json!({"hybrid_stream": stream, "hybrid_frame": first["frame"]}));
    let resumed = back.next("agent-cli-frame", &mut skipped);
    assert_eq!(resumed["stream"].as_str(), Some(stream.as_str()));
    assert_eq!(resumed["base"], first["frame"], "a delta from the phone's frame");
    phone.apply(&resumed);
    assert_eq!(phone.text(), screen_text(&surface));
    disconnect_client(&mux, back.client, false);
}

#[test]
fn other_viewers_and_other_programs_keep_the_byte_stream() {
    for (agent, capability) in [(Some("claude"), false), (None, true), (Some("vim"), true)] {
        let (mux, surface) = terminal("hybrid-bytes", agent);
        let viewer = viewer(&mux, capability);
        viewer.attach(&mux, &surface, json!({}));
        let mut skipped = Vec::new();
        viewer.next("vt-state", &mut skipped);
        surface.inject_output_for_test(b"plain");
        let output = viewer.next("output", &mut skipped);
        assert_eq!(output["data"], "cGxhaW4=", "{agent:?} {capability}");
        assert!(!skipped.iter().any(|event| event == "agent-cli-frame"), "{skipped:?}");
        disconnect_client(&mux, viewer.client, false);
    }
}
