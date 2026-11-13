//! The CLI's send step for [`super`]: `cmux tab create terminal` and `cmux
//! browser profile open` with no `--workspace`, `--screen` or `--pane`, run
//! by a caller the owning app places (an agent chat, a Chief turn, or a
//! terminal with an app that places terminals). The tab goes where the app's
//! `beside` answer says, on the request's own connection. Every other
//! no-place creation, and a caller the app does not place, gets the caller's
//! own place from the daemon after this step (resolve.rs `place_creation`).

use std::io::BufReader;

use cmux_tui_core::platform::transport::Stream;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::{
    Caller, Kind, Placement, app_placement, names_no_place, rename_params, split_below_params,
    split_params,
};
use crate::cli::GlobalArgs;
use crate::cli::command::{RequestPlan, WireOperation};
use crate::cli::resolve::{self, SocketRoute};
use crate::cli::wire::{self, KeyReport};
use cmux_json::JsonSet as _;

type Reader = BufReader<Box<dyn Stream>>;

/// What [`apply`] did with a CLI request.
enum Outcome {
    /// Not a tab with no place, or the app does not place the caller.
    Unchanged,
    /// The request now names the pane beside the caller.
    Placed,
    /// A new pane was made for it and the tab opened there; this is the
    /// exit code.
    Answered(i32),
}

/// The kind of tab `plan` creates, when the app's `beside` answer places it.
fn beside_kind(plan: &RequestPlan) -> Option<Kind> {
    match plan.operation {
        WireOperation::Typed(ResourceOperation::TabCreateTerminal) => Some(Kind::Terminal),
        WireOperation::Typed(ResourceOperation::BrowserProfileOpen) => Some(Kind::Browser),
        _ => None,
    }
}

/// Places `plan` beside its caller when the app that owns the request's
/// daemon says where that is. Another machine's daemon has none of this
/// app's ids, so a `--machine` request is left alone.
fn apply(
    global: &GlobalArgs,
    plan: &mut RequestPlan,
    reader: &mut Reader,
    route: &SocketRoute<'_>,
    idempotency_key: Option<&str>,
) -> Outcome {
    let Some(kind) = beside_kind(plan) else { return Outcome::Unchanged };
    let caller = Caller::of_process();
    let Some(params) = plan.params.as_object_mut() else { return Outcome::Unchanged };
    if !caller.is_known() || !names_no_place(params) || !resolve::this_machine(params) {
        return Outcome::Unchanged;
    }
    let Some(placed) = route.identity().and_then(|identity| app_placement(identity, &caller, kind))
    else {
        return Outcome::Unchanged;
    };
    let (workspace, split) = match placed {
        Placement::Pane { workspace, pane } => {
            params.insert("workspace".into(), json!(workspace));
            params.insert("pane".into(), json!(pane));
            return Outcome::Placed;
        }
        Placement::NewColumn { workspace, chat_pane } => {
            let split = split_params(params, &workspace, &chat_pane);
            (workspace, split)
        }
        Placement::SplitBelow { workspace, pane } => {
            let split = split_below_params(params, &workspace, &pane);
            (workspace, split)
        }
    };
    let answered = match kind {
        Kind::Terminal => split_terminal(plan, reader, idempotency_key, split, &workspace),
        Kind::Browser => split_browser(plan, reader, idempotency_key, split, &workspace),
    };
    Outcome::Answered(match answered {
        Ok(result) => wire::print_result(global, plan, result),
        Err(failure) => failure.report(global.output),
    })
}

/// Answers a `tab create terminal` with `split` (a new column or a pane
/// below one), then names the new tab as the creation asked.
fn split_terminal(
    plan: &RequestPlan,
    reader: &mut Reader,
    idempotency_key: Option<&str>,
    split: Map<String, Value>,
    workspace: &str,
) -> Result<Value, resolve::Failure> {
    let key = idempotency_key.map(|key| format!("{key}-beside"));
    let created = resolve::call(reader, ResourceOperation::PaneSplit, split, key.as_deref())?;
    let path = created.get("value").filter(|value| value.is_object()).unwrap_or(&created);
    let rename = plan.params.as_object().and_then(|params| rename_params(params, workspace, path));
    if let Some(rename) = rename {
        let key = idempotency_key.map(|key| format!("{key}-name"));
        resolve::call(reader, ResourceOperation::TabRename, rename, key.as_deref())?;
    }
    Ok(created)
}

/// Answers a `browser profile open` in a new pane: `split` makes the pane
/// (with a shell tab, since a pane holds at least one tab), the browser tab
/// opens there, and the shell ends, which leaves the pane to the browser. A
/// failed open ends the shell too, and with it the new pane.
fn split_browser(
    plan: &RequestPlan,
    reader: &mut Reader,
    idempotency_key: Option<&str>,
    split: Map<String, Value>,
    workspace: &str,
) -> Result<Value, resolve::Failure> {
    let key = idempotency_key.map(|key| format!("{key}-beside"));
    let created = resolve::call(reader, ResourceOperation::PaneSplit, split, key.as_deref())?;
    let path = created.get("value").filter(|value| value.is_object()).unwrap_or(&created);
    let text = |field: &str| path.get(field).and_then(Value::as_str).map(str::to_owned);
    let (Some(pane), Some(shell)) = (text("pane_id"), text("terminal_id")) else {
        return Err(resolve::Failure::Transport(
            "protocol error: the daemon's split names no new pane".into(),
        ));
    };
    let mut open = plan.params.as_object().cloned().unwrap_or_default();
    open.insert("workspace".into(), json!(workspace));
    open.insert("pane".into(), json!(pane));
    let route = resolve::route(&open);
    let opened =
        resolve::call(reader, ResourceOperation::BrowserProfileOpen, open, idempotency_key);
    let mut close = route;
    close.insert("terminal".into(), json!(shell));
    let key = idempotency_key.map(|key| format!("{key}-shell"));
    // The browser tab is open either way; a shell that stays is closed by hand.
    let _ = resolve::call(reader, ResourceOperation::TerminalClose, close, key.as_deref());
    opened
}

/// [`apply`] at the CLI's send step (wire.rs): `Ok(Some(bytes))` for a
/// request that now names the pane beside the caller, `Ok(None)` for one
/// left as it was, `Err(exit code)` when a new pane answered it.
pub(in crate::cli) fn run(
    global: &GlobalArgs,
    plan: &mut RequestPlan,
    request: &mut Value,
    reader: &mut Reader,
    route: &SocketRoute<'_>,
    caller_route: bool,
    key_report: &KeyReport,
) -> Result<Option<Vec<u8>>, i32> {
    if !caller_route {
        return Ok(None);
    }
    let key = request.get("idempotency_key").and_then(Value::as_str).map(str::to_owned);
    match apply(global, plan, reader, route, key.as_deref()) {
        Outcome::Unchanged => Ok(None),
        Outcome::Placed => {
            request.set("params", plan.params.clone());
            wire::encode_request(request).map(Some)
        }
        Outcome::Answered(code) => {
            if code == 0 {
                key_report.succeeded();
            }
            key_report.finish(global.output);
            Err(code)
        }
    }
}
