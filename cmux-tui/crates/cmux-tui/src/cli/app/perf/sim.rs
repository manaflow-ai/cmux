//! `cmux perf sim [--profile cosmic-gray|unreasonable] [--scale N] [--seconds N] [--build-seconds N]
//! [--events N] [--shape FILE]`: load on the app behind a named socket (`--app-socket` or
//! `--socket`; it never guesses).
//!
//! It builds first (cut short after `--build-seconds`, default 180), then runs for `--seconds`
//! from the moment the build ends; the summary gives `build_ms` and `run_ms` apart. Before it
//! builds it caps its terminals at the host's free PTYs less a headroom (pty.rs) and says so.
//!
//! The shape is data: `--shape FILE`, else `$CMUX_PERF_SIM_DIR/<profile>.json` (default
//! `~/.local/share/cmux-perf-sim/`; a mirror tool may write it from a real session), else the
//! built-in profiles.json. A file may also be a capture of a real session (schema
//! `cmux-perf-sim-profile/1`, what the mirror exports): its workspaces, panes per workspace,
//! busy terminals, streaming chats and browser pages replace the shape's counts, and `--scale N`
//! multiplies them. It makes
//! workspaces of split terminals, puts busy output loops and fake agent sessions (scripted
//! agent-like output, no model) in them, opens local pages it serves itself, fires a burst of
//! `--events` lines across its terminals (and again every `burst_every_s`), and churns the
//! layout: tab and workspace switches, sidebar toggles, splits, equalize and pane resizes.
//!
//! Everything it makes lives in workspaces it made; on exit or Ctrl-C it closes exactly those
//! and goes back to the workspace that was shown. Its state file (temp dir, per socket) lists
//! them, and `cmux perf profile --probe` types into its terminals only.

use std::collections::BTreeSet;
use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::SimArgs;

pub(super) const DEFAULT_PROFILE: &str = "cosmic-gray";
pub(super) const MAX_EVENTS: u64 = 1_000_000;
const BUILTIN: &str = include_str!("profiles.json");
/// The schema of a captured session (the mirror's export).
pub(super) const CAPTURE_SCHEMA: &str = "cmux-perf-sim-profile/1";
/// Captured sessions shipped with the binary, by the name a shape's `capture` gives.
const CAPTURES: &[(&str, &str)] =
    &[("cosmic-gray-2026-11-21", include_str!("captures/cosmic-gray-2026-11-21.json"))];
pub(super) const MAX_SCALE: usize = 100;
const TIMEOUT: Duration = Duration::from_secs(30);

/// One load shape (profiles.json).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub(super) struct Shape {
    pub description: String,
    /// A built-in capture whose counts replace this shape's (see [`apply_capture`]).
    pub capture: Option<String>,
    /// Every count times this, after the capture.
    pub scale: usize,
    pub workspaces: usize,
    /// Panes in each workspace, one entry per workspace; empty: `splits_per_workspace + 1` each.
    pub panes_per_workspace: Vec<usize>,
    pub splits_per_workspace: usize,
    pub max_panes_per_workspace: usize,
    pub extra_tabs_per_pane: usize,
    pub busy_terminals: usize,
    pub busy_sleep_s: f64,
    pub agents: usize,
    pub agent_sleep_s: f64,
    pub browsers: usize,
    pub burst_lines: u64,
    /// 0: one burst only.
    pub burst_every_s: u64,
    pub churn_interval_ms: u64,
    /// Steps: tab, workspace, sidebar, split, equalize, resize.
    pub churn: Vec<String>,
    /// `{sleep}`.
    pub busy_command: String,
    /// `{name}`, `{sleep}`.
    pub agent_command: String,
    /// `{lines}`.
    pub burst_command: String,
}

impl Default for Shape {
    fn default() -> Self {
        Self {
            description: String::new(),
            capture: None,
            scale: 1,
            workspaces: 1,
            panes_per_workspace: Vec::new(),
            splits_per_workspace: 1,
            max_panes_per_workspace: 4,
            extra_tabs_per_pane: 0,
            busy_terminals: 1,
            busy_sleep_s: 0.02,
            agents: 1,
            agent_sleep_s: 0.1,
            browsers: 0,
            burst_lines: super::DEFAULT_SIM_EVENTS,
            burst_every_s: 0,
            churn_interval_ms: 500,
            churn: vec!["tab".into(), "workspace".into(), "sidebar".into(), "sidebar".into()],
            busy_command: "while :; do echo \"$RANDOM stress output line\"; sleep {sleep}; done\r"
                .into(),
            agent_command: "while :; do echo '{name}: working'; sleep {sleep}; done\r".into(),
            burst_command: "seq 1 {lines}\r".into(),
        }
    }
}

pub(super) fn builtin_profiles() -> Vec<String> {
    serde_json::from_str::<Value>(BUILTIN)
        .ok()
        .and_then(|v| v["profiles"].as_object().map(|p| p.keys().cloned().collect()))
        .unwrap_or_default()
}

pub(super) fn is_known_profile(name: &str) -> bool {
    builtin_profiles().iter().any(|known| known == name)
        || mirror_path(name).is_some_and(|p| p.exists())
}

fn mirror_path(profile: &str) -> Option<PathBuf> {
    if profile.contains('/') || profile.contains("..") {
        return None;
    }
    let dir = match std::env::var_os("CMUX_PERF_SIM_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(std::env::var_os("HOME")?).join(".local/share/cmux-perf-sim"),
    };
    Some(dir.join(format!("{profile}.json")))
}

/// What a captured session says, in the mirror's `cmux-perf-sim-profile/1` export.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub(super) struct Capture {
    pub source: String,
    pub captured_at: String,
    pub workspaces: usize,
    pub panes_per_workspace: Vec<usize>,
    pub streaming_chats: usize,
    pub busy_terminals: usize,
    pub browser_pages: usize,
}

/// `shape` with `capture`'s counts: its workspaces and panes, its busy terminals, its streaming
/// chats as fake agent terminals (no model runs) and its browser pages. A count the shape sets
/// higher stays (a stress profile adds load on top of the real session).
pub(super) fn apply_capture(mut shape: Shape, capture: &Capture) -> Shape {
    let mut panes = capture.panes_per_workspace.clone();
    panes.resize(capture.workspaces, 1);
    shape.workspaces = capture.workspaces;
    shape.panes_per_workspace = panes;
    shape.busy_terminals = shape.busy_terminals.max(capture.busy_terminals);
    shape.agents = shape.agents.max(capture.streaming_chats);
    shape.browsers = shape.browsers.max(capture.browser_pages);
    if shape.description.is_empty() {
        shape.description = format!("{} ({})", capture.source, capture.captured_at);
    }
    shape
}

/// `shape` with every count times `factor`: workspaces (the pane list repeats), busy terminals,
/// agents and pages. The burst stays `burst_lines` lines at once.
pub(super) fn scale(mut shape: Shape, factor: usize) -> Shape {
    let factor = factor.clamp(1, MAX_SCALE);
    if factor == 1 {
        return shape;
    }
    shape.workspaces *= factor;
    shape.panes_per_workspace = shape.panes_per_workspace.repeat(factor);
    shape.busy_terminals *= factor;
    shape.agents *= factor;
    shape.browsers *= factor;
    shape
}

/// How many panes workspace `index` of `shape` gets.
pub(super) fn panes_in(shape: &Shape, index: usize) -> usize {
    shape.panes_per_workspace.get(index).copied().unwrap_or(shape.splits_per_workspace + 1).max(1)
}

/// How many terminals (each one PTY) `shape`'s build opens.
pub(super) fn terminals_in(shape: &Shape) -> usize {
    (0..shape.workspaces).map(|i| panes_in(shape, i) * (1 + shape.extra_tabs_per_pane)).sum()
}

/// `shape` trimmed so its build opens at most `cap` terminals: workspaces keep their panes in
/// order, the one that crosses the cap gets what is left and the rest are not made.
pub(super) fn cap_terminals(mut shape: Shape, cap: usize) -> Shape {
    if terminals_in(&shape) <= cap {
        return shape;
    }
    let per_pane = 1 + shape.extra_tabs_per_pane;
    let mut left = cap;
    let mut panes = Vec::new();
    for index in 0..shape.workspaces {
        let fit = panes_in(&shape, index).min(left / per_pane);
        if fit == 0 {
            break;
        }
        panes.push(fit);
        left -= fit * per_pane;
    }
    shape.workspaces = panes.len();
    shape.panes_per_workspace = panes;
    shape
}

/// The sim's two phases on one clock: the build, cut short at its own deadline, then the run,
/// whose `--seconds` start when the build ends (a slow build never eats the run's window).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Phases {
    pub build_started: Instant,
    pub build_until: Instant,
    pub run_started: Option<Instant>,
    pub run_until: Option<Instant>,
}

impl Phases {
    pub fn new(now: Instant, build_limit: Duration) -> Self {
        Self {
            build_started: now,
            build_until: now + build_limit,
            run_started: None,
            run_until: None,
        }
    }

    /// The build's deadline has passed.
    pub fn build_over(&self, now: Instant) -> bool {
        now >= self.build_until
    }

    /// Ends the build at `now` and starts the run's `seconds`.
    pub fn start_run(&mut self, now: Instant, seconds: u64) {
        self.run_started = Some(now);
        self.run_until = Some(now + Duration::from_secs(seconds));
    }

    /// The run has time left at `now` (false before it starts).
    pub fn running(&self, now: Instant) -> bool {
        self.run_until.is_some_and(|until| now < until)
    }

    /// How long the build took (up to `now` while it is still going).
    pub fn build_time(&self, now: Instant) -> Duration {
        self.run_started.unwrap_or(now).saturating_duration_since(self.build_started)
    }

    /// How long the run took up to `now`.
    pub fn run_time(&self, now: Instant) -> Duration {
        self.run_started.map(|start| now.saturating_duration_since(start)).unwrap_or_default()
    }
}

fn builtin_capture(name: &str) -> Option<Capture> {
    CAPTURES
        .iter()
        .find(|(known, _)| *known == name)
        .and_then(|(_, text)| serde_json::from_str(text).ok())
}

/// A shape from a file's text: a capture, a bare shape, or `{"profiles": {name: shape}}`.
/// A capture takes the built-in `profile` (else cosmic-gray) for its timings and commands.
pub(super) fn parse_shape(text: &str, profile: &str) -> Option<Shape> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value["schema"] == CAPTURE_SCHEMA {
        let capture: Capture = serde_json::from_value(value).ok()?;
        let mut base =
            parse_shape(BUILTIN, profile).or_else(|| parse_shape(BUILTIN, DEFAULT_PROFILE))?;
        base.capture = None;
        base.description = String::new();
        let factor = base.scale;
        return Some(scale(apply_capture(base, &capture), factor));
    }
    let shape = match value.get("profiles") {
        Some(profiles) => profiles.get(profile)?.clone(),
        None => value,
    };
    let shape: Shape = serde_json::from_value(shape).ok()?;
    let factor = shape.scale;
    let shape = match shape.capture.as_deref() {
        Some(name) => apply_capture(shape.clone(), &builtin_capture(name)?),
        None => shape,
    };
    Some(scale(shape, factor))
}

/// The shape for `args`: `--shape`, else the mirrored file, else the built-in one.
pub(super) fn load_shape(args: &SimArgs) -> Result<(Shape, String), String> {
    let messages = &crate::localization::catalog().app_control.perf;
    let from_file = |path: &Path| -> Result<(Shape, String), String> {
        let text = std::fs::read_to_string(path).map_err(|error| {
            super::fill(
                messages.unreadable,
                &[("path", path.display().to_string()), ("error", error.to_string())],
            )
        })?;
        parse_shape(&text, &args.profile)
            .map(|shape| (shape, path.display().to_string()))
            .ok_or_else(|| messages.bad_shape.replace("{path}", &path.display().to_string()))
    };
    let found = if let Some(path) = &args.shape {
        from_file(path)
    } else if let Some(path) = mirror_path(&args.profile).filter(|p| p.exists()) {
        from_file(&path)
    } else {
        parse_shape(BUILTIN, &args.profile)
            .map(|shape| (shape, "built-in".into()))
            .ok_or_else(|| messages.unknown_profile.replace("{name}", &args.profile))
    };
    found.map(|(shape, from)| (scale(shape, args.scale), from))
}

/// `template` with `{name}` filled.
pub(super) fn command(template: &str, pairs: &[(&str, String)]) -> String {
    super::fill(template, pairs)
}

/// How many of `total` lines each of `terminals` prints so the burst is `total` in all.
pub(super) fn burst_split(total: u64, terminals: usize) -> Vec<u64> {
    if terminals == 0 {
        return Vec::new();
    }
    let n = terminals as u64;
    (0..n).map(|i| total / n + u64::from(i < total % n)).filter(|lines| *lines > 0).collect()
}

/// The roles for `terminals` terminals: busy loops first, then agents; extra terminals idle.
pub(super) fn roles(shape: &Shape, terminals: usize) -> Vec<Role> {
    (0..terminals)
        .map(|i| {
            if i < shape.busy_terminals {
                Role::Busy
            } else if i < shape.busy_terminals + shape.agents {
                Role::Agent(i - shape.busy_terminals + 1)
            } else {
                Role::Idle
            }
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Role {
    Busy,
    Agent(usize),
    Idle,
}

/// What a run made, also written to its state file.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub(super) struct State {
    pub pid: u32,
    pub socket: String,
    pub workspaces: Vec<String>,
    pub terminals: Vec<String>,
    pub panes: Vec<(String, String)>,
}

fn state_path(socket: &Path) -> PathBuf {
    // FNV-1a of the socket path: one state file per app.
    let hash = socket
        .to_string_lossy()
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
    std::env::temp_dir().join(format!("cmux-perf-sim-{hash:016x}.json"))
}

/// The terminals a live `cmux perf sim` on `global`'s socket made (none when no sim runs).
pub(super) fn state_terminal_tabs(global: &GlobalArgs) -> Vec<String> {
    let Ok(socket) = super::super::command_socket(global) else { return Vec::new() };
    let Ok(text) = std::fs::read_to_string(state_path(&socket.path)) else { return Vec::new() };
    let Ok(state) = serde_json::from_str::<State>(&text) else { return Vec::new() };
    // SAFETY: kill with signal 0 only checks that the pid exists.
    let alive = unsafe { libc::kill(state.pid as libc::pid_t, 0) } == 0;
    if alive { state.terminals } else { Vec::new() }
}

/// The local pages the browser tabs load: one animated page, from a loopback port.
struct Pages {
    url: String,
    stop: Arc<AtomicBool>,
}

const PAGE: &str = "<!doctype html><title>cmux perf sim</title><style>body{font:14px monospace;margin:0}\
.b{position:absolute;width:40px;height:40px;background:#58f;border-radius:8px;animation:m 1.2s ease-in-out infinite alternate}\
@keyframes m{to{transform:translate(70vw,60vh) rotate(180deg)}}</style><div id=log></div><script>\
for(let i=0;i<24;i++){const d=document.createElement('div');d.className='b';d.style.left=(i*4)+'%';d.style.animationDelay=(i*0.05)+'s';document.body.appendChild(d)}\
let n=0;const log=document.getElementById('log');function tick(){n++;const p=document.createElement('div');p.textContent='event '+n+' '+Math.random();log.prepend(p);while(log.childNodes.length>400)log.lastChild.remove();requestAnimationFrame(tick)}tick();</script>";

impl Pages {
    /// The server thread belongs to `scope`; dropping the Pages stops it and the scope joins it.
    fn start<'scope, 'env>(scope: &'scope std::thread::Scope<'scope, 'env>) -> Option<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").ok()?;
        listener.set_nonblocking(true).ok()?;
        let url = format!("http://127.0.0.1:{}/", listener.local_addr().ok()?.port());
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        scope.spawn(move || {
            while !flag.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut conn, _)) => {
                        let _ = conn.set_nonblocking(false);
                        let _ = conn.set_read_timeout(Some(Duration::from_secs(2)));
                        let mut buf = [0u8; 2048];
                        let _ = conn.read(&mut buf);
                        let body = PAGE.as_bytes();
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = conn.write_all(head.as_bytes());
                        let _ = conn.write_all(body);
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(20)),
                }
            }
        });
        Some(Self { url, stop })
    }
}

impl Drop for Pages {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

struct Sim<'a> {
    stream: UnixStream,
    state: State,
    state_file: PathBuf,
    shape: &'a Shape,
    refusals: Vec<String>,
    sidebar_toggles: usize,
    actions: u64,
    /// While building: the build's deadline; every wait ends by it.
    build_until: Option<Instant>,
    /// The most terminals the sim may open (the host's PTYs less headroom); `None`: no cap.
    terminal_cap: Option<usize>,
    /// Terminals the churn's splits opened.
    churn_terminals: usize,
}

fn interrupted() -> bool {
    crate::shutdown_requested()
}

impl Sim<'_> {
    fn action(&mut self, name: &str, args: Value, target: Option<String>, focus: bool) -> bool {
        let mut params =
            json!({ "action": name, "args": args, "focus": focus, "origin": "script" });
        if let Some(target) = target {
            params["target"] = json!(target);
        }
        self.actions += 1;
        match super::super::exchange(&mut self.stream, "action.run", params, TIMEOUT) {
            Ok(Ok(_)) => true,
            Ok(Err(error)) => {
                self.refusals
                    .push(format!("{name}: {}", error["message"].as_str().unwrap_or("refused")));
                false
            }
            Err(error) => {
                self.refusals.push(format!("{name}: {error}"));
                false
            }
        }
    }

    fn topology(&mut self) -> Value {
        super::profile::call(&mut self.stream, "snapshot.get", json!({}))
            .map(|s| s["topology"].clone())
            .unwrap_or(Value::Null)
    }

    fn wait_for<T>(
        &mut self,
        seconds: u64,
        mut probe: impl FnMut(&Value) -> Option<T>,
    ) -> Option<T> {
        let mut deadline = Instant::now() + Duration::from_secs(seconds);
        if let Some(until) = self.build_until {
            deadline = deadline.min(until);
        }
        while Instant::now() < deadline && !interrupted() {
            if let Some(found) = probe(&self.topology()) {
                return Some(found);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        None
    }

    fn save(&self) {
        let _ = std::fs::write(
            &self.state_file,
            serde_json::to_string(&self.state).unwrap_or_default(),
        );
    }

    fn new_workspace(&mut self) -> Option<String> {
        let before = workspace_ids(&self.topology());
        self.action("workspace.newAtBottom", json!({}), None, true);
        let made =
            self.wait_for(30, |t| workspace_ids(t).into_iter().find(|id| !before.contains(id)))?;
        self.state.workspaces.push(made.clone());
        self.save();
        self.action("goToWorkspace", json!({ "workspace": made }), None, true);
        Some(made)
    }

    fn split(&mut self, workspace: &str, pane: &str, verb: &str) -> Option<String> {
        let before: BTreeSet<String> =
            panes(&self.topology(), workspace).into_iter().map(|p| p.0).collect();
        self.action(verb, json!({}), Some(format!("pane:{pane}")), false);
        let ws = workspace.to_owned();
        self.wait_for(15, |t| {
            panes(t, &ws).into_iter().find(|p| !before.contains(&p.0)).map(|p| p.0)
        })
    }

    fn terminal_of(
        &mut self,
        workspace: &str,
        pane: &str,
        skip: &BTreeSet<String>,
    ) -> Option<String> {
        let (ws, pane) = (workspace.to_owned(), pane.to_owned());
        self.wait_for(20, |t| {
            panes(t, &ws).into_iter().find(|p| p.0 == pane).and_then(|p| {
                p.1.into_iter()
                    .find(|(id, kind)| {
                        kind == "terminal" && !id.starts_with("pending_") && !skip.contains(id)
                    })
                    .map(|t| t.0)
            })
        })
    }

    fn send(&mut self, tab: &str, text: String) {
        self.action(
            "terminal.sendText",
            json!({ "text": text }),
            Some(format!("tab:{tab}")),
            false,
        );
    }

    /// Interrupted, or the build's deadline passed.
    fn stop_building(&self) -> bool {
        interrupted() || self.build_until.is_some_and(|until| Instant::now() >= until)
    }

    /// Builds the shape until its deadline; whether it was cut short.
    fn build(&mut self, pages: Option<&Pages>) -> bool {
        let cut = self.build_workspaces(pages);
        self.build_until = None;
        self.start_roles();
        cut
    }

    fn build_workspaces(&mut self, pages: Option<&Pages>) -> bool {
        let shape = self.shape;
        for index in 0..shape.workspaces {
            if self.stop_building() {
                return !interrupted();
            }
            let Some(workspace) = self.new_workspace() else { continue };
            let Some(first) =
                self.wait_for(30, |t| panes(t, &workspace).first().map(|p| p.0.clone()))
            else {
                continue;
            };
            let mut ws_panes = vec![first];
            for split in 0..panes_in(shape, index) - 1 {
                if self.stop_building() {
                    return !interrupted();
                }
                let verb = if split % 2 == 0 { "splitRight" } else { "splitDown" };
                let at = ws_panes[ws_panes.len() - 1].clone();
                if let Some(pane) = self.split(&workspace, &at, verb) {
                    ws_panes.push(pane);
                }
            }
            for pane in &ws_panes {
                let mut mine = BTreeSet::new();
                if let Some(tab) = self.terminal_of(&workspace, pane, &mine) {
                    mine.insert(tab.clone());
                    self.state.terminals.push(tab.clone());
                    for _ in 0..shape.extra_tabs_per_pane {
                        self.action("newSurface", json!({}), Some(format!("tab:{tab}")), false);
                        if let Some(extra) = self.terminal_of(&workspace, pane, &mine) {
                            mine.insert(extra.clone());
                            self.state.terminals.push(extra);
                        }
                    }
                }
                self.state.panes.push((workspace.clone(), pane.clone()));
            }
            self.save();
            if let Some(pages) = pages {
                let per = shape.browsers.div_ceil(shape.workspaces.max(1));
                let opened = self.state.terminals.len();
                for _ in 0..per.min(shape.browsers.saturating_sub(index * per)) {
                    if let Some(tab) = self.state.terminals.get(opened.saturating_sub(1)).cloned() {
                        self.action(
                            "openBrowser.chromium",
                            json!({ "url": pages.url }),
                            Some(format!("tab:{tab}")),
                            false,
                        );
                    }
                }
            }
            eprintln!(
                "cmux perf sim: workspace {}/{} ({} terminals)",
                index + 1,
                shape.workspaces,
                self.state.terminals.len()
            );
        }
        false
    }

    fn burst(&mut self, total: u64) {
        let terminals = self.state.terminals.clone();
        for (tab, lines) in terminals.iter().zip(burst_split(total, terminals.len())) {
            // A busy terminal's loop reads its input only at its prompt; the burst goes to the idle
            // and agent shells too, so the app gets it from every pane at once.
            self.send(
                tab,
                format!(
                    "\u{3}{}",
                    command(&self.shape.burst_command, &[("lines", lines.to_string())])
                ),
            );
        }
    }

    /// Starts (or, after a burst, restarts) each terminal's busy loop or fake agent.
    fn start_roles(&mut self) {
        let terminals = self.state.terminals.clone();
        let shape = self.shape;
        for (tab, role) in terminals.iter().zip(roles(shape, terminals.len())) {
            match role {
                Role::Busy => self.send(
                    tab,
                    command(&shape.busy_command, &[("sleep", shape.busy_sleep_s.to_string())]),
                ),
                Role::Agent(n) => self.send(
                    tab,
                    command(
                        &shape.agent_command,
                        &[
                            ("name", format!("agent-{n}")),
                            ("sleep", shape.agent_sleep_s.to_string()),
                        ],
                    ),
                ),
                Role::Idle => {}
            }
        }
    }

    fn churn(&mut self, step: &str, tick: usize) {
        let workspaces = self.state.workspaces.clone();
        let panes_made = self.state.panes.clone();
        match step {
            "tab" => {
                self.action(
                    if tick % 2 == 0 { "nextSurface" } else { "prevSurface" },
                    json!({}),
                    None,
                    true,
                );
            }
            "workspace" if !workspaces.is_empty() => {
                let workspace = &workspaces[tick % workspaces.len()];
                self.action("goToWorkspace", json!({ "workspace": workspace }), None, true);
            }
            "sidebar" => {
                if self.action("toggleSidebar", json!({}), None, true) {
                    self.sidebar_toggles += 1;
                }
            }
            "split" if !panes_made.is_empty() => {
                let (workspace, pane) = &panes_made[tick % panes_made.len()];
                let count = panes(&self.topology(), workspace).len();
                let at_cap = self
                    .terminal_cap
                    .is_some_and(|cap| self.state.terminals.len() + self.churn_terminals >= cap);
                if !at_cap
                    && count < self.shape.max_panes_per_workspace
                    && let Some(new) = self.split(
                        workspace,
                        pane,
                        if tick % 2 == 0 { "splitRight" } else { "splitDown" },
                    )
                {
                    self.churn_terminals += 1;
                    self.state.panes.push((workspace.clone(), new));
                    self.save();
                }
            }
            "equalize" => {
                self.action("equalizeSplits", json!({}), None, true);
            }
            "resize" if !panes_made.is_empty() => {
                let (_, pane) = &panes_made[tick % panes_made.len()];
                let verb = ["resizePaneRight", "resizePaneLeft", "resizePaneDown", "resizePaneUp"]
                    [tick % 4];
                self.action(verb, json!({}), Some(format!("pane:{pane}")), false);
            }
            _ => {}
        }
    }

    fn cleanup(&mut self, shown: Option<String>) {
        if self.sidebar_toggles % 2 == 1 {
            self.action("toggleSidebar", json!({}), None, true);
        }
        if let Some(workspace) = shown {
            self.action("goToWorkspace", json!({ "workspace": workspace }), None, true);
        }
        for workspace in self.state.workspaces.clone() {
            self.action(
                "closeWorkspace",
                json!({ "confirm": true }),
                Some(format!("workspace:{workspace}")),
                false,
            );
        }
        let _ = std::fs::remove_file(&self.state_file);
    }
}

fn workspace_ids(topology: &Value) -> BTreeSet<String> {
    topology["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| w["id"].as_str().map(str::to_owned))
        .collect()
}

/// `workspace`'s panes (not docks): id and (tab id, kind) pairs.
pub(super) fn panes(topology: &Value, workspace: &str) -> Vec<(String, Vec<(String, String)>)> {
    topology["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|w| w["id"] == workspace)
        .flat_map(|w| w["screens"].as_array().into_iter().flatten())
        .flat_map(|s| s["panes"].as_array().into_iter().flatten())
        .filter(|p| p["dock"].is_null() || p["dock"] == false)
        .filter_map(|p| {
            let id = p["id"].as_str()?.to_owned();
            let tabs = p["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|t| {
                    Some((
                        t["id"].as_str()?.to_owned(),
                        t["kind"].as_str().unwrap_or("").to_owned(),
                    ))
                })
                .collect();
            Some((id, tabs))
        })
        .collect()
}

pub(super) fn run(global: &GlobalArgs, args: &SimArgs) -> i32 {
    std::thread::scope(|scope| run_in(scope, global, args))
}

fn run_in<'scope, 'env>(
    scope: &'scope std::thread::Scope<'scope, 'env>,
    global: &GlobalArgs,
    args: &SimArgs,
) -> i32 {
    let messages = &crate::localization::catalog().app_control.perf;
    let output = global.output;
    let print_error = |code: &str, message: String| {
        super::super::super::wire::print_local_error(&super::local_error(code, message), output, 2)
    };
    let socket = match super::super::command_socket(global) {
        Ok(socket) if socket.named_by.is_some() => socket,
        _ => return print_error("perf.sim_needs_socket", messages.sim_needs_socket.to_owned()),
    };
    let (shape, from) = match load_shape(args) {
        Ok(found) => found,
        Err(message) => return print_error("perf.bad_shape", message),
    };
    // The host's PTYs are shared with every other terminal on it: keep some free.
    let pool = super::pty::read_pool();
    let terminal_cap = pool.map(|pool| super::pty::cap(pool, super::pty::HEADROOM));
    let wanted = terminals_in(&shape);
    let shape = match terminal_cap {
        Some(cap) => cap_terminals(shape, cap),
        None => shape,
    };
    if let (Some(pool), Some(cap)) = (pool, terminal_cap) {
        eprintln!(
            "{}",
            super::fill(
                messages.sim_pty_cap,
                &[
                    ("max", pool.max.to_string()),
                    ("used", pool.in_use.map_or_else(|| "?".to_owned(), |n| n.to_string())),
                    ("headroom", super::pty::HEADROOM.to_string()),
                    ("cap", cap.to_string()),
                    ("wanted", wanted.to_string()),
                    ("terminals", terminals_in(&shape).to_string()),
                ],
            )
        );
    }
    let mut stream = match super::super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::super::wire::print_local_error(&error, output, 3),
    };
    let shown = super::profile::call(&mut stream, "snapshot.get", json!({})).and_then(|s| {
        s["topology"]["windows"]
            .as_array()
            .and_then(|w| w.first())
            .and_then(|w| w["workspace"].as_str())
            .map(str::to_owned)
    });
    eprintln!(
        "{}",
        super::fill(
            messages.sim_start,
            &[
                ("profile", args.profile.clone()),
                ("from", from),
                ("seconds", args.seconds.to_string()),
                ("events", args.events.unwrap_or(shape.burst_lines).to_string())
            ],
        )
    );
    let pages = if shape.browsers > 0 { Pages::start(scope) } else { None };
    let mut sim = Sim {
        stream,
        state: State {
            pid: std::process::id(),
            socket: socket.path.display().to_string(),
            ..State::default()
        },
        state_file: state_path(&socket.path),
        shape: &shape,
        refusals: Vec::new(),
        sidebar_toggles: 0,
        actions: 0,
        build_until: None,
        terminal_cap,
        churn_terminals: 0,
    };
    sim.save();
    let mut phases = Phases::new(Instant::now(), Duration::from_secs(args.build_seconds));
    sim.build_until = Some(phases.build_until);
    let build_cut = sim.build(pages.as_ref());
    phases.start_run(Instant::now(), args.seconds);
    let build_ms = phases.build_time(Instant::now()).as_millis();
    eprintln!(
        "{}",
        super::fill(
            if build_cut { messages.sim_built_cut } else { messages.sim_built },
            &[
                ("build_s", format!("{:.1}", build_ms as f64 / 1000.0)),
                ("terminals", sim.state.terminals.len().to_string()),
                ("seconds", args.seconds.to_string()),
            ],
        )
    );
    let events = args.events.unwrap_or(shape.burst_lines).clamp(1, MAX_EVENTS);
    let mut bursts = 0;
    if !interrupted() {
        sim.burst(events);
        bursts += 1;
    }
    let mut last_burst = Instant::now();
    let interval = Duration::from_millis(shape.churn_interval_ms.max(10));
    let mut tick = 0usize;
    while phases.running(Instant::now()) && !interrupted() {
        if !shape.churn.is_empty() {
            let step = shape.churn[tick % shape.churn.len()].clone();
            sim.churn(&step, tick);
        }
        tick += 1;
        if shape.burst_every_s > 0
            && last_burst.elapsed() >= Duration::from_secs(shape.burst_every_s)
        {
            sim.burst(events);
            sim.start_roles();
            bursts += 1;
            last_burst = Instant::now();
        }
        std::thread::sleep(interval);
    }
    let interrupted = interrupted();
    let run_ms = phases.run_time(Instant::now()).as_millis();
    sim.cleanup(shown);
    drop(pages);
    let summary = json!({
        "profile": args.profile,
        "shape": shape,
        "workspaces": sim.state.workspaces.len(),
        "panes": sim.state.panes.len(),
        "terminals": sim.state.terminals.len(),
        "bursts": bursts,
        "events_per_burst": events,
        "churn_steps": tick,
        "actions": sim.actions,
        "build_ms": build_ms,
        "build_cut_short": build_cut,
        "build_seconds_max": args.build_seconds,
        "run_ms": run_ms,
        "seconds": args.seconds,
        "terminal_cap": terminal_cap,
        "terminals_wanted": wanted,
        "interrupted": interrupted,
        "refusals": sim.refusals.iter().take(20).collect::<Vec<_>>(),
        "refusal_count": sim.refusals.len(),
    });
    let code = super::super::super::wire::print_local_success(&summary, output);
    if interrupted { 130 } else { code }
}
