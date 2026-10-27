//! The crash conditions and the walk record of the `resource_ops` target
//! (p15-oracle-186): the oracle's I1 (one receipt or one typed error) and I2
//! (ids stay stable unless the step created or closed them) over one step,
//! and the daemon facet's own consistency (every row's container exists, a
//! screen's layout holds exactly its panes, the journal head never falls).
//! The rules are scripts/cmux-next/oracle/invariants.py's, read on the
//! in-process `session.snapshot` instead of a recorded trace.

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

/// Every structural id of `snapshot` with its container and pointer.
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

fn ancestors(graph: &BTreeMap<String, Node>, start: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut at = graph.get(start).and_then(|node| node.parent.clone());
    while let Some(parent) = at {
        if !out.insert(parent.clone()) {
            break;
        }
        at = graph.get(&parent).and_then(|node| node.parent.clone());
    }
    out
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

/// Every string in `value` with its JSON pointer (RFC 6901) under `at`.
pub fn pointed_strings(value: &Value, at: &str, out: &mut Vec<(String, String)>) {
    match value {
        Value::String(text) => out.push((at.to_owned(), text.clone())),
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                pointed_strings(item, &format!("{at}/{index}"), out);
            }
        }
        Value::Object(members) => {
            for (key, item) in members {
                let token = key.replace('~', "~0").replace('/', "~1");
                pointed_strings(item, &format!("{at}/{token}"), out);
            }
        }
        _ => {}
    }
}

/// I1 on one response to the request `id`: one protocol response, either a
/// result (a MutationResult for a mutation) or one typed error. A
/// catalog-contract refusal (the daemon refused its own reply as outside the
/// operation's contract, resource_router/catalog_validation.rs) is neither.
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
            let result = &reply["result"];
            let receipt = result.get("value").is_some()
                && result["generation"].as_str().is_some_and(|text| !text.is_empty())
                && result.get("revision").is_some_and(|value| !value.is_null())
                && result["replayed"].is_boolean();
            if mutation && !receipt {
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
            if let Some(contract) = error["details"]["contract"].as_str() {
                let detail = &error["details"];
                return bad(
                    "/error/details/contract",
                    format!(
                        "the daemon refused its own {contract} as outside the catalog: {detail:.300}"
                    ),
                );
            }
            Ok(())
        }
        _ => bad("/ok", format!("not one result or one error: {reply:.300}")),
    }
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

/// What one step acted on: its selector and selector-typed param ids, and
/// the ids its reply names.
pub struct Scope<'a> {
    pub targets: &'a BTreeSet<String>,
    pub named: &'a BTreeSet<String>,
    /// The reply is a result (not a refusal) of a mutation.
    pub changed: bool,
}

/// I2 over one step. A read or a refused request creates and closes
/// nothing. A mutation closes only its targets, their containers (closing
/// the last tab closes its pane), what is inside a target, and what its
/// reply names; it creates only what its reply names, what is inside a new
/// object, and objects inside a target or a target's container below the
/// session (invariants.py `Checker.i2`, with the reply's ids as roots).
pub fn i2(
    before: &BTreeMap<String, Node>,
    after: &BTreeMap<String, Node>,
    scope: &Scope<'_>,
) -> Result<(), Violation> {
    let closed: Vec<_> = before.keys().filter(|id| !after.contains_key(*id)).collect();
    let created: Vec<_> = after.keys().filter(|id| !before.contains_key(*id)).collect();
    if !scope.changed {
        if let Some(id) = closed.first() {
            let node = &before[*id];
            let message = format!("{} {id} disappeared in a step that changed nothing", node.kind);
            return Err(Violation::new("I2", node.pointer.clone(), message));
        }
        if let Some(id) = created.first() {
            let node = &after[*id];
            let message = format!("{} {id} appeared in a step that changed nothing", node.kind);
            return Err(Violation::new("I2", node.pointer.clone(), message));
        }
        return Ok(());
    }
    let mut reach = BTreeSet::new();
    for target in scope.targets {
        reach.insert(target.clone());
        reach.extend(ancestors(before, target));
    }
    for id in closed {
        let node = &before[id];
        let with_container = node.parent.as_ref().is_some_and(|parent| !after.contains_key(parent));
        let inside_target = ancestors(before, id).iter().any(|up| scope.targets.contains(up));
        if with_container || reach.contains(id) || inside_target || scope.named.contains(id) {
            continue;
        }
        let message = format!("{} {id} disappeared, but the step did not close it", node.kind);
        return Err(Violation::new("I2", node.pointer.clone(), message));
    }
    for id in created {
        let node = &after[id];
        let parent = node.parent.as_deref();
        let with_container = parent.is_some_and(|parent| !before.contains_key(parent));
        let in_reach = parent.is_some_and(|parent| {
            reach.contains(parent) && before.get(parent).is_some_and(|up| up.kind != "session")
        });
        if with_container || in_reach || scope.named.contains(id) {
            continue;
        }
        let message = format!("{} {id} appeared, but the step did not create it", node.kind);
        return Err(Violation::new("I2", node.pointer.clone(), message));
    }
    Ok(())
}

/// The facet's consistency: ids are unique, every row's container is in the
/// same cut, a terminal tab's terminal exists, and each screen's layout
/// leaves are exactly the panes of that screen, its active and zoomed panes
/// among them.
pub fn consistency(snapshot: &Value) -> Result<(), Violation> {
    let bad =
        |pointer: String, message: String| Err(Violation::new("consistency", pointer, message));
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
    let containers = [
        ("screens", "workspace_id", "workspace"),
        ("panes", "screen_id", "screen"),
        ("tabs", "pane_id", "pane"),
    ];
    for (index, row) in rows(snapshot, "workspaces").iter().enumerate() {
        if row["session_id"] != session {
            return bad(
                format!("/workspaces/{index}/session_id"),
                format!("not session {session}"),
            );
        }
    }
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
/// names a file (`fuzz_to_case.py` sets it when it replays a crash): each
/// line is flushed before the request it describes runs, so a daemon
/// abort still leaves every step up to it.
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

    pub fn violation(&mut self, step: &str, violation: &Violation) {
        self.line(json!({
            "walk": "violation",
            "step": step,
            "invariant": violation.invariant,
            "pointer": violation.pointer,
            "message": violation.message,
        }));
    }
}
