//! Cold-scrollback codec: `Terminal::into_cold` and
//! `ColdTerminal::thaw` restore the terminal exactly, or refuse and hand it
//! back unchanged. "Exactly" is checked two ways: the thawed terminal reads
//! the same as before (snapshots, VT replay, text, markers, Kitty scene), and
//! after the same further input it still matches a control terminal that
//! never went cold.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use ghostty_vt::{
    Callbacks, ColdPagesError, KittyGraphicsSnapshot, Rgb, Scrollbar, SnapshotPhase, Terminal,
};

const CELL_PX: (u32, u32) = (8, 17);
const SCROLLBACK_BYTES: usize = 10_000_000;

struct Probe {
    term: Terminal,
    written: Arc<Mutex<Vec<u8>>>,
    titles: Arc<AtomicUsize>,
}

impl Probe {
    fn new(cols: u16, rows: u16, scrollback: usize) -> Self {
        let written = Arc::new(Mutex::new(Vec::new()));
        let titles = Arc::new(AtomicUsize::new(0));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let written = written.clone();
                move |bytes: &[u8]| written.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let titles = titles.clone();
                move || {
                    titles.fetch_add(1, Ordering::Relaxed);
                }
            })),
            on_clipboard_read: Some(Box::new(|_| {})),
            ..Callbacks::default()
        };
        let mut term = Terminal::new(cols, rows, scrollback, callbacks).unwrap();
        term.set_default_colors(
            Some(Rgb { r: 0xff, g: 0xff, b: 0xff }),
            Some(Rgb { r: 0x28, g: 0x2c, b: 0x34 }),
            None,
        );
        term.resize(cols, rows, CELL_PX.0, CELL_PX.1).unwrap();
        Self { term, written, titles }
    }

    fn take_written(&self) -> Vec<u8> {
        std::mem::take(&mut *self.written.lock().unwrap())
    }

    /// Freeze and thaw, returning the cold sizes.
    fn cold_round_trip(&mut self) -> (u64, usize) {
        let placeholder = Terminal::new(1, 1, 0, Callbacks::default()).unwrap();
        let term = std::mem::replace(&mut self.term, placeholder);
        let cold = term.into_cold().unwrap();
        let sizes = (cold.snapshot_bytes(), cold.compressed_snapshot_bytes());
        assert!(cold.held_bytes() >= sizes.1);
        self.term = cold.thaw().unwrap();
        sizes
    }
}

/// Everything a reader of the terminal can observe.
#[derive(Debug)]
struct Observed {
    ready: Vec<u8>,
    replay: Vec<u8>,
    text: String,
    scrollbar: Option<Scrollbar>,
    cursor: Option<(u16, u16)>,
    title: Option<String>,
    pwd: Option<String>,
    marker_epoch: u64,
    active_top_marker: u64,
    oldest_rows: Option<String>,
    history_epoch: u64,
    kitty: KittyGraphicsSnapshot,
    kitty_replay: Vec<u8>,
}

/// The fields that differ, with the first differing byte of byte fields.
/// `layout` includes READY, whose PAGE records follow the page splits.
fn differences(a: &Observed, b: &Observed, layout: bool) -> Vec<String> {
    fn bytes(name: &str, a: &[u8], b: &[u8], out: &mut Vec<String>) {
        if a != b {
            let at = a.iter().zip(b).position(|(x, y)| x != y).unwrap_or(a.len().min(b.len()));
            out.push(format!(
                "{name}: lengths {} and {}, first difference at {at}",
                a.len(),
                b.len()
            ));
        }
    }
    let mut out = Vec::new();
    if layout {
        bytes("ready", &a.ready, &b.ready, &mut out);
    }
    bytes("replay", &a.replay, &b.replay, &mut out);
    bytes("text", a.text.as_bytes(), b.text.as_bytes(), &mut out);
    bytes("kitty_replay", &a.kitty_replay, &b.kitty_replay, &mut out);
    let small = [
        ("scrollbar", format!("{:?}", a.scrollbar), format!("{:?}", b.scrollbar)),
        ("cursor", format!("{:?}", a.cursor), format!("{:?}", b.cursor)),
        ("title", format!("{:?}", a.title), format!("{:?}", b.title)),
        ("pwd", format!("{:?}", a.pwd), format!("{:?}", b.pwd)),
        ("marker_epoch", a.marker_epoch.to_string(), b.marker_epoch.to_string()),
        ("active_top_marker", a.active_top_marker.to_string(), b.active_top_marker.to_string()),
        ("oldest_rows", format!("{:?}", a.oldest_rows), format!("{:?}", b.oldest_rows)),
        ("history_epoch", a.history_epoch.to_string(), b.history_epoch.to_string()),
        ("kitty", format!("{:?}", a.kitty), format!("{:?}", b.kitty)),
    ];
    for (name, x, y) in small {
        if x != y {
            out.push(format!("{name}: {x} vs {y}"));
        }
    }
    out
}

/// Identical, page layout included: right after a thaw.
#[track_caller]
fn assert_same(label: &str, a: &Observed, b: &Observed) {
    let diff = differences(a, b, true);
    assert!(diff.is_empty(), "{label}: {diff:#?}");
}

/// Identical content after further input. libghostty-vt restores each
/// PAGE record into a page of exactly its rows, so output after a thaw
/// opens a new page where the never-frozen terminal still had room: READY
/// splits its rows differently while every cell, row and marker matches.
#[track_caller]
fn assert_same_content(label: &str, a: &Observed, b: &Observed) {
    let diff = differences(a, b, false);
    assert!(diff.is_empty(), "{label}: {diff:#?}");
}

fn kitty_scene(mut snapshot: KittyGraphicsSnapshot) -> KittyGraphicsSnapshot {
    snapshot.generation = 0;
    for image in &mut snapshot.images {
        image.generation = 0;
    }
    snapshot
}

fn observe(term: &mut Terminal) -> Observed {
    let epoch = term.history_marker_epoch();
    let oldest = term.history_marker(0);
    let oldest_rows = term.read_marker_range(Some(epoch), (oldest, 0), (oldest + 2, 0), true).ok();
    Observed {
        ready: term.encode_snapshot(SnapshotPhase::Ready).unwrap(),
        replay: term.vt_replay().unwrap().into_self_contained_bytes(),
        text: term.plain_text().unwrap(),
        scrollbar: term.scrollbar(),
        cursor: term.cursor_position(),
        title: term.title(),
        pwd: term.pwd(),
        marker_epoch: epoch,
        active_top_marker: term.active_top_marker(),
        oldest_rows,
        history_epoch: term.history_epoch(),
        kitty: kitty_scene(term.kitty_graphics_snapshot().unwrap()),
        kitty_replay: term.encode_kitty_replay(u64::MAX).unwrap().0,
    }
}

fn corpus_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/terminal-corpus")
}

/// `(name, cols, rows, bytes)` of every corpus case.
fn corpus() -> Vec<(String, u16, u16, Vec<u8>)> {
    let manifest = std::fs::read_to_string(corpus_dir().join("manifest.json")).unwrap();
    let field = |object: &str, key: &str| -> String {
        let start = object.find(&format!("\"{key}\"")).unwrap();
        let rest = &object[start + key.len() + 2..];
        let rest = rest[rest.find(':').unwrap() + 1..].trim_start();
        rest[..rest.find([',', '\n', '}']).unwrap()].trim().trim_matches('"').to_string()
    };
    let cases = &manifest[manifest.find("\"cases\"").unwrap()..];
    cases
        .split("\"name\"")
        .skip(1)
        .map(|chunk| {
            let object = format!("\"name\"{}", &chunk[..chunk.find('}').unwrap()]);
            let bytes = std::fs::read(corpus_dir().join(field(&object, "file"))).unwrap();
            (
                field(&object, "name"),
                field(&object, "cols").parse().unwrap(),
                field(&object, "rows").parse().unwrap(),
                bytes,
            )
        })
        .collect()
}

/// Input both terminals get after the thaw: text, styles, a hyperlink, a
/// title, a query whose reply goes to the pty, and enough lines to scroll.
fn further_input() -> Vec<u8> {
    let mut bytes =
        b"\x1b[1;31mred\x1b[0m \x1b]8;;https://cmux.dev\x1b\\link\x1b]8;;\x1b\\".to_vec();
    bytes.extend_from_slice(b"\x1b]2;after thaw\x07\x1b[6n\x1b[?2027$p");
    for line in 0..200 {
        bytes.extend_from_slice(format!("further line {line}\r\n").as_bytes());
    }
    bytes
}

fn report(line: &str) {
    // Direct stderr bypasses libtest capture, so CI logs keep the numbers.
    let _ = std::io::Write::write_all(&mut std::io::stderr(), format!("{line}\n").as_bytes());
}

#[test]
fn cold_pages_round_trip_the_terminal_corpus() {
    let cases = corpus();
    assert!(cases.len() >= 7, "manifest lists {} cases", cases.len());
    let (mut all_snapshots, mut all_compressed) = (0u64, 0u64);
    for (name, cols, rows, bytes) in cases {
        let mut cold = Probe::new(cols, rows, SCROLLBACK_BYTES);
        let mut control = Probe::new(cols, rows, SCROLLBACK_BYTES);
        cold.term.vt_write(&bytes);
        control.term.vt_write(&bytes);
        let complete = cold.term.encode_snapshot(SnapshotPhase::Complete).unwrap();
        let before = observe(&mut cold.term);

        let (snapshot_bytes, compressed) = cold.cold_round_trip();
        let ratio = snapshot_bytes as f64 / compressed as f64;
        report(&format!(
            "cold_pages {name}: snapshot {snapshot_bytes} B, deflated {compressed} B, ratio {ratio:.1}x"
        ));
        assert_eq!(snapshot_bytes, complete.len() as u64, "{name}");
        all_snapshots += snapshot_bytes;
        all_compressed += compressed as u64;
        assert_same(&format!("{name}: thawed"), &observe(&mut cold.term), &before);
        assert_eq!(
            cold.term.encode_snapshot(SnapshotPhase::Complete).unwrap(),
            complete,
            "{name}: COMPLETE snapshot differs after the thaw"
        );

        cold.take_written();
        control.take_written();
        let further = further_input();
        cold.term.vt_write(&further);
        control.term.vt_write(&further);
        assert_eq!(cold.take_written(), control.take_written(), "{name}: pty replies differ");
        let (mut thawed, kept) = (observe(&mut cold.term), observe(&mut control.term));
        // Each terminal numbers its own marker epochs and history epochs.
        thawed.marker_epoch = kept.marker_epoch;
        thawed.history_epoch = kept.history_epoch;
        assert_same_content(&format!("{name}: after more input"), &thawed, &kept);
        assert_eq!(cold.titles.load(Ordering::Relaxed), control.titles.load(Ordering::Relaxed));
    }
    // Small screens without history are mostly the fixed TERMINAL record
    // (palette, tab stops), so the 8x bar is for the corpus as a whole.
    let ratio = all_snapshots as f64 / all_compressed as f64;
    report(&format!(
        "cold_pages corpus: {all_snapshots} B to {all_compressed} B, ratio {ratio:.1}x"
    ));
    assert!(ratio >= 8.0, "corpus ratio {ratio:.1}x is under 8x");
}

#[test]
fn cold_pages_compress_large_scrollback_eight_times_and_keep_eviction() {
    let text: Vec<u8> = corpus()
        .into_iter()
        .filter(|(name, ..)| !matches!(name.as_str(), "kitty-graphics" | "alt-screen-editor"))
        .flat_map(|(.., bytes)| bytes)
        .collect();
    // 2 MB of scrollback, written until its oldest rows are evicted.
    let mut cold = Probe::new(120, 40, 2_000_000);
    let mut control = Probe::new(120, 40, 2_000_000);
    // PTY-sized writes: a write that evicts its own pinned row starts a new
    // marker epoch instead of counting.
    let mut written = 0;
    while cold.term.history_marker(0) == 0 {
        assert!(written < 64_000_000, "no row was evicted after {written} B");
        for chunk in text.chunks(16 * 1024) {
            cold.term.vt_write(chunk);
            control.term.vt_write(chunk);
        }
        written += text.len();
    }
    let resident = cold.term.primary_resident_bytes().unwrap_or(0);
    let before = observe(&mut cold.term);
    let (snapshot_bytes, compressed) = cold.cold_round_trip();
    let ratio = snapshot_bytes as f64 / compressed as f64;
    report(&format!(
        "cold_pages large: resident {resident} B, snapshot {snapshot_bytes} B, deflated {compressed} B, ratio {ratio:.1}x, resident/deflated {:.1}x",
        resident as f64 / compressed as f64
    ));
    assert!(ratio >= 8.0, "ratio {ratio:.1}x is under 8x");
    assert_same("large: thawed", &observe(&mut cold.term), &before);

    // More output keeps counting markers from where the thaw left off.
    // Eviction is per page under the byte budget, and restored pages are
    // sized to their rows, so the thawed terminal may keep more of the
    // oldest rows than the control, never fewer; every row both keep
    // matches, under the same marker.
    let evicted_before = control.term.history_marker(0);
    for chunk in text.chunks(16 * 1024).cycle().take(3 * text.len().div_ceil(16 * 1024)) {
        cold.term.vt_write(chunk);
        control.term.vt_write(chunk);
    }
    assert!(control.term.history_marker(0) > evicted_before, "the input evicts more rows");
    assert_eq!(cold.term.history_marker_epoch(), before.marker_epoch, "same marker epoch");
    assert_eq!(cold.term.active_top_marker(), control.term.active_top_marker());
    let oldest_kept = control.term.history_marker(0);
    assert!(cold.term.history_marker(0) <= oldest_kept, "the thawed terminal evicted more");
    let last = control.term.active_top_marker() + u64::from(control.term.rows()) - 1;
    let kept_rows = |term: &mut Terminal| {
        let epoch = term.history_marker_epoch();
        term.read_marker_range(Some(epoch), (oldest_kept, 0), (last, 119), true).unwrap()
    };
    assert_eq!(kept_rows(&mut cold.term), kept_rows(&mut control.term));
    let (thawed, kept) = (observe(&mut cold.term), observe(&mut control.term));
    assert_eq!(thawed.scrollbar.map(|bar| bar.len), kept.scrollbar.map(|bar| bar.len));
    assert_eq!(thawed.cursor, kept.cursor);
    assert!(thawed.text.ends_with(&kept.text), "the kept rows read the same");
}

#[test]
fn cold_pages_keep_an_unfinished_sequence_callbacks_and_terminfo() {
    let mut cold = Probe::new(80, 24, SCROLLBACK_BYTES);
    let mut control = Probe::new(80, 24, SCROLLBACK_BYTES);
    for probe in [&mut cold, &mut control] {
        probe.term.set_terminfo_name("xterm-ghostty").unwrap();
        probe.term.vt_write(b"\x1b]2;before\x07prompt$ \x1b[3");
    }
    cold.cold_round_trip();
    // TN capability query, then the rest of the SGR sequence.
    for probe in [&mut cold, &mut control] {
        probe.take_written();
        probe.term.vt_write(b"1mX\x1b[0m\x1bP+q544e\x1b\\\x1b]2;after\x07");
    }
    let reply = control.take_written();
    assert!(!reply.is_empty(), "the TN query is answered");
    assert_eq!(cold.take_written(), reply);
    assert_eq!(cold.titles.load(Ordering::Relaxed), 2);
    assert_eq!(cold.term.title().as_deref(), Some("after"));
    let (mut thawed, kept) = (observe(&mut cold.term), observe(&mut control.term));
    thawed.marker_epoch = kept.marker_epoch;
    thawed.history_epoch = kept.history_epoch;
    assert_same_content("unfinished sequence", &thawed, &kept);
}

#[test]
fn cold_pages_keep_a_scrolled_back_viewport() {
    let mut probe = Probe::new(80, 24, SCROLLBACK_BYTES);
    for line in 0..300 {
        probe.term.vt_write(format!("line {line}\r\n").as_bytes());
    }
    probe.term.scroll_delta(-37);
    let before = probe.term.scrollbar().unwrap();
    assert!(before.scrolled_back());
    probe.cold_round_trip();
    assert_eq!(probe.term.scrollbar(), Some(before));
    assert_eq!(probe.term.viewport_text().unwrap(), {
        let mut control = Probe::new(80, 24, SCROLLBACK_BYTES);
        for line in 0..300 {
            control.term.vt_write(format!("line {line}\r\n").as_bytes());
        }
        control.term.scroll_delta(-37);
        control.term.viewport_text().unwrap()
    });
}

#[test]
fn cold_pages_give_a_thawed_terminal_a_new_instance() {
    let mut probe = Probe::new(80, 24, SCROLLBACK_BYTES);
    probe.term.vt_write(b"hello");
    let point = probe.term.track_screen_point(0, 0).unwrap();
    assert!(probe.term.tracked_screen_point(&point).is_some());
    probe.cold_round_trip();
    assert_eq!(probe.term.tracked_screen_point(&point), None);
}

fn kitty(params: &str, payload: &str) -> Vec<u8> {
    format!("\x1b_G{params};{payload}\x1b\\").into_bytes()
}

/// One RGBA pixel.
const PIXEL: &str = "/wAAfw==";

/// Kitty state the replay stream carries, then more commands that depend on
/// the restored image numbers and implicit ID cursors of both screens. The
/// alternate screen exists but holds no image (an image there, inactive,
/// is refused: cold_pages_refuse_images_on_the_inactive_alternate_screen).
#[test]
fn cold_pages_round_trip_kitty_placements_numbers_and_both_screens() {
    let setup = [
        b"before\r\n".to_vec(),
        kitty("a=T,t=d,f=32,i=21,p=2,s=1,v=1,c=2,r=2,z=4,q=2", PIXEL),
        kitty("a=T,t=d,f=32,I=7,s=1,v=1,X=1,Y=2,c=3,r=1,z=-2,q=2", PIXEL),
        kitty("a=T,t=d,f=32,s=1,v=1,c=1,r=1,q=2", PIXEL),
        b"\x1b[?1049halt\x1b[?1049l".to_vec(),
    ]
    .concat();
    let further = [
        kitty("a=p,I=7,c=2,r=2,q=2", ""),
        kitty("a=T,t=d,f=32,s=1,v=1,c=1,r=1,q=2", PIXEL),
        b"\x1b[?1049h".to_vec(),
        kitty("a=T,t=d,f=32,i=40,p=3,s=1,v=1,c=1,r=1,q=2", PIXEL),
        kitty("a=T,t=d,f=32,s=1,v=1,c=1,r=1,q=2", PIXEL),
    ]
    .concat();
    let mut cold = Probe::new(20, 8, SCROLLBACK_BYTES);
    let mut control = Probe::new(20, 8, SCROLLBACK_BYTES);
    cold.term.vt_write(&setup);
    control.term.vt_write(&setup);
    let before = observe(&mut cold.term);
    assert_eq!(before.kitty.images.len(), 3, "{:?}", before.kitty);
    cold.cold_round_trip();
    assert_same("kitty: thawed", &observe(&mut cold.term), &before);

    cold.term.vt_write(&further);
    control.term.vt_write(&further);
    let (mut thawed, kept) = (observe(&mut cold.term), observe(&mut control.term));
    thawed.marker_epoch = kept.marker_epoch;
    thawed.history_epoch = kept.history_epoch;
    assert_same_content("kitty: after more input", &thawed, &kept);
}

/// A refused terminal comes back unchanged and still works.
fn assert_refused(probe: &mut Probe, reason: ColdPagesError) {
    let before = observe(&mut probe.term);
    let placeholder = Terminal::new(1, 1, 0, Callbacks::default()).unwrap();
    let term = std::mem::replace(&mut probe.term, placeholder);
    let refused = term.into_cold().expect_err("the codec cannot restore this exactly");
    assert_eq!(refused.reason, reason);
    probe.term = refused.terminal;
    assert_same("refused", &observe(&mut probe.term), &before);
    probe.term.vt_write(b"still alive");
    assert!(probe.term.plain_text().unwrap().contains("still alive"));
}

#[test]
fn cold_pages_refuse_a_placement_only_in_scrollback() {
    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    probe.term.vt_write(&kitty("a=T,t=d,f=32,i=5,s=1,v=1,c=1,r=1,q=2", PIXEL));
    for line in 0..30 {
        probe.term.vt_write(format!("\r\nline {line}").as_bytes());
    }
    assert_refused(&mut probe, ColdPagesError::KittyNotReplayable);
}

/// The review's reproduction: placement p=1 only in the primary scrollback,
/// p=2 of the same image showing (so the image keeps its pixels in the
/// replay), then the alternate screen active. The replay drops p=1 and only
/// the active screen's placements can be compared, so the codec refuses.
#[test]
fn cold_pages_refuse_a_scrollback_placement_under_the_alternate_screen() {
    let setup = |probe: &mut Probe| {
        probe.term.vt_write(&kitty("a=T,t=d,f=32,i=5,p=1,s=1,v=1,c=1,r=1,q=2", PIXEL));
        for line in 0..30 {
            probe.term.vt_write(format!("\r\nline {line}").as_bytes());
        }
        probe.term.vt_write(&kitty("a=p,i=5,p=2,q=2", ""));
    };
    let mut primary_active = Probe::new(20, 8, SCROLLBACK_BYTES);
    setup(&mut primary_active);
    assert_refused(&mut primary_active, ColdPagesError::KittyNotReplayable);

    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    setup(&mut probe);
    probe.term.vt_write(b"\x1b[?1049h");
    assert_refused(&mut probe, ColdPagesError::KittyNotReplayable);
    probe.term.vt_write(b"\x1b[?1049l");
    let placements = probe.term.kitty_graphics_snapshot().unwrap().placements;
    assert_eq!(placements.len(), 2, "the refused terminal keeps p=1 and p=2: {placements:?}");
}

/// Images on the inactive alternate screen cannot be compared either.
#[test]
fn cold_pages_refuse_images_on_the_inactive_alternate_screen() {
    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    probe.term.vt_write(b"\x1b[?1049h");
    probe.term.vt_write(&kitty("a=T,t=d,f=32,i=40,s=1,v=1,c=1,r=1,q=2", PIXEL));
    probe.term.vt_write(b"\x1b[?1049l");
    assert_refused(&mut probe, ColdPagesError::KittyNotReplayable);
}

/// Kitty state on the active screen only round-trips with the alternate
/// screen active, and the primary screen it returns to is intact.
#[test]
fn cold_pages_round_trip_kitty_on_the_active_alternate_screen() {
    let setup = [
        b"shell\r\n\x1b[?1049h".to_vec(),
        kitty("a=T,t=d,f=32,i=40,p=3,s=1,v=1,c=2,r=1,q=2", PIXEL),
        kitty("a=T,t=d,f=32,I=9,s=1,v=1,c=1,r=1,q=2", PIXEL),
    ]
    .concat();
    let further = [
        kitty("a=p,I=9,c=2,r=2,q=2", ""),
        b"\x1b[?1049l".to_vec(),
        kitty("a=T,t=d,f=32,s=1,v=1,c=1,r=1,q=2", PIXEL),
    ]
    .concat();
    let mut cold = Probe::new(20, 8, SCROLLBACK_BYTES);
    let mut control = Probe::new(20, 8, SCROLLBACK_BYTES);
    cold.term.vt_write(&setup);
    control.term.vt_write(&setup);
    let before = observe(&mut cold.term);
    assert_eq!(before.kitty.images.len(), 2, "{:?}", before.kitty);
    cold.cold_round_trip();
    assert_same("alternate kitty: thawed", &observe(&mut cold.term), &before);

    cold.term.vt_write(&further);
    control.term.vt_write(&further);
    let (mut thawed, kept) = (observe(&mut cold.term), observe(&mut control.term));
    thawed.marker_epoch = kept.marker_epoch;
    thawed.history_epoch = kept.history_epoch;
    assert_same_content("alternate kitty: after more input", &thawed, &kept);
}

#[test]
fn cold_pages_refuse_an_unplaced_image() {
    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    probe.term.vt_write(&kitty("a=t,t=d,f=32,i=6,s=1,v=1,q=2", PIXEL));
    assert_refused(&mut probe, ColdPagesError::KittyNotReplayable);
}

#[test]
fn cold_pages_refuse_a_kitty_upload_in_progress() {
    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    probe.term.vt_write(&kitty("a=t,t=d,f=24,i=8,s=1,v=2,m=1,q=2", "AAAA"));
    assert!(probe.term.kitty_upload_in_progress());
    assert_refused(&mut probe, ColdPagesError::KittyUploadInProgress);
}

#[test]
fn cold_pages_refuse_deferred_clipboard_reads() {
    let mut probe = Probe::new(20, 8, SCROLLBACK_BYTES);
    probe.term.set_clipboard_reads_deferred(true);
    assert_refused(&mut probe, ColdPagesError::ClipboardReadsDeferred);
    probe.term.set_clipboard_reads_deferred(false);
    probe.cold_round_trip();
}

/// Deterministic log lines that do not repeat: timestamps, ids, durations
/// and paths from a linear congruential generator, some of them styled.
fn varied_log(bytes: usize) -> Vec<u8> {
    const LEVELS: [&str; 4] = ["\x1b[32mINFO\x1b[0m", "\x1b[33mWARN\x1b[0m", "DEBUG", "TRACE"];
    const WORDS: [&str; 8] =
        ["request", "compile", "fetch", "render", "socket", "worker", "cache", "write"];
    let mut state = 0x2545_f491_4f6c_dd1du64;
    let mut next = move || {
        state =
            state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        state >> 33
    };
    let mut out = Vec::with_capacity(bytes + 256);
    let mut second = 0u64;
    while out.len() < bytes {
        second += next() % 3;
        let line = format!(
            "2026-10-26T{:02}:{:02}:{:02}.{:03}Z {} [{}-{}] {} id={:016x} took {}ms /api/v{}/{}/{:x}\r\n",
            (second / 3600) % 24,
            (second / 60) % 60,
            second % 60,
            next() % 1000,
            LEVELS[(next() % 4) as usize],
            WORDS[(next() % 8) as usize],
            next() % 64,
            WORDS[(next() % 8) as usize],
            next() << 20 | next(),
            next() % 5000,
            1 + next() % 3,
            WORDS[(next() % 8) as usize],
            next(),
        );
        out.extend_from_slice(line.as_bytes());
    }
    out
}

/// The 112/040 comparison with libghostty-vt's own page compression
/// (`ghostty_terminal_compress`): the same filled 10 MB scrollback, resident
/// bytes after each, and what the next read costs. Numbers go to stderr and
/// into p07-memory.md; the asserts check that both keep the content and that
/// the codec holds at most half of what native compression leaves resident
/// (the 2x bar for keeping a codec of our own).
#[test]
fn cold_pages_compare_with_native_page_compression() {
    let corpus_text: Vec<u8> = corpus()
        .into_iter()
        .filter(|(name, ..)| !matches!(name.as_str(), "kitty-graphics" | "alt-screen-editor"))
        .flat_map(|(.., bytes)| bytes)
        .collect();
    for (name, text) in [("corpus", corpus_text), ("varied log", varied_log(4_000_000))] {
        compare_with_native(name, &text);
    }
}

fn compare_with_native(name: &str, text: &[u8]) {
    let fill = |probe: &mut Probe| {
        let mut written = 0;
        while probe.term.history_marker(0) == 0 {
            assert!(written < 256_000_000, "no row was evicted after {written} B");
            for chunk in text.chunks(16 * 1024) {
                probe.term.vt_write(chunk);
            }
            written += text.len();
        }
    };
    let mut native = Probe::new(120, 40, SCROLLBACK_BYTES);
    let mut cold = Probe::new(120, 40, SCROLLBACK_BYTES);
    fill(&mut native);
    fill(&mut cold);
    let expected = native.term.plain_text().unwrap();
    let live = native.term.page_memory().unwrap();

    let started = std::time::Instant::now();
    let outcome = native.term.compress_scrollback(true).unwrap();
    let native_compress = started.elapsed();
    let compressed = native.term.page_memory().unwrap();
    let started = std::time::Instant::now();
    let viewport = native.term.viewport_text().unwrap();
    let native_viewport_read = started.elapsed();
    let started = std::time::Instant::now();
    let native_text = native.term.plain_text().unwrap();
    let native_full_read = started.elapsed();
    assert_eq!(native_text, expected, "native compression keeps the content");

    let placeholder = Terminal::new(1, 1, 0, Callbacks::default()).unwrap();
    let term = std::mem::replace(&mut cold.term, placeholder);
    let started = std::time::Instant::now();
    let frozen = term.into_cold().unwrap();
    let codec_freeze = started.elapsed();
    let held = frozen.held_bytes() as u64;
    let started = std::time::Instant::now();
    cold.term = frozen.thaw().unwrap();
    let codec_thaw = started.elapsed();
    assert_eq!(cold.term.viewport_text().unwrap(), viewport);
    assert_eq!(cold.term.plain_text().unwrap(), expected, "the codec keeps the content");

    report(&format!(
        "cold_pages vs native ({name}): live resident {} B in {} pages; native {outcome:?}: resident {} B \
         ({} of {} pages, {} B compressed), {:.1}x, compress {:?}, viewport read {:?}, full read {:?}; \
         codec: held {held} B, {:.1}x, freeze {:?}, thaw {:?}; codec over native {:.2}x",
        live.resident_bytes,
        live.pages,
        compressed.resident_bytes,
        compressed.compressed_pages,
        compressed.pages,
        compressed.compressed_bytes,
        live.resident_bytes as f64 / compressed.resident_bytes as f64,
        native_compress,
        native_viewport_read,
        native_full_read,
        live.resident_bytes as f64 / held as f64,
        codec_freeze,
        codec_thaw,
        compressed.resident_bytes as f64 / held as f64,
    ));
    assert!(held * 2 <= compressed.resident_bytes, "{name}: the codec is not 2x over native");
}
