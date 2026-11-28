//! `cmux-tui __scroll-probe --socket PATH`: the terminal scroll-integrity probe
//! (goal terminal-scroll-integrity: 0 blank or missing rows and 0 viewport
//! jumps while scrolled up, on local, SSH and Cloud terminals).
//!
//! Given any daemon protocol socket (a local session, the local socket of
//! `remote connect ssh://…`, or `carrier serve`'s socket for a Cloud machine)
//! it creates one terminal, runs a generator in it that prints strictly
//! numbered rows, and watches two views of that terminal while it is scrolled
//! back and output keeps coming:
//!
//! - `mirror`: a byte attach (`attach-surface` `mode:"bytes"`, the attach the
//!   Mac app's surface and `cmux-tui remote` use) fed into its own ghostty-vt
//!   terminal, which the probe scrolls itself. Byte clients keep their own
//!   scroll position (spec/render.md).
//! - `daemon`: a render attach (`mode:"render"`) of the daemon's shared render
//!   viewport, scrolled with `scroll-surface`.
//!
//! For each view it counts `blank_rows` (an empty row where a numbered row
//! belongs), `missing_rows` (a gap in the numbers, or a row whose text is not
//! the row its number names) and `jumps` (the viewport's first row changed with
//! no scroll from the probe, or a scroll moved it by another amount than asked).
//! A viewport moved because the rows it showed were pruned from the scrollback
//! is counted as `pruned_moves`, not a jump.
//!
//! The stream has plain bursts, slow trickles, soft-wrapped long rows, a
//! TUI-style phase (a status block at the bottom redrawn in place with cursor
//! up, erase and synchronized output, numbered rows printed above it, as an
//! agent CLI does) and a long summary burst at the end. Mid-stream the probe
//! types a key (the daemon viewport snaps to the bottom on input, by design;
//! the byte mirror must not move), detaches and reattaches the byte client and
//! rebuilds its mirror from the replay at the anchor `session/remote.rs` keeps
//! (rows from the viewport top to the end), and stops reading the byte stream
//! for a while to see whether the daemon drops or resyncs it.
//!
//! The generator is POSIX `sh` and `awk`, so the far side of an SSH or Cloud
//! link needs no cmux build of its own. Output: one JSON report on stdout.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use ghostty_vt::{Callbacks, RenderState, Terminal};

use crate::session::{ScrolledBackAnchor, restore_scrolled_back_anchor, scrolled_back_anchor};
use serde_json::{Value, json};

pub(crate) const MODE: &str = "__scroll-probe";

const USAGE: &str = "usage: cmux-tui __scroll-probe --socket PATH [--surface-label NAME] [--json] \
[--cols N] [--rows N] [--scroll-up N] [--fill N] [--bursts N] [--burst-lines N] [--tui-batches N] \
[--summary-lines N] [--timeout-seconds N] [--keep-terminal]";

/// The marker the generator prints last.
const DONE_MARK: &[u8] = b"SCROLLPROBE-DONE";
/// Ghostty's default scrollback budget (bytes), which the Mac's surface and
/// the daemon both use (`DEFAULT_SCROLLBACK_LIMIT_BYTES`).
const MIRROR_SCROLLBACK_BYTES: usize = 10_000_000;
const STATUS_ROWS: u64 = 3;

#[derive(Clone)]
struct Options {
    socket: String,
    label: String,
    json: bool,
    cols: u16,
    rows: u16,
    scroll_up: i64,
    fill: u64,
    bursts: u64,
    burst_lines: u64,
    tui_batches: u64,
    summary_lines: u64,
    timeout: Duration,
    keep_terminal: bool,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self, String> {
        let mut options = Self {
            socket: String::new(),
            label: "local".into(),
            json: false,
            cols: 120,
            rows: 40,
            scroll_up: 60,
            fill: 600,
            bursts: 4,
            burst_lines: 300,
            tui_batches: 150,
            summary_lines: 800,
            timeout: Duration::from_secs(180),
            keep_terminal: false,
        };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let mut value = |name: &str| {
                it.next().cloned().ok_or_else(|| format!("{name} needs a value\n{USAGE}"))
            };
            let number = |name: &str, text: String| {
                text.parse::<u64>().map_err(|_| format!("{name}: not a number: {text}"))
            };
            match arg.as_str() {
                "--socket" => options.socket = value("--socket")?,
                "--surface-label" => options.label = value("--surface-label")?,
                "--json" => options.json = true,
                "--keep-terminal" => options.keep_terminal = true,
                "--cols" => {
                    options.cols = number("--cols", value("--cols")?)?.clamp(40, 500) as u16;
                }
                "--rows" => {
                    options.rows = number("--rows", value("--rows")?)?.clamp(10, 200) as u16;
                }
                "--scroll-up" => {
                    options.scroll_up = number("--scroll-up", value("--scroll-up")?)? as i64;
                }
                "--fill" => options.fill = number("--fill", value("--fill")?)?,
                "--bursts" => options.bursts = number("--bursts", value("--bursts")?)?,
                "--burst-lines" => {
                    options.burst_lines = number("--burst-lines", value("--burst-lines")?)?;
                }
                "--tui-batches" => {
                    options.tui_batches = number("--tui-batches", value("--tui-batches")?)?;
                }
                "--summary-lines" => {
                    options.summary_lines = number("--summary-lines", value("--summary-lines")?)?;
                }
                "--timeout-seconds" => {
                    options.timeout = Duration::from_secs(number(
                        "--timeout-seconds",
                        value("--timeout-seconds")?,
                    )?);
                }
                "-h" | "--help" => return Err(USAGE.into()),
                other => return Err(format!("unknown argument {other}\n{USAGE}")),
            }
        }
        if options.socket.is_empty() {
            return Err(format!("--socket is required\n{USAGE}"));
        }
        // The scroll must leave the live screen entirely and keep room to
        // scroll further both ways while streaming.
        options.scroll_up = options.scroll_up.max(i64::from(options.rows) + 10);
        options.fill = options.fill.max(options.scroll_up as u64 * 3);
        Ok(options)
    }
}

pub(crate) fn run(args: &[String]) -> i32 {
    let options = match Options::parse(args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            return 2;
        }
    };
    match std::thread::scope(|scope| Probe::run(&options, scope)) {
        Ok(report) => {
            if options.json {
                println!("{report}");
            } else {
                println!("{}", serde_json::to_string_pretty(&report).unwrap_or_default());
            }
            0
        }
        Err(error) => {
            eprintln!("scroll-probe: {error}");
            1
        }
    }
}

// ---------- the numbered stream (shared by the generator and the checker) ----------

/// Rows line `n` takes at the probe's width: one, or 2..5 soft-wrapped rows
/// for every ninth line.
fn segments(n: u64) -> u64 {
    if n % 9 == 4 { 2 + n % 4 } else { 1 }
}

fn fill_char(n: u64) -> char {
    char::from(b'a' + (n % 26) as u8)
}

/// The text of row `k` of line `n`, trailing spaces trimmed. A wrapped line
/// is written as one string exactly `cols` wide per row, so every row starts
/// with its own marker (`L0000042 ` or `+0000042/1 `).
fn expected_row(n: u64, k: u64, cols: u64) -> String {
    let c = fill_char(n);
    let segs = segments(n);
    let (head, fill) = if segs == 1 {
        (format!("L{n:07} "), (n * 37) % (cols - 20))
    } else if k == 0 {
        (format!("L{n:07} "), cols - 9)
    } else if k + 1 < segs {
        (format!("+{n:07}/{k} "), cols - 11)
    } else {
        (format!("+{n:07}/{k} "), (n * 13) % (cols - 40))
    };
    let mut row = head;
    row.extend(std::iter::repeat_n(c, fill as usize));
    row.trim_end().to_string()
}

/// The generator: `sh` and `awk` only. `go` on its input starts the stream
/// after the fill; echo is off so typed input never reaches the screen.
fn generator_script(o: &Options) -> String {
    let cols = u64::from(o.cols);
    let awk_line = format!(
        r#"function rep(c,k,  s){{s="";while(k-->0)s=s c;return s}}
function line(n,  c,s,o,k,m){{c=sprintf("%c",97+n%26);s=(n%9==4)?2+n%4:1;
if(s==1)return sprintf("L%07d ",n) rep(c,(n*37)%{single});
o=sprintf("L%07d ",n) rep(c,{first});
for(k=1;k<s;k++){{m=sprintf("+%07d/%d ",n,k);o=o m rep(c,(k<s-1)?{middle}:(n*13)%{last})}}
return o}}"#,
        single = cols - 20,
        first = cols - 9,
        middle = cols - 11,
        last = cols - 40,
    );
    let plain = |from: &str, to: &str| {
        format!("awk -v a={from} -v b={to} '{awk_line}\nBEGIN{{for(n=a;n<b;n++)print line(n)}}'")
    };
    // The TUI phase: a status block at the bottom, redrawn in place. Each
    // batch moves up over the block, erases to the end of the screen, prints
    // three numbered lines where it was and draws the block again below
    // them, inside a synchronized update (DEC 2026), as an agent CLI does.
    let h = STATUS_ROWS;
    let tui = format!(
        "awk -v a=\"$1\" -v b=\"$2\" '{awk_line}\nBEGIN{{drawn=0;for(n=a;n<b;n+=3){{\
if(drawn)printf \"\\033[{h}A\\r\\033[J\";printf \"\\033[?2026h\";\
for(i=n;i<n+3&&i<b;i++)print line(i);\
for(j=0;j<{h};j++)printf \"STATUS %d/{h} working on line %d %s\\n\",j+1,n,substr(\"|/-\\\\\",n%4+1,1);\
printf \"\\033[?2026l\";drawn=1;fflush();system(\"sleep 0.01\")}}\
printf \"\\033[{h}A\\r\\033[J\"}}'",
    );
    let fill_end = 1 + o.fill;
    let mut next = fill_end;
    let mut body = String::new();
    for _ in 0..o.bursts {
        let burst_end = next + o.burst_lines;
        body.push_str(&format!("{}\n", plain(&next.to_string(), &burst_end.to_string())));
        next = burst_end;
        // A trickle: ten batches of three lines, 20 ms apart.
        for _ in 0..10 {
            body.push_str(&format!(
                "{}\nsleep 0.02\n",
                plain(&next.to_string(), &(next + 3).to_string())
            ));
            next += 3;
        }
    }
    let tui_end = next + 3 * o.tui_batches;
    body.push_str(&format!("tui {next} {tui_end}\n"));
    next = tui_end;
    let summary_end = next + o.summary_lines;
    body.push_str(&format!("{}\n", plain(&next.to_string(), &summary_end.to_string())));
    format!(
        "stty -echo 2>/dev/null\ntui() {{ {tui}; }}\n{fill}\nread go\nsleep 1\n{body}\
printf 'SCROLLPROBE-DONE {last}\\n'\nexec sleep 600\n",
        fill = plain("1", &fill_end.to_string()),
        last = summary_end - 1,
    )
}

/// The lines the generator prints in total (1-based, inclusive).
fn last_line(o: &Options) -> u64 {
    o.fill + o.bursts * (o.burst_lines + 30) + 3 * o.tui_batches + o.summary_lines
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Row {
    Blank,
    Numbered { n: u64, k: u64, intact: bool },
    Other,
}

fn parse_row(text: &str, cols: u64) -> Row {
    if text.is_empty() {
        return Row::Blank;
    }
    let bytes = text.as_bytes();
    let digits = |from: usize| {
        text.get(from..from + 7)
            .filter(|s| s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse::<u64>().ok())
    };
    let (n, k) = match bytes.first() {
        Some(b'L') => match digits(1) {
            Some(n) => (n, 0),
            None => return Row::Other,
        },
        Some(b'+') => {
            match (digits(1), bytes.get(8), text.get(9..10).and_then(|s| s.parse::<u64>().ok())) {
                (Some(n), Some(b'/'), Some(k)) => (n, k),
                _ => return Row::Other,
            }
        }
        _ => return Row::Other,
    };
    let intact = k < segments(n) && text == expected_row(n, k, cols);
    Row::Numbered { n, k, intact }
}

/// The row index of `(n, k)` in the whole stream.
struct Ordinals(Vec<u64>);

impl Ordinals {
    fn new(last: u64) -> Self {
        let mut starts = Vec::with_capacity(last as usize + 2);
        starts.push(0); // line 0 does not exist
        let mut at = 0;
        for n in 1..=last + 1 {
            starts.push(at);
            at += segments(n);
        }
        Self(starts)
    }

    fn of(&self, n: u64, k: u64) -> Option<u64> {
        self.0.get(n as usize).filter(|_| n >= 1).map(|start| start + k)
    }
}

#[derive(Default, Clone, Copy)]
struct Defects {
    blank: u64,
    missing: u64,
}

/// Checks one viewport: numbered rows must follow each other with no gap and
/// no blank between them. Below the last numbered row, blank, status and
/// other rows are the live screen's own (the cursor's row, the status block,
/// the done line) and pass only when the viewport reaches the live bottom.
/// Returns the defects and the first row's stream index.
fn check_viewport(
    rows: &[String],
    at_bottom: bool,
    cols: u64,
    ordinals: &Ordinals,
) -> (Defects, Option<u64>) {
    let parsed: Vec<Row> = rows.iter().map(|r| parse_row(r, cols)).collect();
    let mut defects = Defects::default();
    let last_numbered = parsed.iter().rposition(|r| matches!(r, Row::Numbered { .. }));
    let Some(last_numbered) = last_numbered else {
        // No numbered row at all: a blank viewport while scrolled back.
        if !at_bottom {
            defects.blank += parsed.iter().filter(|r| **r == Row::Blank).count() as u64;
            defects.missing += parsed.iter().filter(|r| **r == Row::Other).count() as u64;
        }
        return (defects, None);
    };
    let first_numbered = parsed.iter().position(|r| matches!(r, Row::Numbered { .. })).unwrap_or(0);
    let mut expected: Option<u64> = None;
    let mut top = None;
    for (index, row) in parsed.iter().enumerate() {
        let tail = index > last_numbered;
        if tail && at_bottom {
            break;
        }
        match row {
            Row::Numbered { n, k, intact } => {
                let at = ordinals.of(*n, *k);
                if index == first_numbered {
                    top = at.map(|at| at.saturating_sub(index as u64));
                    // Rows above the first numbered row: nothing may precede line 1.
                    defects.missing += index as u64;
                } else if at != expected {
                    defects.missing += 1;
                }
                if !intact {
                    defects.missing += 1;
                }
                expected = at.map(|at| at + 1);
            }
            Row::Blank if index > first_numbered => {
                defects.blank += 1;
                expected = expected.map(|e| e + 1);
            }
            Row::Other if index > first_numbered => {
                defects.missing += 1;
                expected = expected.map(|e| e + 1);
            }
            _ => {}
        }
    }
    (defects, top)
}

// ---------- the daemon connections ----------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Conn {
    Control,
    Bytes(u32),
    Render,
}

struct Link {
    conn: Conn,
    writer: UnixStream,
    paused: Arc<AtomicBool>,
}

/// A link's reader thread runs in the probe's `std::thread::scope`, which
/// joins it: shutting the socket down ends its read, so a dropped link (a
/// replaced or finished connection) never keeps the scope open.
impl Drop for Link {
    fn drop(&mut self) {
        self.paused.store(false, Ordering::Relaxed);
        let _ = self.writer.shutdown(std::net::Shutdown::Both);
    }
}

fn open<'s, 'e>(
    scope: &'s std::thread::Scope<'s, 'e>,
    socket: &str,
    conn: Conn,
    events: &mpsc::Sender<(Conn, Option<Value>)>,
) -> Result<Link, String> {
    let stream = UnixStream::connect(socket).map_err(|e| format!("connect {socket}: {e}"))?;
    let reader = stream.try_clone().map_err(|e| e.to_string())?;
    let paused = Arc::new(AtomicBool::new(false));
    let paused_reader = paused.clone();
    let events = events.clone();
    scope.spawn(move || {
        let mut reader = BufReader::with_capacity(1 << 16, reader);
        let mut line = String::new();
        loop {
            while paused_reader.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(10));
            }
            line.clear();
            match reader.read_line(&mut line) {
                Ok(n) if n > 0 => {
                    let value = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
                    if events.send((conn, Some(value))).is_err() {
                        return;
                    }
                }
                _ => {
                    let _ = events.send((conn, None));
                    return;
                }
            }
        }
    });
    Ok(Link { conn, writer: stream, paused })
}

// ---------- the views ----------

struct Mirror {
    term: Terminal,
    render: RenderState,
    attach: u32,
    alive: bool,
    /// The last checked viewport, so an unchanged one is not counted twice.
    last_rows: Vec<String>,
    /// The first row's stream index when the probe last placed the viewport.
    top: Option<u64>,
    /// The last check found the viewport scrolled back.
    was_back: bool,
    done_tail: Vec<u8>,
}

impl Mirror {
    fn from_replay(
        cols: u16,
        rows: u16,
        replay: &[u8],
        pending: &[u8],
        attach: u32,
    ) -> Result<Self, String> {
        let mut term = Terminal::new(cols, rows, MIRROR_SCROLLBACK_BYTES, Callbacks::default())
            .map_err(|e| format!("mirror terminal: {e}"))?;
        term.vt_write(replay);
        term.vt_write(pending);
        let render = RenderState::new().map_err(|e| format!("render state: {e}"))?;
        Ok(Self {
            term,
            render,
            attach,
            alive: true,
            last_rows: Vec::new(),
            top: None,
            was_back: false,
            done_tail: Vec::new(),
        })
    }

    /// The viewport's rows, or None when they can't be read (counted, never a clean sample).
    fn rows(&mut self) -> Option<Vec<String>> {
        self.render.update(&mut self.term).ok()?;
        self.render.text_lines().ok()
    }

    fn at_bottom(&self) -> bool {
        self.term.scrollbar().is_none_or(|s| !s.scrolled_back())
    }

    /// `session/remote.rs`' own anchor, so the probe measures what the app does.
    fn anchor(&mut self) -> Option<ScrolledBackAnchor> {
        scrolled_back_anchor(&mut self.term)
    }

    fn restore_anchor(&mut self, anchor: &ScrolledBackAnchor) {
        restore_scrolled_back_anchor(&mut self.term, anchor);
    }
}

#[derive(Default)]
struct DaemonView {
    rows: Vec<String>,
    cols: u64,
    at_bottom: bool,
    offset: u64,
    scrollback_rows: u64,
    alive: bool,
    /// scroll-surface calls whose scroll-changed has not come yet.
    solicited: u32,
    /// The stream index the probe's last scroll should bring to the top.
    expect_top: Option<u64>,
    /// Input was sent: the next move to the bottom is the documented snap.
    expect_snap: bool,
    top: Option<u64>,
    last_checked: Vec<String>,
    /// The last checked frame was scrolled back.
    was_back: bool,
}

impl DaemonView {
    fn apply(&mut self, event: &Value) {
        if let Some(size) = event.get("size") {
            let rows = size.get("rows").and_then(Value::as_u64).unwrap_or(0) as usize;
            self.cols = size.get("cols").and_then(Value::as_u64).unwrap_or(self.cols);
            self.rows = vec![String::new(); rows];
        }
        if event.get("full").and_then(Value::as_bool) == Some(true)
            || event.get("event").and_then(Value::as_str) == Some("render-state")
        {
            self.rows.iter_mut().for_each(String::clear);
        }
        if let Some(n) = event.get("scrollback_rows").and_then(Value::as_u64) {
            self.scrollback_rows = n;
        }
        for row in event.get("rows").and_then(Value::as_array).into_iter().flatten() {
            let Some(index) = row.get("row").and_then(Value::as_u64) else { continue };
            let text: String = row
                .get("runs")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|run| run.get("text").and_then(Value::as_str))
                .collect();
            if let Some(slot) = self.rows.get_mut(index as usize) {
                *slot = text.trim_end().to_string();
            }
        }
    }
}

#[derive(Default)]
struct ViewCounts {
    blank_rows: u64,
    missing_rows: u64,
    jumps: u64,
    pruned_moves: u64,
    samples: u64,
    /// Samples taken while scrolled back: the ones the goal is about.
    scrolled_samples: u64,
    /// Viewports that could not be read.
    read_errors: u64,
    notes: Vec<String>,
}

impl ViewCounts {
    fn json(&self) -> Value {
        json!({
            "blank_rows": self.blank_rows,
            "missing_rows": self.missing_rows,
            "jumps": self.jumps,
            "bad": self.blank_rows + self.missing_rows + self.jumps,
            "pruned_moves": self.pruned_moves,
            "samples": self.samples,
            "scrolled_samples": self.scrolled_samples,
            "read_errors": self.read_errors,
            "notes": self.notes.iter().take(40).collect::<Vec<_>>(),
        })
    }

    fn note(&mut self, text: String) {
        if self.notes.len() < 200 {
            self.notes.push(text);
        }
    }
}

// ---------- the run ----------

struct Probe<'s, 'e> {
    scope: &'s std::thread::Scope<'s, 'e>,
    o: Options,
    events: mpsc::Receiver<(Conn, Option<Value>)>,
    sender: mpsc::Sender<(Conn, Option<Value>)>,
    control: Link,
    bytes: Option<Link>,
    render: Option<Link>,
    next_id: u64,
    surface: u64,
    ordinals: Ordinals,
    mirror: Option<Mirror>,
    daemon: DaemonView,
    m: ViewCounts,
    d: ViewCounts,
    done: bool,
    output_events: u64,
    output_bytes: u64,
    attaches: u32,
    reattach: Vec<Value>,
    stall: Value,
    snap_on_input: Option<bool>,
    mirror_after_input_moved: Option<bool>,
    unsolicited_scroll_changed: u64,
    resized: u64,
    overflow: u64,
    max_scrollback_seen: u64,
    newest: u64,
}

impl<'s, 'e> Probe<'s, 'e> {
    fn run(o: &Options, scope: &'s std::thread::Scope<'s, 'e>) -> Result<Value, String> {
        let (sender, events) = mpsc::channel();
        let control = open(scope, &o.socket, Conn::Control, &sender)?;
        let mut probe = Probe {
            scope,
            o: o.clone(),
            events,
            sender,
            control,
            bytes: None,
            render: None,
            next_id: 1,
            surface: 0,
            ordinals: Ordinals::new(last_line(o)),
            mirror: None,
            daemon: DaemonView { at_bottom: true, alive: true, ..DaemonView::default() },
            m: ViewCounts::default(),
            d: ViewCounts::default(),
            done: false,
            output_events: 0,
            output_bytes: 0,
            attaches: 0,
            reattach: Vec::new(),
            stall: Value::Null,
            snap_on_input: None,
            mirror_after_input_moved: None,
            unsolicited_scroll_changed: 0,
            resized: 0,
            overflow: 0,
            max_scrollback_seen: 0,
            newest: 0,
        };
        let started = Instant::now();
        // A link socket (`remote connect --local-socket`) answers before its
        // first dial ends: retry identify on a fresh connection for up to 60 s.
        let mut identity =
            probe.request_within(Conn::Control, json!({"cmd": "identify"}), Duration::from_secs(5));
        while identity.is_err() && started.elapsed() < Duration::from_secs(60) {
            std::thread::sleep(Duration::from_millis(500));
            probe.control = open(probe.scope, &o.socket, Conn::Control, &probe.sender)?;
            identity = probe.request_within(
                Conn::Control,
                json!({"cmd": "identify"}),
                Duration::from_secs(5),
            );
        }
        let identity = identity?;
        let protocol = identity.get("protocol").and_then(Value::as_u64).unwrap_or(0);
        if protocol < 7 {
            return Err(format!("the daemon speaks protocol {protocol}; the render view needs 7"));
        }
        let name = format!("scroll-probe-{}", std::process::id());
        let workspace =
            probe.request(Conn::Control, json!({"cmd": "create-workspace", "name": name}))?;
        let key = workspace
            .get("key")
            .and_then(Value::as_str)
            .ok_or("create-workspace: no key")?
            .to_string();
        let created = probe.request(
            Conn::Control,
            json!({"cmd": "create-terminal", "key": key, "name": name,
                   "argv": ["/bin/sh", "-c", generator_script(o)], "cols": o.cols, "rows": o.rows}),
        )?;
        probe.surface =
            created.get("surface").and_then(Value::as_u64).ok_or("create-terminal: no surface")?;
        let terminal_id = created.get("terminal_id").cloned().unwrap_or(Value::Null);
        let result = probe.drive(started);
        let unvouched = probe.unvouched();
        if !o.keep_terminal {
            let _ = probe.request(
                Conn::Control,
                json!({"cmd": "close-terminal", "terminal_id": terminal_id}),
            );
            let _ = probe.request(Conn::Control, json!({"cmd": "close-workspace", "key": key}));
        }
        result?;
        if !unvouched.is_empty() {
            // A view that never looked while scrolled back, or could not look,
            // measured nothing: no rows, so the surface reads unknown, never 0.
            return Err(format!("the run cannot vouch for its counts: {}", unvouched.join("; ")));
        }
        Ok(probe.report(protocol, identity.get("version").cloned().unwrap_or(Value::Null), started))
    }

    fn drive(&mut self, started: Instant) -> Result<(), String> {
        let deadline = started + self.o.timeout;
        self.attach_bytes()?;
        self.attach_render()?;
        // The fill: wait until the mirror's bottom shows the fill's last line.
        let fill_last =
            expected_row(self.o.fill, segments(self.o.fill) - 1, u64::from(self.o.cols));
        self.pump_until(deadline, |p| p.mirror_rows().contains(&fill_last))?;
        // Start the stream, then scroll both views up before it begins (the
        // generator sleeps 1 s after `go`). Input snaps the daemon viewport to
        // the bottom, so it goes first.
        self.request(
            Conn::Control,
            json!({"cmd": "send", "surface": self.surface, "text": "go\n"}),
        )?;
        self.pump_for(Duration::from_millis(150))?;
        let up = -self.o.scroll_up;
        self.scroll_mirror(up as isize);
        self.scroll_daemon(up)?;
        let tui_first = 1 + self.o.fill + self.o.bursts * (self.o.burst_lines + 30);
        let mid = self.o.fill + self.o.bursts * (self.o.burst_lines + 30) / 2;
        let mut step = 0u64;
        let mut typed = false;
        let mut reattached = false;
        let mut stalled = false;
        let mut tui_reattached = false;
        while !self.done {
            if Instant::now() > deadline {
                return Err(format!("the stream did not finish within {:?}", self.o.timeout));
            }
            self.pump_for(Duration::from_millis(16))?;
            step += 1;
            // Scroll while streaming: 3 rows up, then 3 down, staying back.
            if step.is_multiple_of(25) {
                let delta = if (step / 25) % 2 == 1 { -3 } else { 3 };
                self.scroll_mirror(delta);
                self.scroll_daemon(delta as i64)?;
            }
            let seen = self.newest_line();
            if !typed && seen >= mid {
                typed = true;
                self.type_while_scrolled(deadline)?;
            }
            if !reattached && seen >= mid + self.o.burst_lines / 2 {
                reattached = true;
                self.detach_and_reattach("mid-stream", Duration::from_millis(300))?;
            }
            if !stalled && seen >= mid + self.o.burst_lines {
                stalled = true;
                self.stall_bytes(Duration::from_millis(2500))?;
            }
            if !tui_reattached && seen >= tui_first + self.o.tui_batches {
                tui_reattached = true;
                self.detach_and_reattach("tui-phase", Duration::from_millis(200))?;
            }
        }
        // Let the last frames land, then read both views once more.
        self.pump_for(Duration::from_millis(500))?;
        self.check_mirror(false);
        self.check_daemon();
        Ok(())
    }

    // ----- protocol -----

    fn link(&mut self, conn: Conn) -> Option<&mut Link> {
        match conn {
            Conn::Control => Some(&mut self.control),
            Conn::Bytes(_) => self.bytes.as_mut().filter(|l| l.conn == conn),
            Conn::Render => self.render.as_mut(),
        }
    }

    fn send(&mut self, conn: Conn, mut request: Value) -> Result<u64, String> {
        let id = self.next_id;
        self.next_id += 1;
        if let Some(fields) = request.as_object_mut() {
            fields.insert("id".into(), json!(id));
        }
        let link = self.link(conn).ok_or_else(|| format!("{conn:?} is closed"))?;
        let mut line = request.to_string();
        line.push('\n');
        link.writer.write_all(line.as_bytes()).map_err(|e| format!("{conn:?} write: {e}"))?;
        Ok(id)
    }

    fn request(&mut self, conn: Conn, request: Value) -> Result<Value, String> {
        self.request_within(conn, request, Duration::from_secs(30))
    }

    fn request_within(
        &mut self,
        conn: Conn,
        request: Value,
        limit: Duration,
    ) -> Result<Value, String> {
        let cmd = request.get("cmd").and_then(Value::as_str).unwrap_or("?").to_string();
        let id = self.send(conn, request)?;
        let deadline = Instant::now() + limit;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let (from, message) = self
                .events
                .recv_timeout(left)
                .map_err(|_| format!("{cmd}: no answer in {limit:?}"))?;
            let Some(message) = message else {
                self.closed(from);
                // A replaced control connection's end can arrive late; the deadline covers the live one.
                if from == conn && conn != Conn::Control {
                    return Err(format!("{cmd}: the connection closed"));
                }
                continue;
            };
            if from == conn && message.get("id").and_then(Value::as_u64) == Some(id) {
                if message.get("ok").and_then(Value::as_bool) != Some(true) {
                    return Err(format!("{cmd}: {message}"));
                }
                return Ok(message.get("data").cloned().unwrap_or(Value::Null));
            }
            self.handle(from, message);
        }
    }

    fn pump_for(&mut self, period: Duration) -> Result<(), String> {
        let until = Instant::now() + period;
        loop {
            let left = until.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(left) {
                Ok((from, Some(message))) => self.handle(from, message),
                Ok((from, None)) => self.closed(from),
                Err(mpsc::RecvTimeoutError::Timeout) => return Ok(()),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err("event channel closed".into());
                }
            }
        }
    }

    fn pump_until(
        &mut self,
        deadline: Instant,
        mut done: impl FnMut(&mut Self) -> bool,
    ) -> Result<(), String> {
        while !done(self) {
            if Instant::now() > deadline {
                return Err("timed out waiting for the generator's fill".into());
            }
            self.pump_for(Duration::from_millis(20))?;
        }
        Ok(())
    }

    fn attach_bytes(&mut self) -> Result<(), String> {
        self.attaches += 1;
        let conn = Conn::Bytes(self.attaches);
        let link = open(self.scope, &self.o.socket.clone(), conn, &self.sender.clone())?;
        self.bytes = Some(link);
        self.request(conn, json!({"cmd": "identify"}))?;
        self.request(
            conn,
            json!({"cmd": "attach-surface", "surface": self.surface, "mode": "bytes"}),
        )?;
        // vt-state precedes the answer, so the mirror exists now.
        if self.mirror.as_ref().is_none_or(|m| m.attach != self.attaches) {
            return Err("attach-surface answered without a vt-state".into());
        }
        Ok(())
    }

    fn attach_render(&mut self) -> Result<(), String> {
        let link = open(self.scope, &self.o.socket.clone(), Conn::Render, &self.sender.clone())?;
        self.render = Some(link);
        self.request(Conn::Render, json!({"cmd": "identify"}))?;
        self.request(
            Conn::Render,
            json!({"cmd": "attach-surface", "surface": self.surface, "mode": "render"}),
        )?;
        Ok(())
    }

    fn closed(&mut self, from: Conn) {
        match from {
            Conn::Bytes(n) => {
                if let Some(m) = self.mirror.as_mut().filter(|m| m.attach == n) {
                    m.alive = false;
                }
            }
            Conn::Render => self.daemon.alive = false,
            Conn::Control => {}
        }
    }

    fn handle(&mut self, from: Conn, message: Value) {
        let event = message.get("event").and_then(Value::as_str).unwrap_or("");
        match (from, event) {
            (Conn::Bytes(n), _) if self.attaches != n => {} // an old attach's tail
            (Conn::Bytes(n), "vt-state") | (Conn::Bytes(n), "resized") => {
                if event == "resized" {
                    self.resized += 1;
                }
                let decode = |key: &str| {
                    message
                        .get(key)
                        .and_then(Value::as_str)
                        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                        .unwrap_or_default()
                };
                let replay = if event == "resized" && message.get("replay").is_some() {
                    decode("replay")
                } else {
                    decode("data")
                };
                let cols =
                    message.get("cols").and_then(Value::as_u64).unwrap_or(u64::from(self.o.cols))
                        as u16;
                let rows =
                    message.get("rows").and_then(Value::as_u64).unwrap_or(u64::from(self.o.rows))
                        as u16;
                // A fresh state on the live attach (a resync, not the probe's
                // reattach) that drops a scrolled-back viewport is a jump; the
                // anchor is restored so the run goes on scrolled back.
                let resync_anchor = self
                    .mirror
                    .as_mut()
                    .filter(|m| m.attach == n && m.was_back)
                    .and_then(Mirror::anchor);
                match Mirror::from_replay(cols, rows, &replay, &decode("pending"), n) {
                    Ok(mut mirror) => {
                        if let Some(anchor) = resync_anchor {
                            self.m.jumps += 1;
                            self.m.note(format!("mirror rebuilt by {event} while scrolled back"));
                            mirror.restore_anchor(&anchor);
                        }
                        self.mirror = Some(mirror);
                    }
                    Err(error) => self.m.note(format!("replay: {error}")),
                }
            }
            (Conn::Bytes(_), "output") => {
                let data = message
                    .get("data")
                    .and_then(Value::as_str)
                    .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                    .unwrap_or_default();
                self.output_events += 1;
                self.output_bytes += data.len() as u64;
                self.newest = self.newest.max(newest_number(&data));
                if let Some(m) = self.mirror.as_mut() {
                    m.term.vt_write(&data);
                    m.done_tail.extend_from_slice(&data);
                    if memchr_find(&m.done_tail, DONE_MARK) {
                        self.done = true;
                    }
                    let keep = m.done_tail.len().saturating_sub(DONE_MARK.len());
                    m.done_tail.drain(..keep);
                }
                self.check_mirror(false);
            }
            (Conn::Bytes(_), "overflow") | (Conn::Bytes(_), "detached") => {
                if event == "overflow" {
                    self.overflow += 1;
                }
                if let Some(m) = self.mirror.as_mut() {
                    m.alive = false;
                }
            }
            (Conn::Render, "render-state") | (Conn::Render, "render-delta") => {
                if self.daemon.cols == 0 {
                    self.daemon.cols = u64::from(self.o.cols);
                }
                self.daemon.apply(&message);
                self.max_scrollback_seen =
                    self.max_scrollback_seen.max(self.daemon.scrollback_rows);
                self.check_daemon();
            }
            (Conn::Render, "scroll-changed") => {
                let offset = message.get("offset").and_then(Value::as_u64).unwrap_or(0);
                let at_bottom = message.get("at_bottom").and_then(Value::as_bool).unwrap_or(true);
                if self.daemon.solicited > 0 {
                    self.daemon.solicited -= 1;
                } else if self.daemon.expect_snap && at_bottom {
                    self.snap_on_input = Some(true);
                    // The documented snap: not a jump even if its frame comes later.
                    self.daemon.was_back = false;
                } else {
                    self.unsolicited_scroll_changed += 1;
                    self.d.note(format!(
                        "unsolicited scroll-changed offset {}->{offset} at_bottom {}->{at_bottom}",
                        self.daemon.offset, self.daemon.at_bottom
                    ));
                }
                self.daemon.offset = offset;
                self.daemon.at_bottom = at_bottom;
            }
            (Conn::Render, "detached") => self.daemon.alive = false,
            _ => {}
        }
    }

    // ----- the two views -----

    fn mirror_rows(&mut self) -> Vec<String> {
        self.mirror.as_mut().and_then(Mirror::rows).unwrap_or_default()
    }

    /// The newest numbered line the byte stream has carried.
    fn newest_line(&self) -> u64 {
        self.newest
    }

    /// Checks the mirror's viewport. `moved_by_probe`: the probe just
    /// scrolled it, so a changed first row is expected (and checked against
    /// what was asked by the caller).
    fn check_mirror(&mut self, moved_by_probe: bool) -> Option<u64> {
        let cols = u64::from(self.o.cols);
        let m = self.mirror.as_mut()?;
        let Some(rows) = m.rows() else {
            self.m.read_errors += 1;
            self.m.note("mirror viewport could not be read".into());
            return m.top;
        };
        if rows == m.last_rows && !moved_by_probe {
            return m.top;
        }
        let at_bottom = m.at_bottom();
        let (defects, top) = check_viewport(&rows, at_bottom, cols, &self.ordinals);
        self.m.samples += 1;
        if defects.blank + defects.missing > 0 {
            self.m.blank_rows += defects.blank;
            self.m.missing_rows += defects.missing;
            self.m.note(format!(
                "mirror viewport blank {} missing {} at_bottom {at_bottom}: {:?}",
                defects.blank,
                defects.missing,
                rows.iter().map(|r| r.chars().take(14).collect::<String>()).collect::<Vec<_>>()
            ));
        }
        if !at_bottom {
            self.m.scrolled_samples += 1;
        }
        if !moved_by_probe && m.was_back && at_bottom {
            // Scrolled back, not moved by the probe, now at the bottom: the
            // jump to the bottom of cmux#37222.
            self.m.jumps += 1;
            self.m.note(format!("mirror snapped to the bottom from top {:?}", m.top));
        } else if !moved_by_probe && !at_bottom && m.top.is_some() && top != m.top {
            // Not moved by the probe: the viewport jumped, unless its rows
            // were pruned and Ghostty moved it to the oldest retained row.
            if m.term.scrollbar().is_some_and(|s| s.offset == 0) {
                self.m.pruned_moves += 1;
            } else {
                self.m.jumps += 1;
                self.m.note(format!("mirror jump: top {:?} -> {top:?}", m.top));
            }
        }
        m.last_rows = rows;
        m.was_back = !at_bottom;
        if !moved_by_probe && !at_bottom {
            m.top = top.or(m.top);
        }
        top
    }

    fn scroll_mirror(&mut self, delta: isize) {
        let before = self.check_mirror(false);
        let Some(m) = self.mirror.as_mut() else { return };
        m.term.scroll_delta(delta);
        let after = self.check_mirror(true);
        let Some(m) = self.mirror.as_mut() else { return };
        if let (Some(before), Some(after)) = (before, after)
            && after as i128 != before as i128 + delta as i128
        {
            self.m.jumps += 1;
            self.m.note(format!("mirror scroll {delta} moved the top {before} -> {after}"));
        }
        m.top = after;
    }

    fn check_daemon(&mut self) {
        let rows = self.daemon.rows.clone();
        if rows.is_empty() || rows == self.daemon.last_checked {
            return;
        }
        let at_bottom = self.daemon.at_bottom;
        let (defects, top) = check_viewport(&rows, at_bottom, self.daemon.cols, &self.ordinals);
        self.d.samples += 1;
        if defects.blank + defects.missing > 0 {
            self.d.blank_rows += defects.blank;
            self.d.missing_rows += defects.missing;
            self.d.note(format!(
                "daemon viewport blank {} missing {} at_bottom {at_bottom}: {:?}",
                defects.blank,
                defects.missing,
                rows.iter().map(|r| r.chars().take(14).collect::<String>()).collect::<Vec<_>>()
            ));
        }
        self.daemon.last_checked = rows;
        if !at_bottom {
            self.d.scrolled_samples += 1;
        }
        let snapped = at_bottom
            && self.daemon.was_back
            && !self.daemon.expect_snap
            && self.daemon.expect_top.is_none();
        self.daemon.was_back = !at_bottom;
        if snapped {
            self.d.jumps += 1;
            self.d.note(format!(
                "daemon snapped to the bottom from top {:?} with no input",
                self.daemon.top
            ));
            self.daemon.top = top;
            return;
        }
        if top == self.daemon.top {
            return;
        }
        if let Some(expected) = self.daemon.expect_top
            && top == Some(expected)
        {
            self.daemon.expect_top = None;
            self.daemon.top = top;
            return;
        }
        if self.daemon.expect_snap && at_bottom {
            self.daemon.top = top;
            return;
        }
        if !at_bottom && self.daemon.top.is_some() && self.daemon.expect_top.is_none() {
            if self.daemon.offset == 0 {
                self.d.pruned_moves += 1;
            } else {
                self.d.jumps += 1;
                self.d.note(format!(
                    "daemon jump: top {:?} -> {top:?} (offset {})",
                    self.daemon.top, self.daemon.offset
                ));
            }
        } else if self.daemon.expect_top.is_some() && !at_bottom {
            // A frame between the scroll and its own frame, or a scroll that
            // landed elsewhere: decided when the expected top shows or not.
            self.d
                .note(format!("daemon top {:?} while expecting {:?}", top, self.daemon.expect_top));
        }
        if !at_bottom {
            self.daemon.top = top;
        }
    }

    fn scroll_daemon(&mut self, delta: i64) -> Result<(), String> {
        if !self.daemon.alive {
            return Ok(());
        }
        // A scroll the daemon has not shown yet is a miss of its own.
        if let Some(missed) = self.daemon.expect_top.take() {
            self.d.jumps += 1;
            self.d.note(format!(
                "daemon scroll never showed top {missed}; it shows {:?}",
                self.daemon.top
            ));
        }
        self.daemon.expect_top = self.daemon.top.and_then(|t| u64::try_from(t as i64 + delta).ok());
        self.daemon.solicited += 1;
        self.request(
            Conn::Control,
            json!({"cmd": "scroll-surface", "surface": self.surface, "delta": delta}),
        )?;
        // From the bottom the first scroll's target is not known before it shows.
        if self.daemon.top.is_none() || self.daemon.at_bottom && delta < 0 {
            self.daemon.expect_top = None;
            self.pump_for(Duration::from_millis(100))?;
            self.daemon.top = self.daemon_top_now();
        }
        Ok(())
    }

    fn daemon_top_now(&self) -> Option<u64> {
        check_viewport(&self.daemon.rows, self.daemon.at_bottom, self.daemon.cols, &self.ordinals).1
    }

    /// Types a key while both views are scrolled back. The daemon viewport
    /// snaps to the bottom (spec/render.md: input snaps it back); the byte
    /// mirror is the client's own and must not move. Then the daemon view is
    /// scrolled back up again.
    fn type_while_scrolled(&mut self, _deadline: Instant) -> Result<(), String> {
        let mirror_top = self.check_mirror(false);
        self.daemon.expect_snap = true;
        self.snap_on_input = Some(false);
        self.request(Conn::Control, json!({"cmd": "send", "surface": self.surface, "text": "x"}))?;
        self.pump_for(Duration::from_millis(200))?;
        self.daemon.expect_snap = false;
        let after = self.check_mirror(false);
        self.mirror_after_input_moved = Some(after != mirror_top);
        if self.daemon.at_bottom {
            self.daemon.top = None;
            self.scroll_daemon(-self.o.scroll_up)?;
        }
        Ok(())
    }

    /// Drops the byte attach while output flows, attaches again, rebuilds the
    /// mirror from the replay and restores the scroll position the way
    /// `session/remote.rs` does (its own `restore_scrolled_back_anchor`).
    fn detach_and_reattach(&mut self, why: &str, gap: Duration) -> Result<(), String> {
        let before_top = self.check_mirror(false);
        let anchor = self.mirror.as_mut().and_then(Mirror::anchor);
        if let Some(link) = self.bytes.take() {
            let _ = link.writer.shutdown(std::net::Shutdown::Both);
        }
        self.pump_for(gap)?;
        self.attach_bytes()?;
        if let (Some(anchor), Some(m)) = (anchor.as_ref(), self.mirror.as_mut()) {
            m.restore_anchor(anchor);
        }
        let anchor = anchor.map(|a| a.rows_from_end);
        let after_top = self.check_mirror(true);
        let shift = match (before_top, after_top) {
            (Some(b), Some(a)) => Some(a as i64 - b as i64),
            _ => None,
        };
        if shift != Some(0) {
            self.m.jumps += 1;
            self.m.note(format!(
                "{why} reattach moved the viewport top {before_top:?} -> {after_top:?}"
            ));
        }
        if let Some(m) = self.mirror.as_mut() {
            m.top = after_top;
        }
        self.reattach.push(json!({"why": why, "gap_ms": gap.as_millis() as u64, "anchor_rows_from_end": anchor,
                                   "top_before": before_top, "top_after": after_top, "shift_rows": shift}));
        Ok(())
    }

    /// Stops reading the byte stream during output, then reads on. A daemon
    /// that drops the slow attach (`overflow`, `detached`, EOF) makes the
    /// client reattach, as the app does; that reattach is checked as above.
    fn stall_bytes(&mut self, period: Duration) -> Result<(), String> {
        let bytes_before = self.output_bytes;
        if let Some(link) = self.bytes.as_ref() {
            link.paused.store(true, Ordering::Relaxed);
        }
        self.pump_for(period)?;
        if let Some(link) = self.bytes.as_ref() {
            link.paused.store(false, Ordering::Relaxed);
        }
        self.pump_for(Duration::from_millis(300))?;
        let dropped = self.mirror.as_ref().is_some_and(|m| !m.alive);
        self.stall = json!({"ms": period.as_millis() as u64, "dropped": dropped,
                            "bytes_after_resume": self.output_bytes - bytes_before});
        if dropped {
            self.detach_and_reattach("after-stall", Duration::ZERO)?;
        }
        Ok(())
    }

    /// Why the counts can't stand for the run, if they can't.
    fn unvouched(&self) -> Vec<String> {
        let mut why = Vec::new();
        for (name, view) in [("mirror", &self.m), ("daemon", &self.d)] {
            if view.scrolled_samples == 0 {
                why.push(format!("{name}: no sample while scrolled back"));
            }
            if view.read_errors > 0 {
                why.push(format!("{name}: {} viewports could not be read", view.read_errors));
            }
        }
        if !self.daemon.alive {
            why.push("daemon: the render attach ended mid-run".into());
        }
        why
    }

    fn report(&self, protocol: u64, version: Value, started: Instant) -> Value {
        let mirror = self.m.json();
        let daemon = self.d.json();
        let bad_of = |view: &Value| view.get("bad").and_then(Value::as_u64).unwrap_or(0);
        let bad = bad_of(&mirror) + bad_of(&daemon);
        let total_rows =
            self.ordinals.of(last_line(&self.o), segments(last_line(&self.o)) - 1).unwrap_or(0) + 1;
        let mirror_total = self.mirror.as_ref().and_then(|m| m.term.scrollbar()).map(|s| s.total);
        json!({
            "surface": self.o.label,
            "bad": bad,
            "views": {"mirror": mirror, "daemon": daemon},
            "stream": {
                "lines": last_line(&self.o), "rows": total_rows, "cols": self.o.cols, "screen_rows": self.o.rows,
                "scroll_up": self.o.scroll_up, "output_events": self.output_events,
                "output_bytes": self.output_bytes,
                "mirror_total_rows": mirror_total,
                "daemon_scrollback_rows": self.max_scrollback_seen,
                "pruned": mirror_total.is_some_and(|t| t < total_rows),
            },
            "events": {
                "snap_on_input": self.snap_on_input, "mirror_moved_on_input": self.mirror_after_input_moved,
                "unsolicited_scroll_changed": self.unsolicited_scroll_changed, "resized": self.resized,
                "overflow": self.overflow, "reattach": self.reattach, "stall": self.stall,
            },
            "protocol": protocol,
            "daemon_version": version,
            "seconds": started.elapsed().as_secs_f64(),
        })
    }
}

/// The largest `L<7 digits> ` line number in a chunk of output.
fn newest_number(data: &[u8]) -> u64 {
    data.windows(9)
        .filter_map(|w| match w {
            [b'L', digits @ .., b' '] if digits.iter().all(u8::is_ascii_digit) => {
                std::str::from_utf8(digits).ok()?.parse().ok()
            }
            _ => None,
        })
        .max()
        .unwrap_or(0)
}

fn memchr_find(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> Options {
        Options::parse(&["--socket".into(), "/x".into()]).unwrap()
    }

    /// A wrapped line's rows fill the width exactly, so each row starts with its own marker.
    #[test]
    fn every_row_of_a_wrapped_line_but_the_last_fills_the_width() {
        let cols = 120;
        for n in 1..400u64 {
            let segs = segments(n);
            for k in 0..segs {
                let row = expected_row(n, k, cols);
                assert!(row.len() as u64 <= cols, "{n}/{k}");
                if k + 1 < segs {
                    assert_eq!(row.len() as u64, cols, "{n}/{k}");
                }
                assert_eq!(parse_row(&row, cols), Row::Numbered { n, k, intact: true });
            }
        }
    }

    #[test]
    fn a_blank_or_missing_row_inside_the_viewport_is_counted() {
        let o = opts();
        let ordinals = Ordinals::new(last_line(&o));
        let cols = u64::from(o.cols);
        let mut rows: Vec<String> = (0..20).map(|i| row_at(&ordinals, i, cols)).collect();
        assert_eq!(check_viewport(&rows, false, cols, &ordinals).0.blank, 0);
        rows[5] = String::new();
        rows[9] = row_at(&ordinals, 30, cols);
        let (defects, top) = check_viewport(&rows, false, cols, &ordinals);
        assert_eq!((defects.blank, defects.missing, top), (1, 2, Some(0)));
        // At the live bottom, blank rows below the last numbered row are the screen's own.
        let mut bottom: Vec<String> = (0..10).map(|i| row_at(&ordinals, i, cols)).collect();
        bottom.extend(["STATUS 1/3".to_string(), String::new()]);
        assert_eq!(check_viewport(&bottom, true, cols, &ordinals).0.missing, 0);
        assert_eq!(check_viewport(&bottom, false, cols, &ordinals).0.missing, 1);
    }

    fn row_at(ordinals: &Ordinals, index: u64, cols: u64) -> String {
        let n = ordinals.0.iter().rposition(|start| *start <= index).unwrap() as u64;
        let n = (1..=n).rev().find(|n| ordinals.of(*n, 0).unwrap() <= index).unwrap();
        expected_row(n, index - ordinals.of(n, 0).unwrap(), cols)
    }
}
