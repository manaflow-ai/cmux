//! `cmux pane <pane> move`: move a whole pane (every tab in it, in order) to
//! another place, as tmux `join-pane` / `break-pane` do:
//!
//! - `--to-pane <pane>`: the tabs go to the end of that pane. With `--split
//!   right|down|left|up` they go into a new pane split off that pane.
//! - `--to-tab <tab>`: the tabs go into the pane that shows that tab, after it.
//! - `--to-workspace <ws>`: the tabs go into a new screen in that workspace.
//! - `--new-screen` (or `--new-tab`): the tabs go into a new screen in the
//!   pane's own workspace.
//!
//! The daemon has no pane move, so this is a composite of `tab.move` steps.
//! A split or a new screen starts with a shell tab; its shell ends
//! (`terminal <t> close`, which takes the tab with it) after the tabs moved
//! in, so the new pane never runs empty and no shell outlives its tab (W5-O).
//! The emptied source pane closes itself.
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

use super::command::{CommandPlan, RequestPlan};
use super::{GlobalArgs, UsageError, wire};

/// Where `pane move` puts the pane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Destination {
    /// The end of this pane, or a new pane split off it in `split`'s direction.
    Pane { pane: String, split: Option<String> },
    /// The pane that shows this tab, after the tab.
    Tab(String),
    /// A new screen in this workspace; `None` is the pane's own workspace.
    NewScreen { workspace: Option<String> },
}

/// `pane <pane> move`, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct MoveRequest {
    pub pane: String,
    pub destination: Destination,
    /// The new screen's name (`--to-workspace`, `--new-screen`).
    pub name: Option<String>,
    /// `--focus`: focus the destination pane instead of keeping the focus.
    pub focus: bool,
    /// `--idempotency-key`: the command's key, from which each step's key
    /// derives; `None` makes a new random one.
    pub idempotency_key: Option<String>,
    /// The caller's own terminal (`CMUX_TUI_TERMINAL_ID`), which `current`
    /// and `caller` selectors name; `None` outside cmux or when routed.
    pub caller_terminal: Option<String>,
}

/// The flags of `pane <pane> move`, as `command.rs` read them.
#[derive(Debug, Default)]
pub(super) struct MoveFlags {
    pub to_pane: Option<String>,
    pub to_tab: Option<String>,
    pub to_workspace: Option<String>,
    pub split: Option<String>,
    pub name: Option<String>,
    pub new_screen: bool,
    pub focus: bool,
    pub idempotency_key: Option<String>,
}

const USAGE: &str = "pane move takes one of --to-pane <pane> [--split right|down|left|up], \
                     --to-tab <tab>, --to-workspace <ws> or --new-screen (--new-tab), and \
                     --name <screen name> and --focus";

/// Checks `flags` for `pane <target> move` and makes the request.
pub(super) fn request(target: &str, flags: MoveFlags) -> Result<MoveRequest, UsageError> {
    let MoveFlags {
        to_pane,
        to_tab,
        to_workspace,
        split,
        name,
        new_screen,
        focus,
        idempotency_key,
    } = flags;
    for (flag, value) in [
        ("--to-pane", &to_pane),
        ("--to-tab", &to_tab),
        ("--to-workspace", &to_workspace),
        ("--split", &split),
        ("--name", &name),
    ] {
        if value.as_deref() == Some("") {
            return Err(UsageError::new(format!("{flag} needs a value")));
        }
    }
    if let Some(direction) = &split
        && !matches!(direction.as_str(), "right" | "down" | "left" | "up")
    {
        return Err(UsageError::new(format!(
            "--split takes right, down, left or up, not {direction:?}"
        )));
    }
    let chosen = [to_pane.is_some(), to_tab.is_some(), to_workspace.is_some(), new_screen];
    if chosen.iter().filter(|chosen| **chosen).count() != 1 {
        return Err(UsageError::new(format!("{USAGE}: give exactly one destination")));
    }
    if split.is_some() && to_pane.is_none() {
        return Err(UsageError::new("--split goes with --to-pane <pane>"));
    }
    let destination = match (to_pane, to_tab) {
        (Some(pane), _) => Destination::Pane { pane, split },
        (_, Some(tab)) => Destination::Tab(tab),
        _ => Destination::NewScreen { workspace: to_workspace },
    };
    if name.is_some() && !matches!(destination, Destination::NewScreen { .. }) {
        return Err(UsageError::new(
            "--name names a new screen: it goes with --to-workspace or --new-screen",
        ));
    }
    if let Some(key) = &idempotency_key {
        cmux_tui_core::resource::validate_idempotency_key(key)
            .map_err(|error| UsageError::new(error.message))?;
    }
    Ok(MoveRequest {
        pane: target.to_owned(),
        destination,
        name,
        focus,
        idempotency_key,
        caller_terminal: None,
    })
}

pub(super) fn run(global: GlobalArgs, mut request: MoveRequest) -> i32 {
    // A routed command (--socket, --session, --machine) runs in another
    // session, where the caller's terminal does not exist.
    if global.socket.is_none() && global.session.is_none() && global.machine.is_none() {
        request.caller_terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok();
    }
    let key = match request.idempotency_key.clone() {
        Some(key) => key,
        None => match wire::random_idempotency_key() {
            Ok(key) => key,
            Err(error) => {
                let failure = StepFailure::usage(error.0);
                return wire::print_local_error(&failure.error, global.output, failure.exit);
            }
        },
    };
    match move_pane(&Cli(&global), &request, &key) {
        Ok(result) => wire::print_local_success(&result, global.output),
        Err(failure) => wire::print_local_error(&failure.error, global.output, failure.exit),
    }
}

/// Sends one step to the daemon: the result, or the error as JSON.
pub(super) trait Daemon {
    fn request(&self, plan: RequestPlan) -> Result<Value, Value>;
}

/// The daemon this CLI talks to.
struct Cli<'a>(&'a GlobalArgs);

impl Daemon for Cli<'_> {
    fn request(&self, plan: RequestPlan) -> Result<Value, Value> {
        wire::fetch(self.0, plan)
    }
}

/// A failed step, and the exit code the CLI gives it.
#[derive(Debug)]
pub(super) struct StepFailure {
    pub error: Value,
    pub exit: i32,
}

impl StepFailure {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            error: json!({"code": "usage.invalid", "message": message.into(), "details": {},
                          "retryable": false}),
            exit: 2,
        }
    }
}

/// The CLI exit code for a failed request: 2 for a usage error, 3 when the
/// session could not be reached, 1 for an error the server answered.
fn exit_code(error: &Value) -> i32 {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    if code.starts_with("usage.") {
        2
    } else if code.starts_with("transport.") {
        3
    } else {
        1
    }
}

/// The plan `words` make, with `key` when it is a mutation.
fn plan(words: &[&str], key: Option<String>) -> Result<RequestPlan, StepFailure> {
    let words = words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    match super::command::parse(&words) {
        Ok(CommandPlan::Protocol(mut plan)) => {
            plan.idempotency_key = key;
            Ok(plan)
        }
        Ok(_) => Err(StepFailure::usage(format!("{} is not a plain request", words.join(" ")))),
        Err(error) => Err(StepFailure::usage(error.0)),
    }
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

/// `error` of `step`, with what the steps before it made, and no retry key.
fn step_failure(mut error: Value, step: &str, made: Value) -> StepFailure {
    if !error.is_object() {
        error = json!({"code": "operation.failed", "message": error.to_string()});
    }
    if !error.get("details").is_some_and(Value::is_object) {
        error["details"] = json!({});
    }
    let exit = exit_code(&error);
    let details = error["details"].as_object_mut().expect("details is an object");
    details.insert("step".into(), json!(step));
    if !made.is_null() {
        details.insert("made".into(), made);
    }
    details.remove("idempotency_key");
    details.insert("retry".into(), json!(NO_RETRY));
    StepFailure { error, exit }
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
/// screen_id, pane_id, tab_id, terminal_id}`.
fn created_path(result: &Value) -> Value {
    result.get("value").cloned().unwrap_or_else(|| result.clone())
}

/// The shell tab a new pane started with, and its terminal.
struct Placeholder {
    tab: String,
    terminal: Option<String>,
}

fn placeholder_of(path: &Value) -> Placeholder {
    Placeholder {
        tab: text(path, "tab_id"),
        terminal: path.get("terminal_id").and_then(Value::as_str).map(str::to_owned),
    }
}

/// Runs `pane <pane> move`; the result names the moved tabs, where they
/// went, what was made and the pane that has the focus after.
pub(super) fn move_pane<B: Daemon + ?Sized>(
    backend: &B,
    request: &MoveRequest,
    command_key: &str,
) -> Result<Value, StepFailure> {
    let snapshot = backend
        .request(plan(&["session", "current", "snapshot"], None)?)
        .map_err(|error| step_failure(error, "snapshot", Value::Null))?;
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
    // shell a new pane started with.
    let (workspace, screen, pane, start, placeholder, created) = match &request.destination {
        Destination::Pane { pane, split } => {
            let target = text(resolve(&snapshot, "pane", pane, caller)?, "id");
            if target == source {
                return Err(StepFailure::usage("pane move needs a destination outside the pane"));
            }
            match split {
                Some(direction) => {
                    let split = backend
                        .request(plan(
                            &["pane", target.as_str(), "split", format!("--{direction}").as_str()],
                            Some(step_key(command_key, "split")),
                        )?)
                        .map_err(|error| step_failure(error, "split", Value::Null))?;
                    let path = created_path(&split);
                    (
                        text(&path, "workspace_id"),
                        text(&path, "screen_id"),
                        text(&path, "pane_id"),
                        1,
                        Some(placeholder_of(&path)),
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
            let mut create = vec!["screen", "create", "--workspace", workspace.as_str()];
            if let Some(name) = &request.name {
                create.extend(["--name", name.as_str()]);
            }
            let created = backend
                .request(plan(&create, Some(step_key(command_key, "screen")))?)
                .map_err(|error| step_failure(error, "screen", Value::Null))?;
            let path = created_path(&created);
            (
                text(&path, "workspace_id"),
                text(&path, "screen_id"),
                text(&path, "pane_id"),
                1,
                Some(placeholder_of(&path)),
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
        let step_words = [
            "tab",
            tab.as_str(),
            "move",
            "--workspace",
            workspace.as_str(),
            "--screen",
            screen.as_str(),
            "--pane",
            pane.as_str(),
            "--index",
            index.as_str(),
        ];
        backend.request(plan(&step_words, Some(step_key(command_key, &step)))?).map_err(
            |error| step_failure(error, &step, made(moved.get(..offset).unwrap_or_default())),
        )?;
    }
    if let Some(placeholder) = &placeholder {
        // Ending the shell takes its tab; closing only the tab left the
        // shell running with no tab until the session ended (W5-O). A result
        // that names no terminal gets the tab close, which leaves the shell
        // to the session's end (main's daemon has no reaper and always names
        // the terminal).
        let close = match &placeholder.terminal {
            Some(terminal) => ["terminal", terminal.as_str(), "close"],
            None => ["tab", placeholder.tab.as_str(), "close"],
        };
        backend
            .request(plan(&close, Some(step_key(command_key, "close-shell")))?)
            .map_err(|error| step_failure(error, "close-shell", made(&moved)))?;
        // The new pane keeps the moved pane's name.
        if let Some(name) = &source_name {
            let rename = ["pane", pane.as_str(), "rename", "--name", name.as_str()];
            backend
                .request(plan(&rename, Some(step_key(command_key, "rename")))?)
                .map_err(|error| step_failure(error, "rename", made(&moved)))?;
        }
    }
    // The tab that was selected in the pane is selected again (each move
    // selects the tab it moved).
    if let Some(active) = active.filter(|active| moved.last() != Some(active)) {
        backend
            .request(plan(
                &["tab", active.as_str(), "focus"],
                Some(step_key(command_key, "select-tab")),
            )?)
            .map_err(|error| step_failure(error, "select-tab", made(&moved)))?;
    }
    let focus_target = match focused_before {
        _ if request.focus => Some(pane.clone()),
        Some(before) if before != source => Some(before),
        // The focused pane was the moved one: the focus went with its tabs.
        _ => None,
    };
    if let Some(target) = &focus_target {
        backend
            .request(plan(
                &["pane", target.as_str(), "focus"],
                Some(step_key(command_key, "focus")),
            )?)
            .map_err(|error| step_failure(error, "focus", made(&moved)))?;
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
