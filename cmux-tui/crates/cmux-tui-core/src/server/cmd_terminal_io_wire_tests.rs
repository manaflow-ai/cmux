//! The lines the macOS app sends for its TerminalIO requests reach the daemon unchanged.
//! Spec/fixtures/terminal-io-requests/lines.json records them before their
//! migration to the generated `<Name>Request` types; TerminalIORequestWireGoldenTests
//! (CmuxNextDaemonTests) proves the app encodes exactly these lines. Here every line goes
//! through the server's own `Request` parse, and each `echo` line is handled against a
//! terminal whose PTY writes are recorded: the PTY gets exactly the input's bytes.
use super::super::*;
use std::sync::mpsc;

const FIXTURE: &str = include_str!("../../../../spec/fixtures/terminal-io-requests/lines.json");

fn fixture() -> Value {
    serde_json::from_str(FIXTURE).expect("spec/fixtures/terminal-io-requests/lines.json")
}

/// `(name, line)` of every entry of `section`.
fn entries(section: &str) -> Vec<(String, Value)> {
    fixture()[section]
        .as_array()
        .unwrap_or_else(|| panic!("no {section} in lines.json"))
        .iter()
        .map(|entry| (entry["name"].as_str().expect("name").to_owned(), entry["line"].clone()))
        .collect()
}

/// The line as the connection reads it: one JSON text through `line_parses::parse`.
fn parse(line: &Value) -> serde_json::Result<Request> {
    let text = line.to_string();
    crate::line_parses::parse::<Request>(&text)
}

/// The wire command a TerminalIO `Command` is, or `None` for any other.
fn terminal_io_command(command: &Command) -> Option<&'static str> {
    Some(match command {
        Command::Send(_) => "send",
        Command::SendKey { .. } => "send-key",
        Command::AttachSurface { .. } => "attach-surface",
        Command::ClearHistory { .. } => "clear-history",
        Command::TerminalClipboardSubscribe { .. } => "terminal-clipboard-subscribe",
        Command::TerminalClipboardReply { .. } => "terminal-clipboard-reply",
        Command::ReleaseAttachedViewSize { .. } => "release-attached-view-size",
        Command::SetSizeCounts { .. } => "set-size-counts",
        Command::DetachAttachedView { .. } => "detach-attached-view",
        Command::SetClientSizing { .. } => "set-client-sizing",
        Command::SetSizePolicy { .. } => "set-size-policy",
        Command::ReadScreen { .. } => "read-screen",
        Command::ReadScrollback { .. } => "read-scrollback",
        Command::ResizeSurface { .. } => "resize-surface",
        Command::ResizeAttachedView { .. } => "resize-attached-view",
        Command::SnapshotRequest(_) => "snapshot-request",
        _ => return None,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn every_recorded_line_parses_as_its_command() {
    let lines = [entries("requests"), entries("echo")].concat();
    assert!(lines.len() > 20, "lines.json has {} lines", lines.len());
    for (name, line) in lines {
        let request = parse(&line).unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(request.id, Some(json!(1)), "{name}");
        assert_eq!(terminal_io_command(&request.cmd), line["cmd"].as_str(), "{name}");
    }
}

/// Every field of the app's fullest `send` lands in the daemon's params as sent.
#[test]
fn a_full_send_line_fills_every_param() {
    let (_, line) = entries("requests")
        .into_iter()
        .find(|(name, _)| name == "send with every field")
        .expect("send with every field");
    let Command::Send(params) = parse(&line).unwrap().cmd else { panic!("not a send") };
    assert_eq!(params.surface, Some(7));
    assert_eq!(params.text.as_deref(), Some("yes"));
    assert_eq!(params.bytes.as_deref(), Some("YQ=="));
    assert!(params.paste);
    assert_eq!(params.expect_foreground.as_deref(), Some("/usr/local/bin/claude"));
    assert_eq!(params.flow, Some((4242 << 32) | 7));
    assert!(params.terminal_id.is_none() && params.expect_agent.is_none() && !params.submit);
}

struct PtyRecorder(mpsc::Sender<Vec<u8>>);

impl Write for PtyRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.send(bytes.to_vec()).map_err(std::io::Error::other)?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The echo test: each `echo` line, sent to a live terminal, writes exactly `pty_hex` (its
/// input's text, then its bytes) to the PTY: every byte value, control keys, invalid UTF-8,
/// multi-byte text and an unbracketed paste.
#[test]
fn every_echo_line_writes_its_input_bytes_to_the_pty() {
    let mux = Mux::new_for_test("terminal-io-echo", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (written, pty) = mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(PtyRecorder(written)));
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    for entry in fixture()["echo"].as_array().expect("echo") {
        let name = entry["name"].as_str().expect("name");
        let mut line = entry["line"].clone();
        line["surface"] = json!(surface.id);
        let request = parse(&line).unwrap_or_else(|error| panic!("{name}: {error}"));
        handle_command(&mux, client, request.cmd, &writer)
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        let bytes: Vec<u8> = pty.try_iter().flatten().collect();
        assert_eq!(hex(&bytes), entry["pty_hex"].as_str().expect("pty_hex"), "{name}");
    }
    mux.shutdown();
}
