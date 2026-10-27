//! Resource-op sequence fuzzer (plans/cmux-next/chrome-parity/p15-oracle.md,
//! task 186): `arbitrary` decodes the input into a sequence of typed
//! `cmux.protocol/2` requests (workspace, screen, pane, tab and terminal
//! mutations, reads and same-key retries) whose ids name a live object, a
//! closed one or a well-formed id that never existed. Each request goes
//! through the daemon's own dispatch in process
//! (`cmux_tui_core::fuzz_entry::ResourceSession`), on the daemon's own
//! owner model: a registry on disk and one `__terminal-host` process per
//! terminal (this binary, which serves a host when asked to before libFuzzer
//! starts). Around each request the target reads `session.snapshot`, the
//! step's before and settled checkpoints, and checks I1, I2 and I19 as
//! invariants.py checks them on the converted case (support/
//! resource_walk.rs). A broken one, like a daemon panic, is a crash. The
//! process runs in an oracle case's hermetic environment
//! (`hermetic_environment`), set once before the first input.
//!
//! An input picks objects among those an earlier reply named, in the order
//! the replies first named them, never by a snapshot row: rows are ordered by
//! random public ids, so the same input would pick other objects in another
//! run, and a converted case's reference would name another object in the
//! oracle's daemon. A case names each object through the reply that named it
//! (`$step:<step>#<pointer>`).
//!
//! Chrome reference (chromium/src): mojo/docs/mojolpm.md, a structured
//! fuzzer that drives a real interface implementation in process with a
//! sequence of typed calls and their ids; testing/libfuzzer/README.md for
//! the coverage-guided loop and typed inputs (FuzzTest's domains).
//!
//! A crash becomes an oracle walk case: `fuzz_to_case.py` replays the crash
//! with `CMUX_RESOURCE_OPS_WALK` set, and this target then writes every
//! step as a case-v1 step, each checkpoint before its snapshot is read, the
//! reply's outcome and the broken invariant (resource_walk.rs `Recorder`).
#![no_main]

#[path = "support/resource_walk.rs"]
mod resource_walk;

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use arbitrary::Arbitrary;
use cmux_tui_core::fuzz_entry::{ResourceSession, serve_terminal_host};
use libfuzzer_sys::fuzz_target;
use resource_walk::{Node, Owner, PROTOCOL, Recorder, Violation};
use serde_json::{Map, Value, json};

/// Steps of one input: enough to build, split, move and close a few
/// workspaces, few enough that one input stays well under a second.
const MAX_OPS: usize = 24;
/// Each terminal runs this instead of a login shell: it starts at once,
/// writes nothing and exits when its PTY closes.
const TERMINAL_ARGV: &str = "/bin/cat";
/// A terminal host that loses this process (a crash) ends its terminal after
/// this many seconds, so a crashed input leaves no `/bin/cat` behind for the
/// debug build's ten-minute grace.
const HOST_ORPHAN_GRACE_SECS: &str = "5";

#[derive(Arbitrary, Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Workspace,
    Screen,
    Pane,
    Tab,
    Terminal,
}

impl Kind {
    /// The selector name, which is also the object kind of the facet.
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
    fn unknown(self) -> Picked {
        let prefix = match self {
            Self::Workspace => "ws",
            Self::Screen => "screen",
            Self::Pane => "pane",
            Self::Tab => "tab",
            Self::Terminal => "term",
        };
        let id = format!("{prefix}_{}", "0".repeat(32));
        Picked { case: id.clone(), id }
    }
}

/// Which object an id names.
#[derive(Arbitrary, Debug, Clone, Copy)]
enum Pick {
    /// The n-th (modulo) live object of its kind, in the order replies
    /// first named them.
    Live(u8),
    /// The n-th (modulo) closed object of its kind, in the same order.
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
/// the walk: a `$step:` reference to the reply that named it, or the id
/// itself for one that never existed.
#[derive(Debug, Clone)]
struct Picked {
    id: String,
    case: String,
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
}

impl Call {
    fn new(method: &'static str, read: bool) -> Self {
        Self { method, read, selectors: Vec::new(), fields: Map::new(), case_fields: Map::new() }
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

    /// A selector-typed field (a move's destination): a param, not a
    /// target, as the case carries it.
    fn id_field(mut self, key: &str, picked: Picked) -> Self {
        self.fields.insert(key.into(), json!(picked.id));
        self.case_fields.insert(key.into(), json!(picked.case));
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

    /// The ids of the step's `target` (invariants.py `target_ids`): its
    /// selectors. `machine` and `session` stay `current` in the case, which
    /// names no object.
    fn targets(&self) -> BTreeSet<String> {
        self.selectors.iter().map(|(_, picked)| picked.id.clone()).collect()
    }
}

/// An object an ok mutation reply named: its kind and where the reply names
/// it.
struct Named {
    id: String,
    kind: &'static str,
    case: String,
}

/// The session at the last checkpoint, and every object replies named so
/// far, in the order they first named it.
#[derive(Default)]
struct World {
    nodes: BTreeMap<String, Node>,
    named: Vec<Named>,
    known: BTreeSet<String>,
}

impl World {
    fn pick(&self, kind: Kind, pick: Pick) -> Picked {
        let among = |live: bool, n: u8| {
            let found: Vec<&Named> = self
                .named
                .iter()
                .filter(|named| {
                    named.kind == kind.selector() && self.nodes.contains_key(&named.id) == live
                })
                .collect();
            match found.len() {
                0 => kind.unknown(),
                len => {
                    let named = found[usize::from(n) % len];
                    Picked { id: named.id.clone(), case: named.case.clone() }
                }
            }
        };
        match pick {
            Pick::Live(n) => among(true, n),
            Pick::Gone(n) => among(false, n),
            Pick::Unknown => kind.unknown(),
        }
    }

    /// `id` as the reply that named it gives it, else an id that never
    /// existed: the walk sends nothing the case could not send.
    fn named(&self, kind: Kind, id: Option<&str>) -> Picked {
        id.and_then(|id| self.named.iter().find(|named| named.id == id)).map_or_else(
            || kind.unknown(),
            |named| Picked { id: named.id.clone(), case: named.case.clone() },
        )
    }

    /// The ids a mutation's result names that are live after it, where it
    /// names them first.
    fn note_reply(&mut self, step: &str, result: &Value, after: &BTreeMap<String, Node>) {
        let mut found = Vec::new();
        resource_walk::singular_strings(result, "", &mut found);
        for (pointer, id) in found {
            let Some(node) = after.get(&id) else { continue };
            if node.kind != "session" && self.known.insert(id.clone()) {
                self.named.push(Named {
                    id,
                    kind: node.kind,
                    case: format!("$step:{step}#{pointer}"),
                });
            }
        }
    }

    /// A pane and the screen and workspace that hold it, for the
    /// selector-typed fields of a move or a swap. A closed or unknown pane
    /// gets unknown containers.
    fn pane_path(&self, pick: Pick) -> (Picked, Picked, Picked) {
        let pane = self.pick(Kind::Pane, pick);
        let parent = |id: &str| self.nodes.get(id).and_then(|node| node.parent.clone());
        let screen = parent(&pane.id);
        let workspace = screen.as_deref().and_then(parent);
        (
            self.named(Kind::Workspace, workspace.as_deref()),
            self.named(Kind::Screen, screen.as_deref()),
            pane,
        )
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

/// One checkpoint: the walk line first, so a panic in the read leaves it.
fn checkpoint(
    session: &ResourceSession,
    recorder: &mut Recorder,
    step: &str,
    name: &str,
) -> (Value, BTreeMap<String, Node>, u64) {
    recorder.checkpoint(step, name);
    let (snapshot, head) =
        session.snapshot().unwrap_or_else(|error| panic!("session.snapshot refused: {error:#}"));
    let nodes = resource_walk::nodes(&snapshot);
    (snapshot, nodes, head)
}

/// Stops the input at a broken invariant: the walk names it, the panic
/// makes libFuzzer keep the input.
fn fail(recorder: &mut Recorder, step: &str, checkpoint: Option<&str>, violation: Violation) -> ! {
    recorder.violation(step, checkpoint, &violation);
    let at = checkpoint.unwrap_or("reply");
    panic!(
        "{} at step {step} ({at}): {} ({})",
        violation.invariant, violation.message, violation.pointer
    );
}

/// The step that owns the changes up to the next checkpoint, kept past it:
/// a before checkpoint's changes are the previous step's late effects
/// (invariants.py `Checker.owner`).
struct Last {
    step: String,
    mutating: bool,
    targets: BTreeSet<String>,
    replies: BTreeSet<String>,
    nodes: BTreeMap<String, Node>,
    head: u64,
}

impl Last {
    fn owner(&self) -> Owner<'_> {
        Owner {
            step: &self.step,
            mutating: self.mutating,
            targets: &self.targets,
            replies: &self.replies,
        }
    }
}

fn run(ops: &[Op], session: &ResourceSession, recorder: &mut Recorder) {
    let mut world = World::default();
    // Mutations sent so far with their keys, for Retry.
    let mut sent: Vec<(Call, String)> = Vec::new();
    let mut last: Option<Last> = None;
    for (index, op) in ops.iter().take(MAX_OPS).enumerate() {
        if matches!(op, Op::Retry(_)) && sent.is_empty() {
            continue;
        }
        let step = format!("op{index}");
        let (before, before_nodes, before_head) = checkpoint(session, recorder, &step, "before");
        if let Some(last) = &last {
            if let Err(violation) = resource_walk::i2(&last.nodes, &before_nodes, &last.owner()) {
                fail(recorder, &step, Some("before"), violation);
            }
            if let Err(violation) = resource_walk::i19_journal(last.head, before_head) {
                fail(recorder, &step, Some("before"), violation);
            }
        }
        if let Err(violation) = resource_walk::i19(&before) {
            fail(recorder, &step, Some("before"), violation);
        }
        world.nodes = before_nodes;
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
        recorder.line(json!({"walk": "step", "step": call.step(&step, key.as_deref())}));
        let request = format!("request-{step}");
        let Some(reply) = session.call(&call.line(&request, key.as_deref())) else {
            panic!("{} is not a router operation: the target must not pick it", call.method);
        };
        let ok = reply["ok"] == true;
        if recorder.enabled() {
            let outcome = if ok { "ok" } else { "error" };
            recorder.line(json!({
                "walk": "reply",
                "step": step,
                "outcome": outcome,
                "error": reply["error"]["code"],
                "details": reply["error"]["details"],
            }));
        }
        if let Err(violation) = resource_walk::i1(&reply, &request, !call.read) {
            fail(recorder, &step, None, violation);
        }
        let (after, after_nodes, after_head) = checkpoint(session, recorder, &step, "settled");
        if let Err(violation) = resource_walk::i19_journal(before_head, after_head) {
            fail(recorder, &step, Some("settled"), violation);
        }
        if let Err(violation) = resource_walk::i19(&after) {
            fail(recorder, &step, Some("settled"), violation);
        }
        // The trace's replies: {receipt, result} for a result, {error} for
        // an error, whose code names no object.
        let mut replies = BTreeSet::new();
        if ok {
            resource_walk::strings(&reply["result"], &mut replies);
        }
        let current = Last {
            step: step.clone(),
            mutating: !call.read,
            targets: call.targets(),
            replies,
            nodes: after_nodes,
            head: after_head,
        };
        if let Err(violation) = resource_walk::i2(&world.nodes, &current.nodes, &current.owner()) {
            fail(recorder, &step, Some("settled"), violation);
        }
        if ok && !call.read {
            world.note_reply(&step, &reply["result"], &current.nodes);
        }
        last = Some(current);
    }
}

/// Each input's own state root under the process's hermetic TMPDIR.
fn fresh_state_root() -> PathBuf {
    static INPUTS: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!("in-{}", INPUTS.fetch_add(1, Ordering::Relaxed)));
    std::fs::create_dir_all(&root)
        .unwrap_or_else(|error| panic!("create {}: {error}", root.display()));
    root
}

/// The environment of an oracle daemon case (scripts/cmux-next/oracle/
/// hermetic_env.py `daemon_case`), set once before the first input as
/// Chromium's fuzzers set theirs in `LLVMFuzzerInitialize`: a private HOME,
/// XDG and state root, offline, git without the person's config, hosts bound
/// in their install's own directory, and no editor project sources
/// (state/project_watch.rs reads HOME's editor data and its watch thread
/// outlives a session until the next file event). Blocking checks record
/// (`CMUX_DAEMON_BLOCKING=record`, driver_daemon.py `--daemon-blocking
/// record`, which `fuzz_to_case.py` runs each case with): a blocking call on
/// a thread that disallows it is I11's finding, which the oracle reads from
/// the recorded sites, not a crash of this target.
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
        ("CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT", "1"),
        ("CMUX_TUI_HOST_ORPHAN_GRACE_SECS", HOST_ORPHAN_GRACE_SECS),
        ("CMUX_DAEMON_BLOCKING", "record"),
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

/// libFuzzer's initialization: a terminal host this process's sessions
/// started (`__terminal-host ...`) serves its terminal and exits here, before
/// libFuzzer reads its arguments; the fuzzer itself sets its environment.
fn initialize() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(served) = serve_terminal_host(&args) {
        let code = match served {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("resource_ops terminal host: {error:#}");
                1
            }
        };
        std::process::exit(code);
    }
    hermetic_environment();
}

fuzz_target!(init: initialize(), |ops: Vec<Op>| {
    let mut recorder = Recorder::from_env();
    let root = fresh_state_root();
    let session_name = format!("fuzz-resource-ops-{}", std::process::id());
    let session = ResourceSession::open(&session_name, &root, vec![TERMINAL_ARGV.into()])
        .unwrap_or_else(|error| panic!("open the session: {error:#}"));
    run(&ops, &session, &mut recorder);
    recorder.line(json!({"walk": "teardown"}));
    session.end().unwrap_or_else(|error| panic!("end the session's terminals: {error:#}"));
    // Best effort: a root left behind is in the process's own hermetic tree.
    let _ = std::fs::remove_dir_all(&root);
});
