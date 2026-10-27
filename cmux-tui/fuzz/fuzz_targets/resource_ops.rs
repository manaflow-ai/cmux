//! Resource-op sequence fuzzer (plans/cmux-next/chrome-parity/p15-oracle.md,
//! task 186): `arbitrary` decodes the input into a sequence of typed
//! `cmux.protocol/2` requests (workspace, screen, pane, tab and terminal
//! mutations, reads and same-key retries) whose ids are picked from the live
//! session, a closed object or a well-formed id that never existed. Each
//! request goes through the daemon's own dispatch in process
//! (`cmux_tui_core::fuzz_entry::ResourceSession`); after each one the target
//! reads `session.snapshot` and checks I1, I2 and the facet's consistency
//! (support/resource_walk.rs). A broken one, like a daemon panic, is a crash.
//! The process runs in an oracle case's hermetic environment
//! (`hermetic_environment`), set once before the first input.
//!
//! Chrome reference (chromium/src): mojo/docs/mojolpm.md, a structured
//! fuzzer that drives a real interface implementation in process with a
//! sequence of typed calls and their ids; testing/libfuzzer/README.md for
//! the coverage-guided loop and typed inputs (FuzzTest's domains).
//!
//! A crash becomes an oracle walk case: `fuzz_to_case.py` replays the crash
//! with `CMUX_RESOURCE_OPS_WALK` set, and this target then writes every
//! step as a case-v1 step (ids as `$step:` references into the session
//! snapshot taken before the step) and the reply's outcome.
#![no_main]

#[path = "support/resource_walk.rs"]
mod resource_walk;

use std::collections::{BTreeMap, BTreeSet};

use arbitrary::Arbitrary;
use cmux_tui_core::fuzz_entry::ResourceSession;
use libfuzzer_sys::fuzz_target;
use resource_walk::{PROTOCOL, Recorder, Scope, Violation};
use serde_json::{Map, Value, json};

/// Steps of one input: enough to build, split, move and close a few
/// workspaces, few enough that one input stays well under a second.
const MAX_OPS: usize = 24;
/// Each terminal runs this instead of a login shell: it starts at once,
/// writes nothing and exits when its PTY closes.
const TERMINAL_ARGV: &str = "/bin/cat";

#[derive(Arbitrary, Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Workspace,
    Screen,
    Pane,
    Tab,
    Terminal,
}

impl Kind {
    fn table(self) -> &'static str {
        match self {
            Self::Workspace => "workspaces",
            Self::Screen => "screens",
            Self::Pane => "panes",
            Self::Tab => "tabs",
            Self::Terminal => "terminals",
        }
    }

    /// The selector name, which is also the object kind of the walk.
    fn selector(self) -> &'static str {
        match self {
            Self::Workspace => "workspace",
            Self::Screen => "screen",
            Self::Pane => "pane",
            Self::Tab => "tab",
            Self::Terminal => "terminal",
        }
    }

    /// A well-formed id of this kind that no session ever gives out.
    fn unknown_id(self) -> String {
        let prefix = match self {
            Self::Workspace => "ws",
            Self::Screen => "screen",
            Self::Pane => "pane",
            Self::Tab => "tab",
            Self::Terminal => "term",
        };
        format!("{prefix}_{}", "0".repeat(32))
    }
}

/// Which object an id names.
#[derive(Arbitrary, Debug, Clone, Copy)]
enum Pick {
    /// The n-th (modulo) live object of its kind.
    Live(u8),
    /// The n-th (modulo) object of its kind an earlier step closed.
    Gone(u8),
    /// An id that never existed.
    Unknown,
}

#[derive(Arbitrary, Debug, Clone)]
struct Text(String);

impl Text {
    fn value(&self) -> String {
        self.0.chars().take(40).collect()
    }
}

fn nullable(text: &Option<Text>) -> Value {
    text.as_ref().map_or(Value::Null, |text| json!(text.value()))
}

#[derive(Arbitrary, Debug, Clone, Copy)]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    fn wire(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Up => "up",
            Self::Down => "down",
        }
    }
}

#[derive(Arbitrary, Debug, Clone, Copy)]
enum Read {
    WorkspaceList,
    WorkspaceGet,
    ScreenGet,
    PaneGet,
    TabGet,
}

#[derive(Arbitrary, Debug, Clone)]
enum Op {
    WorkspaceCreate {
        terminal: bool,
        name: Option<Text>,
        focus: bool,
    },
    WorkspaceClose(Pick),
    WorkspaceRename(Pick, Text),
    WorkspaceFocus(Pick),
    ScreenCreate {
        workspace: Option<Pick>,
        name: Option<Text>,
    },
    ScreenClose(Pick),
    ScreenFocus(Pick),
    ScreenRename(Pick, Option<Text>),
    PaneCreate {
        screen: Option<Pick>,
    },
    PaneSplit {
        pane: Pick,
        direction: Direction,
        ratio: Option<u8>,
    },
    PaneClose(Pick),
    PaneFocus(Pick),
    PaneZoom(Pick, Option<bool>),
    PaneRename(Pick, Option<Text>),
    PaneSwap(Pick, Pick),
    TabCreateTerminal {
        pane: Option<Pick>,
    },
    TabClose {
        tab: Pick,
        pane: Option<Pick>,
    },
    TabFocus {
        tab: Pick,
        pane: Option<Pick>,
    },
    TabRename(Pick, Option<Text>),
    TabMove {
        tab: Pick,
        to: Pick,
        index: u8,
    },
    TabPin {
        tab: Pick,
        pin: bool,
    },
    TerminalClose(Pick),
    Read(Read, Pick),
    /// The n-th (modulo) earlier mutation again, with its idempotency key.
    Retry(u8),
}

/// An id for a request and the case-v1 value that names the same object in
/// the walk: a `$step:` reference into a session snapshot step, or the id.
#[derive(Debug, Clone)]
struct Picked {
    id: String,
    case: String,
}

impl Picked {
    fn literal(id: String) -> Self {
        Self { case: id.clone(), id }
    }
}

/// Where an object was seen: the snapshot step and its row.
#[derive(Debug, Clone)]
struct Seen {
    kind: &'static str,
    step: String,
    index: usize,
}

/// One request: the operation, its selectors and fields, and the same
/// with `$step:` references for the walk.
#[derive(Debug, Clone)]
struct Call {
    method: &'static str,
    read: bool,
    selectors: Vec<(&'static str, Picked)>,
    fields: Map<String, Value>,
    case_fields: Map<String, Value>,
    /// The ids of selector-typed fields (a move's destination).
    field_ids: Vec<String>,
}

impl Call {
    fn new(method: &'static str, read: bool) -> Self {
        Self {
            method,
            read,
            selectors: Vec::new(),
            fields: Map::new(),
            case_fields: Map::new(),
            field_ids: Vec::new(),
        }
    }

    fn select(mut self, selector: &'static str, picked: Picked) -> Self {
        self.selectors.push((selector, picked));
        self
    }

    fn field(mut self, key: &str, value: Value) -> Self {
        self.fields.insert(key.into(), value.clone());
        self.case_fields.insert(key.into(), value);
        self
    }

    fn id_field(mut self, key: &str, picked: Picked) -> Self {
        self.fields.insert(key.into(), json!(picked.id));
        self.case_fields.insert(key.into(), json!(picked.case));
        self.field_ids.push(picked.id);
        self
    }

    fn line(&self, request: &str, key: Option<&str>) -> String {
        let mut params = self.fields.clone();
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        for (selector, picked) in &self.selectors {
            params.insert((*selector).into(), json!(picked.id));
        }
        let mut envelope = json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": request,
            "operation": self.method,
            "params": params,
        });
        if let Some(key) = key {
            envelope["idempotency_key"] = json!(key);
        }
        envelope.to_string()
    }

    /// The case-v1 step of this call.
    fn step(&self, id: &str, key: Option<&str>) -> Value {
        let mut target = Map::new();
        target.insert("machine".into(), json!("current"));
        target.insert("session".into(), json!("current"));
        for (selector, picked) in &self.selectors {
            target.insert((*selector).into(), json!(picked.case));
        }
        let mut args = json!({"method": self.method, "params": self.case_fields});
        if let Some(key) = key {
            args["idempotencyKey"] = json!(key);
        }
        let mut step = json!({
            "id": id,
            "op": "resource.call",
            "target": target,
            "args": args,
            "checkpoint": ["before", "settled"],
        });
        if self.read {
            step["readOnly"] = json!(true);
        }
        step
    }

    fn targets(&self, session: Option<&str>) -> BTreeSet<String> {
        let mut out: BTreeSet<String> =
            self.selectors.iter().map(|(_, picked)| picked.id.clone()).collect();
        out.extend(self.field_ids.iter().cloned());
        out.extend(session.map(str::to_owned));
        out
    }
}

/// The session as the last snapshot saw it, and every object seen so far.
struct World {
    snapshot: Value,
    head: u64,
    step: String,
    seen: BTreeMap<String, Seen>,
    /// Each id an ok reply named: the `$step:` reference to it there.
    origins: BTreeMap<String, String>,
}

impl World {
    fn observe(&mut self, snapshot: Value, head: u64, step: String) {
        for (table, kind, _) in resource_walk::TABLES {
            for (index, row) in resource_walk::rows(&snapshot, table).iter().enumerate() {
                if let Some(id) = row["id"].as_str() {
                    self.seen.entry(id.to_owned()).or_insert_with(|| Seen {
                        kind,
                        step: step.clone(),
                        index,
                    });
                }
            }
        }
        self.snapshot = snapshot;
        self.head = head;
        self.step = step;
    }

    fn live(&self, kind: Kind) -> &[Value] {
        resource_walk::rows(&self.snapshot, kind.table())
    }

    fn pick(&self, kind: Kind, pick: Pick) -> Picked {
        match pick {
            Pick::Live(n) => {
                let rows = self.live(kind);
                match rows.len() {
                    0 => Picked::literal(kind.unknown_id()),
                    len => {
                        let index = usize::from(n) % len;
                        self.reference(&self.step, kind.table(), index, "id", &rows[index])
                    }
                }
            }
            Pick::Gone(n) => {
                let live: BTreeSet<_> =
                    self.live(kind).iter().filter_map(|row| row["id"].as_str()).collect();
                let gone: Vec<_> = self
                    .seen
                    .iter()
                    .filter(|(id, seen)| {
                        seen.kind == kind.selector() && !live.contains(id.as_str())
                    })
                    .collect();
                match gone.len() {
                    0 => Picked::literal(kind.unknown_id()),
                    len => {
                        let (id, seen) = gone[usize::from(n) % len];
                        let row =
                            format!("$step:{}#/{}/{}/id", seen.step, kind.table(), seen.index);
                        self.named(id, row)
                    }
                }
            }
            Pick::Unknown => Picked::literal(kind.unknown_id()),
        }
    }

    fn reference(&self, step: &str, table: &str, index: usize, key: &str, row: &Value) -> Picked {
        let id = row[key].as_str().unwrap_or_default();
        self.named(id, format!("$step:{step}#/{table}/{index}/{key}"))
    }

    /// `id` named by the earliest reply that gave it, else by `row`, a
    /// snapshot row: a reply names its object whatever else the session
    /// that replays the walk holds.
    fn named(&self, id: &str, row: String) -> Picked {
        Picked { id: id.to_owned(), case: self.origins.get(id).cloned().unwrap_or(row) }
    }

    /// The ids a step's result names, where it names them first.
    fn note_reply(
        &mut self,
        step: &str,
        result: &Value,
        known: &BTreeMap<String, resource_walk::Node>,
    ) {
        let mut found = Vec::new();
        resource_walk::pointed_strings(result, "", &mut found);
        for (pointer, id) in found {
            if known.contains_key(&id) {
                self.origins.entry(id).or_insert_with(|| format!("$step:{step}#{pointer}"));
            }
        }
    }

    /// A pane and the screen and workspace that hold it, for the
    /// selector-typed fields of a move or a swap. A closed or unknown pane
    /// gets unknown containers.
    fn pane_path(&self, pick: Pick) -> (Picked, Picked, Picked) {
        let pane = self.pick(Kind::Pane, pick);
        let row = self.live(Kind::Pane).iter().position(|row| row["id"] == pane.id.as_str());
        let Some(index) = row else {
            return (
                Picked::literal(Kind::Workspace.unknown_id()),
                Picked::literal(Kind::Screen.unknown_id()),
                pane,
            );
        };
        let pane_row = &self.live(Kind::Pane)[index];
        let screen = self.reference(&self.step, "panes", index, "screen_id", pane_row);
        let screens = self.live(Kind::Screen);
        let workspace = match screens.iter().position(|row| row["id"] == screen.id.as_str()) {
            Some(at) => self.reference(&self.step, "screens", at, "workspace_id", &screens[at]),
            None => Picked::literal(Kind::Workspace.unknown_id()),
        };
        (workspace, screen, pane)
    }

    fn call(&self, op: &Op) -> Option<Call> {
        let at = |kind: Kind, pick: Pick| self.pick(kind, pick);
        Some(match op {
            Op::WorkspaceCreate { terminal, name, focus } => {
                let content = if *terminal { "terminal" } else { "empty" };
                let mut call = Call::new("workspace.create", false)
                    .field("initial_content", json!(content))
                    .field("focus", json!(focus));
                if let Some(name) = name {
                    call = call.field("name", json!(name.value()));
                }
                call
            }
            Op::WorkspaceClose(pick) => {
                Call::new("workspace.close", false).select("workspace", at(Kind::Workspace, *pick))
            }
            Op::WorkspaceRename(pick, name) => Call::new("workspace.rename", false)
                .select("workspace", at(Kind::Workspace, *pick))
                .field("name", json!(name.value())),
            Op::WorkspaceFocus(pick) => {
                Call::new("workspace.focus", false).select("workspace", at(Kind::Workspace, *pick))
            }
            Op::ScreenCreate { workspace, name } => {
                let mut call = Call::new("screen.create", false);
                if let Some(pick) = workspace {
                    call = call.select("workspace", at(Kind::Workspace, *pick));
                }
                if let Some(name) = name {
                    call = call.field("name", json!(name.value()));
                }
                call
            }
            Op::ScreenClose(pick) => {
                Call::new("screen.close", false).select("screen", at(Kind::Screen, *pick))
            }
            Op::ScreenFocus(pick) => {
                Call::new("screen.focus", false).select("screen", at(Kind::Screen, *pick))
            }
            Op::ScreenRename(pick, name) => Call::new("screen.rename", false)
                .select("screen", at(Kind::Screen, *pick))
                .field("name", nullable(name)),
            Op::PaneCreate { screen } => {
                let call = Call::new("pane.create", false);
                match screen {
                    Some(pick) => call.select("screen", at(Kind::Screen, *pick)),
                    None => call,
                }
            }
            Op::PaneSplit { pane, direction, ratio } => {
                let mut call = Call::new("pane.split", false)
                    .select("pane", at(Kind::Pane, *pane))
                    .field("direction", json!(direction.wire()));
                if let Some(ratio) = ratio {
                    call = call.field("ratio", json!(f64::from(*ratio) / 255.0));
                }
                call
            }
            Op::PaneClose(pick) => {
                Call::new("pane.close", false).select("pane", at(Kind::Pane, *pick))
            }
            Op::PaneFocus(pick) => {
                Call::new("pane.focus", false).select("pane", at(Kind::Pane, *pick))
            }
            Op::PaneZoom(pick, enabled) => {
                let call = Call::new("pane.zoom", false).select("pane", at(Kind::Pane, *pick));
                match enabled {
                    Some(enabled) => call.field("enabled", json!(enabled)),
                    None => call,
                }
            }
            Op::PaneRename(pick, name) => Call::new("pane.rename", false)
                .select("pane", at(Kind::Pane, *pick))
                .field("name", nullable(name)),
            Op::PaneSwap(pick, other) => {
                let (workspace, screen, pane) = self.pane_path(*other);
                Call::new("pane.swap", false)
                    .select("pane", at(Kind::Pane, *pick))
                    .id_field("other_workspace", workspace)
                    .id_field("other_screen", screen)
                    .id_field("other_pane", pane)
            }
            Op::TabCreateTerminal { pane } => {
                let call = Call::new("tab.create_terminal", false);
                match pane {
                    Some(pick) => call.select("pane", at(Kind::Pane, *pick)),
                    None => call,
                }
            }
            Op::TabClose { tab, pane } | Op::TabFocus { tab, pane } => {
                let method =
                    if matches!(op, Op::TabClose { .. }) { "tab.close" } else { "tab.focus" };
                let mut call = Call::new(method, false);
                if let Some(pick) = pane {
                    call = call.select("pane", at(Kind::Pane, *pick));
                }
                call.select("tab", at(Kind::Tab, *tab))
            }
            Op::TabRename(pick, name) => Call::new("tab.rename", false)
                .select("tab", at(Kind::Tab, *pick))
                .field("name", nullable(name)),
            Op::TabMove { tab, to, index } => {
                let (workspace, screen, pane) = self.pane_path(*to);
                Call::new("tab.move", false)
                    .select("tab", at(Kind::Tab, *tab))
                    .id_field("destination_workspace", workspace)
                    .id_field("destination_screen", screen)
                    .id_field("destination_pane", pane)
                    .field("index", json!(index % 4))
            }
            Op::TabPin { tab, pin } => {
                let method = if *pin { "tab.pin" } else { "tab.unpin" };
                Call::new(method, false).select("tab", at(Kind::Tab, *tab))
            }
            Op::TerminalClose(pick) => {
                Call::new("terminal.close", false).select("terminal", at(Kind::Terminal, *pick))
            }
            Op::Read(read, pick) => {
                let (method, kind) = match read {
                    Read::WorkspaceList => return Some(Call::new("workspace.list", true)),
                    Read::WorkspaceGet => ("workspace.get", Kind::Workspace),
                    Read::ScreenGet => ("screen.get", Kind::Screen),
                    Read::PaneGet => ("pane.get", Kind::Pane),
                    Read::TabGet => ("tab.get", Kind::Tab),
                };
                Call::new(method, true).select(kind.selector(), at(kind, *pick))
            }
            Op::Retry(_) => return None,
        })
    }
}

fn snapshot(session: &ResourceSession) -> (Value, u64) {
    session.snapshot().unwrap_or_else(|error| panic!("session.snapshot refused: {error:#}"))
}

/// Stops the input at a broken invariant: the walk names it, the panic
/// makes libFuzzer keep the input.
fn fail(recorder: &mut Recorder, step: &str, violation: Violation) -> ! {
    recorder.violation(step, &violation);
    panic!("{} at step {step}: {} ({})", violation.invariant, violation.message, violation.pointer);
}

fn run(ops: &[Op]) {
    let mut recorder = Recorder::from_env();
    let session = ResourceSession::new("fuzz-resource-ops", vec![TERMINAL_ARGV.into()]);
    let mut world = World {
        snapshot: Value::Null,
        head: 0,
        step: String::new(),
        seen: BTreeMap::new(),
        origins: BTreeMap::new(),
    };
    // Mutations sent so far with their keys, for Retry; the last step and
    // the facet after its reply, which the next step's snapshot must keep.
    let mut sent: Vec<(Call, String)> = Vec::new();
    let mut last: Option<(String, Value)> = None;
    for (index, op) in ops.iter().take(MAX_OPS).enumerate() {
        if matches!(op, Op::Retry(_)) && sent.is_empty() {
            continue;
        }
        let snapshot_step = format!("s{index}");
        let step = format!("op{index}");
        let (current, head) = snapshot(&session);
        if let Err(violation) = resource_walk::consistency(&current) {
            fail(&mut recorder, last.as_ref().map_or("setup", |(step, _)| step), violation);
        }
        if let Some((previous, after)) = &last {
            // Nothing lands after a step's reply: the oracle reads a step's
            // effects right after it (driver_daemon.py `settle`).
            let none = BTreeSet::new();
            let unchanged = Scope { targets: &none, named: &none, changed: false };
            let after = resource_walk::nodes(after);
            if let Err(mut violation) =
                resource_walk::i2(&after, &resource_walk::nodes(&current), &unchanged)
            {
                violation.message = format!("after its reply: {}", violation.message);
                fail(&mut recorder, previous, violation);
            }
        }
        world.observe(current, head, snapshot_step.clone());
        let (call, key) = match op {
            Op::Retry(n) => {
                let (call, key) = &sent[usize::from(*n) % sent.len()];
                (call.clone(), Some(key.clone()))
            }
            _ => {
                let call = world.call(op).expect("only Retry has no call of its own");
                let key = (!call.read).then(|| format!("fuzz-{step}"));
                if let Some(key) = &key {
                    sent.push((call.clone(), key.clone()));
                }
                (call, key)
            }
        };
        let mut read_snapshot = Call::new("session.snapshot", true).step(&snapshot_step, None);
        if let Some(fields) = read_snapshot.as_object_mut() {
            fields.remove("checkpoint");
        }
        recorder.line(json!({"walk": "step", "step": read_snapshot}));
        recorder.line(json!({"walk": "step", "step": call.step(&step, key.as_deref())}));
        let request = format!("request-{step}");
        let Some(reply) = session.call(&call.line(&request, key.as_deref())) else {
            panic!("{} is not a router operation: the target must not pick it", call.method);
        };
        let outcome = if reply["ok"] == true { "ok" } else { "error" };
        if recorder.enabled() {
            recorder.line(json!({
                "walk": "reply",
                "step": step,
                "outcome": outcome,
                "error": reply["error"]["code"],
                "details": reply["error"]["details"],
            }));
        }
        if let Err(violation) = resource_walk::i1(&reply, &request, !call.read) {
            fail(&mut recorder, &step, violation);
        }
        let (after, after_head) = snapshot(&session);
        if after_head < world.head {
            let message = format!("the journal head fell from {} to {after_head}", world.head);
            fail(
                &mut recorder,
                &step,
                Violation { invariant: "consistency", pointer: "/journalHead".into(), message },
            );
        }
        if let Err(violation) = resource_walk::consistency(&after) {
            fail(&mut recorder, &step, violation);
        }
        let mut named = BTreeSet::new();
        resource_walk::strings(&reply["result"], &mut named);
        let targets = call.targets(resource_walk::session_id(&world.snapshot));
        let scope =
            Scope { targets: &targets, named: &named, changed: !call.read && outcome == "ok" };
        let before_nodes = resource_walk::nodes(&world.snapshot);
        let after_nodes = resource_walk::nodes(&after);
        if let Err(violation) = resource_walk::i2(&before_nodes, &after_nodes, &scope) {
            fail(&mut recorder, &step, violation);
        }
        // A mutation's result names its own objects; a list read's names
        // them by row order, which a snapshot reference already does.
        if scope.changed {
            world.note_reply(&step, &reply["result"], &after_nodes);
        }
        world.head = after_head;
        last = Some((step, after));
    }
}

/// The environment of an oracle daemon case (scripts/cmux-next/oracle/
/// hermetic_env.py `daemon_case`), set once before the first input as
/// Chromium's fuzzers set theirs in `LLVMFuzzerInitialize`: a private HOME,
/// XDG and state root, offline, git without the person's config, and no
/// editor project sources (state/project_watch.rs reads HOME's editor data
/// and its watch thread outlives a session until the next file event).
fn hermetic_environment() {
    let root = std::env::temp_dir().join(format!("cmux-resource-ops-{}", std::process::id()));
    let home = root.join("home");
    let dirs = [
        ("HOME", home.clone()),
        ("XDG_CONFIG_HOME", home.join(".config")),
        ("XDG_DATA_HOME", home.join(".local/share")),
        ("XDG_STATE_HOME", home.join(".local/state")),
        ("XDG_CACHE_HOME", home.join(".cache")),
        ("XDG_RUNTIME_DIR", root.join("run")),
        ("CMUX_TUI_STATE_DIR", root.join("state")),
        ("TMPDIR", root.join("tmp")),
    ];
    let values = [
        ("CMUX_TUI_OFFLINE", "1"),
        ("CMUX_PROJECT_SOURCES", "off"),
        ("GIT_CONFIG_GLOBAL", "/dev/null"),
        ("GIT_CONFIG_NOSYSTEM", "1"),
    ];
    for (_, dir) in &dirs {
        std::fs::create_dir_all(dir)
            .unwrap_or_else(|error| panic!("create {}: {error}", dir.display()));
    }
    let values = values.into_iter().map(|(key, value)| (key, std::ffi::OsString::from(value)));
    for (key, value) in dirs.into_iter().map(|(key, dir)| (key, dir.into_os_string())).chain(values)
    {
        // SAFETY: libFuzzer runs this once, before the first input and before
        // this process starts a thread of its own that reads the environment.
        unsafe { std::env::set_var(key, value) };
    }
}

fuzz_target!(init: hermetic_environment(), |ops: Vec<Op>| {
    run(&ops);
});
