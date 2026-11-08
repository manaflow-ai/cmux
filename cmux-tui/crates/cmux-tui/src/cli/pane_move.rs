//! `cmux pane <pane> move`: move a whole pane (every tab in it, in order) to
//! another place, as tmux `join-pane` / `break-pane` and herdr `pane move` do:
//!
//! - `--to-pane <pane>`: the tabs go to the end of that pane. With `--split
//!   right|down|left|up` they go into a new pane split off that pane.
//! - `--to-tab <tab>`: the tabs go into the pane that shows that tab, after it.
//! - `--to-workspace <ws>`: the tabs go into a new screen in that workspace.
//! - `--new-screen` (or `--new-tab`, herdr's word for a screen): the tabs go
//!   into a new screen in the pane's own workspace.
//!
//! The daemon has no pane move, so this is a composite of `tab.move` steps
//! (the TUI's own Move Tab to Workspace is one `tab.move` too). A split or a
//! new screen starts with a shell tab; it closes after the tabs moved in, so
//! the new pane never runs empty. The emptied source pane closes itself.
//!
//! `tab.move` makes the moved tab the daemon's focus. Without `--focus` the
//! command then focuses the pane that had the focus before, so the person's
//! view stays (unless that pane was the moved one, which no longer exists);
//! with `--focus` it focuses the destination pane.
//!
//! Every selector resolves against one session snapshot, so each request
//! names ids only. Each step is its own daemon request, its key derived from
//! the command's. A failed step names itself and what already moved
//! (`details.step`, `details.made`); running the command again does not
//! resume it, because the new snapshot no longer has the moved tabs there.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::terminal_talk::send::Daemon;
use super::worktree_workspace::{StepFailure, command_key, finish, plan, usage, words};
use super::{GlobalArgs, UsageError};

/// `Some(exit code)` for `pane <pane> move ...` (and `pane move ...`, the
/// caller's pane); `None` for any other pane command (`words` follow `pane`).
pub(in crate::cli) fn run(global: &GlobalArgs, words: &[String]) -> Option<i32> {
    let (target, rest) = match words {
        [verb, rest @ ..] if verb == "move" => ("current", rest),
        [target, verb, rest @ ..] if verb == "move" => (target.as_str(), rest),
        _ => return None,
    };
    Some(match parse(target, rest) {
        Ok(mut request) => {
            // A routed command (--socket, --session) runs in another session,
            // where the caller's terminal does not exist.
            if global.socket.is_none() && global.session.is_none() {
                request.caller_terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok();
            }
            let backend = super::mcp::cli_backend(global.clone());
            let outcome = command_key(global).and_then(|key| move_pane(&backend, &request, &key));
            finish(global, outcome)
        }
        Err(error) => usage(global, &error),
    })
}

/// Where `pane move` puts the pane.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Destination {
    /// The end of this pane, or a new pane split off it in `split`'s direction.
    Pane { pane: String, split: Option<String> },
    /// The pane that shows this tab, after the tab.
    Tab(String),
    /// A new screen in this workspace; `None` is the pane's own workspace.
    NewScreen { workspace: Option<String> },
}

/// `pane <pane> move`, parsed.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct MoveRequest {
    pub pane: String,
    pub destination: Destination,
    /// The new screen's name (`--to-workspace`, `--new-screen`).
    pub name: Option<String>,
    /// `--focus`: focus the destination pane instead of keeping the focus.
    pub focus: bool,
    /// The caller's own terminal (`CMUX_TUI_TERMINAL_ID`), which `current`
    /// and `caller` selectors name; `None` outside cmux or when routed.
    pub caller_terminal: Option<String>,
}

const USAGE: &str = "pane move takes one of --to-pane <pane> [--split right|down|left|up], \
                     --to-tab <tab>, --to-workspace <ws> or --new-screen (--new-tab), and \
                     --name <screen name> and --focus";

pub(in crate::cli) fn parse(target: &str, flags: &[String]) -> Result<MoveRequest, UsageError> {
    if target.starts_with('-') {
        return Err(UsageError(format!("{USAGE}, after the pane: not {target}")));
    }
    let mut to_pane = None;
    let mut to_tab = None;
    let mut to_workspace = None;
    let mut split = None;
    let mut name = None;
    let mut new_screen = false;
    let mut focus = false;
    let mut iter = flags.iter();
    while let Some(word) = iter.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--new-screen" | "--new-tab" => {
                new_screen = true;
                continue;
            }
            "--focus" => {
                focus = true;
                continue;
            }
            "--no-focus" => {
                focus = false;
                continue;
            }
            _ => {}
        }
        let slot = match flag {
            "--to-pane" => &mut to_pane,
            "--to-tab" => &mut to_tab,
            "--to-workspace" => &mut to_workspace,
            "--split" => &mut split,
            "--name" => &mut name,
            other => return Err(UsageError(format!("{USAGE}, not {other}"))),
        };
        let value = match inline {
            Some(value) => value,
            None => {
                iter.next().cloned().ok_or_else(|| UsageError(format!("{flag} needs a value")))?
            }
        };
        if value.is_empty() {
            return Err(UsageError(format!("{flag} needs a value")));
        }
        *slot = Some(value);
    }
    if let Some(direction) = &split
        && !matches!(direction.as_str(), "right" | "down" | "left" | "up")
    {
        return Err(UsageError(format!(
            "--split takes right, down, left or up, not {direction:?}"
        )));
    }
    let chosen = [to_pane.is_some(), to_tab.is_some(), to_workspace.is_some(), new_screen];
    if chosen.iter().filter(|chosen| **chosen).count() != 1 {
        return Err(UsageError(format!("{USAGE}: give exactly one destination")));
    }
    if split.is_some() && to_pane.is_none() {
        return Err(UsageError("--split goes with --to-pane <pane>".into()));
    }
    let destination = match (to_pane, to_tab) {
        (Some(pane), _) => Destination::Pane { pane, split },
        (_, Some(tab)) => Destination::Tab(tab),
        _ => Destination::NewScreen { workspace: to_workspace },
    };
    if name.is_some() && !matches!(destination, Destination::NewScreen { .. }) {
        return Err(UsageError(
            "--name names a new screen: it goes with --to-workspace or --new-screen".into(),
        ));
    }
    Ok(MoveRequest { pane: target.to_owned(), destination, name, focus, caller_terminal: None })
}

/// One step's daemon key, derived from the command's key.
fn step_key(command_key: &str, step: &str) -> String {
    let mut hash = Sha256::new();
    for part in ["cmux.pane.move.v1", command_key, step] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    format!("pane-move-{:x}", hash.finalize())
}

/// The records of `kind` (`workspaces`, `screens`, `panes`, `tabs`) in a
/// session snapshot.
fn records<'a>(snapshot: &'a Value, kind: &str) -> &'a [Value] {
    snapshot.get(kind).and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default()
}

fn find<'a>(snapshot: &'a Value, kind: &str, id: &str) -> Option<&'a Value> {
    records(snapshot, kind).iter().find(|record| record["id"] == id)
}

fn text(value: &Value, field: &str) -> String {
    value.get(field).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// What a failed step's `details.retry` says. A retry would read a new
/// snapshot (the moved tabs are elsewhere by then), so the command does not
/// resume; `details.made` lists what already moved.
const NO_RETRY: &str = "pane move does not resume: `details.made.moved_tabs` moved to \
                        `details.made.destination`; move the other tabs with `tab move`";

/// `failure` of `step`, with what the steps before it made, and no retry key.
fn step_failure(failure: super::mcp::CallFailure, step: &str, made: Value) -> StepFailure {
    let mut failed = StepFailure::step(failure, step, "", made);
    if let Some(details) = failed.error.get_mut("details").and_then(Value::as_object_mut) {
        details.remove("idempotency_key");
        details.insert("retry".into(), json!(NO_RETRY));
    }
    failed
}

/// A selector that names nothing, or more than one record.
fn selector_failure(code: &str, message: String) -> StepFailure {
    StepFailure {
        error: json!({"code": code, "message": message, "details": {}, "retryable": false}),
        exit: 1,
    }
}

/// The snapshot record `selector` names in `scope` (`workspace`, `pane` or
/// `tab`). The command resolves every selector here and sends only ids: an
/// id or a unique id prefix, `name:<name>` or an exact name (one match in
/// the session), `focused`, and `current` / `caller` (the caller's own
/// object; `current` is the focused one when no caller is known).
fn resolve<'a>(
    snapshot: &'a Value,
    scope: &str,
    selector: &str,
    caller_terminal: Option<&str>,
) -> Result<&'a Value, StepFailure> {
    let kind = match scope {
        "workspace" => "workspaces",
        "pane" => "panes",
        _ => "tabs",
    };
    let focused = || -> Option<&'a Value> {
        let pane = records(snapshot, "panes").iter().find(|pane| pane["focused"] == true);
        match scope {
            "workspace" => records(snapshot, "workspaces")
                .iter()
                .find(|workspace| workspace["focused"] == true),
            "pane" => pane,
            _ => records(snapshot, "tabs").iter().find(|tab| {
                tab["focused"] == true && Some(&tab["pane_id"]) == pane.map(|p| &p["id"])
            }),
        }
    };
    let caller = || -> Option<&'a Value> {
        let tab = records(snapshot, "tabs")
            .iter()
            .find(|tab| caller_terminal.is_some_and(|terminal| tab["content_id"] == terminal))?;
        let pane = find(snapshot, "panes", &text(tab, "pane_id"))?;
        match scope {
            "tab" => Some(tab),
            "pane" => Some(pane),
            _ => find(snapshot, "screens", &text(pane, "screen_id"))
                .and_then(|screen| find(snapshot, "workspaces", &text(screen, "workspace_id"))),
        }
    };
    let found = match selector {
        "caller" if caller_terminal.is_none() => {
            return Err(StepFailure::usage(format!(
                "{scope} caller is the {scope} of the cmux terminal this command runs in; \
                 outside one (or with --socket/--session), name the {scope}"
            )));
        }
        "caller" | "current" => caller().or_else(focused),
        "focused" => focused(),
        _ => {
            let name = selector.strip_prefix("name:");
            let matches = records(snapshot, kind)
                .iter()
                .filter(|record| match name {
                    Some(name) => record["name"] == name,
                    None => {
                        (selector.contains('_')
                            && record["id"].as_str().is_some_and(|id| id.starts_with(selector)))
                            || record["name"] == selector
                    }
                })
                .collect::<Vec<_>>();
            match matches.as_slice() {
                [one] => Some(*one),
                [] => None,
                several => {
                    let ids = several.iter().map(|record| text(record, "id")).collect::<Vec<_>>();
                    return Err(selector_failure(
                        "selector.ambiguous",
                        format!(
                            "{scope} {selector} names {} {kind}: {}; pass one id",
                            ids.len(),
                            ids.join(", ")
                        ),
                    ));
                }
            }
        }
    };
    found.ok_or_else(|| {
        selector_failure(
            "selector.not_found",
            format!("no {scope} {selector} in this session (`cmux {scope} list` lists them)"),
        )
    })
}

/// The new pane a split or `screen create` made: `{workspace_id,
/// screen_id, pane_id, tab_id}`.
fn created_path(result: &Value) -> Value {
    result.get("value").cloned().unwrap_or_else(|| result.clone())
}

/// Runs `pane <pane> move`; the result names the moved tabs, where they
/// went, what was made and the pane that has the focus after.
pub(in crate::cli) fn move_pane<B: Daemon + ?Sized>(
    backend: &B,
    request: &MoveRequest,
    command_key: &str,
) -> Result<Value, StepFailure> {
    let snapshot = backend
        .request(None, plan(&words(&["session", "current", "snapshot"]), None)?)
        .map_err(|failure| step_failure(failure, "snapshot", Value::Null))?;
    let caller = request.caller_terminal.as_deref();
    let source = text(resolve(&snapshot, "pane", &request.pane, caller)?, "id");
    let source_workspace = find(&snapshot, "panes", &source)
        .and_then(|pane| find(&snapshot, "screens", &text(pane, "screen_id")))
        .map(|screen| text(screen, "workspace_id"))
        .unwrap_or_default();
    let source_name = find(&snapshot, "panes", &source)
        .and_then(|pane| pane.get("name"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let mut tabs = records(&snapshot, "tabs")
        .iter()
        .filter(|tab| tab["pane_id"] == source)
        .collect::<Vec<_>>();
    tabs.sort_by_key(|tab| tab["index"].as_u64().unwrap_or(u64::MAX));
    let moved = tabs.iter().map(|tab| text(tab, "id")).collect::<Vec<_>>();
    let active = tabs.iter().find(|tab| tab["focused"] == true).map(|tab| text(tab, "id"));
    let focused_before = records(&snapshot, "panes")
        .iter()
        .find(|pane| pane["focused"] == true)
        .map(|pane| text(pane, "id"));
    if moved.is_empty() {
        return Err(StepFailure::usage(format!("pane {source} has no tab to move")));
    }

    // Where the tabs go: (workspace, screen, pane, first index), and the
    // shell tab a new pane started with.
    let (workspace, screen, pane, start, placeholder, created) = match &request.destination {
        Destination::Pane { pane, split } => {
            let target = text(resolve(&snapshot, "pane", pane, caller)?, "id");
            if target == source {
                return Err(StepFailure::usage("pane move needs a destination outside the pane"));
            }
            match split {
                Some(direction) => {
                    let split = backend
                        .request(
                            None,
                            plan(
                                &words(&["pane", &target, "split", &format!("--{direction}")]),
                                Some(step_key(command_key, "split")),
                            )?,
                        )
                        .map_err(|failure| step_failure(failure, "split", Value::Null))?;
                    let path = created_path(&split);
                    (
                        text(&path, "workspace_id"),
                        text(&path, "screen_id"),
                        text(&path, "pane_id"),
                        1,
                        Some(text(&path, "tab_id")),
                        json!({"pane": text(&path, "pane_id")}),
                    )
                }
                None => {
                    let screen = find(&snapshot, "panes", &target)
                        .map(|pane| text(pane, "screen_id"))
                        .unwrap_or_default();
                    let workspace = find(&snapshot, "screens", &screen)
                        .map(|screen| text(screen, "workspace_id"))
                        .unwrap_or_default();
                    let end = records(&snapshot, "tabs")
                        .iter()
                        .filter(|tab| tab["pane_id"] == target)
                        .count();
                    (workspace, screen, target, end, None, Value::Null)
                }
            }
        }
        Destination::Tab(tab) => {
            let shown = resolve(&snapshot, "tab", tab, caller)?;
            let target = text(shown, "pane_id");
            if target == source {
                return Err(StepFailure::usage(
                    "pane move needs a destination outside the pane; that tab is in it",
                ));
            }
            let index = shown.get("index").and_then(Value::as_u64).unwrap_or_default();
            let screen = find(&snapshot, "panes", &target)
                .map(|pane| text(pane, "screen_id"))
                .unwrap_or_default();
            let workspace = find(&snapshot, "screens", &screen)
                .map(|screen| text(screen, "workspace_id"))
                .unwrap_or_default();
            let after = usize::try_from(index).unwrap_or(usize::MAX - 1) + 1;
            (workspace, screen, target, after, None, Value::Null)
        }
        Destination::NewScreen { workspace } => {
            let workspace = match workspace {
                Some(selector) => text(resolve(&snapshot, "workspace", selector, caller)?, "id"),
                None => source_workspace,
            };
            let mut create = words(&["screen", "create", "--workspace", &workspace]);
            if let Some(name) = &request.name {
                create.extend(["--name".to_owned(), name.clone()]);
            }
            let created = backend
                .request(None, plan(&create, Some(step_key(command_key, "screen")))?)
                .map_err(|failure| step_failure(failure, "screen", Value::Null))?;
            let path = created_path(&created);
            (
                text(&path, "workspace_id"),
                text(&path, "screen_id"),
                text(&path, "pane_id"),
                1,
                Some(text(&path, "tab_id")),
                json!({"screen": text(&path, "screen_id"), "pane": text(&path, "pane_id")}),
            )
        }
    };
    let made = |done: &[String]| {
        json!({"created": created.clone(), "moved_tabs": done,
               "destination": {"workspace": &workspace, "screen": &screen, "pane": &pane}})
    };

    for (offset, tab) in moved.iter().enumerate() {
        let index = (start + offset).to_string();
        let step = format!("move-{tab}");
        let step_words = words(&[
            "tab",
            tab,
            "move",
            "--workspace",
            &workspace,
            "--screen",
            &screen,
            "--pane",
            &pane,
            "--index",
            &index,
        ]);
        backend.request(None, plan(&step_words, Some(step_key(command_key, &step)))?).map_err(
            |failure| step_failure(failure, &step, made(moved.get(..offset).unwrap_or_default())),
        )?;
    }
    if let Some(placeholder) = &placeholder {
        let close = words(&["tab", placeholder, "close"]);
        backend
            .request(None, plan(&close, Some(step_key(command_key, "close-shell")))?)
            .map_err(|failure| step_failure(failure, "close-shell", made(&moved)))?;
        // The new pane keeps the moved pane's name.
        if let Some(name) = &source_name {
            let rename = words(&["pane", &pane, "rename", "--name", name]);
            backend
                .request(None, plan(&rename, Some(step_key(command_key, "rename")))?)
                .map_err(|failure| step_failure(failure, "rename", made(&moved)))?;
        }
    }
    // The tab that was selected in the pane is selected again (each move
    // selects the tab it moved).
    if let Some(active) = active.filter(|active| moved.last() != Some(active)) {
        backend
            .request(
                None,
                plan(
                    &words(&["tab", &active, "focus"]),
                    Some(step_key(command_key, "select-tab")),
                )?,
            )
            .map_err(|failure| step_failure(failure, "select-tab", made(&moved)))?;
    }
    let focus_target = match focused_before {
        _ if request.focus => Some(pane.clone()),
        Some(before) if before != source => Some(before),
        // The focused pane was the moved one: the focus went with its tabs.
        _ => None,
    };
    if let Some(target) = &focus_target {
        backend
            .request(
                None,
                plan(&words(&["pane", target, "focus"]), Some(step_key(command_key, "focus")))?,
            )
            .map_err(|failure| step_failure(failure, "focus", made(&moved)))?;
    }
    Ok(json!({
        "pane": source,
        "moved_tabs": moved,
        "destination": {"workspace": workspace, "screen": screen, "pane": &pane, "index": start},
        "created": created,
        "focused_pane": focus_target.unwrap_or(pane),
    }))
}

#[cfg(test)]
#[path = "pane_move_tests.rs"]
mod tests;
