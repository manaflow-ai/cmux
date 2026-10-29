//! A user-admitted native update job on this owner. App execution scopes
//! remain unsupported: an actor JSON field is never execution authority.

use crate::panic_free::JsonFields;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_attach::agent_session_link::AcpmuxLink;
use super::{
    MessageWriter, Response, agent_inventory, apps, origin_gate, responses::send_response,
};
use crate::WorkspaceMutation;
use crate::mux::Mux;
use crate::resource::{MachinePublicId, ResourceError, SessionPublicId};

pub(super) const CAPABILITY: &str = "agent-cli-update-job-v1";
pub(super) const RESOLVE_CAPABILITY: &str = "agent-cli-update-job-resolve-v1";
const COMMAND: &str = "agent-cli-update-job";
const RESOLVE_COMMAND: &str = "agent-cli-update-job-resolve";
const TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Params {
    expected_machine_id: String,
    expected_session_id: String,
    cli: String,
    idempotency_key: String,
}

#[derive(Debug)]
enum Failure {
    NotTrusted,
    BadRequest,
    OwnerMismatch,
    SessionMismatch,
    Busy,
    Unavailable,
    Unsupported,
    InvalidResponse,
    Refused,
}

impl Failure {
    fn code(&self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_cli_job.not_trusted",
            Self::BadRequest => "agent_cli_job.bad_request",
            Self::OwnerMismatch => "agent_cli_job.owner_mismatch",
            Self::SessionMismatch => "agent_cli_job.session_mismatch",
            Self::Busy => "agent_cli_job.busy",
            Self::Unavailable => "agent_cli_job.unavailable",
            Self::Unsupported => "agent_cli_job.unsupported",
            Self::InvalidResponse => "agent_cli_job.invalid_response",
            Self::Refused => "agent_cli_job.refused",
        }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for Failure {}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains(COMMAND) {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let resolve = match fields.remove("cmd").as_ref().and_then(Value::as_str) {
        Some(COMMAND) => false,
        Some(RESOLVE_COMMAND) => true,
        _ => return None,
    };
    let id = fields.remove("id");
    // Same-uid Unix alone is insufficient. Require the proved main app and
    // no terminal/agent binding, before parsing owner/CLI/key or any work.
    if !mux.control_clients.is_unix(client)
        || mux.is_remote_client(client)
        || !origin_gate::is_user(mux, client)
        || !apps::user_origin_allowed(mux, client)
    {
        return Some(reply(writer, id, Err(Failure::NotTrusted.into())));
    }
    let Ok(params) = serde_json::from_value::<Params>(Value::Object(fields)) else {
        return Some(reply(writer, id, Err(Failure::BadRequest.into())));
    };
    let Ok(expected) = MachinePublicId::parse(params.expected_machine_id) else {
        return Some(reply(writer, id, Err(Failure::BadRequest.into())));
    };
    if expected != mux.machine_public_id {
        return Some(reply(writer, id, Err(Failure::OwnerMismatch.into())));
    }
    let Ok(expected_session) = SessionPublicId::parse(params.expected_session_id) else {
        return Some(reply(writer, id, Err(Failure::BadRequest.into())));
    };
    if expected_session != mux.session_public_id {
        return Some(reply(writer, id, Err(Failure::SessionMismatch.into())));
    }
    if params.cli.is_empty()
        || params.cli.len() > 128
        || !params.cli.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
    {
        return Some(reply(writer, id, Err(Failure::BadRequest.into())));
    }
    let mutation = match WorkspaceMutation::new(
        params.idempotency_key,
        "agent_cli.update",
        origin_gate::connection_actor(mux, client),
    ) {
        Ok(mutation) => mutation,
        Err(_) => return Some(reply(writer, id, Err(Failure::BadRequest.into()))),
    };
    if resolve {
        return Some(reply(writer, id, mux.resolve_agent_cli_update_job(&params.cli, &mutation)));
    }
    let slot = match agent_inventory::reserve(mux) {
        Ok(slot) => slot,
        Err(_) => return Some(reply(writer, id, Err(Failure::Busy.into()))),
    };
    let owner = mux.clone();
    // Capture this owner's configured socket, but do not require it until
    // the kernel knows there is no durable receipt to replay.
    let socket = mux.control_clients.agent_sessions.socket();
    let output = writer.clone();
    let request_id = id.clone();
    let spawned = std::thread::Builder::new().name("mux-agent-cli-job".into()).spawn(move || {
        let cli = params.cli;
        let result = owner.create_agent_cli_update_job(&cli, &mutation, || {
            prepare(socket.as_deref().ok_or(Failure::Unavailable)?, &cli)
        });
        drop(slot);
        reply(&output, request_id, result);
    });
    if spawned.is_err() {
        return Some(reply(writer, id, Err(Failure::Busy.into())));
    }
    Some(true)
}

fn prepare(socket: &Path, cli: &str) -> anyhow::Result<Vec<String>> {
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Failure::Unavailable)?;
    let hello = link
        .call("initialize", json!({"protocolVersion":1}), TIMEOUT)
        .map_err(|_| Failure::Unavailable)?;
    let features = hello.pointer("/_meta/acpmux/features").and_then(Value::as_array);
    if !features.is_some_and(|f| {
        f.iter().all(Value::is_string) && f.contains(&json!("harnessUpdatePrepare"))
    }) {
        return Err(Failure::Unsupported.into());
    }
    let plan = link
        .call("_acpmux/harness/update/prepare", json!({"cli":cli}), TIMEOUT)
        .map_err(|_| Failure::Refused)?;
    let fields = plan.as_object().ok_or(Failure::InvalidResponse)?;
    if fields.len() != 2 || plan.field("cli") != cli {
        return Err(Failure::InvalidResponse.into());
    }
    let argv = plan
        .field("argv")
        .as_array()
        .ok_or(Failure::InvalidResponse)?
        .iter()
        .map(|v| v.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or(Failure::InvalidResponse)?;
    if !(2..=9).contains(&argv.len())
        || !argv.first().is_some_and(|program| Path::new(program).is_absolute())
        || argv.iter().any(|v| v.contains('\0'))
        || argv.iter().map(String::len).sum::<usize>() > 16 * 1024
    {
        return Err(Failure::InvalidResponse.into());
    }
    Ok(argv)
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: anyhow::Result<Value>) -> bool {
    let response = match result {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => {
            let code = if let Some(failure) = error.downcast_ref::<Failure>() {
                failure.code().to_owned()
            } else if error.downcast_ref::<crate::mux::AgentCLIJobBusy>().is_some() {
                Failure::Busy.code().to_owned()
            } else if let Some(resource) = error.downcast_ref::<ResourceError>() {
                resource.code.clone()
            } else {
                "operation.failed".to_owned()
            };
            Response {
                id,
                ok: false,
                data: None,
                error: Some("The owner could not start the update job".into()),
                error_code: Some(code),
                error_delivery: None,
            }
        }
    };
    send_response(writer, response)
}
