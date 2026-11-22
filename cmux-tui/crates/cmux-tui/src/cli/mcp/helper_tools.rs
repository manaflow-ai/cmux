//! cmux Helper's MCP tools (docs/cmux-helper.md, Settings and controls): the
//! helper's grants, and this Mac's Screen Sharing switch and device access.
//! Status reads the daemon; sharing changes go to the cmux app: turning
//! sharing on and a device's access ask the person first, share off and stop
//! are the app's own Stop actions.

use serde_json::{Map, Value, json};

use super::super::app::{ActionName, action_run_params, waiting_run_timeout};
// One person-confirmation budget with `cmux helper`.
use super::super::helper::{CONFIRM_TIMEOUT, LowerChange};
use super::transport::{CallFailure, FailureKind};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

pub(super) struct HelperTool {
    pub name: &'static str,
    description: &'static str,
    schema: fn() -> Value,
}

fn no_arguments() -> Value {
    json!({"type": "object", "properties": {}, "additionalProperties": false})
}

fn share() -> Value {
    json!({"type": "object", "properties": {
        "on": {"type": "boolean"},
        "device": {"type": "string", "description": "Another Mac of yours to share (its device id or name), with on: true. The person confirms on this device's cmux; that Mac admits it only from a machine its owner granted."}},
        "required": ["on"], "additionalProperties": false})
}

fn access() -> Value {
    json!({"type": "object", "properties": {
        "device": {"type": "string", "description": "A device id or name of the person's devices"},
        "scope": {"type": "string", "enum": ["none", "ask", "view", "full"]}},
        "required": ["device", "scope"], "additionalProperties": false})
}

pub(super) const TOOLS: &[HelperTool] = &[
    HelperTool {
        name: "helper_status",
        description: "cmux Helper's state: the macOS grants it holds for Computer Use and Screen Sharing (Accessibility, Screen Recording) as the cmux app last read them, and the name System Settings lists it under.",
        schema: no_arguments,
    },
    HelperTool {
        name: "helper_share",
        description: "Share This Mac on the device hub. Off works at once; on asks the person in cmux first. With device, share another Mac of yours: the person confirms on this device, and nothing is shared without that click.",
        schema: share,
    },
    HelperTool {
        name: "helper_set_access",
        description: "A device's access to this Mac's screen (none, ask, view, full). The person confirms it in cmux.",
        schema: access,
    },
    HelperTool {
        name: "helper_stop_session",
        description: "Stop the current Screen Sharing session of this Mac.",
        schema: no_arguments,
    },
];

pub(super) fn find(name: &str) -> Option<&'static HelperTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl HelperTool {
    pub(super) fn descriptor_json(&self) -> Value {
        let mutates = !matches!(self.name, "helper_status");
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": (self.schema)(),
            "annotations": {"readOnlyHint": !mutates, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        })
    }

    pub(super) fn call(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Value {
        let text = |key: &str| arguments.get(key).and_then(Value::as_str).map(str::to_owned);
        match self.name {
            "helper_status" => match backend.daemon(json!({"cmd": "helper-status"})) {
                Ok(value) => success(value, false),
                Err(failure) => failure_result(failure),
            },
            "helper_share" => {
                match (arguments.get("on").and_then(Value::as_bool), text("device")) {
                    (Some(true), Some(device)) => share_device(backend, &device),
                    (Some(false), Some(_)) => {
                        invalid("device works with on: true; turn sharing off on that Mac")
                    }
                    (Some(true), None) => confirm(backend, json!({"action": "share", "on": true})),
                    (Some(false), None) => lower(backend, LowerChange::ShareOff),
                    (None, _) => invalid("on is required"),
                }
            }
            "helper_set_access" => {
                let (Some(device), Some(scope)) = (text("device"), text("scope")) else {
                    return invalid("device and scope are required");
                };
                confirm(backend, json!({"action": "access", "device": device, "scope": scope}))
            }
            "helper_stop_session" => lower(backend, LowerChange::StopSession),
            _ => invalid("unknown cmux Helper tool"),
        }
    }
}

/// Share-off and stop-session: the cmux app's own action, as `cmux helper share off|stop`.
fn lower(backend: &impl Backend, change: LowerChange) -> Value {
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

/// `helper_share {on: true, device}`: the person confirms on this device's cmux, which signs
/// the approval only after the click (`crate::remote_host::share_approval`).
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
