//! The crash conditions and the walk record of the `resource_ops` target
//! (p15-oracle-186), each the rule of scripts/cmux-next/oracle/invariants.py
//! that the converted case is checked with, read on the in-process
//! `session.snapshot` (the daemon facet's `session`) instead of a trace:
//!
//! - I1: one protocol response, a MutationResult for a mutation or one typed
//!   error. A catalog-contract refusal is neither: the oracle's case fails
//!   it through the step's expectation (`fuzz_to_case.py`).
//! - I2 (`Checker.i2`): between two checkpoints, an id closes or appears only
//!   under the step that owns the change. A before checkpoint's changes are
//!   the previous step's late effects (`Checker.owner`).
//! - I19 (`Checker.i19`): the daemon facet is one consistent cut, and its
//!   journal head never falls.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;

use serde_json::{Value, json};

/// The wire protocol of every request and response.
pub const PROTOCOL: &str = "cmux.protocol/2";

/// The structural tables of `session.snapshot`, each with the member that
/// names its container (invariants.py `DAEMON_TABLES`).
pub const TABLES: [(&str, &str, &str); 6] = [
    ("workspaces", "workspace", "session_id"),
    ("screens", "screen", "workspace_id"),
    ("panes", "pane", "screen_id"),
    ("tabs", "tab", "pane_id"),
    ("terminals", "terminal", "tab_id"),
    ("browsers", "browser", "tab_id"),
];

/// A broken invariant: its id, the JSON pointer of the value, what is wrong.
#[derive(Debug)]
pub struct Violation {
    pub invariant: &'static str,
    pub pointer: String,
    pub message: String,
}

impl Violation {
    fn new(
        invariant: &'static str,
        pointer: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self { invariant, pointer: pointer.into(), message: message.into() }
    }
}

/// One structural object of the facet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub kind: &'static str,
    pub parent: Option<String>,
    pub pointer: String,
}

/// The session id of a `session.snapshot` result.
pub fn session_id(snapshot: &Value) -> Option<&str> {
    snapshot["session"]["id"].as_str()
}

/// Every structural id of `snapshot` with its container and pointer
/// (invariants.py `daemon_ids`).
pub fn nodes(snapshot: &Value) -> BTreeMap<String, Node> {
    let mut out = BTreeMap::new();
    if let Some(id) = session_id(snapshot) {
        out.insert(
            id.to_owned(),
            Node { kind: "session", parent: None, pointer: "/session/id".into() },
        );
    }
    for (table, kind, parent_key) in TABLES {
        for (index, row) in rows(snapshot, table).iter().enumerate() {
            let Some(id) = row["id"].as_str() else { continue };
            let parent = row[parent_key].as_str().map(str::to_owned);
            out.insert(id.to_owned(), Node { kind, parent, pointer: format!("/{table}/{index}") });
        }
    }
    out
}

pub fn rows<'a>(snapshot: &'a Value, table: &str) -> &'a [Value] {
    snapshot[table].as_array().map_or(&[], Vec::as_slice)
}

/// Every string in `value`, for the ids a reply names.
pub fn strings(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::String(text) => {
            out.insert(text.clone());
        }
        Value::Array(items) => items.iter().for_each(|item| strings(item, out)),
        Value::Object(members) => members.values().for_each(|item| strings(item, out)),
        _ => {}
    }
}

/// Every string in `value` with its JSON pointer (RFC 6901) under `at`,
/// except inside an array of more than one item: an index there is the
/// position of an id among others, which another run may order otherwise.
pub fn singular_strings(value: &Value, at: &str, out: &mut Vec<(String, String)>) {
    match value {
        Value::String(text) => out.push((at.to_owned(), text.clone())),
        Value::Array(items) if items.len() == 1 => {
            singular_strings(&items[0], &format!("{at}/0"), out)
        }
        Value::Object(members) => {
            for (key, item) in members {
                let token = key.replace('~', "~0").replace('/', "~1");
                singular_strings(item, &format!("{at}/{token}"), out);
            }
        }
        _ => {}
    }
}

/// I1 on one response to the request `id`: one protocol response, either a
/// result (a MutationResult for a mutation) or one typed error. A
/// catalog-contract refusal (the daemon refused its own reply as outside the
/// operation's contract: resource_router/catalog_validation.rs
/// `contract_failure`, `details.extra.contract`) is neither.
pub fn i1(reply: &Value, id: &str, mutation: bool) -> Result<(), Violation> {
    let bad = |pointer: &str, message: String| Err(Violation::new("I1", pointer, message));
    if reply["protocol"] != PROTOCOL || reply["type"] != "response" {
        return bad("/protocol", format!("not a {PROTOCOL} response: {reply:.300}"));
    }
    if reply["id"] != id {
        return bad("/id", format!("the response answers {}, not {id}", reply["id"]));
    }
    let has = |key: &str| reply.get(key).is_some_and(|value| !value.is_null());
    match (reply["ok"].as_bool(), has("result"), has("error")) {
        (Some(true), true, false) => {
            if mutation && !mutation_result(&reply["result"]) {
                let result = &reply["result"];
                return bad(
                    "/result",
                    format!("a mutation's result is no MutationResult: {result:.300}"),
                );
            }
            Ok(())
        }
        (Some(false), false, true) => {
            let error = &reply["error"];
            let code = error["code"].as_str().unwrap_or_default();
            if !typed_error_code(code) {
                return bad(
                    "/error/code",
                    format!("{:?} is not a typed error code", error["code"]),
                );
            }
            let extra = &error["details"]["extra"];
            if let Some(contract) = extra["contract"].as_str() {
                return bad(
                    "/error/details/extra/contract",
                    format!(
                        "the daemon refused its own {contract} as outside the catalog: {extra:.300}"
                    ),
                );
            }
            Ok(())
        }
        _ => bad("/ok", format!("not one result or one error: {reply:.300}")),
    }
}

/// resource_router.rs `mutation_result`: {value, generation, revision,
/// replayed}, the keys driver_daemon.py's `mutation_result` receipt checks.
pub fn mutation_result(result: &Value) -> bool {
    result.get("value").is_some()
        && result["generation"].as_str().is_some_and(|text| !text.is_empty())
        && result.get("revision").is_some_and(|value| !value.is_null())
        && result["replayed"].is_boolean()
}

/// case-v1 `$defs.expect.error`: `^[a-z][a-z_]*(\.[a-z][a-z_]*)+$`.
fn typed_error_code(code: &str) -> bool {
    let mut parts = code.split('.');
    let word = |part: &str| {
        part.chars().next().is_some_and(|first| first.is_ascii_lowercase())
            && part.chars().all(|c| c.is_ascii_lowercase() || c == '_')
    };
    parts.next().is_some_and(word) && {
        let rest: Vec<_> = parts.collect();
        !rest.is_empty() && rest.into_iter().all(word)
    }
}

/// The step that owns a change, as invariants.py's I2 sees it in the trace:
/// whether it mutates (a resource.call without readOnly, refused or not),
/// the ids of its `target`, and every string of its replies.
pub struct Owner<'a> {
    pub step: &'a str,
    pub mutating: bool,
    pub targets: &'a BTreeSet<String>,
    pub replies: &'a BTreeSet<String>,
}

type Graph<'a> = BTreeMap<&'a str, BTreeSet<&'a str>>;

fn ancestors<'a>(graph: &Graph<'a>, start: &str) -> BTreeSet<&'a str> {
    let mut out = BTreeSet::new();
    let mut todo: Vec<&str> = graph.get(start).into_iter().flatten().copied().collect();
    while let Some(parent) = todo.pop() {
        if out.insert(parent) {
            todo.extend(graph.get(parent).into_iter().flatten().copied());
        }
    }
    out
}

/// invariants.py `Checker.i2` from checkpoint `a` to checkpoint `b`, the
/// change of one owner: an id closed or appeared only as a target, a
/// container of one, a child of one, a sibling of a target (the direct
/// containers of the targets, `beside`), what its replies name, or inside
/// what closed or appeared with it.
pub fn i2(
    a: &BTreeMap<String, Node>,
    b: &BTreeMap<String, Node>,
    owner: &Owner<'_>,
) -> Result<(), Violation> {
    let mut graph: Graph<'_> = BTreeMap::new();
    for nodes in [a, b] {
        for (key, node) in nodes {
            let parents = graph.entry(key.as_str()).or_default();
            parents.extend(node.parent.as_deref());
        }
    }
    let mut roots: BTreeSet<&str> = BTreeSet::new();
    let mut may: BTreeSet<&str> = BTreeSet::new();
    let mut beside: BTreeSet<&str> = BTreeSet::new();
    if owner.mutating {
        roots.extend(owner.targets.iter().map(String::as_str));
        roots.extend(owner.replies.iter().map(String::as_str).filter(|s| graph.contains_key(s)));
        may.extend(owner.targets.iter().map(String::as_str));
        for target in owner.targets {
            beside.extend(graph.get(target.as_str()).into_iter().flatten().copied());
        }
    }
    may.extend(roots.iter().copied());
    for root in &roots {
        may.extend(ancestors(&graph, root));
    }
    let by = if owner.mutating {
        format!("step {} (resource.call)", owner.step)
    } else {
        format!("step {} (a read)", owner.step)
    };
    let parents = |key: &str| graph.get(key).cloned().unwrap_or_default();
    for (key, node) in a.iter().filter(|(key, _)| !b.contains_key(*key)) {
        if node.parent.as_ref().is_some_and(|up| a.contains_key(up) && !b.contains_key(up)) {
            continue; // closed with its container
        }
        if may.contains(key.as_str())
            || !ancestors(&graph, key).is_disjoint(&roots)
            || !parents(key).is_disjoint(&beside)
        {
            continue;
        }
        let message = format!("{} {key} disappeared, but {by} did not close it", node.kind);
        return Err(Violation::new("I2", node.pointer.clone(), message));
    }
    for (key, node) in b.iter().filter(|(key, _)| !a.contains_key(*key)) {
        if node.parent.as_ref().is_some_and(|up| b.contains_key(up) && !a.contains_key(up)) {
            continue; // created with its container
        }
        if may.contains(key.as_str()) || !parents(key).is_disjoint(&may) {
            continue;
        }
        let message = format!("{} {key} appeared, but {by} did not create it", node.kind);
        return Err(Violation::new("I2", node.pointer.clone(), message));
    }
    Ok(())
}

/// invariants.py `facet_inconsistencies` (I19) on one daemon facet: ids are
/// unique, every workspace is in the snapshot's session, every screen, pane
/// and tab names a container of the snapshot, a terminal's or browser's tab
/// is one of its tabs, a terminal tab's content is a terminal, and each
/// screen's layout leaves are exactly that screen's panes, its active and
/// zoomed panes among them.
pub fn i19(snapshot: &Value) -> Result<(), Violation> {
    let bad = |pointer: String, message: String| Err(Violation::new("I19", pointer, message));
    let Some(session) = session_id(snapshot) else {
        return bad("/session/id".into(), "the snapshot names no session".into());
    };
    let mut ids: BTreeMap<&str, (&str, String)> = BTreeMap::new();
    for (table, kind, _) in TABLES {
        for (index, row) in rows(snapshot, table).iter().enumerate() {
            let pointer = format!("/{table}/{index}/id");
            let Some(id) = row["id"].as_str() else {
                return bad(pointer, format!("a {kind} row has no id"));
            };
            if let Some((_, first)) = ids.insert(id, (kind, pointer.clone())) {
                return bad(pointer, format!("{id} is also at {first}"));
            }
        }
    }
    let is = |id: &Value, kind: &str| {
        id.as_str().and_then(|id| ids.get(id)).is_some_and(|(found, _)| *found == kind)
    };
    for (index, row) in rows(snapshot, "workspaces").iter().enumerate() {
        if row["session_id"] != session {
            return bad(
                format!("/workspaces/{index}/session_id"),
                format!("{} is not session {session}", row["session_id"]),
            );
        }
    }
    let containers = [
        ("screens", "workspace_id", "workspace"),
        ("panes", "screen_id", "screen"),
        ("tabs", "pane_id", "pane"),
    ];
    for (table, key, kind) in containers {
        for (index, row) in rows(snapshot, table).iter().enumerate() {
            if !is(&row[key], kind) {
                let message = format!("{} names no {kind} of this snapshot", row[key]);
                return bad(format!("/{table}/{index}/{key}"), message);
            }
        }
    }
    for table in ["terminals", "browsers"] {
        for (index, row) in rows(snapshot, table).iter().enumerate() {
            if !row["tab_id"].is_null() && !is(&row["tab_id"], "tab") {
                let message = format!("{} names no tab of this snapshot", row["tab_id"]);
                return bad(format!("/{table}/{index}/tab_id"), message);
            }
        }
    }
    for (index, tab) in rows(snapshot, "tabs").iter().enumerate() {
        if tab["content_kind"] == "terminal" && !is(&tab["content_id"], "terminal") {
            let message = format!("terminal tab content {} is no terminal", tab["content_id"]);
            return bad(format!("/tabs/{index}/content_id"), message);
        }
    }
    for (index, screen) in rows(snapshot, "screens").iter().enumerate() {
        let panes: BTreeSet<&str> = rows(snapshot, "panes")
            .iter()
            .filter(|pane| pane["screen_id"] == screen["id"])
            .filter_map(|pane| pane["id"].as_str())
            .collect();
        let layout = &screen["layout"];
        let mut leaves = Vec::new();
        layout_leaves(&layout["root"], &mut leaves);
        let unique: BTreeSet<&str> = leaves.iter().copied().collect();
        let at = format!("/screens/{index}/layout");
        if unique.len() != leaves.len() || unique != panes {
            let message = format!("layout leaves {leaves:?}, the screen's panes {panes:?}");
            return bad(format!("{at}/root"), message);
        }
        for key in ["active_pane_id", "zoomed_pane_id"] {
            let pane = &layout[key];
            if !pane.is_null() && !pane.as_str().is_some_and(|pane| panes.contains(pane)) {
                return bad(format!("{at}/{key}"), format!("{pane} is no pane of this screen"));
            }
        }
    }
    Ok(())
}

/// I19 across two checkpoints: the journal head never falls.
pub fn i19_journal(previous: u64, head: u64) -> Result<(), Violation> {
    if head < previous {
        let message = format!("the journal head fell from {previous} to {head}");
        return Err(Violation::new("I19", "/journalHead", message));
    }
    Ok(())
}

fn layout_leaves<'a>(node: &'a Value, out: &mut Vec<&'a str>) {
    match node["kind"].as_str() {
        Some("leaf") => out.extend(node["pane_id"].as_str()),
        Some("split") => {
            layout_leaves(&node["first"], out);
            layout_leaves(&node["second"], out);
        }
        _ => {}
    }
}

/// The walk of one input as JSON lines, written only when the environment
/// names a file (`fuzz_to_case.py` sets it when it replays a crash). Each
/// line is flushed before what it announces runs (a checkpoint's
/// `session.snapshot`, a request, the teardown), so a daemon abort still
/// leaves every line up to the work it died in:
///
/// - `{"walk": "checkpoint", "step", "checkpoint": "before"|"settled"}`
/// - `{"walk": "step", "step": <case-v1 step>}`
/// - `{"walk": "reply", "step", "outcome", "error", "details"}`
/// - `{"walk": "violation", "step", "checkpoint": "before"|"settled"|null,
///   "invariant", "pointer", "message"}` (null: the reply itself)
/// - `{"walk": "teardown"}`
pub struct Recorder(Option<std::fs::File>);

/// The file `fuzz_to_case.py` reads the walk from.
pub const WALK_ENV: &str = "CMUX_RESOURCE_OPS_WALK";

impl Recorder {
    pub fn from_env() -> Self {
        let file = std::env::var_os(WALK_ENV).map(|path| {
            std::fs::File::create(&path).unwrap_or_else(|error| {
                panic!("{WALK_ENV}={}: {error}", std::path::Path::new(&path).display())
            })
        });
        Self(file)
    }

    pub fn enabled(&self) -> bool {
        self.0.is_some()
    }

    pub fn line(&mut self, value: Value) {
        if let Some(file) = self.0.as_mut() {
            writeln!(file, "{value}").and_then(|()| file.flush()).expect("write the walk");
        }
    }

    pub fn checkpoint(&mut self, step: &str, checkpoint: &str) {
        self.line(json!({"walk": "checkpoint", "step": step, "checkpoint": checkpoint}));
    }

    pub fn violation(&mut self, step: &str, checkpoint: Option<&str>, violation: &Violation) {
        self.line(json!({
            "walk": "violation",
            "step": step,
            "checkpoint": checkpoint,
            "invariant": violation.invariant,
            "pointer": violation.pointer,
            "message": violation.message,
        }));
    }
}
