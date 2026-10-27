//! Resize sequences against a real child process (Lawrence 2026-10-27: "we
//! need resize tests, for both windows, and panes too").
//!
//! A window or pane resize reaches a terminal as a run of sizes: a grow, a
//! shrink, a drag that sends one size per frame, a pane squeezed to one
//! column, a window larger than any screen. After every size the daemon's
//! terminal grid, the PTY's winsize (what `TIOCGWINSZ` returns to the child)
//! and the size the child reads after its SIGWINCH must agree. The resize
//! conformance suite checks the reflow against plain Ghostty with injected
//! output; these tests run a real program on the PTY: a size logger, a
//! full-screen alternate-screen program that redraws on SIGWINCH (htop-like),
//! and a program that keeps streaming output while the window is dragged.

use super::*;
use std::path::{Path, PathBuf};

const WAIT: Duration = Duration::from_secs(20);

/// A fresh directory for one test's child files.
fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-resize-seq-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A local PTY surface running the command in `opts` (a real child process,
/// outside the resource catalog so no cwd publication touches the registry),
/// registered in the mux so its client resize path finds it.
fn spawn_child(mux: &Arc<Mux>, id: SurfaceId, opts: SurfaceOptions) -> Arc<Surface> {
    let surface = Surface::spawn_auxiliary(id, opts, Arc::downgrade(mux)).unwrap();
    mux.insert_surface_runtime_for_test(surface.clone());
    surface
}

fn sh(script: &str, arg: &Path) -> SurfaceOptions {
    SurfaceOptions {
        command: Some(vec![
            "/bin/sh".into(),
            "-c".into(),
            script.into(),
            "sh".into(),
            arg.to_string_lossy().into_owned(),
        ]),
        cols: 80,
        rows: 24,
        ..SurfaceOptions::default()
    }
}

/// Appends the size the child reads from its PTY (`stty size`: "rows cols")
/// to `$1/sizes`, once at start and once per SIGWINCH.
const SIZE_LOGGER: &str = r#"
dir=$1
report() { stty size >> "$dir/sizes"; }
trap report WINCH
report
while :; do sleep 0.02; done
"#;

/// The last size the child logged, as (cols, rows).
fn child_size(dir: &Path) -> Option<(u16, u16)> {
    let text = std::fs::read_to_string(dir.join("sizes")).ok()?;
    let line = text.lines().rev().find(|line| !line.trim().is_empty())?;
    let mut parts = line.split_whitespace();
    let rows = parts.next()?.parse().ok()?;
    let cols = parts.next()?.parse().ok()?;
    Some((cols, rows))
}

fn wait_for_child_size(dir: &Path, expected: (u16, u16), step: &str) {
    let deadline = Instant::now() + WAIT;
    loop {
        let seen = child_size(dir);
        if seen == Some(expected) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{step}: the child reads {seen:?} from its PTY after SIGWINCH, the grid is {expected:?}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The daemon's grid, the PTY winsize (cells and pixels) and the surface's
/// size are the same, `expected`.
fn assert_geometry(surface: &Surface, expected: (u16, u16), step: &str) {
    let (cols, rows) = surface.try_with_terminal(|term| (term.cols(), term.rows())).unwrap();
    assert_eq!((cols, rows), expected, "{step}: the terminal grid");
    let pty = surface.test_master_size();
    assert_eq!((pty.cols, pty.rows), expected, "{step}: the PTY winsize (TIOCGWINSZ)");
    let (cell_w, cell_h) = surface.test_cell_pixel_size();
    assert_eq!(
        (pty.pixel_width, pty.pixel_height),
        (expected.0.saturating_mul(cell_w.max(1)), expected.1.saturating_mul(cell_h.max(1))),
        "{step}: the PTY pixel size is the grid at the cell size"
    );
    assert_eq!(surface.size(), expected, "{step}: the surface size");
}

fn wait_for_viewport(surface: &Surface, what: &str, mut ready: impl FnMut(&str) -> bool) -> String {
    let deadline = Instant::now() + WAIT;
    loop {
        let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
        if ready(&text) {
            return text;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}: {text:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Numbered scrollback lines `prefix NNNN` in `text`, in order.
fn numbered(text: &str, prefix: &str) -> Vec<u64> {
    text.lines()
        .filter_map(|line| line.trim_end().strip_prefix(prefix))
        .filter_map(|rest| rest.trim().parse().ok())
        .collect()
}

/// The numbers are consecutive: reflow kept every line it kept in order, and
/// dropped only the oldest ones (the scrollback limit).
fn assert_consecutive(numbers: &[u64], last: u64, what: &str) {
    assert!(!numbers.is_empty(), "{what}: no numbered line survived");
    for pair in numbers.windows(2) {
        assert_eq!(pair[1], pair[0] + 1, "{what}: line {} follows line {}", pair[1], pair[0]);
    }
    assert_eq!(*numbers.last().unwrap(), last, "{what}: the newest line");
}

/// Grow, shrink, a pane squeezed to one column, a window larger than any
/// display, and back, through the mux's client resize (the path every
/// frontend's pane size takes). After each size the grid, the PTY and the
/// child agree, and the scrollback is still in order at the end.
#[test]
fn resize_sequence_grid_pty_and_child_agree_after_every_step() {
    let dir = scratch_dir("steps");
    let mux = Mux::new_for_test("resize-seq-steps", SurfaceOptions::default());
    let surface = spawn_child(&mux, 4301, sh(SIZE_LOGGER, &dir));
    wait_for_child_size(&dir, (80, 24), "start");
    let mut history = String::new();
    for i in 0..3000 {
        history.push_str(&format!("hist {i:04}\r\n"));
    }
    surface.inject_output_for_test(history.as_bytes());

    // (requested, expected): the mux clamps to the sizing engine's minimum
    // (2 x 1), the largest side (10000) and the 4M-cell area.
    let steps: [((u16, u16), (u16, u16)); 13] = [
        ((100, 30), (100, 30)),
        ((160, 50), (160, 50)),
        ((60, 20), (60, 20)),
        ((20, 8), (20, 8)),
        ((1, 24), (2, 24)),
        ((1, 1), (2, 1)),
        ((2, 60), (2, 60)),
        ((500, 200), (500, 200)),
        ((2000, 600), (2000, 600)),
        ((u16::MAX, u16::MAX), (10_000, 400)),
        ((300, 1), (300, 1)),
        ((41, 12), (41, 12)),
        ((80, 24), (80, 24)),
    ];
    for (requested, expected) in steps {
        let step = format!("{}x{} (asked {}x{})", expected.0, expected.1, requested.0, requested.1);
        mux.resize_surface_for_client(surface.id, 0, requested.0, requested.1).unwrap();
        assert_geometry(&surface, expected, &step);
        wait_for_child_size(&dir, expected, &step);
    }
    let text = surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
    assert_consecutive(&numbered(&text, "hist "), 2999, "scrollback after the sequence");
    drop(surface);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A window or divider drag: one size per frame, as fast as the frontend
/// sends them, with no wait for the child. Every call leaves the grid and the
/// PTY on the size it asked for, and the child ends on the last one, not on
/// a size the drag passed through.
#[test]
fn resize_drag_burst_settles_the_child_on_the_last_size() {
    let dir = scratch_dir("drag");
    let mux = Mux::new_for_test("resize-seq-drag", SurfaceOptions::default());
    let surface = spawn_child(&mux, 4302, sh(SIZE_LOGGER, &dir));
    wait_for_child_size(&dir, (80, 24), "start");
    surface.inject_output_for_test(&b"drag line\r\n".repeat(500));
    for frame in 0..240u16 {
        // Out and back twice, like a person dragging the window edge.
        let phase = frame % 120;
        let delta = if phase < 60 { phase } else { 120 - phase };
        let size = (40 + delta * 2, 12 + delta / 3);
        mux.resize_surface_for_client(surface.id, 0, size.0, size.1).unwrap();
        assert_geometry(&surface, size, &format!("drag frame {frame}"));
    }
    mux.resize_surface_for_client(surface.id, 0, 97, 31).unwrap();
    assert_geometry(&surface, (97, 31), "drag end");
    wait_for_child_size(&dir, (97, 31), "drag end");
    drop(surface);
    let _ = std::fs::remove_dir_all(&dir);
}

/// No frame at a new size before the PTY has it: whenever the terminal grid
/// is observed (under the terminal lock, as the frame builder reads it), the
/// PTY already holds that size, so a program reading its size after SIGWINCH
/// never draws for an older size into a newer grid. Sampled from another
/// thread while a drag resizes.
#[test]
fn the_grid_never_shows_a_size_the_pty_does_not_have() {
    let dir = scratch_dir("sampler");
    let mux = Mux::new_for_test("resize-seq-sampler", SurfaceOptions::default());
    let surface = spawn_child(&mux, 4303, sh(SIZE_LOGGER, &dir));
    wait_for_child_size(&dir, (80, 24), "start");
    let stop = Arc::new(AtomicBool::new(false));
    let sampler = {
        let surface = surface.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut samples = 0u64;
            let mut mismatches = Vec::new();
            while !stop.load(Ordering::Acquire) {
                let pty = surface.as_pty().unwrap();
                let term = pty.term.lock().unwrap();
                let grid = (term.cols(), term.rows());
                let master = surface.test_master_size();
                drop(term);
                if grid != (master.cols, master.rows) && mismatches.len() < 8 {
                    mismatches.push((grid, (master.cols, master.rows)));
                }
                samples += 1;
                std::thread::yield_now();
            }
            (samples, mismatches)
        })
    };
    for frame in 0..400u16 {
        let size = (30 + (frame * 7) % 150, 8 + (frame * 5) % 50);
        mux.resize_surface_for_client(surface.id, 0, size.0, size.1).unwrap();
    }
    stop.store(true, Ordering::Release);
    let (samples, mismatches) = sampler.join().unwrap();
    assert!(samples > 0, "the sampler never ran");
    assert!(
        mismatches.is_empty(),
        "the grid showed a size the PTY did not have ({} of {samples} samples): {mismatches:?}",
        mismatches.len()
    );
    drop(surface);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A full-screen program on the alternate screen, like htop: it writes
/// scrollback, enters the alternate screen and redraws every row for the
/// size it reads after each SIGWINCH. After every resize (and after a drag
/// burst) the screen shows exactly the program's frame for the new size,
/// every row of it, and leaving the program shows the primary screen with
/// its scrollback intact.
#[test]
fn an_alternate_screen_program_redraws_for_every_new_size() {
    const PROGRAM: &str = r#"
dir=$1
i=0
while [ $i -lt 400 ]; do printf 'hist %04d\n' $i; i=$((i+1)); done
printf '\033[?1049h'
draw() {
  set -- $(stty size)
  rows=$1; cols=$2
  printf '\033[?2026h\033[H\033[2J'
  r=1
  while [ $r -le $rows ]; do printf '\033[%d;1Hr%d %dx%d' $r $r $cols $rows; r=$((r+1)); done
  printf '\033[?2026l'
  echo "$rows $cols" > "$dir/drawn.tmp"; mv "$dir/drawn.tmp" "$dir/drawn"
}
# The handler only flags the resize: a full-screen program redraws from its
# main loop, so a SIGWINCH during a redraw never lets an older redraw finish last.
resized=0
trap 'resized=1' WINCH
draw
while [ ! -e "$dir/quit" ]; do
  if [ $resized = 1 ]; then resized=0; draw; fi
  sleep 0.02
done
printf '\033[?1049l'
printf 'left-alt\n'
while :; do sleep 1; done
"#;
    let dir = scratch_dir("alt");
    let mux = Mux::new_for_test("resize-seq-alt", SurfaceOptions::default());
    let surface = spawn_child(&mux, 4304, sh(PROGRAM, &dir));

    let shows_frame = |surface: &Surface, (cols, rows): (u16, u16), step: &str| {
        let drawn = || {
            let text = std::fs::read_to_string(dir.join("drawn")).ok()?;
            let mut parts = text.split_whitespace();
            Some((parts.next()?.parse::<u16>().ok()?, parts.next()?.parse::<u16>().ok()?))
        };
        let deadline = Instant::now() + WAIT;
        while drawn() != Some((rows, cols)) {
            assert!(Instant::now() < deadline, "{step}: the program never drew for {cols}x{rows}");
            std::thread::sleep(Duration::from_millis(5));
        }
        let label = format!("{cols}x{rows}");
        let text = wait_for_viewport(surface, &format!("{step}: the frame for {label}"), |text| {
            text.lines().count() == usize::from(rows)
                && text
                    .lines()
                    .enumerate()
                    .all(|(i, line)| line.trim_end() == format!("r{} {label}", i + 1))
        });
        assert_eq!(text.lines().count(), usize::from(rows), "{step}: rows on screen");
        let screen = surface.try_with_terminal(|term| term.active_screen()).unwrap();
        assert_eq!(screen, Screen::Alternate, "{step}: the program's screen");
        assert_geometry(surface, (cols, rows), step);
    };

    shows_frame(&surface, (80, 24), "start");
    let steps: [(u16, u16); 8] =
        [(120, 40), (60, 20), (200, 60), (12, 4), (90, 30), (90, 10), (30, 50), (100, 30)];
    for size in steps {
        mux.resize_surface_for_client(surface.id, 0, size.0, size.1).unwrap();
        // The PTY has the size when the resize returns, before the program
        // draws anything for it.
        let master = surface.test_master_size();
        assert_eq!((master.cols, master.rows), size, "the PTY took {size:?} with the grid");
        shows_frame(&surface, size, &format!("resize to {}x{}", size.0, size.1));
    }
    for frame in 0..60u16 {
        let size = (40 + frame, 12 + frame / 4);
        mux.resize_surface_for_client(surface.id, 0, size.0, size.1).unwrap();
    }
    mux.resize_surface_for_client(surface.id, 0, 80, 24).unwrap();
    shows_frame(&surface, (80, 24), "after a drag burst");

    std::fs::write(dir.join("quit"), b"").unwrap();
    wait_for_viewport(&surface, "the primary screen", |text| text.contains("left-alt"));
    let screen = surface.try_with_terminal(|term| term.active_screen()).unwrap();
    assert_eq!(screen, Screen::Primary);
    let text = surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
    let hist = numbered(&text, "hist ");
    assert_eq!(hist.first(), Some(&0), "the primary screen lost its oldest history: {text:?}");
    assert_consecutive(&hist, 399, "primary scrollback after the alternate screen resizes");
    assert!(!text.contains(" 80x24\n"), "the program's frame leaked into the primary screen");
    drop(surface);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A window dragged while a program streams output: every resize lands
/// between the bytes the PTY delivers, and no line is lost, duplicated or
/// split by the reflow. The program prints numbered lines, then DONE.
#[test]
fn resizes_while_output_streams_lose_and_duplicate_no_line() {
    const LAST: u64 = 59_999;
    const PROGRAM: &str = r#"
i=0
while [ $i -le 59999 ]; do echo "line $i"; i=$((i+1)); done
echo DONE
while :; do sleep 1; done
"#;
    let dir = scratch_dir("stream");
    let mux = Mux::new_for_test("resize-seq-stream", SurfaceOptions::default());
    let surface = spawn_child(&mux, 4305, sh(PROGRAM, &dir));
    wait_for_viewport(&surface, "streaming output", |text| text.contains("line "));
    let mut resizes = 0u32;
    let mut during_stream = 0u32;
    let deadline = Instant::now() + WAIT;
    loop {
        let done = surface
            .try_with_terminal(|term| term.viewport_text())
            .unwrap()
            .unwrap()
            .contains("DONE");
        if !done {
            during_stream = resizes;
        }
        if done && resizes >= 50 {
            break;
        }
        assert!(Instant::now() < deadline, "the stream never finished ({resizes} resizes)");
        // Widths stay above "line 59999" so no line soft-wraps.
        let size = (14 + (resizes as u16 * 13) % 180, 5 + (resizes as u16 * 7) % 55);
        mux.resize_surface_for_client(surface.id, 0, size.0, size.1).unwrap();
        assert_geometry(&surface, size, &format!("resize {resizes} while streaming"));
        resizes += 1;
    }
    assert!(
        during_stream >= 10,
        "only {during_stream} resizes landed while the program streamed; the test proves nothing"
    );
    mux.resize_surface_for_client(surface.id, 0, 80, 24).unwrap();
    assert_geometry(&surface, (80, 24), "after the stream");
    let text = surface.try_with_terminal(|term| term.plain_text()).unwrap().unwrap();
    let lines = numbered(&text, "line ");
    assert_consecutive(&lines, LAST, &format!("streamed scrollback after {resizes} resizes"));
    let after_last = text
        .lines()
        .skip_while(|line| line.trim_end() != format!("line {LAST}"))
        .nth(1)
        .map(str::trim_end);
    assert_eq!(after_last, Some("DONE"), "the line after the last numbered line");
    drop(surface);
    let _ = std::fs::remove_dir_all(&dir);
}
