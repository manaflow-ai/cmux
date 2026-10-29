use std::os::fd::OwnedFd;

use cmux_holder::ring::Ring;
use ghostty_vt::Callbacks;

use super::*;
use crate::screen_page::{PageReader, create_page, page_len_for};

const GEOMETRY: Geometry = Geometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };

struct Fixture {
    ring: Ring,
    capacity: u64,
    page: OwnedFd,
    page_len: usize,
}

fn fixture(capacity: usize) -> Fixture {
    let page_len = page_len_for(GEOMETRY.cols, GEOMETRY.rows);
    Fixture {
        ring: Ring::new(0, capacity),
        capacity: capacity as u64,
        page: create_page(page_len).expect("page"),
        page_len,
    }
}

fn attach(shard: &mut Shard, id: u64, fixture: &Fixture, events: &mut Vec<Event>) {
    let ring = fixture.ring.segment().expect("shared ring").try_clone().expect("dup ring");
    shard.attach(
        Attach {
            id,
            start: 0,
            ring,
            ring_capacity: fixture.capacity,
            page: fixture.page.try_clone().expect("dup page"),
            page_len: fixture.page_len as u64,
            scrollback: 100_000,
            geometry: GEOMETRY,
            kitty_limits: KittyGraphicsLimits::default(),
        },
        events,
    );
}

fn run(shard: &mut Shard, events: &mut Vec<Event>) {
    while shard.step(events) {}
}

fn reference(bytes: &[u8]) -> Vec<Vec<ghostty_vt::Cell>> {
    let mut terminal = Terminal::new(GEOMETRY.cols, GEOMETRY.rows, 100_000, Callbacks::default())
        .expect("terminal");
    terminal.resize(GEOMETRY.cols, GEOMETRY.rows, 8, 16).expect("resize");
    terminal.vt_write(bytes);
    let mut render = RenderState::new().expect("render");
    render.update(&mut terminal).expect("update");
    let mut rows = Vec::new();
    render.walk_rows(|_, _, cells| rows.push(cells.to_vec())).expect("walk");
    rows
}

#[test]
fn a_terminal_parses_its_ring_into_its_page() {
    let mut fixture = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    assert_eq!(events, [Event::Parsed { id: 1, offset: 0, frame: 1 }]);
    let bytes = b"hello \x1b[1;31mred\x1b[0m\r\nline two";
    fixture.ring.push(bytes);
    shard.advance(1, fixture.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    assert_eq!(events, [Event::Parsed { id: 1, offset: bytes.len() as u64, frame: 2 }]);
    let screen =
        PageReader::open(&fixture.page, fixture.page_len).expect("reader").read().expect("screen");
    assert_eq!(screen.cells, reference(bytes));
    assert_eq!(screen.parsed, bytes.len() as u64);
}

#[test]
fn answers_titles_bells_and_pwd_become_events() {
    let mut fixture = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    fixture.ring.push(b"\x1b[c\x1b]0;build\x07\x07\x07\x1b]7;file://host/tmp\x07\x1b[6n");
    shard.advance(1, fixture.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    let answer = events.iter().find_map(|event| match event {
        Event::PtyWrite { id: 1, bytes } => Some(bytes.clone()),
        _ => None,
    });
    let answer = String::from_utf8(answer.expect("DA and DSR answers")).expect("ascii");
    assert!(answer.starts_with("\x1b[?"), "{answer:?}");
    assert!(answer.ends_with("\x1b[1;1R"), "{answer:?}");
    assert!(events.contains(&Event::Title { id: 1, title: "build".to_owned() }));
    assert!(events.contains(&Event::Bell { id: 1, count: 2 }));
    assert!(
        events
            .iter()
            .any(|event| matches!(event, Event::Pwd { id: 1, pwd } if pwd.contains("/tmp")))
    );
}

#[test]
fn a_lapped_ring_cancels_and_continues_at_the_oldest_byte() {
    let mut fixture = fixture(4096);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    fixture.ring.push(&vec![b'x'; 10_000]);
    shard.advance(1, fixture.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    let oldest = fixture.ring.oldest();
    assert!(oldest > 0);
    assert_eq!(events[0], Event::Lapped { id: 1, from: 0, oldest });
    assert!(events.contains(&Event::Parsed { id: 1, offset: 10_000, frame: 3 }));
}

#[test]
fn slices_alternate_between_terminals() {
    let mut first = fixture(1 << 20);
    let mut second = fixture(1 << 20);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &first, &mut events);
    attach(&mut shard, 2, &second, &mut events);
    first.ring.push(&vec![b'a'; SLICE_BYTES * 3]);
    second.ring.push(&vec![b'b'; SLICE_BYTES * 3]);
    shard.advance(1, first.ring.end());
    shard.advance(2, second.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    let order: Vec<u64> = events
        .iter()
        .filter_map(|event| match event {
            Event::Parsed { id, .. } => Some(*id),
            _ => None,
        })
        .collect();
    assert_eq!(order, [1, 2, 1, 2, 1, 2]);
}

#[test]
fn a_bad_ring_or_a_duplicate_id_fails_the_attach() {
    let fixture = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    attach(&mut shard, 1, &fixture, &mut events);
    assert_eq!(
        events.last(),
        Some(&Event::AttachFailed { id: 1, reason: AttachFailure::Duplicate })
    );
    let page_len = page_len_for(GEOMETRY.cols, GEOMETRY.rows);
    shard.attach(
        Attach {
            id: 2,
            start: 0,
            // A page is not a ring.
            ring: create_page(page_len).expect("page"),
            ring_capacity: (page_len - crate::ring_view::RING_HEADER) as u64,
            page: create_page(page_len).expect("page"),
            page_len: page_len as u64,
            scrollback: 0,
            geometry: GEOMETRY,
            kitty_limits: KittyGraphicsLimits::default(),
        },
        &mut events,
    );
    assert_eq!(events.last(), Some(&Event::AttachFailed { id: 2, reason: AttachFailure::Ring }));
    assert_eq!(shard.len(), 1);
}

#[test]
fn a_resize_too_big_for_the_page_asks_for_a_bigger_one() {
    let fixture = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    events.clear();
    let big = Geometry { cols: 200, rows: 60, ..GEOMETRY };
    shard.resize(1, big, None, &mut events);
    assert!(matches!(events[0], Event::PageTooSmall { id: 1, .. }));
    let len = page_len_for(big.cols, big.rows);
    let page = create_page(len).expect("page");
    let reader_fd = page.try_clone().expect("dup");
    events.clear();
    shard.resize(1, big, Some((page, len as u64)), &mut events);
    assert!(matches!(events[0], Event::Parsed { id: 1, .. }));
    let screen = PageReader::open(&reader_fd, len).expect("reader").read().expect("screen");
    assert_eq!((screen.cols, screen.rows), (200, 60));
}

/// A file-medium Kitty command stops only its own terminal: the worker asks
/// the daemon for the read, parses nothing past the command until the
/// answer, and another terminal keeps parsing meanwhile.
#[test]
fn a_kitty_file_read_waits_for_the_daemon_and_pauses_only_its_terminal() {
    let mut first = fixture(1 << 16);
    let mut second = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &first, &mut events);
    attach(&mut shard, 2, &second, &mut events);
    // base64("/no/such/file.png"): the worker never opens it itself.
    let command = b"\x1b_Ga=T,f=100,i=4,t=f;L25vL3N1Y2gvZmlsZS5wbmc=\x1b\\";
    let mut bytes = b"before ".to_vec();
    bytes.extend_from_slice(command);
    bytes.extend_from_slice(b"after");
    first.ring.push(&bytes);
    second.ring.push(b"other terminal");
    shard.advance(1, first.ring.end());
    shard.advance(2, second.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    let at = (b"before ".len() + command.len()) as u64;
    let request = events.iter().find_map(|event| match event {
        Event::KittyMediaRequest { id: 1, request } => Some(request.clone()),
        _ => None,
    });
    let request = request.expect("a media request");
    assert_eq!(request.name, b"L25vL3N1Y2gvZmlsZS5wbmc=");
    assert!(events.contains(&Event::Parsed { id: 1, offset: at, frame: 2 }));
    assert!(events.contains(&Event::Parsed { id: 2, offset: 14, frame: 2 }));
    assert!(!shard.has_work(), "the waiting terminal takes no slice");

    events.clear();
    shard.kitty_media(1, Err(MediaRefusal::Forbidden), &mut events);
    run(&mut shard, &mut events);
    assert!(events.contains(&Event::Parsed { id: 1, offset: bytes.len() as u64, frame: 4 }));
    // The refused command reached the parser unchanged: ghostty-vt, with
    // file media off, answers it with an error, as the daemon's parser does.
    let answer: Vec<u8> = events
        .iter()
        .filter_map(|event| match event {
            Event::PtyWrite { id: 1, bytes } => Some(bytes.clone()),
            _ => None,
        })
        .flatten()
        .collect();
    assert!(answer.starts_with(b"\x1b_Gi=4;"), "{:?}", String::from_utf8_lossy(&answer));
    // A second answer nothing waits for changes nothing.
    events.clear();
    shard.kitty_media(1, Ok(vec![1, 2, 3]), &mut events);
    assert!(events.is_empty());
}

/// The daemon's output rewrites run before the worker's parser: a title
/// pop restores the pushed title, and a killed program's mouse mode ends
/// at the shell's next prompt.
#[test]
fn the_daemons_output_rewrites_run_before_the_parser() {
    let mut fixture = fixture(1 << 16);
    let mut shard = Shard::new();
    let mut events = Vec::new();
    attach(&mut shard, 1, &fixture, &mut events);
    fixture.ring.push(
        b"\x1b]2;shell\x07\x1b]133;C\x07\x1b[22;0t\x1b]2;vim\x07\x1b[?1000h\x1b[23;0t\x1b]133;D;137\x07\x1b]133;A\x07$ ",
    );
    shard.advance(1, fixture.ring.end());
    events.clear();
    run(&mut shard, &mut events);
    assert!(events.contains(&Event::Title { id: 1, title: "shell".to_owned() }));
    let screen =
        PageReader::open(&fixture.page, fixture.page_len).expect("reader").read().expect("screen");
    assert!(!screen.modes.contains(Modes::MOUSE_NORMAL));
    assert!(
        events.contains(&Event::ProgramStatus { id: 1, event: ProgramStatusEvent::PromptStart })
    );
}
