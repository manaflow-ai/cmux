//! Terminal resize fuzzer (felt item 1e: "the terminal does not resize
//! properly; resize must be fluid").
//!
//! Each case drives one real daemon terminal (a `/bin/sh` child on a real
//! PTY) through the raw command path the app uses: `set-client-info` with
//! `shared-sizing-v1` and view leases, `attach-surface` with GHOSTSNP
//! snapshots (with and without local history), `resize-attached-view`, and
//! disconnects. A seeded random sequence mixes tiny grids (1x1, 2x1, 1x2),
//! huge ones (500x300 and past the daemon's clamp), rapid bursts, the same
//! size twice, heavy output with resizes during it, a mirror that attaches
//! mid-burst, re-attaches, two and three viewers of different sizes, a first
//! line wider than the grid written by the child before the first resize, and
//! (when the daemon offers `live-resize-v1`) live drag steps with and
//! without their end.
//!
//! After each step that settles, every one of these holds:
//! - the daemon grid, the PTY winsize (cells and pixels), the surface size and
//!   the size the child reads after SIGWINCH (`stty size`) equal the size the
//!   policy picks (`smallest` of the attached viewers' last reports, clamped);
//! - every attached viewer's last READY and last `size-state` name that size;
//!   the READYs and `size-state`s a viewer got since the last settle are a
//!   subsequence of the grids the daemon applied, in order (no announcement
//!   goes back to an older size), and generations never go back;
//! - a local-history READY is cut exactly at the viewer's offset (no skipped
//!   range), output offsets are contiguous after every cut, and no output
//!   arrives for a generation the viewer has no READY of;
//! - the viewer's screen (its last READY restored, plus the output after its
//!   cut) equals the daemon's: the same viewport text and cursor as the
//!   daemon's terminal, and every visible row, blank rows too, cell by cell
//!   with its style, the same as the daemon's READY restored and rendered.
//!   (GHOSTSNP PAGE records are not compared: the daemon's first screen page
//!   also holds the history rows above it, which a viewer that restored no
//!   history does not have; a failure names the first differing record.)
//! - a marker line written before a burst is still in the daemon's text after
//!   it (skipped when the burst at the widest grid may fill the scrollback
//!   limit), and every line the child printed during the burst reached each
//!   viewer that was attached through it with only local READYs, in order,
//!   once.
//!
//! The test runs one scripted case (each kind of step once, a few seconds)
//! and then `CMUX_RESIZE_FUZZ_SEEDS` seeded random cases (default 0 here) of
//! `CMUX_RESIZE_FUZZ_STEPS` steps from `CMUX_RESIZE_FUZZ_SEED`. A failure
//! names the seed, the step and the operations so far.
//!
//! The long random form is not a CI test: run it yourself as a fleet step
//! before and after each resize fix. Merge the fix branch into the scratch
//! branch `cp/fix-resize-daemon-fuzz-long` (5 seeds x 200 steps from
//! 0x1e10, never merged), push, and run at its head:
//! `cmux-ci run --class light --script scripts/ci/cmux-tui-rust-check.sh
//! --arg test --arg resize_fuzz --ref <sha>`. Output timing is real, so a
//! seed fixes the operations, not their interleaving with output.
#![cfg(unix)]

use super::*;
use crate::mux::host_policy::HostSizeMode;
use std::collections::VecDeque;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(20);
const LIVE_RESIZE_CAPABILITY: &str = "live-resize-v1";
/// H10: a live resize with no end settles this long after its last step.
const LIVE_SETTLE: Duration = Duration::from_secs(2);
/// The case terminal's scrollback limit (bytes of page memory).
const SCROLLBACK: usize = 64 << 20;
fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| {
            let raw = raw.trim();
            raw.strip_prefix("0x")
                .map_or_else(|| raw.parse().ok(), |hex| u64::from_str_radix(hex, 16).ok())
        })
        .unwrap_or(default)
}

/// splitmix64: a small seeded generator, so a seed names one sequence.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// Uniform in `low..=high`.
    fn range(&mut self, low: u64, high: u64) -> u64 {
        low + self.next() % (high - low + 1)
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }

    /// A requested grid: mostly ordinary, sometimes tiny, huge or past the clamp.
    fn size(&mut self) -> (u16, u16) {
        match self.range(0, 99) {
            0..=7 => [(1, 1), (2, 1), (1, 2), (2, 2), (1, 40), (300, 1)][self.range(0, 5) as usize],
            8..=11 => (500, 300),
            12 => (u16::MAX, u16::MAX),
            13 => (10_000, 1),
            _ => (self.range(10, 250) as u16, self.range(3, 80) as u16),
        }
    }
}

/// The child: logs the size it reads after each SIGWINCH to `$1/size`,
/// prints `$2` (a first line, maybe wider than the grid) at once, then prints
/// `n` numbered lines `TAG NNNNNN` whenever `$1/go` names `n TAG`, and marks
/// each burst done with `$1/done-TAG`.
const CHILD: &str = r#"
dir=$1
report() { stty size > "$dir/size.tmp" 2>/dev/null && mv "$dir/size.tmp" "$dir/size"; }
trap report WINCH
if [ -n "$2" ]; then printf '%s' "$2"; fi
report
while :; do
  if [ -e "$dir/go" ]; then
    read n tag < "$dir/go"
    rm -f "$dir/go"
    awk -v n="$n" -v t="$tag" 'BEGIN { for (i = 0; i < n; i++) printf "%s %06d\n", t, i }'
    : > "$dir/done-$tag"
  fi
  sleep 0.01
done
"#;

fn scratch_dir(seed: u64) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-resize-fuzz-{seed:x}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn child_size(dir: &Path) -> Option<(u16, u16)> {
    let text = std::fs::read_to_string(dir.join("size")).ok()?;
    let mut parts = text.split_whitespace();
    let rows = parts.next()?.parse().ok()?;
    let cols = parts.next()?.parse().ok()?;
    Some((cols, rows))
}

fn b64(event: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(event["data"].as_str().unwrap_or_default())
        .unwrap_or_default()
}

fn grid_of(value: &Value) -> Option<(u16, u16)> {
    Some((value["cols"].as_u64()? as u16, value["rows"].as_u64()? as u16))
}

/// Is `seen` a subsequence of `applied`, in order? Returns the first entry
/// of `seen` that is not.
fn not_in_order(seen: &[(u16, u16)], applied: &[(u16, u16)]) -> Option<(usize, (u16, u16))> {
    let mut at = 0;
    for (index, grid) in seen.iter().enumerate() {
        match applied[at..].iter().position(|applied| applied == grid) {
            Some(found) => at += found,
            None => return Some((index, *grid)),
        }
    }
    None
}

#[derive(Clone)]
struct Ready {
    generation: u64,
    offset: u64,
    grid: (u16, u16),
    local: bool,
    data: Vec<u8>,
}

/// One app-like connection with one view of the terminal, and the stream
/// state a viewer keeps (TerminalAttachFrameDecoder: a READY sets the offset
/// output continues from; output before it is on the screen already; output
/// after a gap is lost).
struct Viewer {
    name: String,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    lease: String,
    local_history: bool,
    /// The last size this view reported, as the daemon clamps it.
    requested: (u16, u16),
    ready: Option<Ready>,
    generation: u64,
    next_offset: u64,
    /// Output after the last READY's cut.
    after_cut: Vec<u8>,
    size_state_generation: Option<u64>,
    last_size_state: Option<(u16, u16)>,
    /// READY grids and `size-state` grids since the last settle.
    window_readies: Vec<(u16, u16)>,
    window_size_states: Vec<(u16, u16)>,
    /// Every output byte this view kept since the current burst started,
    /// and whether it was contiguous (only local READYs) through the burst.
    burst_bytes: Vec<u8>,
    burst_contiguous: bool,
    log: VecDeque<String>,
    errors: Vec<String>,
}

impl Viewer {
    fn note(&mut self, line: String) {
        if self.log.len() == 40 {
            self.log.pop_front();
        }
        self.log.push_back(line);
    }

    fn fail(&mut self, error: String) {
        self.note(format!("ERROR {error}"));
        self.errors.push(error);
    }

    /// Applies every event queued for this view.
    fn pump(&mut self) {
        while let Some(message) = self.outbound.try_pop() {
            let Ok(event) = serde_json::from_str::<Value>(&message) else {
                self.fail(format!("undecodable stream line {message:.120}"));
                continue;
            };
            self.apply(&event);
        }
    }

    fn apply(&mut self, event: &Value) {
        match (event["event"].as_str().unwrap_or_default(), event["phase"].as_str()) {
            ("snapshot", Some("ready")) => self.apply_ready(event),
            ("snapshot", Some(phase)) => {
                let generation = event["generation"].as_u64().unwrap_or_default();
                self.note(format!("{phase} g{generation} done={}", event["done"]));
                let after_local = self
                    .ready
                    .as_ref()
                    .is_some_and(|ready| ready.local && ready.generation == generation);
                if after_local {
                    self.fail(format!("a {phase} chunk follows the local READY g{generation}"));
                }
                if generation > self.generation {
                    self.fail(format!(
                        "a {phase} chunk of g{generation} before its READY (at g{})",
                        self.generation
                    ));
                }
            }
            ("output", _) => self.apply_output(event),
            ("size-state", _) => {
                let state = &event["state"];
                let generation = state["generation"].as_u64().unwrap_or_default();
                let grid = grid_of(state).unwrap_or_default();
                self.note(format!("size-state g{generation} {}x{}", grid.0, grid.1));
                if let Some(previous) = self.size_state_generation
                    && generation <= previous
                {
                    self.fail(format!(
                        "size-state generation went back: g{generation} after g{previous}"
                    ));
                }
                self.size_state_generation = Some(generation);
                self.last_size_state = Some(grid);
                self.window_size_states.push(grid);
            }
            ("digest", _) => {
                self.note(format!(
                    "digest g{} o{}",
                    event["generation"].as_u64().unwrap_or_default(),
                    event["offset"].as_u64().unwrap_or_default()
                ));
            }
            ("notification" | "colors-changed" | "scroll-changed" | "title-changed", _) => {}
            ("detached" | "attach-ended" | "attach-overflow" | "ended", _) => {
                self.fail(format!("the view ended: {}", truncate(event)));
            }
            (other, _) => self.note(format!("event {other}")),
        }
    }

    fn apply_ready(&mut self, event: &Value) {
        let generation = event["generation"].as_u64().unwrap_or_default();
        let offset = event["offset"].as_u64().unwrap_or_default();
        let grid = grid_of(event).unwrap_or_default();
        let local = event["history"] == "local";
        self.note(format!(
            "READY g{generation} o{offset} {}x{}{}",
            grid.0,
            grid.1,
            if local { " local" } else { "" }
        ));
        if self.ready.is_some() {
            if generation < self.generation {
                self.fail(format!(
                    "READY generation went back: g{generation} after g{}",
                    self.generation
                ));
            }
            // The local-history READY of a resize comes after every output
            // frame before the resize, at the offset at the resize: the view
            // keeps its own screen up to there, so a cut past it skips bytes
            // and a cut before it repeats them.
            if local && offset != self.next_offset {
                self.fail(format!(
                    "local READY g{generation} cut at o{offset}, the view is at o{}",
                    self.next_offset
                ));
            }
        }
        if local
            && (event["history_rows"].as_u64().is_none()
                || event["history_digest"].as_str().is_none_or(str::is_empty))
        {
            self.fail(format!("local READY g{generation} without its history check"));
        }
        if !local {
            self.burst_contiguous = false;
        }
        self.ready = Some(Ready { generation, offset, grid, local, data: b64(event) });
        self.generation = generation;
        self.next_offset = offset;
        self.after_cut.clear();
        self.window_readies.push(grid);
    }

    fn apply_output(&mut self, event: &Value) {
        let data = b64(event);
        let generation = event["generation"].as_u64().unwrap_or_default();
        let Some(end) = event["offset"].as_u64() else {
            self.fail(format!("output without an offset: {}", truncate(event)));
            return;
        };
        let start = end.saturating_sub(data.len() as u64);
        if self.ready.is_none() {
            self.fail(format!("output o{start}..o{end} before the first READY"));
            return;
        }
        if generation > self.generation {
            self.fail(format!(
                "output of g{generation} before its READY (the view is at g{})",
                self.generation
            ));
        }
        if start > self.next_offset {
            self.fail(format!(
                "gap: output o{start}..o{end} after o{} (g{generation}, view g{})",
                self.next_offset, self.generation
            ));
            return;
        }
        if end <= self.next_offset {
            return;
        }
        let fresh = &data[(self.next_offset - start) as usize..];
        self.after_cut.extend_from_slice(fresh);
        self.burst_bytes.extend_from_slice(fresh);
        self.next_offset = end;
    }
}

fn truncate(value: &Value) -> String {
    let mut text = value.to_string();
    text.truncate(200);
    text
}

/// What the daemon holds, read under the terminal lock in one hold.
struct Host {
    grid: (u16, u16),
    position: (u64, u64),
    ready: Vec<u8>,
    text: String,
    cursor: Option<(u16, u16)>,
    /// Every visible row, blank ones too, cell by cell with its style: the
    /// daemon's READY restored into a scratch terminal and rendered (a render
    /// of the daemon's own terminal would take its renderer's dirty rows).
    rows: Vec<Vec<ghostty_vt::Cell>>,
}

/// Every visible row of `terminal`, blank ones too, with each cell's text,
/// width and style, as a renderer draws them.
fn visible_rows(
    terminal: &mut ghostty_vt::Terminal,
) -> ghostty_vt::Result<Vec<Vec<ghostty_vt::Cell>>> {
    let mut render = RenderState::new()?;
    render.update(terminal)?;
    Ok(render.build_frame()?.styled_rows().to_vec())
}

/// The SCREEN, PAGE and CONTINUATION records of a READY (for a failure
/// report), with the SCREEN history extent (payload bytes 4..12; the viewer
/// restored no history) and the PAGE capacity hints (payload bytes 8..20,
/// which depend on the page's history, not on what it shows) set to zero.
fn screen_records(snapshot: &[u8]) -> Vec<(u16, Vec<u8>)> {
    use ghostty_vt::snapshot_tag::{CONTINUATION, PAGE, SCREEN};
    ghostty_vt::snapshot_records(snapshot)
        .filter(|record| matches!(record.tag, SCREEN | PAGE | CONTINUATION))
        .map(|record| {
            let mut payload = record.payload().to_vec();
            if record.tag == SCREEN && payload.len() >= 12 {
                payload[4..12].fill(0);
            }
            if record.tag == PAGE && payload.len() >= 20 {
                payload[8..20].fill(0);
            }
            (record.tag, payload)
        })
        .collect()
}

/// Where two READYs differ: the first differing record and byte.
fn record_diff(viewer: &[u8], host: &[u8]) -> String {
    let (viewer, host) = (screen_records(viewer), screen_records(host));
    if viewer == host {
        return "equal".into();
    }
    let Some(index) = viewer.iter().zip(&host).position(|(a, b)| a != b) else {
        return format!("{} records vs the daemon's {}", viewer.len(), host.len());
    };
    let (a, b) = (&viewer[index].1, &host[index].1);
    let byte = a.iter().zip(b).position(|(x, y)| x != y).unwrap_or(a.len().min(b.len()));
    format!(
        "record {index} (tag {}) differs at payload byte {byte} of {} (the daemon's {})",
        viewer[index].0,
        a.len(),
        b.len()
    )
}

#[derive(Debug, Clone)]
enum Op {
    Resize { viewer: usize, size: (u16, u16) },
    SameSize { viewer: usize },
    Burst { viewer: usize, sizes: Vec<(u16, u16)> },
    Output { lines: u64, resizes: Vec<(usize, (u16, u16))>, mirror: Option<((u16, u16), bool)> },
    WideLine { extra: u16, newline: bool, then: (u16, u16) },
    Marker,
    Attach { size: (u16, u16), local_history: bool },
    Reattach { viewer: usize, size: (u16, u16) },
    Detach { viewer: usize },
    Drag { viewer: usize, sizes: Vec<(u16, u16)>, end: Option<(u16, u16)> },
}

struct Case {
    seed: u64,
    step: usize,
    mux: Arc<Mux>,
    surface: Arc<crate::Surface>,
    dir: PathBuf,
    viewers: Vec<Viewer>,
    next_viewer: usize,
    live_resize: bool,
    /// The grids the daemon applied since the last settle, oldest first.
    applied: Vec<(u16, u16)>,
    /// The grid when no viewer counts (held).
    held: (u16, u16),
    ops: Vec<String>,
    bursts: u64,
    /// The marker to find after the current burst, and the most columns any
    /// grid of the burst had (a wide grid may fill the scrollback limit).
    marker: Option<String>,
    burst_tag: Option<String>,
    burst_lines: u64,
    widest: u64,
}

impl Case {
    fn new(seed: u64, first_line: &str) -> Self {
        let dir = scratch_dir(seed);
        let options = SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                CHILD.into(),
                "sh".into(),
                dir.to_string_lossy().into_owned(),
                first_line.into(),
            ]),
            // Room for a burst at most grids, so a marker leaves the
            // history only where check_burst says it may.
            scrollback: SCROLLBACK,
            cols: 80,
            rows: 24,
            ..SurfaceOptions::default()
        };
        let mux = Mux::new_for_test(format!("resize-fuzz-{seed:x}"), SurfaceOptions::default());
        // The settings file's default (spec/commands.md, set-host-size-policy):
        // fit the smallest viewer. Before the settings owner publishes one,
        // terminals use `latest`.
        mux.set_host_size_policy(HostSizeMode::Smallest, None).unwrap();
        // A terminal in a pane, as the app shows it, whose test runtime is
        // replaced by a real child on a real PTY.
        let id = mux.new_workspace(None, Some((80, 24))).unwrap().id;
        let surface = mux.respawn_with_real_child_for_test(id, options).unwrap();
        let mut case = Self {
            seed,
            step: 0,
            mux,
            surface,
            dir,
            viewers: Vec::new(),
            next_viewer: 0,
            live_resize: false,
            applied: Vec::new(),
            held: (80, 24),
            ops: Vec::new(),
            bursts: 0,
            marker: None,
            burst_tag: None,
            burst_lines: 0,
            widest: 0,
        };
        case.applied.push(case.surface.size());
        case
    }

    fn fail(&mut self, message: &str) -> ! {
        for viewer in &mut self.viewers {
            viewer.pump();
        }
        let mut report = format!(
            "resize fuzz seed=0x{:x} step={} failed: {message}\n\
             rerun: CMUX_RESIZE_FUZZ_SEED=0x{:x} CMUX_RESIZE_FUZZ_SEEDS=1 \
             CMUX_RESIZE_FUZZ_STEPS={}\nops:\n",
            self.seed,
            self.step,
            self.seed,
            self.step + 1
        );
        for op in &self.ops {
            let _ = writeln!(report, "  {op}");
        }
        let _ = writeln!(report, "applied grids since the last settle: {:?}", self.applied);
        for viewer in &self.viewers {
            let _ = writeln!(
                report,
                "viewer {} (client {}, local_history {}, requested {:?}) last events:",
                viewer.name, viewer.client, viewer.local_history, viewer.requested
            );
            for line in &viewer.log {
                let _ = writeln!(report, "    {line}");
            }
        }
        panic!("{report}");
    }

    fn command(&mut self, viewer: usize, request: Value) -> Value {
        let (client, writer) = (self.viewers[viewer].client, self.viewers[viewer].writer.clone());
        match handle_command(&self.mux, client, json_command(request.clone()), &writer) {
            Ok(reply) => reply,
            Err(error) => self.fail(&format!("{request} failed: {error:#}")),
        }
    }

    fn connect(&mut self, size: (u16, u16), local_history: bool) {
        let name = format!("v{}", self.next_viewer);
        self.next_viewer += 1;
        let (writer, outbound) = captured_writer();
        let client = self.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let mux = self.mux.clone();
        let request = |value: Value| (client, writer.clone(), value);
        let run = |(client, writer, value): (u64, MessageWriter, Value)| {
            handle_command(&mux, client, json_command(value.clone()), &writer)
                .map_err(|error| format!("{value} failed: {error:#}"))
        };
        let info = run(request(json!({
            "cmd": "set-client-info",
            "kind": "frontend",
            "device_kind": "mac",
            "device_name": name,
            "capabilities": [SHARED_SIZING_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY],
        })));
        if let Err(error) = info {
            self.fail(&error);
        }
        let identity = run(request(json!({"cmd": "identify"})));
        let live_resize = identity.as_ref().is_ok_and(|identity| {
            identity["capabilities"]
                .as_array()
                .is_some_and(|all| all.iter().any(|value| value == LIVE_RESIZE_CAPABILITY))
        });
        let mut attach = json!({
            "cmd": "attach-surface",
            "surface": self.surface.id,
            "snapshot": "ghostsnp",
            "snapshot_version": ghostty_vt::snapshot_version(),
            "cols": size.0,
            "rows": size.1,
        });
        if local_history {
            attach["snapshot_local_history"] = json!(true);
        }
        let reply = match run(request(attach)) {
            Ok(reply) => reply,
            Err(error) => self.fail(&error),
        };
        let Some(lease) = reply["lease"].as_str().map(str::to_owned) else {
            self.fail(&format!("attach-surface gave no lease: {reply}"))
        };
        self.live_resize = live_resize;
        self.viewers.push(Viewer {
            name,
            client,
            writer,
            outbound,
            lease,
            local_history,
            requested: crate::mux::clamp_terminal_size(size.0, size.1),
            ready: None,
            generation: 0,
            next_offset: 0,
            after_cut: Vec::new(),
            size_state_generation: None,
            last_size_state: None,
            window_readies: Vec::new(),
            window_size_states: Vec::new(),
            burst_bytes: Vec::new(),
            burst_contiguous: false,
            log: Default::default(),
            errors: Vec::new(),
        });
        self.applied.push(self.surface.size());
    }

    fn disconnect(&mut self, viewer: usize) {
        let viewer = self.viewers.remove(viewer);
        disconnect_client(&self.mux, viewer.client, false);
        self.applied.push(self.surface.size());
    }

    fn resize(&mut self, viewer: usize, size: (u16, u16), live: Option<bool>) {
        let mut request = json!({
            "cmd": "resize-attached-view",
            "surface": self.surface.id,
            "lease": self.viewers[viewer].lease,
            "cols": size.0,
            "rows": size.1,
        });
        if let Some(live) = live {
            request["live"] = json!(live);
        }
        let reply = self.command(viewer, request);
        if reply["outcome"] != "applied" {
            self.fail(&format!("resize to {}x{} answered {reply}", size.0, size.1));
        }
        self.viewers[viewer].requested = crate::mux::clamp_terminal_size(size.0, size.1);
        self.applied.push(self.surface.size());
        self.widest = self.widest.max(u64::from(self.surface.size().0));
    }

    fn pump(&mut self) {
        for viewer in &mut self.viewers {
            viewer.pump();
        }
        if let Some((viewer, error)) = self
            .viewers
            .iter()
            .find_map(|viewer| Some((viewer.name.clone(), viewer.errors.first()?.clone())))
        {
            self.fail(&format!("viewer {viewer}: {error}"));
        }
    }

    /// The size the documented policy picks: `smallest` of every attached
    /// view's last report; with no view, the grid stays where it was.
    fn expected(&self) -> (u16, u16) {
        self.viewers
            .iter()
            .map(|viewer| viewer.requested)
            .reduce(|a, b| (a.0.min(b.0), a.1.min(b.1)))
            .unwrap_or(self.held)
    }

    /// The daemon's grid, stream position and READY, in one terminal lock
    /// hold (output is parsed and published under that lock).
    fn host(&self) -> Host {
        let surface = self.surface.clone();
        let mut host = self
            .surface
            .try_with_terminal(|term| Host {
                grid: (term.cols(), term.rows()),
                position: surface.snapshot_stream_position().unwrap_or_default(),
                ready: term.encode_snapshot(ghostty_vt::SnapshotPhase::Ready).unwrap_or_default(),
                text: term.viewport_text().unwrap_or_default(),
                cursor: term.cursor_position(),
                rows: Vec::new(),
            })
            .unwrap();
        host.rows = ghostty_vt::Terminal::from_ready_snapshot(&host.ready, SCROLLBACK)
            .and_then(|mut restored| visible_rows(&mut restored))
            .unwrap_or_default();
        host
    }

    /// Asks the child for `lines` numbered lines; returns the burst's tag and
    /// the stream offset the daemon must reach when they are all in.
    fn start_output(&mut self, lines: u64) -> (String, u64) {
        self.bursts += 1;
        let tag = format!("B{}", self.bursts);
        // `TAG NNNNNN` and CR LF (the PTY's onlcr).
        let bytes = lines * (tag.len() as u64 + 9);
        let from = self.surface.snapshot_stream_position().unwrap_or_default().1;
        let go = self.dir.join("go.tmp");
        std::fs::write(&go, format!("{lines} {tag}\n")).unwrap();
        std::fs::rename(go, self.dir.join("go")).unwrap();
        (tag, from + bytes)
    }

    fn wait_output_done(&mut self, tag: &str, until: u64) {
        let deadline = Instant::now() + WAIT;
        loop {
            let at = self.surface.snapshot_stream_position().unwrap_or_default().1;
            if at >= until && self.dir.join(format!("done-{tag}")).exists() {
                return;
            }
            if Instant::now() > deadline {
                self.fail(&format!(
                    "burst {tag}: the daemon's stream is at o{at}, the child's output ends at o{until}"
                ));
            }
            self.pump();
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    /// Wait until the daemon stopped moving and every view is at its stream
    /// position, then check every property against one host read.
    fn settle(&mut self, why: &str) {
        let deadline = Instant::now() + WAIT;
        let mut quiet_since: Option<(Instant, (u64, u64))> = None;
        let host = loop {
            self.pump();
            let size = self.surface.size();
            if self.applied.last() != Some(&size) {
                self.applied.push(size);
            }
            let host = self.host();
            let caught_up = self.viewers.iter().all(|viewer| {
                viewer.ready.is_some() && (viewer.generation, viewer.next_offset) == host.position
            });
            match quiet_since {
                Some((since, at)) if at == host.position && caught_up => {
                    if since.elapsed() >= Duration::from_millis(60) {
                        break host;
                    }
                }
                _ => quiet_since = caught_up.then(|| (Instant::now(), host.position)),
            }
            if Instant::now() > deadline {
                let behind = self
                    .viewers
                    .iter()
                    .map(|viewer| {
                        format!("{} at g{} o{}", viewer.name, viewer.generation, viewer.next_offset)
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                self.fail(&format!(
                    "{why}: the views never caught up with the daemon at g{} o{} ({behind})",
                    host.position.0, host.position.1
                ));
            }
            std::thread::sleep(Duration::from_millis(3));
        };
        self.check(why, host);
    }

    fn check(&mut self, why: &str, host: Host) {
        let expected = self.expected();
        if host.grid != expected {
            let reports = self.viewers.iter().map(|viewer| viewer.requested).collect::<Vec<_>>();
            self.fail(&format!(
                "{why}: the daemon grid is {:?}, the policy (smallest of {reports:?}) picks {expected:?}",
                host.grid
            ));
        }
        let size = self.surface.size();
        if size != expected {
            self.fail(&format!("{why}: the surface size is {size:?}, not {expected:?}"));
        }
        let master = self.surface.test_master_size();
        if (master.cols, master.rows) != expected {
            self.fail(&format!(
                "{why}: the PTY winsize (TIOCGWINSZ) is {}x{}, not {expected:?}",
                master.cols, master.rows
            ));
        }
        let (cell_w, cell_h) = self.surface.test_cell_pixel_size();
        let pixels =
            (expected.0.saturating_mul(cell_w.max(1)), expected.1.saturating_mul(cell_h.max(1)));
        if (master.pixel_width, master.pixel_height) != pixels {
            self.fail(&format!(
                "{why}: the PTY pixel size is {}x{}, the grid at the cell size is {pixels:?}",
                master.pixel_width, master.pixel_height
            ));
        }
        let deadline = Instant::now() + WAIT;
        while child_size(&self.dir) != Some(expected) {
            if Instant::now() > deadline {
                let seen = child_size(&self.dir);
                self.fail(&format!(
                    "{why}: the child reads {seen:?} after SIGWINCH, the grid is {expected:?}"
                ));
            }
            std::thread::sleep(Duration::from_millis(3));
        }
        for index in 0..self.viewers.len() {
            if let Some(error) = self.viewer_divergence(index, expected, &host) {
                let name = self.viewers[index].name.clone();
                self.fail(&format!("{why}: viewer {name}: {error}"));
            }
        }
        self.check_burst(why);
        for viewer in &mut self.viewers {
            viewer.window_readies.clear();
            viewer.window_size_states.clear();
        }
        self.held = expected;
        self.applied = vec![expected];
    }

    /// How the settled view `index` differs from the daemon, if it does.
    fn viewer_divergence(&self, index: usize, expected: (u16, u16), host: &Host) -> Option<String> {
        let viewer = &self.viewers[index];
        let Some(ready) = &viewer.ready else { return Some("no READY".into()) };
        if ready.grid != expected {
            return Some(format!("its last READY is {:?}, the grid is {expected:?}", ready.grid));
        }
        if let Some(state) = viewer.last_size_state
            && state != expected
        {
            return Some(format!("its last size-state is {state:?}, the grid is {expected:?}"));
        }
        if let Some((at, grid)) = not_in_order(&viewer.window_readies, &self.applied) {
            return Some(format!(
                "READY {at} ({grid:?}) is not a grid the daemon applied after the previous one: \
                 READYs {:?}, applied {:?}",
                viewer.window_readies, self.applied
            ));
        }
        if let Some((at, grid)) = not_in_order(&viewer.window_size_states, &self.applied) {
            return Some(format!(
                "size-state {at} ({grid:?}) is not a grid the daemon applied after the previous \
                 one: size-states {:?}, applied {:?}",
                viewer.window_size_states, self.applied
            ));
        }
        let mut screen = match ghostty_vt::Terminal::from_ready_snapshot(&ready.data, SCROLLBACK) {
            Ok(screen) => screen,
            Err(error) => {
                return Some(format!(
                    "its READY g{} does not restore: {error:?}",
                    ready.generation
                ));
            }
        };
        screen.vt_write(&viewer.after_cut);
        let text = screen.viewport_text().unwrap_or_default();
        let cursor = screen.cursor_position();
        let encoded = screen.encode_snapshot(ghostty_vt::SnapshotPhase::Ready).unwrap_or_default();
        let rows = match visible_rows(&mut screen) {
            Ok(rows) => rows,
            Err(error) => return Some(format!("its screen does not render: {error:?}")),
        };
        if text == host.text && cursor == host.cursor && rows == host.rows {
            return None;
        }
        let first_row = rows.iter().zip(&host.rows).position(|(a, b)| a != b);
        let after = &viewer.after_cut;
        Some(format!(
            "its screen (READY g{} o{} {:?}{}, then {} bytes) differs from the daemon's at g{} o{}: \
             text {}, cursor {:?} vs the daemon's {:?}, {} rows vs the daemon's {}, first differing \
             row {first_row:?}, records {}\n  daemon screen: {:?}\n  \
             viewer screen: {text:?}\n  bytes after the cut (last 300): {:?}",
            ready.generation,
            ready.offset,
            ready.grid,
            if ready.local { " local" } else { "" },
            after.len(),
            host.position.0,
            host.position.1,
            if text == host.text { "equal" } else { "DIFFERS" },
            cursor,
            host.cursor,
            rows.len(),
            host.rows.len(),
            record_diff(&encoded, &host.ready),
            host.text,
            String::from_utf8_lossy(&after[after.len().saturating_sub(300)..])
        ))
    }

    fn check_burst(&mut self, why: &str) {
        let Some(tag) = self.burst_tag.take() else { return };
        let lines = self.burst_lines;
        if let Some(marker) = self.marker.take() {
            // A burst on a wide grid may fill the scrollback limit, which
            // drops the oldest rows (the marker too) by design.
            let estimate = self.widest.max(10) * (lines + 400) * 16;
            if estimate < (SCROLLBACK as u64) * 3 / 4 {
                // Soft wraps break the marker over rows in the dump.
                let text: String = self
                    .surface
                    .try_with_terminal(|term| term.plain_text().unwrap_or_default())
                    .unwrap()
                    .chars()
                    .filter(|c| *c != '\n' && *c != '\r')
                    .collect();
                if !text.contains(&marker) {
                    self.fail(&format!("{why}: the marker {marker} before burst {tag} is gone"));
                }
            }
        }
        let prefix = format!("{tag} ");
        for index in 0..self.viewers.len() {
            let viewer = &self.viewers[index];
            if !viewer.burst_contiguous {
                continue;
            }
            let text = String::from_utf8_lossy(&viewer.burst_bytes);
            let numbers: Vec<u64> = text
                .split('\n')
                .filter_map(|line| line.trim_end_matches('\r').strip_prefix(&prefix))
                .filter_map(|rest| rest.trim().parse().ok())
                .collect();
            if numbers.len() as u64 != lines || numbers.iter().zip(0..).any(|(a, b)| *a != b) {
                let first_bad =
                    numbers.iter().zip(0u64..).position(|(a, b)| *a != b).unwrap_or(numbers.len());
                let message = format!(
                    "{why}: viewer {} got {} of burst {tag}'s {lines} lines; the stream diverges \
                     at line {first_bad} ({:?})",
                    viewer.name,
                    numbers.len(),
                    numbers.get(first_bad)
                );
                self.fail(&message);
            }
        }
    }

    fn begin_burst_window(&mut self, tag: &str, lines: u64) {
        self.burst_tag = Some(tag.to_owned());
        self.burst_lines = lines;
        self.widest = u64::from(self.surface.size().0);
        for viewer in &mut self.viewers {
            viewer.burst_bytes.clear();
            viewer.burst_contiguous = viewer.local_history;
        }
    }

    fn pick(&mut self, rng: &mut Rng) -> Op {
        let viewers = self.viewers.len() as u64;
        let any = |rng: &mut Rng| rng.range(0, viewers.saturating_sub(1)) as usize;
        loop {
            let roll = rng.range(0, 99);
            let op = match roll {
                0..=24 => Op::Resize { viewer: any(rng), size: rng.size() },
                25..=29 => Op::SameSize { viewer: any(rng) },
                30..=41 => Op::Burst {
                    viewer: any(rng),
                    sizes: (0..rng.range(2, 30)).map(|_| rng.size()).collect(),
                },
                42..=55 => {
                    let resizes = (0..rng.range(0, 16)).map(|_| (any(rng), rng.size())).collect();
                    let mirror = rng.chance(30).then(|| (rng.size(), rng.chance(50)));
                    Op::Output { lines: rng.range(50, 20_000), resizes, mirror }
                }
                56..=63 => Op::WideLine {
                    extra: rng.range(1, 60) as u16,
                    newline: rng.chance(50),
                    then: rng.size(),
                },
                64..=68 => Op::Marker,
                69..=74 if viewers < 3 => {
                    Op::Attach { size: rng.size(), local_history: rng.chance(70) }
                }
                75..=80 => Op::Reattach { viewer: any(rng), size: rng.size() },
                81..=84 if viewers > 1 => Op::Detach { viewer: any(rng) },
                85..=99 => {
                    let start = (rng.range(20, 200) as u16, rng.range(5, 60) as u16);
                    let steps = rng.range(3, 40) as u16;
                    let (dc, dr) = (rng.range(0, 6) as i32 - 3, rng.range(0, 2) as i32 - 1);
                    let sizes = (0..steps)
                        .map(|step| {
                            let step = i32::from(step);
                            (
                                (i32::from(start.0) + dc * step).clamp(1, 400) as u16,
                                (i32::from(start.1) + dr * step).clamp(1, 120) as u16,
                            )
                        })
                        .collect();
                    let end = rng.chance(80).then(|| rng.size());
                    Op::Drag { viewer: any(rng), sizes, end }
                }
                _ => continue,
            };
            return op;
        }
    }

    fn run(&mut self, op: Op) {
        self.ops.push(format!("{}: {op:?}", self.step));
        let why = format!("step {} {op:?}", self.step);
        match op {
            Op::Resize { viewer, size } => {
                self.resize(viewer, size, None);
                self.settle(&why);
            }
            Op::SameSize { viewer } => {
                let size = self.viewers[viewer].requested;
                self.resize(viewer, size, None);
                self.resize(viewer, size, None);
                self.settle(&why);
            }
            Op::Burst { viewer, sizes } => {
                for size in sizes {
                    self.resize(viewer, size, None);
                }
                self.settle(&why);
            }
            Op::Output { lines, resizes, mirror } => {
                self.marker_line();
                // The marker is in every view before the burst starts.
                self.settle(&format!("{why}: before the burst"));
                let (tag, until) = self.start_output(lines);
                self.begin_burst_window(&tag, lines);
                let mut mirror = mirror;
                for (index, (viewer, size)) in resizes.into_iter().enumerate() {
                    if index == 1
                        && let Some((size, local_history)) = mirror.take()
                    {
                        self.connect(size, local_history);
                    }
                    let viewer = viewer.min(self.viewers.len() - 1);
                    self.resize(viewer, size, None);
                    self.pump();
                    std::thread::sleep(Duration::from_micros(500));
                }
                if let Some((size, local_history)) = mirror {
                    self.connect(size, local_history);
                }
                self.wait_output_done(&tag, until);
                self.settle(&why);
            }
            Op::WideLine { extra, newline, then } => {
                let cols = self.surface.size().0;
                let mut line = "w".repeat(usize::from(cols) + usize::from(extra));
                if newline {
                    line.push_str("\r\n");
                }
                self.surface.inject_output_for_test(line.as_bytes());
                let viewer = self.viewers.len() - 1;
                self.resize(viewer, then, None);
                self.settle(&why);
            }
            Op::Marker => {
                self.marker_line();
                self.settle(&why);
            }
            Op::Attach { size, local_history } => {
                self.connect(size, local_history);
                self.settle(&why);
            }
            Op::Reattach { viewer, size } => {
                let local_history = self.viewers[viewer].local_history;
                self.disconnect(viewer);
                self.connect(size, local_history);
                self.settle(&why);
            }
            Op::Detach { viewer } => {
                self.disconnect(viewer);
                self.settle(&why);
            }
            Op::Drag { viewer, sizes, end } => {
                let live = self.live_resize.then_some(true);
                for size in sizes {
                    self.resize(viewer, size, live);
                    self.pump();
                }
                match end {
                    Some(size) => self.resize(viewer, size, self.live_resize.then_some(false)),
                    // H10: a drag whose end never comes settles after 2 s.
                    None if self.live_resize => {
                        std::thread::sleep(LIVE_SETTLE + Duration::from_millis(200))
                    }
                    None => {}
                }
                self.settle(&why);
            }
        }
    }

    fn finish(mut self) {
        for viewer in std::mem::take(&mut self.viewers) {
            disconnect_client(&self.mux, viewer.client, false);
        }
        self.mux.shutdown();
        let _ = std::fs::remove_dir_all(&self.dir);
    }

    /// Writes a marker line the way the child writes output (between
    /// bursts: the child is idle, so the line is whole).
    fn marker_line(&mut self) {
        let marker = format!("MARK-{:x}-{}-END", self.seed, self.step);
        self.surface.inject_output_for_test(format!("\r\n{marker}\r\n").as_bytes());
        self.marker = Some(marker);
    }
}

fn run_case(seed: u64, steps: usize) {
    let mut rng = Rng(seed);
    // Half the cases start like the 1e report: the child writes a first line
    // wider than the grid at once, before any view attaches and resizes.
    let first_line =
        if rng.chance(50) { "f".repeat(rng.range(81, 240) as usize) } else { String::new() };
    let mut case = Case::new(seed, &first_line);
    case.ops.push(format!("start: a first line of {} columns on 80x24", first_line.len()));
    // Attach before or after the daemon parsed the first line.
    if !first_line.is_empty() && rng.chance(50) {
        let deadline = Instant::now() + WAIT;
        // No view is attached yet, so the stream position does not move:
        // read the screen (soft wraps break the line over rows).
        let parsed = |surface: &crate::Surface| {
            surface
                .try_with_terminal(|term| term.plain_text().unwrap_or_default())
                .unwrap()
                .chars()
                .filter(|c| *c == 'f')
                .count()
        };
        while parsed(&case.surface) < first_line.len() {
            if Instant::now() > deadline {
                case.fail("the child's first line never reached the daemon");
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        case.ops.push("the daemon parsed the first line".into());
    }
    // The app attaches at the terminal's grid, then its first resize comes
    // (the 1e report), or attaches at its own size.
    let at_grid = rng.chance(50);
    let first = if at_grid { (80, 24) } else { rng.size() };
    let local_history = rng.chance(80);
    case.connect(first, local_history);
    case.ops.push(format!("attach {first:?} local_history={local_history}"));
    if at_grid {
        let size = rng.size();
        case.ops.push(format!("the first resize: {size:?}"));
        case.resize(0, size, None);
    }
    if rng.chance(40) {
        let second = rng.size();
        let local_history = rng.chance(50);
        case.connect(second, local_history);
        case.ops.push(format!("attach {second:?} local_history={local_history}"));
    }
    case.settle("attach");
    for step in 0..steps {
        case.step = step;
        let op = case.pick(&mut rng);
        case.run(op);
    }
    case.finish();
    eprintln!("resize fuzz seed=0x{seed:x}: {steps} steps passed");
}

/// Seeded random cases the test runs after the scripted one: none here (the
/// test stays a few seconds under the CI per-test limit); the scratch branch
/// `cp/fix-resize-daemon-fuzz-long` sets 5 x 200 (see the module docs).
const RANDOM_SEEDS: u64 = 0;
const RANDOM_STEPS: u64 = 200;
const RANDOM_FIRST_SEED: u64 = 0x1e10;

/// The fixed regression: one terminal, each kind of step once.
fn run_scripted() {
    // The 1e report: a first line wider than the grid, written at once right
    // after the terminal is made and parsed before any view attaches; the
    // app attaches at the terminal's grid, then its first resize narrows it
    // (a 118-column line in a 110-column grid).
    let first_line = "f".repeat(118);
    let mut case = Case::new(0, &first_line);
    case.ops.push("start: a first line of 118 columns on 80x24".into());
    let deadline = Instant::now() + WAIT;
    // No view is attached yet, so the stream position does not move: read
    // the screen (soft wraps break the line over rows).
    let parsed = |surface: &crate::Surface| {
        surface
            .try_with_terminal(|term| term.plain_text().unwrap_or_default())
            .unwrap()
            .chars()
            .filter(|c| *c == 'f')
            .count()
    };
    while parsed(&case.surface) < first_line.len() {
        if Instant::now() > deadline {
            case.fail("the child's first line never reached the daemon");
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    case.connect((80, 24), true);
    case.ops.push("attach (80, 24) local_history=true".into());
    case.ops.push("the first resize: (110, 30)".into());
    case.resize(0, (110, 30), None);
    case.settle("the first resize");
    let script = [
        // Tiny grids (the daemon clamps to 2 x 1).
        Op::Resize { viewer: 0, size: (1, 1) },
        Op::Resize { viewer: 0, size: (2, 1) },
        Op::Resize { viewer: 0, size: (1, 2) },
        // Huge grids: 500 x 300 and past the clamp (10000 x 400).
        Op::Resize { viewer: 0, size: (500, 300) },
        Op::Resize { viewer: 0, size: (u16::MAX, u16::MAX) },
        Op::Resize { viewer: 0, size: (100, 30) },
        Op::SameSize { viewer: 0 },
        Op::Burst {
            viewer: 0,
            sizes: vec![(90, 20), (1, 1), (200, 60), (91, 21), (40, 10), (120, 40), (120, 40)],
        },
        // Output with resizes during it; a mirror (local history) attaches
        // after the first resize, mid-burst.
        Op::Output {
            lines: 3_000,
            resizes: vec![(0, (70, 20)), (0, (130, 45)), (0, (15, 36)), (0, (95, 28))],
            mirror: Some(((117, 58), true)),
        },
        // A third viewer without local history: three sizes, smallest wins.
        Op::Attach { size: (150, 50), local_history: false },
        Op::Resize { viewer: 2, size: (60, 18) },
        Op::Resize { viewer: 1, size: (61, 17) },
        Op::WideLine { extra: 20, newline: false, then: (70, 20) },
        Op::Drag {
            viewer: 0,
            sizes: (0..12).map(|step| (60 + step * 3, 18 + step)).collect(),
            end: Some((80, 24)),
        },
        Op::Marker,
        Op::Reattach { viewer: 0, size: (90, 30) },
        Op::Detach { viewer: 2 },
        Op::Resize { viewer: 1, size: (100, 30) },
    ];
    for (step, op) in script.into_iter().enumerate() {
        case.step = step;
        case.run(op);
    }
    case.finish();
    eprintln!("resize fuzz: the scripted case passed");
}

#[test]
fn resize_fuzz_grid_pty_child_and_every_viewer_agree() {
    run_scripted();
    let first = env_u64("CMUX_RESIZE_FUZZ_SEED", RANDOM_FIRST_SEED);
    let seeds = env_u64("CMUX_RESIZE_FUZZ_SEEDS", RANDOM_SEEDS);
    let steps = env_u64("CMUX_RESIZE_FUZZ_STEPS", RANDOM_STEPS) as usize;
    if seeds > 0 {
        eprintln!("resize fuzz: seeds 0x{first:x}..+{seeds}, {steps} steps each");
    }
    for seed in first..first + seeds {
        run_case(seed, steps);
    }
}
