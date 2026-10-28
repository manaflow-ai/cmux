//! Resize sequences on a hosted terminal (Lawrence 2026-10-27: "we need
//! resize tests, for both windows, and panes too").
//!
//! Every terminal in the cmux-next app runs in a terminal host
//! (`PtyRuntime::Hosted`): the daemon's mirror does not reflow when a view
//! resizes. It sends the size to the host, and the grid changes only when
//! the host's `Resized` replay comes back. The in-process resize sequence
//! tests (cmux-tui-core `surface/tests/resize_sequence.rs`) run local PTYs;
//! these run the same kinds of sequences through a real daemon and its
//! hosts: a grow/shrink run, a drag that sends one size per frame without
//! waiting, and a full-screen program on the alternate screen. After each
//! settled size the mirror, the size the child reads after SIGWINCH and the
//! screen agree, the viewport still shows the newest line, and no late or
//! reordered replay moves the grid back to a size the drag passed through.

use super::*;

/// History, then the size the child reads (`stty size`: "rows cols") in
/// `$1/size`, at start and after every SIGWINCH.
const SIZE_LOGGER: &str = r#"
dir=$1
i=0
while [ $i -lt 300 ]; do printf 'hist %04d\n' $i; i=$((i+1)); done
report() { stty size > "$dir/size.tmp"; mv "$dir/size.tmp" "$dir/size"; }
# The handler only flags the resize and the loop reports, so a SIGWINCH
# during a report never runs a second report over the first one's file.
resized=0
trap 'resized=1' WINCH
report
while :; do
  if [ $resized = 1 ]; then resized=0; report; fi
  sleep 0.02
done
"#;

/// A daemon with one hosted terminal running `script` with `dir` as `$1`,
/// and one attached view on its own connection, which sizes it.
struct HostedTerminal {
    harness: RecoveryHarness,
    surface: u64,
    dir: PathBuf,
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    next_id: u64,
}

impl HostedTerminal {
    fn start(name: &str, script: &str) -> Self {
        let harness = RecoveryHarness::start(name);
        let dir = harness.dir.join("child");
        fs::create_dir_all(&dir).unwrap();
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id": 1, "cmd": "run",
                "argv": ["/bin/sh", "-c", script, "sh", dir.to_string_lossy()],
                "new_workspace": true, "name": name, "cols": 80, "rows": 24,
            }),
        );
        let surface = created["surface"].as_u64().unwrap();
        let stream = transport::connect(&harness.socket).unwrap();
        stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        stream_request(
            &mut writer,
            &mut reader,
            serde_json::json!({
                "id": 2, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24,
            }),
        );
        Self { harness, surface, dir, writer, reader, next_id: 10 }
    }

    /// The view asks for `size`; returns once the daemon answered, not once
    /// the host applied it (the hosted path is asynchronous).
    fn resize(&mut self, (cols, rows): (u16, u16)) {
        self.next_id += 1;
        stream_request(
            &mut self.writer,
            &mut self.reader,
            serde_json::json!({
                "id": self.next_id, "cmd": "resize-surface", "surface": self.surface,
                "cols": cols, "rows": rows,
            }),
        );
    }

    fn vt_size(&self) -> (u64, u64) {
        let state = request(
            &self.harness.socket,
            serde_json::json!({"cmd": "vt-state", "surface": self.surface}),
        );
        (state["cols"].as_u64().unwrap_or(0), state["rows"].as_u64().unwrap_or(0))
    }

    /// The size the child last read from its PTY, as (cols, rows).
    fn child_size(&self, file: &str) -> Option<(u16, u16)> {
        let text = fs::read_to_string(self.dir.join(file)).ok()?;
        let mut parts = text.split_whitespace();
        let rows = parts.next()?.parse().ok()?;
        let cols = parts.next()?.parse().ok()?;
        Some((cols, rows))
    }

    fn screen(&self) -> String {
        request(
            &self.harness.socket,
            serde_json::json!({"cmd": "read-screen", "surface": self.surface}),
        )["text"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    /// The host applied `size`: the mirror has the grid (after the host's
    /// `Resized` replay), the child read it after its SIGWINCH (from `file`),
    /// and `screen_ok` holds for what the viewport shows.
    fn settles_at(
        &self,
        size: (u16, u16),
        file: &str,
        step: &str,
        screen_ok: impl Fn(&str) -> bool,
    ) {
        let want = (u64::from(size.0), u64::from(size.1));
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        loop {
            let vt = self.vt_size();
            let child = self.child_size(file);
            if vt == want && child == Some(size) {
                let text = self.screen();
                if screen_ok(&text) {
                    return;
                }
                assert!(Instant::now() < deadline, "{step}: the screen at {size:?} is {text:?}");
            } else {
                assert!(
                    Instant::now() < deadline,
                    "{step}: the mirror is {vt:?} and the child reads {child:?}, the view asked {size:?}"
                );
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// No late replay moves the grid off `size` for `window`.
    fn stays_at(&self, size: (u16, u16), window: Duration, step: &str) {
        let want = (u64::from(size.0), u64::from(size.1));
        let end = Instant::now() + window;
        while Instant::now() < end {
            assert_eq!(self.vt_size(), want, "{step}: a late replay moved the grid");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

/// The last non-empty line on screen is the newest history line: a resize
/// left the viewport at the bottom.
fn shows_newest(text: &str) -> bool {
    text.lines().rev().map(str::trim_end).find(|line| !line.is_empty()) == Some("hist 0299")
}

/// Grow, shrink, small, large and back on a hosted terminal: after each size
/// the host's replay gives the mirror the grid, the child reads it, and the
/// viewport still shows the newest line.
#[test]
fn hosted_resize_sequence_settles_mirror_child_and_viewport_at_each_size() {
    let mut terminal = HostedTerminal::start("hosted-resize-steps", SIZE_LOGGER);
    terminal.settles_at((80, 24), "size", "start", shows_newest);
    let steps: [(u16, u16); 8] =
        [(100, 30), (160, 50), (60, 20), (20, 8), (250, 80), (41, 12), (120, 40), (80, 24)];
    for size in steps {
        terminal.resize(size);
        terminal.settles_at(
            size,
            "size",
            &format!("resize to {}x{}", size.0, size.1),
            shows_newest,
        );
    }
    terminal.stays_at((80, 24), Duration::from_millis(300), "after the sequence");
}

/// A window or divider drag on a hosted terminal: one size per frame, sent
/// without waiting for the host. The grid, the child and the screen end on
/// the last size, and no reordered replay of a size the drag passed through
/// arrives after it.
#[test]
fn hosted_resize_drag_burst_ends_on_the_last_size() {
    let mut terminal = HostedTerminal::start("hosted-resize-drag", SIZE_LOGGER);
    terminal.settles_at((80, 24), "size", "start", shows_newest);
    for frame in 0..120u16 {
        let phase = frame % 60;
        let delta = if phase < 30 { phase } else { 60 - phase };
        terminal.resize((40 + delta * 3, 12 + delta / 2));
    }
    terminal.resize((97, 31));
    terminal.settles_at((97, 31), "size", "drag end", shows_newest);
    terminal.stays_at((97, 31), Duration::from_millis(500), "after the drag");
}

/// A full-screen program on the alternate screen of a hosted terminal
/// redraws every row for each new size, after single resizes and after a
/// drag burst; the frame on screen is the one for the final size.
#[test]
fn hosted_alternate_screen_program_redraws_for_the_final_size() {
    const PROGRAM: &str = r#"
dir=$1
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
resized=0
trap 'resized=1' WINCH
draw
while :; do
  if [ $resized = 1 ]; then resized=0; draw; fi
  sleep 0.02
done
"#;
    let frame_for = |(cols, rows): (u16, u16)| {
        move |text: &str| {
            let label = format!("{cols}x{rows}");
            text.lines().count() == usize::from(rows)
                && text
                    .lines()
                    .enumerate()
                    .all(|(i, line)| line.trim_end() == format!("r{} {label}", i + 1))
        }
    };
    let mut terminal = HostedTerminal::start("hosted-resize-alt", PROGRAM);
    terminal.settles_at((80, 24), "drawn", "start", frame_for((80, 24)));
    for size in [(120, 40), (60, 20), (200, 60), (30, 10), (100, 30)] {
        terminal.resize(size);
        terminal.settles_at(
            size,
            "drawn",
            &format!("resize to {}x{}", size.0, size.1),
            frame_for(size),
        );
    }
    for frame in 0..60u16 {
        terminal.resize((40 + frame, 12 + frame / 4));
    }
    terminal.resize((80, 24));
    terminal.settles_at((80, 24), "drawn", "after a drag burst", frame_for((80, 24)));
    terminal.stays_at((80, 24), Duration::from_millis(300), "after the drag burst");
}
