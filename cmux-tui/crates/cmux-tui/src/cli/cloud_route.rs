//! `--machine <Cloud VM>` for every session verb (`terminal list`, `tab list`, `pane …`).
//!
//! The local daemon has no Cloud VM in its catalog, so copying `--machine vm:ID` into its
//! request answered `selector.not_found` (or `validation.invalid` for a `vm_…` id) for every
//! verb but `workspace list`, which the app's rows answered (cloud_workspaces.rs). The VM's own
//! daemon answers every verb, and the app already holds a link to it: `cloud.machine_stream
//! {machine}` answers a local socket each connection of which reaches that daemon (the socket
//! `cmux chat --on vm:… --wait` observes, cloud_start_chat.rs). So a request whose `--machine`
//! names a Cloud VM goes there whole: the same request, on that socket, without the `machine`
//! selector (the VM's daemon is its own `current` machine).
//!
//! A VM is named as everywhere else: `vm:ID`, its `vm_…` id, `machine:ID`, or its one title in
//! the app's list. `vm:ID` is a VM whatever the app says; any other word is one only when the
//! app lists it, so a paired device's name still goes to the local daemon as before.

use serde_json::{Value, json};

/// Where a request with `--machine` goes.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// No Cloud VM named: the local daemon, as before.
    Local,
    /// The VM's daemon, through the app's link socket.
    Link { machine_id: String, socket: String },
    /// A Cloud VM was named but cannot be reached: the error to print.
    Refused(Value),
}

/// Whether `selector` says it is a Cloud VM whatever the app lists: `vm:ID`.
fn definite_vm(selector: &str) -> Option<&str> {
    selector.strip_prefix("vm:").filter(|id| !id.is_empty())
}

/// Whether `selector` looks like a Cloud VM's id (`vm_…`, `vm-…`, `machine:…`), so a VM the app
/// does not list is a VM it does not know, not a local machine's name.
fn vm_shaped(selector: &str) -> bool {
    selector.starts_with("vm:")
        || selector.starts_with("vm_")
        || selector.starts_with("vm-")
        || selector.starts_with("machine:")
}

/// The route for `--machine selector`. `machines`: the app's `cloud.machines` rows (`None`
/// with no app); `stream`: the app's link socket for a machine id, or its refusal.
pub(super) fn decide(
    selector: &str,
    machines: impl FnOnce() -> Option<Vec<Value>>,
    stream: impl FnOnce(&str) -> Result<String, Value>,
) -> Route {
    // The local daemon's own words: `current`, and its `machine_…` ids.
    if selector == "current" || selector.starts_with("machine_") {
        return Route::Local;
    }
    let Some(machines) = machines() else {
        if !vm_shaped(selector) {
            return Route::Local;
        }
        let id = definite_vm(selector).unwrap_or_else(|| super::vm_words::bare_id(selector));
        return Route::Refused(error(
            "cloud.app_required",
            format!("vm:{id} is a Cloud VM, and only the cmux app reaches one; open the cmux app"),
            json!({"machine": selector}),
        ));
    };
    let machine_id = match super::cloud_workspaces::find(&machines, selector) {
        Ok(Some(machine)) => machine.get("id").and_then(Value::as_str).map(str::to_owned),
        Ok(None) => None,
        Err(ambiguous) => return Route::Refused(ambiguous),
    };
    let Some(machine_id) = machine_id else {
        if vm_shaped(selector) {
            let id = super::vm_words::bare_id(selector);
            return Route::Refused(error(
                "selector.not_found",
                format!("no Cloud VM of yours has the id {id}; run `cmux vm ls` for your VMs"),
                json!({"scope": "machine", "selector": selector, "next": "cmux vm ls"}),
            ));
        }
        return Route::Local;
    };
    match stream(&machine_id) {
        Ok(socket) => Route::Link { machine_id, socket },
        Err(refusal) => {
            let reason = refusal
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the app has no link to it")
                .to_owned();
            Route::Refused(error(
                "machine.unreachable",
                format!(
                    "vm:{machine_id} has no link from the cmux app ({reason}); resume it with \
                     `cmux vm resume {machine_id}` or open it in the app, then run this again"
                ),
                json!({"machine": machine_id, "app": refusal}),
            ))
        }
    }
}

fn error(code: &str, message: String, details: Value) -> Value {
    json!({"code": code, "message": message, "details": details, "retryable": false})
}

/// [`decide`] against the app this command reaches, for `plan`. `None` when the request is not
/// routed (no `--machine`, or an explicit `--socket`, which names the daemon itself). A VM the app
/// has no link to still lists its workspaces from the app's rows (cloud_workspaces.rs), so its
/// `workspace list` goes on to that fallback instead of the refusal.
pub(super) fn route(global: &super::GlobalArgs, plan: &super::command::RequestPlan) -> Option<Route> {
    use super::command::WireOperation;
    use cmux_tui_core::resource::ResourceOperation;
    let lists_workspaces =
        matches!(plan.operation, WireOperation::Typed(ResourceOperation::WorkspaceList));
    match route_for(global)? {
        Route::Refused(error)
            if lists_workspaces && error["code"].as_str() == Some("machine.unreachable") =>
        {
            None
        }
        route => Some(route),
    }
}

fn route_for(global: &super::GlobalArgs) -> Option<Route> {
    let selector = global.machine.as_deref()?;
    if global.socket.is_some() {
        return None;
    }
    let route = decide(
        selector,
        || super::cloud_workspaces::read(global),
        |machine| link_socket(global, machine),
    );
    (route != Route::Local).then_some(route)
}

/// The app's link socket to Cloud machine `machine` (`cloud.machine_stream`).
pub(super) fn link_socket(global: &super::GlobalArgs, machine: &str) -> Result<String, Value> {
    let mut stream = super::app::connect_command(global)?;
    let answer = super::app::request(
        &mut stream,
        "cloud.machine_stream",
        json!({"machine": machine}),
        std::time::Duration::from_secs(10),
    )
    .map_err(|message| json!({"code": "app.transport", "message": message}))?;
    let answer = answer?;
    answer.get("socket").and_then(Value::as_str).map(str::to_owned).ok_or_else(
        || json!({"code": "machine_stream.unavailable", "message": "the app answered no socket"}),
    )
}

/// `global` sent to the VM's daemon: its link socket, and no `--machine` (the VM's daemon is
/// its own current machine).
pub(super) fn routed(global: &super::GlobalArgs, socket: &str) -> super::GlobalArgs {
    let mut routed = global.clone();
    routed.machine = None;
    routed.socket = Some(std::path::PathBuf::from(socket));
    routed
}

#[cfg(test)]
mod tests;
