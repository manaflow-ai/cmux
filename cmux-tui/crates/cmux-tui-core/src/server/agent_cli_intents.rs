//! Verified native UI intent persistence. Stored identities are not execution grants.

use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

use super::{MessageWriter, Response, apps, origin_gate, responses::send_response};
use crate::mux::Mux;
use crate::resource::{MachinePublicId, SessionPublicId};
use crate::workspace_registry::agent_cli_intents::AgentCLIIntent;

pub(super) const CAPABILITY: &str = "agent-cli-intents-v1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    intents: Vec<AgentCLIIntent>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Settle {
    keys: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Attach {
    key: String,
    receipt: Value,
}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("agent-cli-intents-") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let command = fields.remove("cmd")?;
    let command = command.as_str()?;
    if !matches!(
        command,
        "agent-cli-intents-record"
            | "agent-cli-intents-list"
            | "agent-cli-intents-attach"
            | "agent-cli-intents-settle"
    ) {
        return None;
    }
    let id = fields.remove("id");
    if !mux.control_clients.is_unix(client)
        || mux.is_remote_client(client)
        || !origin_gate::is_user(mux, client)
        || !apps::user_origin_allowed(mux, client)
    {
        return Some(reply(writer, id, Err("agent_cli_intents.not_trusted")));
    }
    let machine = fields.remove("expected_machine_id").and_then(|v| v.as_str().map(str::to_owned));
    let session = fields.remove("expected_session_id").and_then(|v| v.as_str().map(str::to_owned));
    let (Some(machine), Some(session)) = (machine, session) else {
        return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
    };
    let (Ok(machine), Ok(session)) =
        (MachinePublicId::parse(machine), SessionPublicId::parse(session))
    else {
        return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
    };
    if machine != mux.machine_public_id || session != mux.session_public_id {
        return Some(reply(writer, id, Err("agent_cli_intents.owner_mismatch")));
    }
    let actor = origin_gate::connection_actor(mux, client);
    let input = Value::Object(fields);
    let result: anyhow::Result<Value> = match command {
        "agent-cli-intents-record" => {
            let Ok(Record { intents }) = serde_json::from_value(input) else {
                return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
            };
            mux.personal_mutation(|registry| registry.record_agent_cli_intents(&actor, &intents))
                .map(|(intents, changed)| json!({"intents":intents,"changed":changed}))
        }
        "agent-cli-intents-settle" => {
            let Ok(Settle { keys }) = serde_json::from_value(input) else {
                return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
            };
            mux.personal_mutation(|registry| registry.settle_agent_cli_intents(&actor, &keys))
                .map(|(intents, changed)| json!({"intents":intents,"changed":changed}))
        }
        "agent-cli-intents-attach" => {
            let Ok(Attach { key, receipt }) = serde_json::from_value(input) else {
                return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
            };
            mux.personal_mutation(|registry| {
                registry.attach_agent_cli_intent_receipt(&actor, &key, &receipt)
            })
            .map(|(intent, changed)| json!({"intent":intent,"changed":changed}))
        }
        _ => {
            if input.as_object().is_none_or(|o| !o.is_empty()) {
                return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
            }
            mux.workspace_registry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .list_agent_cli_intents(&actor)
                .map(|intents| json!({"intents":intents}))
        }
    };
    Some(reply(writer, id, result.map_err(|_| "agent_cli_intents.refused")))
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, &str>) -> bool {
    let (ok, data, error_code) = match result {
        Ok(value) => (true, Some(value), None),
        Err(code) => (false, None, Some(code.to_owned())),
    };
    send_response(
        writer,
        Response {
            id,
            ok,
            data,
            error: error_code
                .as_ref()
                .map(|_| "The update intent ledger refused this request".into()),
            error_code,
            error_delivery: None,
        },
    )
}
