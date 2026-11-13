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
    Caller, Earlier, Kind, Placement, app_placement, correlated, correlation_key,
    creation_lookup_params, earlier_creation, names_no_place, rename_params, split_below_params,
    split_params,
};
use crate::cli::GlobalArgs;
use crate::cli::command::{RequestPlan, WireOperation};
use crate::cli::resolve::{self, Failure, SocketRoute};
use crate::cli::wire::{self, KeyReport};
use cmux_json::JsonSet as _;

type Reader = BufReader<Box<dyn Stream>>;

/// What [`apply`] did with a CLI request.
enum Outcome {
    /// Not a tab with no place, or the app does not place the caller.
    Unchanged,
    /// The request now names the pane beside the caller.
    Placed,
    /// The tab opened in a pane made for it, or an earlier try of the same
    /// request had already opened it; this is the exit code.
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

/// The mutations this step sends itself: on the request's connection, with
/// the request's idempotency key (and keys derived from it), and with the
/// caller's launch credential, as the request itself would carry it
/// (wire.rs), so the daemon records the same actor for a tab opened here.
struct Sender<'a> {
    reader: &'a mut Reader,
    key: Option<&'a str>,
    credential: Option<String>,
}

impl Sender<'_> {
    /// One mutation, keyed by the request's key (`step`: `None`) or by
    /// `<key>-<step>`.
    fn send(
        &mut self,
        operation: ResourceOperation,
        params: Map<String, Value>,
        step: Option<&str>,
    ) -> Result<Value, Failure> {
        let key = match (self.key, step) {
            (Some(key), Some(step)) => Some(format!("{key}-{step}")),
            (Some(key), None) => Some(key.to_owned()),
            (None, _) => None,
        };
        resolve::call_as(self.reader, operation, params, key.as_deref(), self.credential.as_deref())
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
    let Some(params) = plan.params.as_object() else { return Outcome::Unchanged };
    if !caller.is_known()
        || !names_no_place(params)
        || !resolve::this_machine(params)
        || !route.has_owner()
    {
        return Outcome::Unchanged;
    }
    let correlation = correlation_key(params, idempotency_key).map(str::to_owned);
    // An earlier try of this request may have opened the tab already, in a
    // place this try would no longer choose: answer with that tab.
    let earlier = correlation.as_deref().and_then(|key| {
        let lookup = creation_lookup_params(params, key);
        let resolution =
            resolve::read(reader, ResourceOperation::SessionCreationResolve, lookup).ok()?;
        earlier_creation(&resolution)
    });
    let placed = route.identity().and_then(|identity| app_placement(identity, &caller, kind));
    if earlier.is_none() && placed.is_none() {
        return Outcome::Unchanged;
    }
    // The creations below can take as long as the request itself.
    let _ = reader.get_mut().set_read_timeout(wire::response_read_timeout(plan, true));
    let credential = crate::cli::launch_credential::for_connection(reader, route.path);
    let mut sender = Sender { reader, key: idempotency_key, credential };
    let answered = match (earlier, placed) {
        (Some(earlier), _) => replay(&mut sender, plan, kind, earlier),
        (None, Some(Placement::Pane { workspace, pane })) => {
            let Some(params) = plan.params.as_object_mut() else { return Outcome::Unchanged };
            params.insert("workspace".into(), json!(workspace));
            params.insert("pane".into(), json!(pane));
            return Outcome::Placed;
        }
        (None, Some(Placement::NewColumn { workspace, chat_pane })) => {
            let split = split_params(params, &workspace, &chat_pane);
            split_for(&mut sender, plan, kind, correlated(split, correlation.as_deref()))
        }
        (None, Some(Placement::SplitBelow { workspace, pane })) => {
            let split = split_below_params(params, &workspace, &pane);
            split_for(&mut sender, plan, kind, correlated(split, correlation.as_deref()))
        }
        (None, None) => return Outcome::Unchanged,
    };
    Outcome::Answered(match answered {
        Ok(result) => wire::print_result(global, plan, result),
        Err(failure) => failure.report(global.output),
    })
}

/// Makes the pane `split` asks for (a new column, or a pane below one) and
/// opens the tab of `plan` in it.
fn split_for(
    sender: &mut Sender<'_>,
    plan: &RequestPlan,
    kind: Kind,
    split: Map<String, Value>,
) -> Result<Value, Failure> {
    let created = sender.send(ResourceOperation::PaneSplit, split, Some("beside"))?;
    let path = created.get("value").filter(|value| value.is_object()).unwrap_or(&created).clone();
    in_new_pane(sender, plan, kind, &path, created)
}

/// Answers with the tab an earlier try of the same request opened, and ends
/// what that try may have left undone. `Err` for a creation of another kind
/// under the same key, which the daemon refuses too.
fn replay(
    sender: &mut Sender<'_>,
    plan: &RequestPlan,
    kind: Kind,
    earlier: Earlier,
) -> Result<Value, Failure> {
    match (kind, earlier.operation.as_str()) {
        // The pane was made: name the terminal, or open the browser tab in it.
        (_, "pane.split") => in_new_pane(sender, plan, kind, &earlier.path, earlier.result),
        // The terminal tab itself.
        (Kind::Terminal, "tab.create_terminal") => Ok(earlier.result),
        (_, other) => Err(Failure::Resource(super::creation_conflict(other))),
    }
}

/// The tab of `plan` in the pane a split made (`path`: the split's created
/// path, `split`: its answer). A terminal is the split's own tab, named as
/// the creation asked. A browser tab opens in the new pane, whose shell then
/// ends, which leaves the pane to the browser; a failed open ends the shell
/// too, and with it the new pane. Every step is keyed, so a retry repeats
/// none of them.
fn in_new_pane(
    sender: &mut Sender<'_>,
    plan: &RequestPlan,
    kind: Kind,
    path: &Value,
    split: Value,
) -> Result<Value, Failure> {
    let text = |field: &str| path.get(field).and_then(Value::as_str).map(str::to_owned);
    let create = plan.params.as_object().cloned().unwrap_or_default();
    let Some(workspace) = text("workspace_id") else {
        return Err(Failure::Transport(
            "protocol error: the daemon's split names no workspace".into(),
        ));
    };
    match kind {
        Kind::Terminal => {
            if let Some(rename) = rename_params(&create, &workspace, path) {
                sender.send(ResourceOperation::TabRename, rename, Some("name"))?;
            }
            Ok(split)
        }
        Kind::Browser => {
            let (Some(pane), Some(shell)) = (text("pane_id"), text("terminal_id")) else {
                return Err(Failure::Transport(
                    "protocol error: the daemon's split names no new pane".into(),
                ));
            };
            let mut close = resolve::route(&create);
            close.insert("terminal".into(), json!(shell));
            let mut open = create;
            open.insert("workspace".into(), json!(workspace));
            open.insert("pane".into(), json!(pane));
            let opened = sender.send(ResourceOperation::BrowserProfileOpen, open, None);
            // The browser tab is open either way; a shell that stays is closed by hand.
            let _ = sender.send(ResourceOperation::TerminalClose, close, Some("shell"));
            opened
        }
    }
}

/// [`apply`] at the CLI's send step (wire.rs): `Ok(Some(bytes))` for a
/// request that now names the pane beside the caller, `Ok(None)` for one
/// left as it was, `Err(exit code)` when this step answered it.
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
