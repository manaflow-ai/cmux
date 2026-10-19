//! `terminal-binary-frames-v1` on a real headless daemon, read off its
//! socket: a viewer that negotiates binary frames receives exactly the bytes
//! a JSON viewer receives (no loss, reordering or duplication, NUL bytes
//! included), snapshot viewers keep their generation and offset contract and
//! the backlog resync, input frames reach the PTY and get the `send` reply,
//! and a connection that did not negotiate the capability keeps JSON lines.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use cmux_tui_core::binary_frames::{self as frames, Frame};
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-bf-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    /// `argv` in a new workspace; its surface.
    fn run(&self, argv: &[&str]) -> u64 {
        let mut control = Conn::open(&self.socket, false);
        let created = control.request(json!({
            "cmd": "run", "argv": argv, "new_workspace": true, "name": "frames",
        }));
        created["surface"].as_u64().expect("run returns the surface")
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Ok(mut control) = Conn::try_open(&self.socket) {
            let _ = control.send_line(&json!({"cmd": "shutdown-daemon", "end_terminals": true}));
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(25));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

enum Message {
    Json(Value),
    Frame(Frame),
}

/// One connection, read as the daemon writes it: JSON lines and binary frames.
struct Conn {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next_id: u64,
}

impl Conn {
    fn try_open(socket: &Path) -> std::io::Result<Self> {
        let stream = transport::connect(socket)?;
        stream.set_read_timeout(Some(test_timeout(Duration::from_secs(20))))?;
        let writer = stream.try_clone_box()?;
        Ok(Self { reader: BufReader::new(stream), writer, next_id: 100 })
    }

    /// Identified, with `terminal-binary-frames-v1` negotiated when `binary`.
    fn open(socket: &Path, binary: bool) -> Self {
        let mut conn = Self::try_open(socket).expect("connect");
        conn.request(json!({"cmd": "identify"}));
        let mut info = json!({"cmd": "set-client-info", "name": "binary-frames-test"});
        if binary {
            info["capabilities"] = json!([frames::BINARY_FRAMES_CAPABILITY]);
        }
        conn.request(info);
        conn
    }

    fn send_line(&mut self, value: &Value) -> std::io::Result<()> {
        writeln!(self.writer, "{value}")
    }

    fn next(&mut self) -> std::io::Result<Message> {
        let first = *self.reader.fill_buf()?.first().ok_or(ErrorKind::UnexpectedEof)?;
        if first == frames::MARKER {
            return frames::read_frame(&mut self.reader, 64 << 20).map(Message::Frame);
        }
        let mut line = String::new();
        self.reader.read_line(&mut line)?;
        Ok(Message::Json(serde_json::from_str(&line).expect("a JSON line")))
    }

    /// Sends `value` with a fresh id and returns its `data`; events and
    /// frames before the reply are dropped (callers attach after this).
    fn request(&mut self, mut value: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = json!(id);
        self.send_line(&value).unwrap();
        loop {
            if let Message::Json(reply) = self.next().unwrap()
                && reply["id"] == id
            {
                assert_eq!(reply["ok"], true, "{value} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }
}

/// Printable ASCII, NUL (the frame marker), line ends and multibyte UTF-8:
/// bytes the terminal publishes unchanged, so the stream ends with them.
fn payload(len: usize) -> Vec<u8> {
    let mut state = 0x2545_f491_4f6c_dd1d_u64;
    let pieces: [&[u8]; 6] =
        [b"\0", b"\r\n", "é".as_bytes(), "漢".as_bytes(), "🎉".as_bytes(), b"~"];
    let mut out = Vec::with_capacity(len + 8);
    while out.len() < len {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        match state % 16 {
            0..=5 => out.extend_from_slice(pieces[(state >> 8) as usize % pieces.len()]),
            _ => out.push(b' ' + ((state >> 16) % 94) as u8),
        }
    }
    out
}

/// A terminal that waits for one line, turns output processing off (raw:
/// no LF to CRLF) and prints `file`, then stays open. With `fifo` the line
/// comes from it and the terminal prints nothing but `file`; else it is
/// typed (and may be echoed).
fn cat_after_go(daemon: &Daemon, file: &Path, fifo: Option<&Path>) -> u64 {
    let script = match fifo {
        Some(fifo) => {
            let status = Command::new("/usr/bin/mkfifo").arg(fifo).status().unwrap();
            assert!(status.success(), "mkfifo");
            // `head -c 4096` is read live by the viewer before it pauses;
            // the second line releases the rest of the file.
            format!(
                "stty raw -echo; exec 3<'{fifo}'; read go <&3; head -c 4096 '{file}'; \
                 read go <&3; tail -c +4097 '{file}'; exec sleep 600",
                fifo = fifo.display(),
                file = file.display()
            )
        }
        None => format!("read go; stty raw -echo; cat '{}'; exec sleep 600", file.display()),
    };
    daemon.run(&["/bin/sh", "-c", &script])
}

/// What a viewer collected: every output byte in order, how they arrived.
#[derive(Default)]
struct Collected {
    bytes: Vec<u8>,
    json_outputs: usize,
    frame_outputs: usize,
}

impl Collected {
    fn add_output(&mut self, message: &Message, surface: u64) -> bool {
        match message {
            Message::Json(event) if event["event"] == "output" && event["surface"] == surface => {
                let data = event["data"].as_str().expect("output data");
                self.bytes.extend(base64::engine::general_purpose::STANDARD.decode(data).unwrap());
                self.json_outputs += 1;
                true
            }
            Message::Frame(frame) if frame.kind == frames::KIND_OUTPUT => {
                let output = frame.output().expect("an output frame");
                assert_eq!(output.surface, surface);
                self.bytes.extend_from_slice(output.data);
                self.frame_outputs += 1;
                true
            }
            _ => false,
        }
    }
}

/// Reads `conn` until its output ends with `tail`.
fn collect_until(conn: &mut Conn, surface: u64, tail: &[u8]) -> Collected {
    let mut collected = Collected::default();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    while !collected.bytes.ends_with(tail) {
        assert!(Instant::now() < deadline, "output never ended with the payload");
        let message = conn.next().expect("the viewer stream stays open");
        collected.add_output(&message, surface);
    }
    collected
}

#[test]
fn binary_viewer_gets_the_bytes_a_json_viewer_gets_and_input_frames_type() {
    let daemon = Daemon::start("replay");
    let file = daemon.dir.join("payload.bin");
    let data = payload(4 << 20);
    fs::write(&file, &data).unwrap();
    let surface = cat_after_go(&daemon, &file, None);

    let mut identify = Conn::open(&daemon.socket, false);
    let identity = identify.request(json!({"cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|cap| cap == frames::BINARY_FRAMES_CAPABILITY)),
        "identify lacks {}: {identity}",
        frames::BINARY_FRAMES_CAPABILITY
    );

    let mut json_viewer = Conn::open(&daemon.socket, false);
    json_viewer.request(json!({"cmd": "attach-surface", "surface": surface}));
    let mut binary_viewer = Conn::open(&daemon.socket, true);
    binary_viewer.request(json!({"cmd": "attach-surface", "surface": surface}));

    // The keystrokes travel as one input frame and get the `send` reply.
    binary_viewer.writer.write_all(&frames::encode_input(7, surface, false, b"go\n")).unwrap();

    // The binary viewer is read concurrently: neither may stall the other.
    let tail = data.clone();
    let binary = std::thread::spawn(move || {
        let mut collected = Collected::default();
        let mut replied = false;
        let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
        while !(replied && collected.bytes.ends_with(&tail)) {
            assert!(Instant::now() < deadline, "binary viewer never got the payload");
            let message = binary_viewer.next().expect("the binary viewer stays open");
            if let Message::Json(reply) = &message
                && reply["id"] == 7
            {
                assert_eq!(reply["ok"], true, "input frame reply: {reply}");
                replied = true;
            }
            collected.add_output(&message, surface);
        }
        collected
    });
    let json = collect_until(&mut json_viewer, surface, &data);
    let binary = binary.join().unwrap();

    assert_eq!(json.frame_outputs, 0, "a viewer without the capability gets no frames");
    assert!(json.json_outputs > 0);
    assert_eq!(binary.json_outputs, 0, "plain output reaches a binary viewer as frames only");
    assert!(binary.frame_outputs > 0);
    assert!(binary.bytes == json.bytes, "both viewers hold the same bytes in the same order");
}

#[test]
fn binary_snapshot_viewer_keeps_positions_and_resyncs_after_a_backlog() {
    let daemon = Daemon::start("snapshot");
    let file = daemon.dir.join("payload.bin");
    let data = payload(6 << 20);
    fs::write(&file, &data).unwrap();
    let fifo = daemon.dir.join("go.fifo");
    let surface = cat_after_go(&daemon, &file, Some(&fifo));

    let mut viewer = Conn::open(&daemon.socket, true);
    viewer
        .send_line(&json!({
            "id": 1, "cmd": "attach-surface", "surface": surface,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            // The smallest backlog, so a paused viewer falls behind quickly.
            "viewer_backlog_bytes": 65536,
        }))
        .unwrap();

    // The READY goes ahead of the reply as one event frame.
    let ready = |frame: &Frame| -> Option<(u64, u64)> {
        let (header, data) = frame.event_data().ok()?;
        let header: Value = serde_json::from_slice(header).expect("event JSON");
        assert!(header.get("data").is_none(), "data travels beside the JSON: {header}");
        (header["event"] == "snapshot" && header["phase"] == "ready").then(|| {
            assert!(!data.is_empty(), "a READY carries its GHOSTSNP prefix");
            (header["generation"].as_u64().unwrap(), header["offset"].as_u64().unwrap())
        })
    };
    let (mut generation, mut offset) = match viewer.next().unwrap() {
        Message::Frame(frame) => ready(&frame).expect("the first message is the READY"),
        Message::Json(event) => panic!("the READY reached a binary viewer as JSON: {event}"),
    };
    let mut readies = 1;
    let mut history_chunks = 0;
    let mut replied = false;
    let mut checked_bytes = 0u64;
    let mut go = 0;
    let mut fifo_writer = None;
    let deadline = Instant::now() + test_timeout(Duration::from_secs(90));
    // Done when the host's whole payload was seen as positioned output and
    // the viewer's position is the host's.
    while offset < data.len() as u64 || !replied || go < 2 {
        assert!(Instant::now() < deadline, "the snapshot viewer never caught up");
        if replied && go == 0 {
            // Opening the fifo waits for the shell's open; one writer for both lines.
            let mut writer = fs::OpenOptions::new().write(true).open(&fifo).unwrap();
            writer.write_all(b"go\n").unwrap();
            fifo_writer = Some(writer);
            go = 1;
        }
        if go == 1 && checked_bytes >= 4096 {
            fifo_writer.as_mut().unwrap().write_all(b"go\n").unwrap();
            go = 2;
            // Fall behind: the backlog fills while nothing is read.
            std::thread::sleep(Duration::from_millis(1500));
        }
        match viewer.next().expect("the snapshot stream stays open") {
            Message::Json(event) if event["id"] == 1 => {
                assert_eq!(event["ok"], true, "{event}");
                replied = true;
            }
            Message::Json(event) => {
                assert_ne!(event["event"], "output", "output reached a binary viewer as JSON");
                assert_ne!(event["event"], "overflow", "a slow viewer is never dropped");
            }
            Message::Frame(frame) if frame.kind == frames::KIND_OUTPUT => {
                let output = frame.output().unwrap();
                let (at_generation, at_offset) =
                    output.position.expect("snapshot output carries its position");
                assert_eq!(at_generation, generation, "output at the last READY's generation");
                offset += output.data.len() as u64;
                assert_eq!(at_offset, offset, "offsets are contiguous after the last READY");
                checked_bytes += output.data.len() as u64;
            }
            Message::Frame(frame) => {
                if let Some(position) = ready(&frame) {
                    assert!(position.1 >= offset, "a READY never moves the viewer back");
                    (generation, offset) = position;
                    readies += 1;
                    continue;
                }
                let (header, chunk) = frame.event_data().expect("an event frame");
                let header: Value = serde_json::from_slice(header).unwrap();
                assert_eq!(header["event"], "snapshot", "{header}");
                if header["phase"] == "history" {
                    assert_eq!(header["compression"], "deflate");
                    assert!(!chunk.is_empty() && header["raw_bytes"].as_u64() > Some(0));
                    history_chunks += 1;
                }
            }
        }
    }
    assert_eq!(offset, data.len() as u64, "the viewer's position is the host's, byte for byte");
    assert!(readies >= 2, "a paused viewer is resynced with a fresh READY, not dropped");
    assert!(history_chunks >= 1, "the resync READY is followed by its history");
    assert!(checked_bytes >= 4096, "positioned output reached the viewer");
}

#[test]
fn a_connection_without_the_capability_keeps_json_and_cannot_send_frames() {
    let daemon = Daemon::start("plain");
    let surface = daemon.run(&["/bin/sh", "-c", "read line; echo \"got:$line\"; exec sleep 600"]);

    // Without negotiation an input frame is not a request: the connection
    // ends and nothing reaches the terminal.
    let mut sender = Conn::open(&daemon.socket, false);
    sender.writer.write_all(&frames::encode_input(9, surface, false, b"frame\n")).unwrap();
    let mut rest = Vec::new();
    let read = sender.reader.read_to_end(&mut rest);
    assert!(read.is_ok() && rest.is_empty(), "the daemon closed the connection: {read:?}");

    // A viewer that did not negotiate keeps the JSON stream.
    let mut viewer = Conn::open(&daemon.socket, false);
    viewer.request(json!({"cmd": "attach-surface", "surface": surface}));
    viewer.request(json!({"cmd": "send", "surface": surface, "text": "json\n"}));
    let collected = collect_until(&mut viewer, surface, b"got:json\r\n");
    assert_eq!(collected.frame_outputs, 0);
    assert!(collected.json_outputs > 0);
    assert!(
        !String::from_utf8_lossy(&collected.bytes).contains("got:frame"),
        "the refused frame's bytes never reached the terminal"
    );
}
