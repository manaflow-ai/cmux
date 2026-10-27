//! The real `cmux-vt-worker` binary, driven as the daemon drives it: a
//! socket at fd 3, BOOTSTRAP with the platform's compiled sandbox, then
//! holder ring segments and daemon-made pages. On macOS the worker parses
//! under its Seatbelt profile, so these tests also prove the profile leaves
//! the parse, the mappings and the socket working.

use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use cmux_holder::ring::Ring;
use cmux_process::{Child, Command, Stdio};
use cmux_vt_worker::sandbox::{self, SandboxMechanism};
use cmux_vt_worker::screen_page::{Modes, PageReader, Screen, create_page, page_len_for};
use cmux_vt_worker::wire::{
    Attach, Colors, Command as WorkerCommand, Event, FrameReader, Geometry, WIRE_VERSION,
    decode_event, send_command,
};
use ghostty_vt::{Callbacks, RenderState, Rgb, Terminal};

const GEOMETRY: Geometry = Geometry { cols: 40, rows: 8, cell_width: 8, cell_height: 16 };
const SCROLLBACK: u64 = 1 << 20;
const RING_CAPACITY: usize = 1 << 20;

struct Worker {
    child: Child,
    socket: UnixStream,
    reader: FrameReader,
}

impl Worker {
    fn spawn() -> Self {
        let (ours, theirs) = UnixStream::pair().expect("socketpair");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-vt-worker"));
        command.stdin(Stdio::null()).stdout(Stdio::null());
        command.inherit_fd(theirs.as_fd(), 3).expect("pass the socket");
        let child = command.spawn().expect("spawn the worker");
        drop(theirs);
        ours.set_read_timeout(Some(Duration::from_secs(30))).expect("timeout");
        Self { child, socket: ours, reader: FrameReader::default() }
    }

    /// Spawn and bootstrap with the policy the daemon would send.
    fn started() -> Self {
        let mut worker = Self::spawn();
        let policy = sandbox::compile_policy().expect("compile the worker sandbox");
        worker.send(&WorkerCommand::Bootstrap(policy));
        let expected = if cfg!(target_os = "macos") {
            SandboxMechanism::Seatbelt
        } else {
            SandboxMechanism::None
        };
        match worker.next_event() {
            Event::Hello { version, sandbox, pid } => {
                assert_eq!(version, WIRE_VERSION);
                assert_eq!(sandbox, expected);
                assert_eq!(pid, worker.child.id());
            }
            other => panic!("expected HELLO, got {other:?}"),
        }
        worker
    }

    fn send(&self, command: &WorkerCommand) {
        send_command(self.socket.as_raw_fd(), command).expect("send a command");
    }

    fn next_event(&mut self) -> Event {
        loop {
            if let Some(frame) = self.reader.next_frame().expect("frame") {
                return decode_event(frame).expect("event");
            }
            let read = self.reader.fill(self.socket.as_raw_fd()).expect("read an event");
            assert!(read > 0, "the worker closed its socket");
        }
    }

    /// Events until `id`'s PARSED reaches `offset`.
    fn parsed_to(&mut self, id: u64, offset: u64) -> Vec<Event> {
        let mut events = Vec::new();
        loop {
            let event = self.next_event();
            if let Event::AttachFailed { .. } = event {
                panic!("{event:?}");
            }
            let done = matches!(event, Event::Parsed { id: got, offset: at, .. } if got == id && at >= offset);
            events.push(event);
            if done {
                return events;
            }
        }
    }
}

struct Attached {
    ring: Ring,
    page: OwnedFd,
    page_len: usize,
}

fn attach(worker: &Worker, id: u64) -> Attached {
    let ring = Ring::new(0, RING_CAPACITY);
    let page_len = page_len_for(GEOMETRY.cols, GEOMETRY.rows);
    let page = create_page(page_len).expect("page");
    worker.send(&WorkerCommand::Attach(Attach {
        id,
        start: 0,
        ring: ring.segment().expect("a shared ring").try_clone().expect("dup ring"),
        ring_capacity: RING_CAPACITY as u64,
        page: page.try_clone().expect("dup page"),
        page_len: page_len as u64,
        scrollback: SCROLLBACK,
        geometry: GEOMETRY,
    }));
    Attached { ring, page, page_len }
}

/// The daemon's own parser fed the same bytes (cmux-tui-core surface/spawn.rs).
fn in_daemon(bytes: &[u8], colors: Option<&Colors>) -> (Screen, Terminal) {
    let mut terminal =
        Terminal::new(GEOMETRY.cols, GEOMETRY.rows, SCROLLBACK as usize, Callbacks::default())
            .expect("terminal");
    terminal.resize(GEOMETRY.cols, GEOMETRY.rows, 8, 16).expect("resize");
    if let Some(colors) = colors {
        terminal.replace_default_colors(colors.fg, colors.bg, colors.cursor);
        terminal.set_default_palette(&colors.palette);
        terminal.replace_default_cursor(colors.cursor_style, colors.cursor_blink);
    }
    terminal.vt_write(bytes);
    let mut render = RenderState::new().expect("render");
    render.update(&mut terminal).expect("update");
    let mut cells = Vec::new();
    render.walk_rows(|_, _, row| cells.push(row.to_vec())).expect("walk");
    let screen = Screen {
        parsed: bytes.len() as u64,
        frame: 0,
        cols: terminal.cols(),
        rows: terminal.rows(),
        cursor: render.cursor(),
        cursor_visual: render.cursor_visual().expect("cursor visual"),
        modes: Modes::of(&terminal),
        mouse_format: terminal.active_mouse_format(),
        cells,
    };
    (screen, terminal)
}

fn corpus() -> Vec<(&'static str, Vec<u8>)> {
    let mut long = Vec::new();
    for line in 0..200 {
        long.extend_from_slice(format!("line {line:03} {}\r\n", "=".repeat(line % 37)).as_bytes());
    }
    vec![
        ("plain and wrapped", b"hello world\r\nthis line is longer than forty columns so it wraps".to_vec()),
        (
            "sgr styles",
            b"\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[9mstrike\x1b[0m \x1b[7minv\x1b[0m \x1b[2mfaint\x1b[0m \x1b[5mblink\x1b[0m \x1b[8mhid\x1b[0m"
                .to_vec(),
        ),
        (
            "colors",
            b"\x1b[31mred\x1b[42mgreen-bg\x1b[0m \x1b[38;5;208m208\x1b[48;5;17mbg17\x1b[0m \x1b[38;2;10;200;30mtrue\x1b[48;2;1;2;3mbg\x1b[0m \x1b[91mbright"
                .to_vec(),
        ),
        ("wide and combining", "漢字 e\u{301} 👍🏽 a\u{200d}b ｗｉｄｅ".as_bytes().to_vec()),
        ("scrolling", long),
        (
            "cursor motion and erase",
            b"abcdefghij\x1b[5D\x1b[K\x1b[2;10Hxy\x1b[1;1H\x1b[2@\x1b[3P\x1b[3;3H\x1b[1J\x1b[4;1Htab\there\x1b[?25l".to_vec(),
        ),
        (
            "scroll region",
            b"\x1b[2;5r\x1b[2;1Ha\r\nb\r\nc\r\nd\r\ne\r\nf\x1b[r\x1b[8;1Hbottom".to_vec(),
        ),
        (
            "alternate screen and modes",
            b"primary\x1b[?1049h\x1b[H\x1b[2Jfull screen app\x1b[?1h\x1b=\x1b[?2004h\x1b[?1004h\x1b[?1006h\x1b[?1002h\x1b[5 q".to_vec(),
        ),
        (
            "split sequences and C1",
            b"\x1b[3".iter().chain(b"1mred\x1b]0;title\x07\xc2\x9b32mgreen\xe6\xbc").chain(b"\xa2").copied().collect(),
        ),
        ("garbage", (0u16..2048).map(|n| (n.wrapping_mul(7919) % 256) as u8).collect()),
    ]
}

#[test]
fn screen_pages_equal_the_in_daemon_parser_on_a_corpus() {
    let mut worker = Worker::started();
    for (index, (name, bytes)) in corpus().into_iter().enumerate() {
        let id = index as u64 + 1;
        let mut terminal = attach(&worker, id);
        // The holder publishes in pieces that cut sequences and characters.
        for piece in bytes.chunks(7) {
            terminal.ring.push(piece);
            worker.send(&WorkerCommand::Advance { id, end: terminal.ring.end() });
        }
        worker.parsed_to(id, bytes.len() as u64);
        let mut page = PageReader::open(&terminal.page, terminal.page_len).expect("reader");
        let mut got = page.read().expect("screen");
        let (expected, _) = in_daemon(&bytes, None);
        assert!(got.frame > 0, "{name}");
        got.frame = 0;
        assert_eq!(got, expected, "{name}");
        worker.send(&WorkerCommand::Detach { id });
    }
}

#[test]
fn colors_reach_the_worker_parser_as_the_daemon_sets_them() {
    let mut worker = Worker::started();
    let mut terminal = attach(&worker, 1);
    let mut colors = Colors {
        fg: Some(Rgb { r: 200, g: 201, b: 202 }),
        bg: Some(Rgb { r: 10, g: 11, b: 12 }),
        cursor: Some(Rgb { r: 1, g: 2, b: 3 }),
        cursor_style: Some(ghostty_vt::CursorShape::Bar),
        cursor_blink: Some(true),
        ..Colors::default()
    };
    colors.palette[1] = Some(Rgb { r: 250, g: 0, b: 128 });
    worker.send(&WorkerCommand::Colors { id: 1, colors: colors.clone() });
    let bytes = b"plain \x1b[31mpalette one\x1b[0m".to_vec();
    terminal.ring.push(&bytes);
    worker.send(&WorkerCommand::Advance { id: 1, end: terminal.ring.end() });
    worker.parsed_to(1, bytes.len() as u64);
    let mut got = PageReader::open(&terminal.page, terminal.page_len)
        .expect("reader")
        .read()
        .expect("screen");
    got.frame = 0;
    let (expected, _) = in_daemon(&bytes, Some(&colors));
    assert_eq!(got, expected);
    assert_eq!(got.cells[0][6].resolved_fg, Some(Rgb { r: 250, g: 0, b: 128 }));
}

#[test]
fn query_answers_come_back_as_events() {
    let mut worker = Worker::started();
    let mut terminal = attach(&worker, 1);
    let bytes = b"\x1b[c\x1b[5n\x1b]2;remote title\x07".to_vec();
    terminal.ring.push(&bytes);
    worker.send(&WorkerCommand::Advance { id: 1, end: terminal.ring.end() });
    let events = worker.parsed_to(1, bytes.len() as u64);
    let answer: Vec<u8> = events
        .iter()
        .filter_map(|event| match event {
            Event::PtyWrite { id: 1, bytes } => Some(bytes.clone()),
            _ => None,
        })
        .flatten()
        .collect();
    let answer = String::from_utf8(answer).expect("ascii answers");
    assert!(answer.starts_with("\x1b[?") && answer.ends_with("\x1b[0n"), "{answer:?}");
    assert!(events.contains(&Event::Title { id: 1, title: "remote title".to_owned() }));
}

#[test]
fn a_frame_before_bootstrap_ends_the_worker() {
    let mut worker = Worker::spawn();
    worker.send(&WorkerCommand::Advance { id: 1, end: 10 });
    let status = worker.child.wait_timeout(Duration::from_secs(30)).expect("wait").expect("exited");
    assert_eq!(status.code(), Some(3));
}

#[test]
fn the_worker_exits_cleanly_when_the_daemon_closes_the_socket() {
    let Worker { mut child, socket, .. } = Worker::started();
    drop(socket);
    let status = child.wait_timeout(Duration::from_secs(30)).expect("wait").expect("exited");
    assert!(status.success(), "{status:?}");
}
