//! cmux Remote's MCP tools (docs/cmux-remote.md, Settings and controls):
//! the host's status and grants, worker restarts, and this Mac's Screen
//! Sharing switch and device access. Reads and lowering go to the daemon
//! (they work with the app quit); turning sharing on and raising a device's
//! access go to the cmux app, which asks the person first.

use serde_json::{Map, Value, json};

use super::super::app::{ActionName, action_run_params, waiting_run_timeout};
// One person-confirmation budget with `cmux remote-host`.
use super::super::remote_host::{CONFIRM_TIMEOUT, LowerChange};
use super::transport::{CallFailure, FailureKind};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

pub(super) struct RemoteTool {
    pub name: &'static str,
    description: &'static str,
    schema: fn() -> Value,
}

fn no_arguments() -> Value {
    json!({"type": "object", "properties": {}, "additionalProperties": false})
}

fn permission() -> Value {
    json!({"type": "object", "properties": {"permission": {"type": "string", "enum": ["accessibility", "screen-recording"]}},
           "required": ["permission"], "additionalProperties": false})
}

fn worker() -> Value {
    json!({"type": "object", "properties": {
        "worker": {"type": "string", "enum": ["computer-use", "screen-sharing"]},
        "force": {"type": "boolean", "description": "End a running Screen Sharing session first"}},
        "required": ["worker"], "additionalProperties": false})
}

fn share() -> Value {
    json!({"type": "object", "properties": {
        "on": {"type": "boolean"},
        "device": {"type": "string", "description": "Another Mac of yours to share (its device id or name), with on: true. The person confirms on this device's cmux; that Mac admits it only from a machine its owner granted."}},
        "required": ["on"], "additionalProperties": false})
}

fn access() -> Value {
    json!({"type": "object", "properties": {
        "device": {"type": "string", "description": "A device id from remote_status's screen.devices"},
        "scope": {"type": "string", "enum": ["none", "ask", "view", "full"]}},
        "required": ["device", "scope"], "additionalProperties": false})
}

pub(super) const TOOLS: &[RemoteTool] = &[
    RemoteTool {
        name: "remote_status",
        description: "cmux Remote's state: the host and its two workers (Computer Use, Screen Sharing), the macOS grants it holds (Accessibility, Screen Recording), a pending upgrade, and this Mac's Screen Sharing (sharing, the session, devices and their access).",
        schema: no_arguments,
    },
    RemoteTool {
        name: "remote_refresh",
        description: "Read cmux Remote's macOS grants again. A worker that started before a new grant restarts (an idle one at once, a busy one after its session), so cmux never needs a relaunch.",
        schema: no_arguments,
    },
    RemoteTool {
        name: "remote_request_permission",
        description: "Ask macOS for one of cmux Remote's grants. macOS asks the person; a second ask opens the System Settings pane where the switch is. At most one ask per grant every 30 s.",
        schema: permission,
    },
    RemoteTool {
        name: "remote_open_settings",
        description: "Open the System Settings pane that lists cmux Remote for a grant.",
        schema: permission,
    },
    RemoteTool {
        name: "remote_restart",
        description: "Start one cmux Remote worker again. A Screen Sharing worker with a session restarts after it unless force is true.",
        schema: worker,
    },
    RemoteTool {
        name: "remote_share",
        description: "Share This Mac on the device hub. Off works at once; on asks the person in cmux first, unless this Mac already shares or they chose Always Allow (remote.shareWithoutAsking). With device, share another Mac of yours: the person confirms on this device, and nothing is shared without that click.",
        schema: share,
    },
    RemoteTool {
        name: "remote_set_access",
        description: "A device's access to this Mac's screen (none, ask, view, full). Lowering works at once; raising asks the person in cmux first.",
        schema: access,
    },
    RemoteTool {
        name: "remote_stop_session",
        description: "Stop the current Screen Sharing session of this Mac.",
        schema: no_arguments,
    },
];

pub(super) fn find(name: &str) -> Option<&'static RemoteTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl RemoteTool {
    pub(super) fn descriptor_json(&self) -> Value {
        let mutates = !matches!(self.name, "remote_status");
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": (self.schema)(),
            "annotations": {"readOnlyHint": !mutates, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        })
    }

    pub(super) fn call(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Value {
        let text = |key: &str| arguments.get(key).and_then(Value::as_str).map(str::to_owned);
        let call = |method: &str, params: Value| json!({"cmd": "remote-host-call", "method": method, "params": params});
        let request = match self.name {
            "remote_status" => json!({"cmd": "remote-host-status"}),
            "remote_refresh" => call("refresh", json!({})),
            "remote_request_permission" | "remote_open_settings" => {
                let Some(permission) = text("permission") else {
                    return invalid("permission is required");
                };
                let method =
                    if self.name == "remote_open_settings" { "open_settings" } else { "request" };
                call(method, json!({"permission": permission}))
            }
            "remote_restart" => {
                let Some(worker) = text("worker") else { return invalid("worker is required") };
                let force = arguments.get("force").and_then(Value::as_bool).unwrap_or(false);
                call("restart", json!({"worker": worker, "force": force}))
            }
            "remote_share" => {
                match (arguments.get("on").and_then(Value::as_bool), text("device")) {
                    (Some(true), Some(device)) => return share_device(backend, &device),
                    (Some(false), Some(_)) => {
                        return invalid("device works with on: true; turn sharing off on that Mac");
                    }
                    (Some(true), None) => {
                        return confirm(backend, json!({"action": "share", "on": true}));
                    }
                    (Some(false), None) => return lower(backend, LowerChange::ShareOff),
                    (None, _) => return invalid("on is required"),
                }
            }
            "remote_set_access" => {
                let (Some(device), Some(scope)) = (text("device"), text("scope")) else {
                    return invalid("device and scope are required");
                };
                match backend
                    .daemon(call("screen.access", json!({"device": device, "scope": scope})))
                {
                    Ok(value) => return success(value, true),
                    Err(failure)
                        if failure.error.get("code").and_then(Value::as_str)
                            == Some("origin.forbidden") =>
                    {
                        return confirm(
                            backend,
                            json!({"action": "access", "device": device, "scope": scope}),
                        );
                    }
                    Err(failure) => return failure_result(failure),
                }
            }
            "remote_stop_session" => return lower(backend, LowerChange::StopSession),
            _ => return invalid("unknown cmux Remote tool"),
        };
        match backend.daemon(request) {
            Ok(mut value) if self.name == "remote_status" => {
                if let Some(note) = super::super::remote_host::not_bundled_note(&value)
                    && let Some(fields) = value.as_object_mut()
                {
                    fields.insert("note".into(), Value::String(note.into()));
                }
                success(value, false)
            }
            Ok(value) => success(value, true),
            Err(failure) => failure_result(failure),
        }
    }
}

/// Share-off and stop-session: cmux Remote's worker when this build has it,
/// the cmux app's own action when the daemon says it has none (Release and
/// NIGHTLY), the same routing as `cmux remote-host share off|stop`.
fn lower(backend: &impl Backend, change: LowerChange) -> Value {
    let status = backend.daemon(json!({"cmd": "remote-host-status"})).ok();
    if !super::super::remote_host::routes_to_app(status.as_ref()) {
        return match backend.daemon(change.worker_call()) {
            Ok(value) => success(value, true),
            Err(failure) => failure_result(failure),
        };
    }
    let action = change.app_action();
    let params = Value::Object(action_run_params(action, ActionName::Any, "cli"));
    match backend.app("action.run", params, waiting_run_timeout(action), None, true) {
        Ok(value) => success(value, true),
        Err(failure) => failure_result(failure),
    }
}

fn invalid(message: &str) -> Value {
    tool_error(envelope(v2_tools::invalid(message.to_string()), "not_run", None))
}

fn confirm(backend: &impl Backend, params: Value) -> Value {
    match backend.app("remote.confirm", params, CONFIRM_TIMEOUT, None, true) {
        Ok(value) => success(value, true),
        Err(failure) => failure_result(failure),
    }
}

/// `remote_share {on: true, device}`: the person confirms on this device's cmux, which signs
/// the approval only after the click (`remote_host::share_approval`).
fn share_device(backend: &impl Backend, device: &str) -> Value {
    use crate::remote_host::share_approval;
    let ask = |params| {
        backend
            .app("remote.confirm", params, CONFIRM_TIMEOUT, None, true)
            .map_err(|failure| failure.error)
    };
    let record = |event: &str, mut fields: Value| {
        if let Some(map) = fields.as_object_mut() {
            map.insert("via".into(), json!("mcp"));
        }
        crate::devices::record(event, fields);
    };
    match share_approval::share_from_here(
        device,
        ask,
        &share_approval::AwaitingSameAccountControl,
        record,
    ) {
        Ok(value) => success(value, true),
        Err(error) => failure_result(CallFailure {
            kind: FailureKind::Rejected,
            error,
            idempotency_key: None,
        }),
    }
}

/// A daemon command's failure in the tools' shape.
pub(super) fn daemon_failure(error: Value) -> CallFailure {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("request.rejected").to_string();
    let message =
        error.get("message").and_then(Value::as_str).unwrap_or("request rejected").to_string();
    let kind =
        if code.starts_with("transport.") { FailureKind::NotRun } else { FailureKind::Rejected };
    CallFailure::local(kind, &code, message)
}
