//! `agent-cli-hybrid-v1` over the raw command path: a viewer that declared it gets an agent
//! CLI terminal as `agent-cli-frame` cell deltas, which rebuild the terminal's screen, and
//! resumes after a drop from its last frame; every other attach is unchanged.

use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::lean::LeanDecoder;
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
    declaring(mux, if capability { &["agent-cli-hybrid-v1"] } else { &[] })
}

fn declaring(mux: &Arc<Mux>, capabilities: &[&str]) -> Viewer {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if !capabilities.is_empty() {
        handle_command(
            mux,
            client,
            command(json!({
                "cmd": "set-client-info", "name": "hybrid test", "capabilities": capabilities,
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
    assert!(capabilities.iter().any(|value| value == "agent-cli-hybrid-v2"), "{identity}");
}

/// The lean form (`agent-cli-hybrid-v2`): the same frames as `agent-cli-lean` events, read back
/// by the viewer's decoder, in fewer bytes than v1's `agent-cli-frame` events.
#[test]
fn a_lean_viewer_gets_compact_frames_that_rebuild_the_screen() {
    let (mux, surface) = terminal("hybrid-lean", Some("claude"));
    surface.inject_output_for_test(b"\x1b[38;5;174m\xe2\x9c\xbb\x1b[0m Claude Code\r\n> ");
    let lean = declaring(&mux, &["agent-cli-hybrid-v1", "agent-cli-hybrid-v2"]);
    let v1 = viewer(&mux, true);
    lean.attach(&mux, &surface, json!({}));
    v1.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let mut decoder = LeanDecoder::new();
    let mut phone: Option<Phone> = None;
    let (mut lean_bytes, mut v1_bytes) = (0, 0);
    for step in 0..2 {
        if step == 1 {
            surface.inject_output_for_test(b"\x1b[1mhello\x1b[0m world ----------");
        }
        let event = lean.next("agent-cli-lean", &mut skipped);
        assert_eq!(
            event.as_object().map(|fields| fields.len()),
            Some(3),
            "only event, surface and f: {event}"
        );
        let bytes =
            base64::engine::general_purpose::STANDARD.decode(event["f"].as_str().unwrap()).unwrap();
        let decoded = decoder.decode(&bytes).expect("a lean frame");
        let phone = phone.get_or_insert_with(|| {
            Phone::new(&json!({"cols": decoded.cols, "rows": decoded.rows}))
        });
        phone.term.vt_write(&vt::frame_bytes(&decoded.frame, phone.rows, decoded.cursor).unwrap());
        assert_eq!(phone.text(), screen_text(&surface), "frame {step}");
        lean_bytes += event.to_string().len();
        v1_bytes += v1.next("agent-cli-frame", &mut skipped).to_string().len();
    }
    assert!(!skipped.iter().any(|event| event == "output"), "no PTY bytes: {skipped:?}");
    assert!(lean_bytes < v1_bytes, "lean {lean_bytes} B against v1's {v1_bytes} B");
    disconnect_client(&mux, lean.client, false);
    disconnect_client(&mux, v1.client, false);
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

/// The events up to and with the next `agent-cli-frame`, in order, within 5 s.
fn through_next_frame(viewer: &Viewer) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut events = Vec::new();
    loop {
        if let Some(message) = viewer.outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            let frame = value["event"] == "agent-cli-frame";
            events.push(value);
            if frame {
                return events;
            }
            continue;
        }
        assert!(Instant::now() < deadline, "no agent-cli-frame; got {events:?}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn output_data(event: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(event["data"].as_str().unwrap()).unwrap()
}

/// Codex and opencode run on the alternate screen with input modes set, and frames carry
/// neither: an agent CLI's viewer gets them as `output` bytes, the screen before its keyframe
/// (after it, the switch would blank the frame), the input modes after it, and each change
/// later on, a switch of screens followed by a keyframe of the screen switched to (#44052 F1).
#[test]
fn an_agent_cli_viewer_follows_the_alternate_screen_and_input_modes() {
    let (mux, surface) = terminal("hybrid-agent-screen", Some("codex"));
    surface.inject_output_for_test(b"\x1b[?1049h\x1b[?2004h\x1b[?1hcodex> one");
    let viewer = viewer(&mux, true);
    viewer.attach(&mux, &surface, json!({}));
    let events = through_next_frame(&viewer);
    let outputs: Vec<Vec<u8>> =
        events.iter().filter(|event| event["event"] == "output").map(output_data).collect();
    assert_eq!(outputs, [b"\x1b[?1049h".to_vec()], "the screen before the keyframe: {events:?}");
    let first = events.last().unwrap();
    assert_eq!(first["base"], Value::Null, "a keyframe");
    assert_eq!(output_bytes(&viewer), b"\x1b[?1h\x1b[?2004h", "the input modes after it");
    let mut phone = Phone::new(first);
    phone.term.vt_write(b"\x1b[?1049h");
    phone.apply(first);
    phone.term.vt_write(b"\x1b[?1h\x1b[?2004h");
    assert_eq!(phone.term.active_screen(), ghostty_vt::Screen::Alternate);
    assert_eq!(phone.text(), screen_text(&surface));

    // The program ends: its modes go, and the shell's screen comes back as a keyframe.
    surface.inject_output_for_test(b"\x1b[?2004l\x1b[?1l\x1b[?1049l$ ");
    let events = through_next_frame(&viewer);
    let outputs: Vec<u8> =
        events.iter().filter(|event| event["event"] == "output").flat_map(output_data).collect();
    assert_eq!(outputs, b"\x1b[?1l\x1b[?2004l\x1b[?1049l", "{events:?}");
    let back = events.last().unwrap();
    assert_eq!(back["base"], Value::Null, "the screen switched to, as a keyframe");
    phone.term.vt_write(&outputs);
    phone.apply(back);
    assert_eq!(phone.term.active_screen(), ghostty_vt::Screen::Primary);
    assert!(!phone.term.mode(2004, false) && !phone.term.mode(1, false));
    assert_eq!(phone.text(), screen_text(&surface));
    disconnect_client(&mux, viewer.client, false);
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

/// Old viewers on a new daemon (Leo, 2026-11-16: "prove it correct"). A viewer that declared
/// neither capability gets an agent CLI's terminal exactly as before the hybrid stream: the same
/// events, the same bytes, as a viewer of a terminal that runs no agent CLI. A viewer that
/// declared only `agent-cli-hybrid-v1` (a phone from before the lean form) gets v1
/// `agent-cli-frame` events with v1's fields, never `agent-cli-lean`.
#[test]
fn old_viewers_get_what_they_got_before() {
    let bytes = b"\x1b[38;5;174m\xe2\x9c\xbb\x1b[0m Claude Code \xe6\x97\xa5\xf0\x9f\x9a\x80\r\n> ";
    let more = b"\x1b[1mhello\x1b[0m world";
    let mut seen = Vec::new();
    for agent in [Some("claude"), None] {
        let name = if agent.is_some() { "hybrid-old-agent" } else { "hybrid-old-shell" };
        let (mux, surface) = terminal(name, agent);
        surface.inject_output_for_test(bytes);
        let viewer = viewer(&mux, false);
        viewer.attach(&mux, &surface, json!({}));
        let mut skipped = Vec::new();
        let state = viewer.next("vt-state", &mut skipped);
        surface.inject_output_for_test(more);
        let output = viewer.next("output", &mut skipped);
        skipped.retain(|event| event != "size-state");
        seen.push((skipped, state["data"].clone(), state["cols"].clone(), output["data"].clone()));
        disconnect_client(&mux, viewer.client, false);
    }
    assert_eq!(seen[0], seen[1], "a bytes viewer of Claude Code gets what a shell viewer gets");
    assert!(!seen[0].0.iter().any(|event| event.starts_with("agent-cli")), "{:?}", seen[0].0);

    let (mux, surface) = terminal("hybrid-old-v1", Some("claude"));
    surface.inject_output_for_test(bytes);
    let v1 = viewer(&mux, true);
    v1.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let first = v1.next("agent-cli-frame", &mut skipped);
    let mut phone = Phone::new(&first);
    phone.apply(&first);
    surface.inject_output_for_test(more);
    let next = v1.next("agent-cli-frame", &mut skipped);
    phone.apply(&next);
    assert_eq!(phone.text(), screen_text(&surface));
    let fields = [
        "base",
        "cols",
        "cursor_visible",
        "cursor_x",
        "cursor_y",
        "data",
        "event",
        "frame",
        "rows",
        "stream",
        "surface",
    ];
    for event in [&first, &next] {
        let mut keys: Vec<&str> = event.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, fields, "v1's fields: {event}");
    }
    assert!(
        !skipped.iter().any(|event| event == "agent-cli-lean" || event == "output"),
        "{skipped:?}"
    );
    disconnect_client(&mux, v1.client, false);
}

/// A terminal whose own program is a shell that prints nothing.
fn shell_terminal(name: &str) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        // `; :` keeps sh itself the terminal's program (no exec of the last command).
        command: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 600; :".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(name, options);
    let surface = mux.new_workspace(None, None).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let program = surface.process_id().and_then(crate::platform::process_executable);
        if program.as_deref().is_some_and(|program| program.ends_with("sh")) {
            break;
        }
        assert!(Instant::now() < deadline, "the shell did not start: {program:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
    (mux, surface)
}

const SHELL_LINES: &[&str] =
    &["agent-cli-hybrid-v1", "agent-cli-hybrid-v2", "terminal-shell-lines-v1"];

/// A phone drawing a shell viewer's stream: lean frames and, for a full-screen program, bytes.
struct LinesPhone {
    decoder: LeanDecoder,
    phone: Option<Phone>,
}

impl LinesPhone {
    fn apply(&mut self, event: &Value) {
        match event["event"].as_str() {
            Some("agent-cli-lean") => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(event["f"].as_str().unwrap())
                    .unwrap();
                let decoded = self.decoder.decode(&bytes).expect("a lean frame");
                let phone = self.phone.get_or_insert_with(|| {
                    Phone::new(&json!({"cols": decoded.cols, "rows": decoded.rows}))
                });
                let frame = vt::frame_bytes(&decoded.frame, phone.rows, decoded.cursor).unwrap();
                phone.term.vt_write(&frame);
            }
            Some("output") => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(event["data"].as_str().unwrap())
                    .unwrap();
                self.phone.as_mut().expect("a frame first").term.vt_write(&bytes);
            }
            other => panic!("not a shell viewer event: {other:?}"),
        }
    }

    fn text(&mut self) -> String {
        self.phone.as_mut().expect("a frame").text()
    }
}

/// The next `agent-cli-lean` or `output` event within 5 s.
fn next_drawn(viewer: &Viewer, skipped: &mut Vec<String>) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(message) = viewer.outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] == "agent-cli-lean" || value["event"] == "output" {
                return value;
            }
            skipped.push(value["event"].as_str().unwrap_or("").to_owned());
            continue;
        }
        assert!(Instant::now() < deadline, "no frame or output; got {skipped:?}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Events until the phone shows the terminal's screen, within 5 s; their names.
fn drain_until_same(viewer: &Viewer, phone: &mut LinesPhone, surface: &Surface) -> Vec<String> {
    let mut names = Vec::new();
    let mut skipped = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while phone.phone.is_none() || phone.text() != screen_text(surface) {
        assert!(Instant::now() < deadline, "the phone never matched: {names:?}");
        let event = next_drawn(viewer, &mut skipped);
        names.push(event["event"].as_str().unwrap_or("").to_owned());
        phone.apply(&event);
    }
    names
}

/// `terminal-shell-lines-v1`: a plain shell reaches the phone as lean frames (its lines and
/// cursor); a full-screen program it runs goes as PTY bytes from the byte that starts it,
/// and frames go on, with no keyframe, when it ends.
#[test]
fn a_shell_reaches_a_lines_viewer_as_frames_and_a_full_screen_program_as_bytes() {
    let (mux, surface) = shell_terminal("hybrid-shell");
    surface.inject_output_for_test(b"$ ls\r\nCargo.toml  src\r\n$ ");
    let viewer = declaring(&mux, SHELL_LINES);
    viewer.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let first = viewer.next("agent-cli-lean", &mut skipped);
    assert!(!skipped.iter().any(|event| event == "vt-state"), "no vt-state: {skipped:?}");
    let mut phone = LinesPhone { decoder: LeanDecoder::new(), phone: None };
    phone.apply(&first);
    assert_eq!(phone.text(), screen_text(&surface));

    surface.inject_output_for_test(b"git log\r\ncommit 1\r\n$ ");
    let lines = drain_until_same(&viewer, &mut phone, &surface);
    assert!(lines.iter().all(|event| event == "agent-cli-lean"), "lines as frames: {lines:?}");

    // A full-screen program: its bytes, from the mode set on.
    surface.inject_output_for_test(b"vim\r\n\x1b[?1049h\x1b[H\x1b[2J~ vim ~\x1b[?1000h");
    let full = drain_until_same(&viewer, &mut phone, &surface);
    assert_eq!(full.last().map(String::as_str), Some("output"), "{full:?}");
    surface.inject_output_for_test(b"\x1b[2;1Hedited");
    let typed = drain_until_same(&viewer, &mut phone, &surface);
    assert!(typed.iter().all(|event| event == "output"), "PTY bytes: {typed:?}");

    // It ends: frames again, on the screen the phone shows.
    surface.inject_output_for_test(b"\x1b[?1000l\x1b[?1049l");
    drain_until_same(&viewer, &mut phone, &surface);
    surface.inject_output_for_test(b"\r\n$ echo back\r\nback\r\n$ ");
    let back = drain_until_same(&viewer, &mut phone, &surface);
    assert!(back.iter().all(|event| event == "agent-cli-lean"), "frames again: {back:?}");
    disconnect_client(&mux, viewer.client, false);
}

/// A shell already running a full-screen program starts with `vt-state` and its bytes.
#[test]
fn a_full_screen_shell_attaches_with_its_bytes() {
    let (mux, surface) = shell_terminal("hybrid-shell-full");
    surface.inject_output_for_test(b"\x1b[?1049h\x1b[Htop");
    let viewer = declaring(&mux, SHELL_LINES);
    viewer.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    viewer.next("vt-state", &mut skipped);
    surface.inject_output_for_test(b"x");
    assert_eq!(viewer.next("output", &mut skipped)["data"], "eA==");
    assert!(!skipped.iter().any(|event| event == "agent-cli-lean"), "{skipped:?}");
    disconnect_client(&mux, viewer.client, false);
}

/// Every terminal is calculated, not only a shell's (Leo, 2026-11-17: "Surely we can just
/// calculate a f***ing terminal and resize whatever needs exceptions when it comes Fall back if
/// need be"): a program that is neither a shell nor an agent CLI reaches a lines viewer as lean
/// frames, and only its full-screen part falls back to PTY bytes.
#[test]
fn any_program_reaches_a_lines_viewer_as_frames_and_falls_back_only_when_full_screen() {
    // `exec sleep 600`: neither a shell nor an agent CLI.
    let (mux, surface) = terminal("hybrid-any-program", None);
    surface.inject_output_for_test(b"build: 1/3\r\nbuild: 2/3\r\n");
    let viewer = declaring(&mux, SHELL_LINES);
    viewer.attach(&mux, &surface, json!({}));
    let mut skipped = Vec::new();
    let first = viewer.next("agent-cli-lean", &mut skipped);
    assert!(!skipped.iter().any(|event| event == "vt-state"), "no vt-state: {skipped:?}");
    let mut phone = LinesPhone { decoder: LeanDecoder::new(), phone: None };
    phone.apply(&first);
    assert_eq!(phone.text(), screen_text(&surface));

    surface.inject_output_for_test(b"build: 3/3\r\ndone\r\n");
    let lines = drain_until_same(&viewer, &mut phone, &surface);
    assert!(lines.iter().all(|event| event == "agent-cli-lean"), "lines as frames: {lines:?}");

    surface.inject_output_for_test(b"\x1b[?1049h\x1b[H\x1b[2Jtop");
    let full = drain_until_same(&viewer, &mut phone, &surface);
    assert_eq!(full.last().map(String::as_str), Some("output"), "{full:?}");
    surface.inject_output_for_test(b"\x1b[?1049l");
    drain_until_same(&viewer, &mut phone, &surface);
    surface.inject_output_for_test(b"after\r\n");
    let back = drain_until_same(&viewer, &mut phone, &surface);
    assert!(back.iter().all(|event| event == "agent-cli-lean"), "frames again: {back:?}");
    disconnect_client(&mux, viewer.client, false);
}

/// `terminal-full-screen-frames-v1`: a full-screen program (a pager that asked for the mouse
/// and repaints its whole screen for each change) reaches the viewer as lean frames too; only
/// its modes go as bytes, and a repaint that moves the page one line costs a few cells, not the
/// screen. When it ends the frames go on.
#[test]
fn a_full_screen_program_reaches_a_full_screen_frames_viewer_as_frames() {
    let (mux, surface) = shell_terminal("hybrid-full-screen-frames");
    surface.inject_output_for_test(b"$ pager\r\n");
    let viewer = declaring(&mux, &[SHELL_LINES, &["terminal-full-screen-frames-v1"][..]].concat());
    viewer.attach(&mux, &surface, json!({}));
    let mut phone = LinesPhone { decoder: LeanDecoder::new(), phone: None };
    drain_until_same(&viewer, &mut phone, &surface);
    let page = |top: usize| {
        let mut out = String::from("\x1b[H");
        for line in top..top + 8 {
            out.push_str(&format!("{line:07} the quick brown fox, pager line\x1b[K\r\n"));
        }
        out.push_str(&format!("\x1b[7m PAGER {top} \x1b[0m\x1b[K"));
        out.into_bytes()
    };
    // Events until the phone shows the screen: their names and the bytes of their payloads.
    let until_same = |phone: &mut LinesPhone| {
        let (mut names, mut bytes, mut skipped) = (Vec::new(), Vec::new(), Vec::new());
        let deadline = Instant::now() + Duration::from_secs(5);
        while phone.text() != screen_text(&surface) {
            assert!(Instant::now() < deadline, "the phone never matched: {names:?}");
            let event = next_drawn(&viewer, &mut skipped);
            let payload = event["f"].as_str().or(event["data"].as_str()).unwrap_or("");
            bytes.push(base64::engine::general_purpose::STANDARD.decode(payload).unwrap());
            names.push(event["event"].as_str().unwrap_or("").to_owned());
            phone.apply(&event);
        }
        (names, bytes)
    };
    surface.inject_output_for_test(
        &[&b"\x1b[?1049h\x1b[?1000h\x1b[?1006h"[..], &page(0)[..]].concat(),
    );
    let (names, bytes) = until_same(&mut phone);
    assert_eq!(names.last().map(String::as_str), Some("agent-cli-lean"), "{names:?}");
    for (name, data) in names.iter().zip(&bytes) {
        if name == "output" {
            assert!(!data.windows(5).any(|w| w == b"quick"), "only modes as bytes: {data:?}");
        }
    }
    let shown = phone.phone.as_ref().unwrap();
    assert_eq!(shown.term.active_screen(), ghostty_vt::Screen::Alternate);
    assert!(shown.term.mode(1000, false) && shown.term.mode(1006, false), "the mouse modes");

    // A wheel step: the pager repaints its whole screen one line down.
    let repaint = page(1);
    surface.inject_output_for_test(&repaint);
    let (names, bytes) = until_same(&mut phone);
    assert!(names.iter().all(|name| name == "agent-cli-lean"), "frames: {names:?}");
    let sent: usize = bytes.iter().map(Vec::len).sum();
    assert!(sent * 2 < repaint.len(), "{sent} bytes for a {}-byte repaint", repaint.len());

    // It ends: the primary screen, and frames go on.
    surface.inject_output_for_test(b"\x1b[?1006l\x1b[?1000l\x1b[?1049l$ ");
    until_same(&mut phone);
    let shown = phone.phone.as_ref().unwrap();
    assert_eq!(shown.term.active_screen(), ghostty_vt::Screen::Primary);
    surface.inject_output_for_test(b"echo back\r\nback\r\n$ ");
    let (names, _) = until_same(&mut phone);
    assert!(names.iter().all(|name| name == "agent-cli-lean"), "frames again: {names:?}");
    disconnect_client(&mux, viewer.client, false);
}

/// A viewer that did not declare the lines keeps the bytes, for a shell and for any program.
#[test]
fn viewers_without_the_lines_keep_the_byte_stream() {
    let (mux, sleep) = terminal("hybrid-shell-other", None);
    let (shell_mux, shell) = shell_terminal("hybrid-shell-no-lines");
    for (mux, surface) in [(&mux, &sleep), (&shell_mux, &shell)] {
        let viewer = declaring(mux, &["agent-cli-hybrid-v1", "agent-cli-hybrid-v2"]);
        viewer.attach(mux, surface, json!({}));
        let mut skipped = Vec::new();
        viewer.next("vt-state", &mut skipped);
        surface.inject_output_for_test(b"plain");
        assert_eq!(viewer.next("output", &mut skipped)["data"], "cGxhaW4=");
        assert!(!skipped.iter().any(|event| event == "agent-cli-lean"), "{skipped:?}");
        disconnect_client(mux, viewer.client, false);
    }
}

/// The output events' bytes among the next events until `lean` frames stop for 300 ms.
fn output_bytes(viewer: &Viewer) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut quiet = Instant::now();
    while quiet.elapsed() < Duration::from_millis(300) {
        let Some(message) = viewer.outbound.try_pop() else {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        };
        quiet = Instant::now();
        let value: Value = serde_json::from_str(&message).expect("outbound JSON");
        if value["event"] == "output" {
            bytes.extend(
                base64::engine::general_purpose::STANDARD
                    .decode(value["data"].as_str().unwrap())
                    .unwrap(),
            );
        }
    }
    bytes
}

/// A lines viewer's keys and pastes follow the program's input modes (bracketed paste,
/// cursor keys), which frames do not carry: the modes the screen has when it attaches, and
/// each set and reset after, reach it as bytes, for a shell and for an agent CLI.
#[test]
fn a_lines_viewer_gets_the_input_modes_frames_do_not_carry() {
    let (mux, shell) = shell_terminal("hybrid-shell-modes");
    shell.inject_output_for_test(b"\x1b[?2004h$ ");
    let viewer = declaring(&mux, SHELL_LINES);
    viewer.attach(&mux, &shell, json!({}));
    let mut skipped = Vec::new();
    viewer.next("agent-cli-lean", &mut skipped);
    assert_eq!(output_bytes(&viewer), b"\x1b[?2004h", "the modes at attach");
    shell.inject_output_for_test(
        b"ls\r\n\x1b[?2004l\x1b[1;32mok\x1b[0m\r\n\x1b[?2004h\x1b[?1h\x1b=$ ",
    );
    assert_eq!(output_bytes(&viewer), b"\x1b[?2004l\x1b[?2004h\x1b[?1h\x1b=", "the modes after");
    disconnect_client(&mux, viewer.client, false);

    let (mux, claude) = terminal("hybrid-agent-modes", Some("claude"));
    let viewer = declaring(&mux, SHELL_LINES);
    viewer.attach(&mux, &claude, json!({}));
    viewer.next("agent-cli-lean", &mut skipped);
    claude.inject_output_for_test(b"\x1b[?2004h> ");
    assert_eq!(output_bytes(&viewer), b"\x1b[?2004h", "an agent's modes");
    disconnect_client(&mux, viewer.client, false);
}

#[path = "phone_link_bench_tests.rs"]
mod phone_link_bench;
