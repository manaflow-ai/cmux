//! Named scenarios: the situations seen on a real phone (a 1 s background, a TURN path that
//! resets, a TUI scrolled while it streams, ...) as data files under `scenarios/`, each one
//! replayable headless with one command and one seed.
//!
//! A scenario file (TOML) names a duress spec (the load), the events laid over it (a pause, a
//! periodic path reset, viewport resizes, scroll inputs, theme switches), the checks its verdict
//! is made of, and the iOS sim step that runs the same case in the app. A case with no Rust path
//! says so (`headless = false` and `headless_reason`) and only carries its sim args.
//!
//! This module is the format, the schedule transforms (pure, no terminal) and the verdict; the
//! run loop through ghostty-vt and the projection is [`crate::replay`] (feature `paths`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_fault::Rng;
use cmux_fault::shaper::{Disruption, LinkProfile};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::knobs::Knobs;

/// The scenario folder, relative to the repository root.
pub const DIR: &str = "cmux-tui/crates/cmux-duress/scenarios";

/// One phone frame at 60 Hz, in ms.
pub const FRAME_MS: f64 = 1000.0 / 60.0;

/// One scenario file.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    /// The file's stem.
    pub name: String,
    pub summary: String,
    /// Where each constant came from (a lane's file, PR, line).
    #[serde(default)]
    pub sources: Vec<String>,
    /// The load, `PRESET[,knob=value...]` (its `seed` knob seeds the scenario's own draws too).
    pub spec: String,
    /// Whether a Rust path runs it. `false` needs `headless_reason`.
    pub headless: bool,
    /// Why there is no headless run, or which half of the case only the sim covers.
    #[serde(default)]
    pub headless_reason: Option<String>,
    /// `terminal` (PTY bytes into the phone's ghostty-vt) or `projection` (a Mac terminal, the
    /// hybrid/lean frames, the phone's terminal).
    #[serde(default)]
    pub path: PathKind,
    /// The phone's terminal: iPhone portrait by default.
    #[serde(default = "default_cols")]
    pub cols: u16,
    #[serde(default = "default_rows")]
    pub rows: u16,
    /// Bytes the phone writes into its terminal per frame; a backlog takes several frames.
    #[serde(default = "default_frame_bytes")]
    pub frame_bytes: usize,
    /// A link written out as a `cmux-fault` profile; replaces the spec's `link`.
    #[serde(default)]
    pub link: Option<LinkProfile>,
    /// The full-screen TUI the Mac runs. On `terminal` its redraws go as PTY bytes, the way a
    /// phone without Agent CLI Screen Changes gets them (the default); on `projection` as
    /// hybrid/lean frames.
    #[serde(default)]
    pub tui: Option<Tui>,
    /// `terminal` with `[tui]` only: `output` at most once per this many ms (`attach-output-coalesce-v1`: the
    /// first bytes after idle at once, the rest at the interval's end); `None` is one event per
    /// redraw, what a phone that declares nothing gets.
    #[serde(default)]
    pub coalesce_ms: Option<u64>,
    /// `terminal` with `[tui]` only: a fixed cost per `output` event on the phone, in ms, on top
    /// of what the run times (a main-thread hop, the app's own decode and paint, which this model
    /// cannot see). A phone slower than the events backs up the Mac's socket.
    #[serde(default)]
    pub phone_event_ms: Option<f64>,
    /// `terminal` with `[tui]` only: when the Mac's writer frees, the PTY reads already pending go
    /// out as one `output` event (no timer). Not with `coalesce_ms`.
    #[serde(default)]
    pub merge_ready: bool,
    #[serde(default, rename = "event")]
    pub events: Vec<Event>,
    #[serde(default, rename = "check")]
    pub checks: Vec<Check>,
    pub sim: Sim,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PathKind {
    #[default]
    Terminal,
    Projection,
}

fn default_cols() -> u16 {
    44
}
fn default_rows() -> u16 {
    40
}
fn default_frame_bytes() -> usize {
    64 * 1024
}

/// A full-screen TUI on the Mac (alternate screen, redrawn whole): a document that grows by
/// `append_lines_per_s` and is redrawn at most `redraw_fps` times a second, or on a scroll input.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tui {
    pub doc_lines: u64,
    #[serde(default)]
    pub append_lines_per_s: u64,
    #[serde(default = "default_fps")]
    pub redraw_fps: u64,
    pub seconds: u64,
}

fn default_fps() -> u64 {
    30
}

/// Something that happens during the run, at times relative to the stream's start.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Event {
    /// The app is in the background from `at_ms` for `ms`: whatever arrives meanwhile is read
    /// in one burst at resume.
    Pause { at_ms: u64, ms: u64 },
    /// The live path resets every draw in `every_ms` (from `from_ms`): the connection goes
    /// silent for a draw in `stall_ms` (default: the link profile's `address_change` stall),
    /// then a new path takes one round trip, and what was sent meanwhile arrives as one burst.
    PathReset {
        every_ms: [u64; 2],
        #[serde(default)]
        stall_ms: Option<[u64; 2]>,
        #[serde(default)]
        from_ms: u64,
    },
    /// The terminal's rows cycle through `rows`, one step every `every_ms`.
    Resize {
        every_ms: u64,
        rows: Vec<u16>,
        #[serde(default)]
        from_ms: u64,
        #[serde(default)]
        until_ms: Option<u64>,
    },
    /// A scroll of `rows` (negative is up) every `every_ms`, turning around after
    /// `steps_each_way` steps.
    Scroll {
        every_ms: u64,
        rows: i64,
        #[serde(default = "default_steps")]
        steps_each_way: u64,
        #[serde(default)]
        from_ms: u64,
        #[serde(default)]
        until_ms: Option<u64>,
    },
    /// The app's theme switches to the next of `themes` every `every_ms`.
    Theme {
        every_ms: u64,
        themes: Vec<Theme>,
        #[serde(default)]
        from_ms: u64,
        #[serde(default)]
        until_ms: Option<u64>,
    },
    /// A key echo every `every_ms`: one byte up the link and its echo back down.
    Echo {
        every_ms: u64,
        #[serde(default)]
        from_ms: u64,
        #[serde(default)]
        until_ms: Option<u64>,
    },
}

fn default_steps() -> u64 {
    8
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Theme {
    pub name: String,
    /// `#rrggbb`.
    pub fg: String,
    pub bg: String,
}

impl Theme {
    pub fn rgb(&self) -> Result<([u8; 3], [u8; 3]), String> {
        Ok((hex_rgb(&self.fg)?, hex_rgb(&self.bg)?))
    }
}

pub fn hex_rgb(text: &str) -> Result<[u8; 3], String> {
    let digits = text.strip_prefix('#').unwrap_or(text);
    let bad = || format!("{text:?} is not #rrggbb");
    if digits.len() != 6 {
        return Err(bad());
    }
    let byte = |i: usize| u8::from_str_radix(digits.get(i..i + 2).unwrap_or(""), 16);
    Ok([byte(0).map_err(|_| bad())?, byte(2).map_err(|_| bad())?, byte(4).map_err(|_| bad())?])
}

/// One check of the verdict: `stat` of `metric` against `max` and/or `min`.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Check {
    pub metric: String,
    #[serde(default)]
    pub stat: Stat,
    #[serde(default)]
    pub max: Option<f64>,
    #[serde(default)]
    pub min: Option<f64>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Stat {
    P50,
    P95,
    #[default]
    Max,
    Min,
    /// The sample count.
    N,
    /// The sum.
    Sum,
}

impl Stat {
    fn name(self) -> &'static str {
        match self {
            Stat::P50 => "p50",
            Stat::P95 => "p95",
            Stat::Max => "max",
            Stat::Min => "min",
            Stat::N => "n",
            Stat::Sum => "sum",
        }
    }
}

/// The iOS sim step for the same case.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sim {
    /// UI suites (`ui=A,B`).
    #[serde(default)]
    pub ui: Vec<String>,
    /// Kit tests (`only=TARGET/SUITE`), for a case whose sim half is a unit test.
    #[serde(default)]
    pub only: Vec<String>,
    /// The `duress=` spec; the scenario's `spec` when unset.
    #[serde(default)]
    pub duress: Option<String>,
    /// The fleet step id once one exists.
    #[serde(default)]
    pub step: Option<String>,
    /// What the sim run covers that the headless one cannot.
    #[serde(default)]
    pub covers: Option<String>,
}

impl Scenario {
    /// Parses and checks one file's text.
    pub fn parse(text: &str) -> Result<Self, String> {
        let scenario: Scenario = toml::from_str(text).map_err(|error| error.to_string())?;
        scenario.validate()?;
        Ok(scenario)
    }

    /// Reads `path`; the file's stem must be the scenario's name.
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        let scenario =
            Self::parse(&text).map_err(|error| format!("{}: {error}", path.display()))?;
        let stem = path.file_stem().and_then(|stem| stem.to_str()).unwrap_or_default();
        if stem != scenario.name {
            return Err(format!(
                "{}: name {:?} is not the file's stem {stem:?}",
                path.display(),
                scenario.name
            ));
        }
        Ok(scenario)
    }

    /// `relay-30`: the relayed hop's link as `turn-path-reset.toml` writes it (cmux#50916, as
    /// relayed: 24.5 ms p50 / 27.7 ms p95 echo), without its resets. Any other name is `None`: a
    /// builtin `cmux-fault` profile the spec's `link=` names (`lan`, `lte`, `none`).
    pub fn named_link(name: &str) -> Result<Option<LinkProfile>, String> {
        if name != "relay-30" {
            return Ok(None);
        }
        toml::from_str(
            "name = \"relay-30\"\nversion = 1\ndown_kbit = 12000\nup_kbit = 12000\nrtt_ms = 21\n\
         jitter_ms = 4\nsource = \"cmux#50916 relay-30, as relayed (turn-path-reset.toml)\"\n",
        )
        .map(Some)
        .map_err(|error| format!("relay-30: {error}"))
    }

    /// The checks `load` runs; a caller that changes a loaded scenario runs them again.
    pub fn validate(&self) -> Result<(), String> {
        let name_ok = !self.name.is_empty()
            && self.name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
        if !name_ok {
            return Err(format!("name {:?}: lowercase letters, digits and -", self.name));
        }
        let knobs = Knobs::parse(&self.spec)?;
        if let Some(duress) = &self.sim.duress {
            Knobs::parse(duress).map_err(|error| format!("sim.duress: {error}"))?;
        }
        if self.sim.ui.is_empty() && self.sim.only.is_empty() {
            return Err("sim: name at least one UI suite (ui) or kit test (only)".to_owned());
        }
        if !self.headless {
            if self.headless_reason.as_deref().is_none_or(str::is_empty) {
                return Err("headless = false needs headless_reason".to_owned());
            }
            if !self.checks.is_empty() || !self.events.is_empty() {
                return Err("a headless = false scenario has no events or checks to run".to_owned());
            }
            return Ok(());
        }
        if self.checks.is_empty() {
            return Err("a headless scenario needs at least one [[check]]".to_owned());
        }
        if self.cols == 0 || self.rows == 0 || self.frame_bytes == 0 {
            return Err("cols, rows and frame_bytes must be above 0".to_owned());
        }
        for check in &self.checks {
            if check.max.is_none() && check.min.is_none() {
                return Err(format!("check {}: needs max or min", check.metric));
            }
        }
        match (self.path, &self.tui) {
            (PathKind::Projection, None) => return Err("path = \"projection\" needs [tui]".into()),
            (PathKind::Terminal, None)
                if self.coalesce_ms.is_some()
                    || self.phone_event_ms.is_some()
                    || self.merge_ready =>
            {
                return Err("coalesce_ms, phone_event_ms and merge_ready need [tui]".into());
            }
            _ => {}
        }
        if self.merge_ready && self.coalesce_ms.is_some_and(|ms| ms > 0) {
            return Err("merge_ready and coalesce_ms are two senders: one at a time".into());
        }
        for event in &self.events {
            let terminal_only = !matches!(event, Event::Scroll { .. } | Event::Echo { .. });
            if self.tui.is_some() && terminal_only {
                return Err(format!("{event:?}: not with [tui] (scroll, echo only)"));
            }
            match event {
                Event::Pause { ms: 0, .. } => return Err("pause: ms must be above 0".into()),
                Event::PathReset { every_ms: [lo, hi], stall_ms, .. } => {
                    if *lo == 0 || lo > hi {
                        return Err("path_reset: every_ms is [lo, hi], 0 < lo <= hi".into());
                    }
                    if stall_ms.is_none() && self.reset_stall(None, &knobs)?.is_none() {
                        return Err(
                            "path_reset: give stall_ms, or a link whose disruption is an address_change"
                                .into(),
                        );
                    }
                }
                Event::Resize { every_ms, rows, .. }
                    if *every_ms == 0 || rows.len() < 2 || rows.contains(&0) =>
                {
                    return Err("resize: every_ms above 0 and at least two row counts".into());
                }
                Event::Scroll { every_ms, rows, steps_each_way, .. }
                    if *every_ms == 0 || *rows == 0 || *steps_each_way == 0 =>
                {
                    return Err("scroll: every_ms, rows and steps_each_way non-zero".into());
                }
                Event::Theme { every_ms, themes, .. } => {
                    if *every_ms == 0 || themes.len() < 2 {
                        return Err("theme: every_ms above 0 and at least two themes".into());
                    }
                    for theme in themes {
                        theme.rgb()?;
                    }
                }
                Event::Echo { every_ms: 0, .. } => return Err("echo: every_ms above 0".into()),
                _ => {}
            }
        }
        Ok(())
    }

    /// The knobs the scenario's load is generated from.
    pub fn knobs(&self) -> Result<Knobs, String> {
        Knobs::parse(&self.spec)
    }

    /// The link: the scenario's own profile, else the spec's.
    pub fn link_profile(&self, knobs: &Knobs) -> Result<Option<LinkProfile>, String> {
        match &self.link {
            Some(link) => Ok(Some(link.clone())),
            None => knobs.link_profile(),
        }
    }

    /// A path reset's stall range: the event's, else the link's `address_change` stall.
    fn reset_stall(
        &self,
        stall_ms: Option<[u64; 2]>,
        knobs: &Knobs,
    ) -> Result<Option<[u64; 2]>, String> {
        if stall_ms.is_some() {
            return Ok(stall_ms);
        }
        Ok(match self.link_profile(knobs)?.and_then(|link| link.disruption) {
            Some(Disruption::AddressChange { stall_ms }) => Some(stall_ms),
            _ => None,
        })
    }

    /// The `duress=` spec the sim step runs.
    pub fn sim_duress(&self) -> &str {
        self.sim.duress.as_deref().unwrap_or(&self.spec)
    }

    /// The sim step's arguments to `scripts/ci/cmux-next-ios-sim.sh`.
    pub fn sim_args(&self) -> String {
        let mut args = vec!["test".to_owned()];
        if !self.sim.only.is_empty() {
            args.push(format!("only={}", self.sim.only.join(",")));
        }
        // The sim script runs duress= only around warm UI suites.
        if !self.sim.ui.is_empty() {
            args.push(format!("ui={}", self.sim.ui.join(",")));
            args.push(format!("duress={}", self.sim_duress()));
        }
        args.join(" ")
    }
}

/// The scenario folder: `--dir`, else the repository's, else the one this binary was built from.
pub fn default_dir(repo: Option<&Path>) -> PathBuf {
    if let Some(repo) = repo {
        let dir = repo.join(DIR);
        if dir.is_dir() {
            return dir;
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("scenarios")
}

/// Every `*.toml` in `dir`, by name.
pub fn load_dir(dir: &Path) -> Result<Vec<Scenario>, String> {
    let entries = std::fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "toml"))
        .collect();
    paths.sort();
    paths.iter().map(|path| Scenario::load(path)).collect()
}

/// One scenario by name from `dir`, listing the names when it is not there.
pub fn find(dir: &Path, name: &str) -> Result<Scenario, String> {
    let path = dir.join(format!("{name}.toml"));
    if path.is_file() {
        return Scenario::load(&path);
    }
    let names: Vec<String> = load_dir(dir)?.into_iter().map(|s| s.name).collect();
    Err(format!("no scenario {name:?} in {}; scenarios: {}", dir.display(), names.join(", ")))
}

/// `scenario list`: one line each.
pub fn list_table(scenarios: &[Scenario]) -> String {
    let width = scenarios.iter().map(|s| s.name.len()).max().unwrap_or(4).max(4);
    let mut out = format!("{:<width$}  {:<9}  summary\n", "name", "headless");
    for scenario in scenarios {
        let headless = if scenario.headless { "yes" } else { "sim-only" };
        out.push_str(&format!("{:<width$}  {headless:<9}  {}\n", scenario.name, scenario.summary));
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Schedule transforms: pure functions over delivery times, shared by the run loop and its tests.

/// A burst the phone must catch up on: everything delivered by `target_ms` is in its terminal.
/// The catch-up is timed from `from_ms`; `kind` prefixes the metric names.
#[derive(Clone, Debug, PartialEq)]
pub struct Mark {
    pub kind: &'static str,
    pub from_ms: f64,
    pub burst_ms: f64,
    pub target_ms: f64,
}

/// Holds every delivery inside a pause until the resume. `times` must be nondecreasing; it
/// stays so.
pub fn apply_pause(times: &mut [f64], at_ms: u64, ms: u64) -> Mark {
    let (from, to) = (at_ms as f64, (at_ms + ms) as f64);
    for t in times.iter_mut() {
        if *t >= from && *t < to {
            *t = to;
        }
    }
    Mark { kind: "resume", from_ms: to, burst_ms: to, target_ms: to }
}

/// The reset times and each one's stall, drawn from `rng`, up to `length_ms`.
pub fn reset_times(
    every_ms: [u64; 2],
    stall_ms: [u64; 2],
    from_ms: u64,
    length_ms: f64,
    rng: &mut Rng,
) -> Vec<(f64, f64)> {
    let mut out = Vec::new();
    let mut at = from_ms as f64;
    loop {
        at += rng.range(every_ms[0], every_ms[1].max(every_ms[0])) as f64;
        if at >= length_ms {
            return out;
        }
        let stall = rng.range(stall_ms[0], stall_ms[1].max(stall_ms[0])) as f64;
        out.push((at, stall));
    }
}

/// A reset at `at` with `stall`: deliveries in `[at, at + stall + rtt)` arrive at the end of that
/// window (the new path's handshake is one round trip).
pub fn apply_reset(times: &mut [f64], at: f64, stall: f64, rtt_ms: f64) -> Mark {
    let back = at + stall + rtt_ms;
    for t in times.iter_mut() {
        if *t >= at && *t < back {
            *t = back;
        }
    }
    Mark { kind: "reset", from_ms: at, burst_ms: back, target_ms: back }
}

/// Times every `every_ms` from `from_ms` (exclusive of 0 unless `from_ms` is 0) up to
/// `until_ms` or `length_ms`.
pub fn ticks(every_ms: u64, from_ms: u64, until_ms: Option<u64>, length_ms: f64) -> Vec<f64> {
    let end = until_ms.map_or(length_ms, |until| (until as f64).min(length_ms));
    let mut out = Vec::new();
    let mut at = from_ms as f64;
    if at == 0.0 {
        at = every_ms as f64;
    }
    while at < end {
        out.push(at);
        at += every_ms as f64;
    }
    out
}

/// The signed scroll steps: `steps_each_way` of `rows`, then as many back, repeated.
pub fn scroll_steps(count: usize, rows: i64, steps_each_way: u64) -> Vec<i64> {
    (0..count as u64)
        .map(|i| if (i / steps_each_way.max(1)).is_multiple_of(2) { rows } else { -rows })
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Metrics and the verdict.

/// Where a number comes from: `headless` (Rust state and timing on this machine) or `sim` (the
/// Swift half, read from a sim run).
pub const HEADLESS: &str = "headless";

/// One metric's samples.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Metric {
    pub samples: Vec<f64>,
    pub unit: &'static str,
}

impl Metric {
    pub fn stat(&self, stat: Stat) -> Option<f64> {
        let mut sorted = self.samples.clone();
        sorted.sort_by(f64::total_cmp);
        let at = |q: f64| {
            let last = sorted.len().checked_sub(1)?;
            sorted.get((last as f64 * q).round() as usize).copied()
        };
        match stat {
            Stat::N => Some(sorted.len() as f64),
            Stat::P50 => at(0.5),
            Stat::P95 => at(0.95),
            Stat::Max => sorted.last().copied(),
            Stat::Min => sorted.first().copied(),
            Stat::Sum => (!sorted.is_empty()).then(|| sorted.iter().sum()),
        }
    }
}

/// Every metric of one run, by name.
#[derive(Clone, Debug, Default)]
pub struct Metrics(pub BTreeMap<String, Metric>);

impl Metrics {
    pub fn push(&mut self, name: &str, unit: &'static str, value: f64) {
        let metric = self.0.entry(name.to_owned()).or_default();
        metric.unit = unit;
        metric.samples.push(value);
    }

    /// A metric that is a count, present (at 0) even with no samples.
    pub fn count(&mut self, name: &str, add: f64) {
        let metric = self.0.entry(name.to_owned()).or_default();
        metric.unit = "count";
        match metric.samples.first_mut() {
            Some(first) => *first += add,
            None => metric.samples.push(add),
        }
    }

    pub fn declare(&mut self, name: &str, unit: &'static str) {
        self.0.entry(name.to_owned()).or_default().unit = unit;
    }
}

/// One check, judged.
#[derive(Clone, Debug, PartialEq)]
pub struct Judged {
    pub check: Check,
    pub value: Option<f64>,
    pub pass: bool,
}

/// Every check against the metrics. A missing metric or an empty one fails its check.
pub fn judge(checks: &[Check], metrics: &Metrics) -> Vec<Judged> {
    checks
        .iter()
        .map(|check| {
            let value = metrics.0.get(&check.metric).and_then(|metric| metric.stat(check.stat));
            let pass = value.is_some_and(|value| {
                check.max.is_none_or(|max| value <= max) && check.min.is_none_or(|min| value >= min)
            });
            Judged { check: check.clone(), value, pass }
        })
        .collect()
}

/// The commit the run is from: `CMUX_DURESS_COMMIT`, `GITHUB_SHA`, else `git rev-parse`.
pub fn commit(repo: Option<&Path>) -> Option<String> {
    for key in ["CMUX_DURESS_COMMIT", "GITHUB_SHA"] {
        if let Ok(value) = std::env::var(key)
            && !value.is_empty()
        {
            return Some(value);
        }
    }
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .current_dir(repo?)
        .output()
        .ok()?;
    let sha = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (output.status.success() && !sha.is_empty()).then_some(sha)
}

fn round(value: f64) -> Value {
    json!((value * 1000.0).round() / 1000.0)
}

/// The run's one JSON line. `verdict` is `pass`, `fail` or `sim-only`.
pub fn report_json(
    scenario: &Scenario,
    seed: u64,
    commit: Option<&str>,
    metrics: &Metrics,
    judged: &[Judged],
    wall_ms: f64,
) -> Value {
    let mut out_metrics = serde_json::Map::new();
    for (name, metric) in &metrics.0 {
        let mut entry = serde_json::Map::new();
        entry.insert("unit".into(), json!(metric.unit));
        entry.insert("n".into(), json!(metric.samples.len()));
        for stat in [Stat::P50, Stat::P95, Stat::Max] {
            entry.insert(stat.name().into(), metric.stat(stat).map_or(Value::Null, round));
        }
        entry.insert("source".into(), json!(HEADLESS));
        out_metrics.insert(name.clone(), Value::Object(entry));
    }
    let checks: Vec<Value> = judged
        .iter()
        .map(|judged| {
            json!({
                "metric": judged.check.metric,
                "stat": judged.check.stat.name(),
                "value": judged.value.map_or(Value::Null, round),
                "max": judged.check.max,
                "min": judged.check.min,
                "pass": judged.pass,
            })
        })
        .collect();
    let verdict = if !scenario.headless {
        "sim-only"
    } else if judged.iter().all(|judged| judged.pass) {
        "pass"
    } else {
        "fail"
    };
    json!({
        "scenario": scenario.name,
        "verdict": verdict,
        "seed": seed,
        "commit": commit,
        "spec": scenario.spec,
        "headless": scenario.headless,
        "headless_reason": scenario.headless_reason,
        "checks": checks,
        "metrics": Value::Object(out_metrics),
        "sim": {
            "source": "sim",
            "step": scenario.sim.step,
            "args": scenario.sim_args(),
            "covers": scenario.sim.covers,
        },
        "wall_ms": round(wall_ms),
    })
}

/// The verdict for people: one line per check, then each metric's p50/p95/max.
pub fn report_text(scenario: &Scenario, metrics: &Metrics, judged: &[Judged]) -> String {
    let mut out = format!("scenario {}: {}\n", scenario.name, scenario.summary);
    if !scenario.headless {
        out.push_str(&format!(
            "  sim-only: {}\n",
            scenario.headless_reason.as_deref().unwrap_or_default()
        ));
    }
    for judged in judged {
        let bound = match (judged.check.min, judged.check.max) {
            (Some(min), Some(max)) => format!("in [{min}, {max}]"),
            (Some(min), None) => format!(">= {min}"),
            (None, Some(max)) => format!("<= {max}"),
            (None, None) => String::new(),
        };
        let value = judged.value.map_or("missing".to_owned(), |value| format!("{value:.3}"));
        out.push_str(&format!(
            "  {} {} {} = {value} ({bound})\n",
            if judged.pass { "PASS" } else { "FAIL" },
            judged.check.metric,
            judged.check.stat.name(),
        ));
    }
    for (name, metric) in &metrics.0 {
        let show = |stat| metric.stat(stat).map_or("-".to_owned(), |v| format!("{v:.3}"));
        out.push_str(&format!(
            "  {name:<28} p50 {} p95 {} max {} n {} ({})\n",
            show(Stat::P50),
            show(Stat::P95),
            show(Stat::Max),
            metric.samples.len(),
            metric.unit,
        ));
    }
    out.push_str(&format!("  sim: scripts/ci/cmux-next-ios-sim.sh {}\n", scenario.sim_args()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = r#"
name = "tiny"
summary = "a pause"
spec = "idle,stream_kbps=64,stream_seconds=4"
headless = true

[[event]]
kind = "pause"
at_ms = 1000
ms = 1000

[[check]]
metric = "resume_catch_up_ms"
max = 100

[sim]
ui = ["TerminalScrollBench"]
"#;

    #[test]
    fn parses_a_minimal_scenario() {
        let scenario = Scenario::parse(MINIMAL).unwrap();
        assert_eq!(scenario.name, "tiny");
        assert_eq!((scenario.cols, scenario.rows, scenario.frame_bytes), (44, 40, 65536));
        assert_eq!(scenario.events, vec![Event::Pause { at_ms: 1000, ms: 1000 }]);
        assert_eq!(scenario.checks[0].stat, Stat::Max);
        assert_eq!(scenario.checks[0].max, Some(100.0));
        assert_eq!(
            scenario.sim_args(),
            "test ui=TerminalScrollBench duress=idle,stream_kbps=64,stream_seconds=4"
        );
    }

    #[test]
    fn rejects_what_would_run_wrong() {
        let bad = |from: &str, to: &str| Scenario::parse(&MINIMAL.replace(from, to)).unwrap_err();
        assert!(bad("ms = 1000\n", "ms = 1000\nspeed = 2\n").contains("speed"));
        assert!(bad("kind = \"pause\"", "kind = \"warp\"").contains("warp"));
        assert!(bad("spec = \"idle,", "spec = \"idel,").contains("idle, duress, heavy"));
        assert!(bad("max = 100", "").contains("max or min"));
        assert!(bad("headless = true", "headless = false").contains("headless_reason"));
        assert!(bad("name = \"tiny\"", "name = \"Tiny\"").contains("lowercase"));
        assert!(bad("ui = [\"TerminalScrollBench\"]", "ui = []").contains("kit test (only)"));
        // A path reset on a link with no address change and no stall_ms of its own.
        let reset = MINIMAL.replace(
            "kind = \"pause\"\nat_ms = 1000\nms = 1000",
            "kind = \"path_reset\"\nevery_ms = [1000, 2000]",
        );
        assert!(Scenario::parse(&reset).unwrap_err().contains("stall_ms"));
        let handoff = reset.replace("stream_seconds=4", "stream_seconds=4,link=5g-lte-handoff");
        assert!(Scenario::parse(&handoff).is_ok());
    }

    #[test]
    fn sim_only_scenarios_carry_a_reason_and_nothing_to_run() {
        let text = r#"
name = "list-only"
summary = "Swift list"
spec = "duress"
headless = false
headless_reason = "the list is SwiftUI"
[sim]
ui = ["WorkspaceListBench"]
duress = "heavy"
"#;
        let scenario = Scenario::parse(text).unwrap();
        assert_eq!(scenario.sim_args(), "test ui=WorkspaceListBench duress=heavy");
        let with_check = format!("{text}\n[[check]]\nmetric = \"x\"\nmax = 1\n");
        assert!(Scenario::parse(&with_check).unwrap_err().contains("no events or checks"));
    }

    #[test]
    fn pause_holds_deliveries_to_the_resume() {
        let mut times = vec![500.0, 1000.0, 1500.0, 1999.0, 2000.0, 2500.0];
        let mark = apply_pause(&mut times, 1000, 1000);
        assert_eq!(times, vec![500.0, 2000.0, 2000.0, 2000.0, 2000.0, 2500.0]);
        assert_eq!((mark.from_ms, mark.target_ms), (2000.0, 2000.0));
    }

    #[test]
    fn resets_are_seeded_and_inside_their_ranges() {
        let draw =
            |seed| reset_times([60_000, 100_000], [1000, 3000], 0, 400_000.0, &mut Rng::new(seed));
        let resets = draw(7);
        assert_eq!(resets, draw(7));
        assert!((4..=6).contains(&resets.len()), "{resets:?}");
        let mut last = 0.0;
        for (at, stall) in &resets {
            assert!((60_000.0..=100_000.0).contains(&(at - last)), "{resets:?}");
            assert!((1000.0..=3000.0).contains(stall));
            last = *at;
        }
        let mut times = vec![0.0, 10_000.0, 10_500.0, 12_100.0, 12_200.0];
        let mark = apply_reset(&mut times, 10_000.0, 2000.0, 100.0);
        assert_eq!(times, vec![0.0, 12_100.0, 12_100.0, 12_100.0, 12_200.0]);
        assert_eq!((mark.from_ms, mark.burst_ms), (10_000.0, 12_100.0));
    }

    #[test]
    fn ticks_and_scroll_steps() {
        assert_eq!(ticks(250, 0, None, 1000.0), vec![250.0, 500.0, 750.0]);
        assert_eq!(ticks(250, 100, Some(700), 1000.0), vec![100.0, 350.0, 600.0]);
        assert_eq!(scroll_steps(6, -3, 2), vec![-3, -3, 3, 3, -3, -3]);
    }

    #[test]
    fn judge_reads_the_named_stat() {
        let mut metrics = Metrics::default();
        for value in [1.0, 2.0, 3.0, 4.0, 100.0] {
            metrics.push("frame_ms", "ms", value);
        }
        metrics.count("mismatch", 0.0);
        let check = |metric: &str, stat, max, min| Check { metric: metric.into(), stat, max, min };
        let judged = judge(
            &[
                check("frame_ms", Stat::P50, Some(3.0), None),
                check("frame_ms", Stat::Max, Some(50.0), None),
                check("frame_ms", Stat::N, None, Some(5.0)),
                check("mismatch", Stat::Max, Some(0.0), None),
                check("absent", Stat::Max, Some(1.0), None),
            ],
            &metrics,
        );
        let passes: Vec<bool> = judged.iter().map(|j| j.pass).collect();
        assert_eq!(passes, vec![true, false, true, true, false]);
        assert_eq!(judged[1].value, Some(100.0));
        assert_eq!(judged[4].value, None);
    }

    #[test]
    fn report_is_one_json_line_with_sources() {
        let scenario = Scenario::parse(MINIMAL).unwrap();
        let mut metrics = Metrics::default();
        metrics.push("resume_catch_up_ms", "ms", 40.0);
        let judged = judge(&scenario.checks, &metrics);
        let value = report_json(&scenario, 1, Some("abc"), &metrics, &judged, 12.5);
        let line = value.to_string();
        assert!(!line.contains('\n'));
        assert_eq!(value["verdict"], "pass");
        assert_eq!(value["commit"], "abc");
        assert_eq!(value["metrics"]["resume_catch_up_ms"]["source"], "headless");
        assert_eq!(value["metrics"]["resume_catch_up_ms"]["p95"], 40.0);
        assert_eq!(value["sim"]["source"], "sim");
        assert_eq!(value["sim"]["step"], Value::Null);
    }

    #[test]
    fn every_bundled_scenario_parses() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("scenarios");
        let scenarios = load_dir(&dir).unwrap();
        let names: Vec<&str> = scenarios.iter().map(|s| s.name.as_str()).collect();
        for name in [
            "resume-after-1s",
            "turn-path-reset",
            "tui-scroll-lag",
            "tui-scroll-lag-projection",
            "keyboard-open-close",
            "blank-favicons-previews",
            "theme-wallpaper-mismatch",
        ] {
            assert!(names.contains(&name), "{name} missing from {names:?}");
        }
        assert!(find(&dir, "nope").unwrap_err().contains("resume-after-1s"));
        assert!(list_table(&scenarios).contains("sim-only"));
        // A kit-test sim half runs without duress=, which the sim script allows only beside ui=.
        let resume = find(&dir, "resume-after-1s").unwrap();
        assert_eq!(resume.sim_args(), "test only=CmuxMobileLiveTests/ReconnectChainTimingTests");
    }
}
