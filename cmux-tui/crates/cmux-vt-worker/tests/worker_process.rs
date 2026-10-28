//! The real `cmux-vt-worker` binary, driven as the daemon drives it: a
//! socket at fd 3, BOOTSTRAP with the platform's compiled sandbox, then
//! holder ring segments and daemon-made pages, and the Kitty file reads the
//! worker asks for answered as the daemon answers them. On macOS the worker
//! parses under its Seatbelt profile, so these tests also prove the profile
//! leaves the parse, the mappings and the socket working.
//!
//! The oracle is the daemon's own output path (surface/local_output.rs):
//! the Kitty file media rewrite, then `cmux_vt_stream::write_output` (title
//! stack, OSC 1, mode resets at prompt marks) into a parser set up as
//! surface/spawn.rs sets it up (Kitty limits, an OSC 7501 owner).

use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_holder::ring::Ring;
use cmux_kitty_media::KittyMediaRewriter;
use cmux_process::{Child, Command, Stdio};
use cmux_vt_stream::ShellMarks;
use cmux_vt_worker::sandbox::{self, SandboxMechanism};
use cmux_vt_worker::screen_page::{Modes, PageReader, Screen, create_page, page_len_for};
use cmux_vt_worker::wire::{
    Attach, Colors, Command as WorkerCommand, Event, FrameReader, Geometry, MediaAnswer,
    WIRE_VERSION, decode_event, send_command,
};
use ghostty_vt::{Callbacks, KittyGraphicsLimits, ProgramStatusEvent, RenderState, Rgb, Terminal};

const GEOMETRY: Geometry = Geometry { cols: 40, rows: 8, cell_width: 8, cell_height: 16 };
const SCROLLBACK: u64 = 1 << 20;
const RING_CAPACITY: usize = 1 << 20;

struct Worker {
    child: Child,
    socket: UnixStream,
    reader: FrameReader,
}

/// What a terminal's parse produced besides its page.
#[derive(Debug, Default, PartialEq, Eq)]
struct Effects {
    /// Every PTY answer, in order.
    answers: Vec<u8>,
    /// The title after the parse ("" for none).
    title: String,
    /// OSC 7501 reports and prompt starts, in order.
    statuses: Vec<ProgramStatusEvent>,
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

    /// Events until `id`'s PARSED reaches `offset`, answering each Kitty
    /// file read as the daemon does (it may open files; the worker not).
    fn parsed_to(&mut self, id: u64, offset: u64) -> Vec<Event> {
        let mut events = Vec::new();
        loop {
            let event = self.next_event();
            match &event {
                Event::AttachFailed { .. } => panic!("{event:?}"),
                Event::KittyMediaRequest { id, request } => {
                    let answer = MediaAnswer::read(request).expect("a media segment");
                    self.send(&WorkerCommand::KittyMedia { id: *id, answer });
                }
                _ => {}
            }
            let done = matches!(event, Event::Parsed { id: got, offset: at, .. } if got == id && at >= offset);
            events.push(event);
            if done {
                return events;
            }
        }
    }
}

/// The answers, last title and status events of `id` in `events`.
fn effects_of(id: u64, events: &[Event]) -> Effects {
    let mut effects = Effects::default();
    for event in events {
        match event {
            Event::PtyWrite { id: got, bytes } if *got == id => {
                effects.answers.extend_from_slice(bytes);
            }
            Event::Title { id: got, title } if *got == id => effects.title = title.clone(),
            Event::ProgramStatus { id: got, event } if *got == id => {
                effects.statuses.push(event.clone());
            }
            _ => {}
        }
    }
    effects
}

struct Attached {
    ring: Ring,
    page: OwnedFd,
    page_len: usize,
}

fn attach(worker: &Worker, id: u64, kitty_limits: KittyGraphicsLimits) -> Attached {
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
        kitty_limits,
    }));
    Attached { ring, page, page_len }
}

/// Push `bytes` into `id`'s ring (in `piece`-byte publishes) and read the
/// page once the worker parsed them all.
fn parse_in_worker(
    worker: &mut Worker,
    id: u64,
    terminal: &mut Attached,
    bytes: &[u8],
    piece: usize,
) -> (Screen, Effects) {
    for chunk in bytes.chunks(piece) {
        terminal.ring.push(chunk);
        worker.send(&WorkerCommand::Advance { id, end: terminal.ring.end() });
    }
    let events = worker.parsed_to(id, bytes.len() as u64);
    let mut screen = PageReader::open(&terminal.page, terminal.page_len)
        .expect("reader")
        .read()
        .expect("screen");
    assert!(screen.frame > 0);
    screen.frame = 0;
    (screen, effects_of(id, &events))
}

/// The daemon's own parser and output path fed the same bytes
/// (surface/spawn.rs, surface/local_output.rs).
fn in_daemon(
    bytes: &[u8],
    colors: Option<&Colors>,
    kitty_limits: KittyGraphicsLimits,
) -> (Screen, Effects) {
    let answers = Arc::new(Mutex::new(Vec::new()));
    let statuses = Arc::new(Mutex::new(Vec::new()));
    let callbacks = Callbacks {
        on_pty_write: Some(Box::new({
            let answers = answers.clone();
            move |bytes| answers.lock().expect("answers").extend_from_slice(bytes)
        })),
        on_program_status: Some(Box::new({
            let statuses = statuses.clone();
            move |event| statuses.lock().expect("statuses").push(event)
        })),
        ..Callbacks::default()
    };
    let mut terminal = Terminal::new(GEOMETRY.cols, GEOMETRY.rows, SCROLLBACK as usize, callbacks)
        .expect("terminal");
    terminal.resize(GEOMETRY.cols, GEOMETRY.rows, 8, 16).expect("resize");
    terminal.set_kitty_graphics_limits(kitty_limits).expect("kitty limits");
    if let Some(colors) = colors {
        terminal.replace_default_colors(colors.fg, colors.bg, colors.cursor);
        terminal.set_default_palette(&colors.palette);
        terminal.replace_default_cursor(colors.cursor_style, colors.cursor_blink);
    }
    let mut rewritten = Vec::new();
    KittyMediaRewriter::new().rewrite(bytes, &mut rewritten);
    let _ = cmux_vt_stream::write_output(&mut terminal, &rewritten, &mut ShellMarks::default());
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
    let effects = Effects {
        answers: answers.lock().expect("answers").clone(),
        title: terminal.title().unwrap_or_default(),
        statuses: statuses.lock().expect("statuses").clone(),
    };
    (screen, effects)
}

/// 2x2 RGB pixels as a direct Kitty transmission with image id `id`.
fn kitty_image(id: u32) -> Vec<u8> {
    format!("\x1b_Ga=T,f=24,s=2,v=2,i={id};/wAAAP8AAAD///8A\x1b\\").into_bytes()
}

/// A regular file of 2x2 RGB pixels for a `t=f` transmission; removed on
/// drop.
struct ImageFile(std::path::PathBuf);

impl ImageFile {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-vt-worker-corpus-{}-{:?}.rgb",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::write(&path, [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]).expect("image file");
        Self(std::fs::canonicalize(path).expect("canonical image path"))
    }

    fn command(&self, id: u32) -> Vec<u8> {
        let path = self.0.to_str().expect("UTF-8 temp path");
        format!("\x1b_Ga=T,f=24,s=2,v=2,t=f,i={id};{}\x1b\\", base64(path.as_bytes())).into_bytes()
    }
}

impl Drop for ImageFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let word = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(char::from(ALPHABET[(word >> (18 - 6 * index) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// A corpus case: its name, its bytes and the publish size (marks are
/// found per parsed chunk, by the daemon too, so cases with marks are
/// published whole).
struct Case {
    name: &'static str,
    bytes: Vec<u8>,
    piece: usize,
}

fn case(name: &'static str, bytes: Vec<u8>) -> Case {
    Case { name, bytes, piece: 7 }
}

fn whole(name: &'static str, bytes: Vec<u8>) -> Case {
    let piece = bytes.len();
    Case { name, bytes, piece }
}

fn corpus(image: &ImageFile) -> Vec<Case> {
    let mut long = Vec::new();
    for line in 0..200 {
        long.extend_from_slice(format!("line {line:03} {}\r\n", "=".repeat(line % 37)).as_bytes());
    }
    let mut kitty_file = b"file image: ".to_vec();
    kitty_file.extend(image.command(31));
    kitty_file.extend_from_slice(b" and a missing one: ");
    kitty_file.extend(
        format!("\x1b_Ga=T,f=24,s=2,v=2,t=f,i=32;{}\x1b\\", base64(b"/no/such/image.rgb"))
            .into_bytes(),
    );
    kitty_file.extend_from_slice(b" done");
    let mut kitty_direct = b"direct image: ".to_vec();
    kitty_direct.extend(kitty_image(30));
    kitty_direct.extend_from_slice(b" text after");
    vec![
        case("plain and wrapped", b"hello world\r\nthis line is longer than forty columns so it wraps".to_vec()),
        case(
            "sgr styles",
            b"\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[9mstrike\x1b[0m \x1b[7minv\x1b[0m \x1b[2mfaint\x1b[0m \x1b[5mblink\x1b[0m \x1b[8mhid\x1b[0m"
                .to_vec(),
        ),
        case(
            "colors",
            b"\x1b[31mred\x1b[42mgreen-bg\x1b[0m \x1b[38;5;208m208\x1b[48;5;17mbg17\x1b[0m \x1b[38;2;10;200;30mtrue\x1b[48;2;1;2;3mbg\x1b[0m \x1b[91mbright"
                .to_vec(),
        ),
        case("wide and combining", "漢字 e\u{301} 👍🏽 a\u{200d}b ｗｉｄｅ".as_bytes().to_vec()),
        case("scrolling", long),
        case(
            "cursor motion and erase",
            b"abcdefghij\x1b[5D\x1b[K\x1b[2;10Hxy\x1b[1;1H\x1b[2@\x1b[3P\x1b[3;3H\x1b[1J\x1b[4;1Htab\there\x1b[?25l".to_vec(),
        ),
        case(
            "scroll region",
            b"\x1b[2;5r\x1b[2;1Ha\r\nb\r\nc\r\nd\r\ne\r\nf\x1b[r\x1b[8;1Hbottom".to_vec(),
        ),
        case(
            "alternate screen and modes",
            b"primary\x1b[?1049h\x1b[H\x1b[2Jfull screen app\x1b[?1h\x1b=\x1b[?2004h\x1b[?1004h\x1b[?1006h\x1b[?1002h\x1b[5 q".to_vec(),
        ),
        case(
            "split sequences and C1",
            b"\x1b[3".iter().chain(b"1mred\x1b]0;title\x07\xc2\x9b32mgreen\xe6\xbc").chain(b"\xa2").copied().collect(),
        ),
        case("garbage", (0u16..2048).map(|n| (n.wrapping_mul(7919) % 256) as u8).collect()),
        // A program killed mid-run (mouse 1000 + SGR, bracketed paste,
        // application cursor keys, hidden cursor, alternate screen): the
        // daemon resets its keyboard modes at 133;D and the rest at 133;A.
        whole(
            "mode resets at prompt marks",
            b"\x1b]133;A\x07$ app\r\n\x1b]133;C\x07\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1h\x1b[?25l\x1b[?1049hfull screen\x1b]133;D;137\x07\x1b]133;A\x07$ "
                .to_vec(),
        ),
        // A mark the program prints itself, after 133;C, keeps its modes.
        whole(
            "a program's own prompt mark keeps its modes",
            b"\x1b]133;C\x07\x1b[?1000h\x1b[?2004h\x1b]133;A\x07inner prompt".to_vec(),
        ),
        // OSC 1 before any OSC 2, then xterm's title stack.
        whole(
            "osc 1 and the title stack",
            b"\x1b]1;icon first\x07\x1b[22;0t\x1b]2;vim notes.md\x07\x1b[22t\x1b]0;inner\x1b\\\x1b[23;0t".to_vec(),
        ),
        whole("kitty direct transmission", kitty_direct),
        whole("kitty file transmission", kitty_file),
        // The OSC 7501 support query and reports, then a prompt start.
        whole(
            "program status",
            b"\x1b]7501;?\x1b\\\x1b]7501;state=working:progress=40:app=Y2FyZ28=\x1b\\\x1b]7501;state=blocked:kind=permission:id=a/b\x07\x1b]133;A\x07$ "
                .to_vec(),
        ),
    ]
}

#[test]
fn screen_pages_equal_the_in_daemon_parser_on_a_corpus() {
    let image = ImageFile::new();
    let mut worker = Worker::started();
    let limits = KittyGraphicsLimits::default();
    for (index, Case { name, bytes, piece }) in corpus(&image).into_iter().enumerate() {
        let id = index as u64 + 1;
        let mut terminal = attach(&worker, id, limits);
        let (got, effects) = parse_in_worker(&mut worker, id, &mut terminal, &bytes, piece);
        let (expected, expected_effects) = in_daemon(&bytes, None, limits);
        assert_eq!(got, expected, "{name}");
        assert_eq!(effects, expected_effects, "{name}");
        worker.send(&WorkerCommand::Detach { id });
    }
}

/// The cases the corpus adds for the daemon's output path each change the
/// outcome, so their equality above is not equality by accident.
#[test]
fn the_corpus_cases_exercise_the_daemons_output_path() {
    let image = ImageFile::new();
    let cases = corpus(&image);
    let find = |name: &str| {
        let case = cases.iter().find(|case| case.name == name).expect("case");
        in_daemon(&case.bytes, None, KittyGraphicsLimits::default())
    };
    let (marks, _) = find("mode resets at prompt marks");
    for mode in [Modes::MOUSE_NORMAL, Modes::BRACKETED_PASTE, Modes::CURSOR_KEYS, Modes::ALT_SCREEN]
    {
        assert!(!marks.modes.contains(mode), "mode {mode:#x} reset");
    }
    assert!(marks.modes.contains(Modes::CURSOR_VISIBLE));
    let (own_mark, _) = find("a program's own prompt mark keeps its modes");
    assert!(own_mark.modes.contains(Modes::MOUSE_NORMAL));
    let (_, titles) = find("osc 1 and the title stack");
    // The pop restores the second push; libghostty-vt alone keeps "inner".
    assert_eq!(titles.title, "vim notes.md");
    let (_, icon) = in_daemon(b"\x1b]1;icon first\x07", None, KittyGraphicsLimits::default());
    assert_eq!(icon.title, "icon first", "OSC 1 before any OSC 2 names the terminal");
    let (_, file) = find("kitty file transmission");
    let answers = String::from_utf8_lossy(&file.answers).into_owned();
    assert!(answers.contains("i=31;OK"), "the file image loads: {answers:?}");
    assert!(answers.contains("i=32;E"), "the missing file is refused: {answers:?}");
    let (_, status) = find("program status");
    assert!(status.answers.starts_with(b"\x1b]7501;"), "{:?}", status.answers);
    assert_eq!(status.statuses.len(), 3, "{:?}", status.statuses);
    assert_eq!(status.statuses[2], ProgramStatusEvent::PromptStart);
}

/// The worker's parser takes the terminal's Kitty budget, at attach and
/// when it changes: an image over it is refused with the daemon's answer.
#[test]
fn kitty_limits_refuse_an_image_as_the_daemon_does() {
    let mut worker = Worker::started();
    let small = KittyGraphicsLimits { image_bytes: 8, ..KittyGraphicsLimits::default() };
    let image = kitty_image(5);
    let mut terminal = attach(&worker, 1, small);
    let (_, effects) = parse_in_worker(&mut worker, 1, &mut terminal, &image, image.len());
    let (_, expected) = in_daemon(&image, None, small);
    let (_, unlimited) = in_daemon(&image, None, KittyGraphicsLimits::default());
    assert_eq!(effects.answers, expected.answers);
    assert_ne!(expected.answers, unlimited.answers, "the budget changes the answer");

    // A budget that changes later, as host_kitty_limits.rs changes it.
    let mut terminal = attach(&worker, 2, KittyGraphicsLimits::default());
    worker.send(&WorkerCommand::KittyLimits { id: 2, limits: KittyGraphicsLimits::disabled() });
    let (_, effects) = parse_in_worker(&mut worker, 2, &mut terminal, &image, image.len());
    let (_, expected) = in_daemon(&image, None, KittyGraphicsLimits::disabled());
    assert_eq!(effects.answers, expected.answers);
    assert_ne!(expected.answers, unlimited.answers);
}

/// The OSC 7501 support query gets the same answer from the worker as from
/// the daemon's parser, and reports reach the daemon as events.
#[test]
fn the_program_status_support_query_gets_the_daemons_answer() {
    let mut worker = Worker::started();
    let mut terminal = attach(&worker, 1, KittyGraphicsLimits::default());
    let bytes = b"\x1b]7501;?\x1b\\\x1b]7501;state=done:id=build\x1b\\".to_vec();
    let (_, effects) = parse_in_worker(&mut worker, 1, &mut terminal, &bytes, bytes.len());
    let (_, expected) = in_daemon(&bytes, None, KittyGraphicsLimits::default());
    assert!(!expected.answers.is_empty(), "the daemon's parser answers the query");
    assert_eq!(effects.answers, expected.answers);
    assert_eq!(effects.statuses, expected.statuses);
    assert_eq!(effects.statuses.len(), 1);
}

#[test]
fn colors_reach_the_worker_parser_as_the_daemon_sets_them() {
    let mut worker = Worker::started();
    let mut terminal = attach(&worker, 1, KittyGraphicsLimits::default());
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
    let (got, _) = parse_in_worker(&mut worker, 1, &mut terminal, &bytes, bytes.len());
    let (expected, _) = in_daemon(&bytes, Some(&colors), KittyGraphicsLimits::default());
    assert_eq!(got, expected);
    assert_eq!(got.cells[0][6].resolved_fg, Some(Rgb { r: 250, g: 0, b: 128 }));
}

#[test]
fn query_answers_come_back_as_events() {
    let mut worker = Worker::started();
    let mut terminal = attach(&worker, 1, KittyGraphicsLimits::default());
    let bytes = b"\x1b[c\x1b[5n\x1b]2;remote title\x07".to_vec();
    let (_, effects) = parse_in_worker(&mut worker, 1, &mut terminal, &bytes, bytes.len());
    let answer = String::from_utf8(effects.answers).expect("ascii answers");
    assert!(answer.starts_with("\x1b[?") && answer.ends_with("\x1b[0n"), "{answer:?}");
    assert_eq!(effects.title, "remote title");
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
