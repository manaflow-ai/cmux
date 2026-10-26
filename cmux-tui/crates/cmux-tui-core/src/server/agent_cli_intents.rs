//! Verified native UI intent persistence. Stored identities are not execution grants.

use serde::Deserialize;
use serde_json::{Value, json};

use super::routes::RouteLine;
use super::{MessageWriter, Response, apps, origin_gate, responses::send_response};
use crate::resource::{MachinePublicId, SessionPublicId};
use crate::workspace_registry::agent_cli_intents::AgentCLIIntent;

pub(super) const CAPABILITY: &str = "agent-cli-intents-v1";

/// The wire names of [`Command`]: the names of this module's route.
pub(in crate::server) const COMMANDS: [&str; 4] = [
    "agent-cli-intents-record",
    "agent-cli-intents-list",
    "agent-cli-intents-settle",
    "agent-cli-intents-attach",
];

/// Every request names this daemon's machine and session; the owner is
/// checked before the command runs. spec/sdk-schema.json types each variant.
#[derive(Deserialize)]
#[serde(tag = "cmd", deny_unknown_fields)]
enum Command {
    #[serde(rename = "agent-cli-intents-record")]
    Record {
        expected_machine_id: String,
        expected_session_id: String,
        intents: Vec<AgentCLIIntent>,
    },
    #[serde(rename = "agent-cli-intents-list")]
    List { expected_machine_id: String, expected_session_id: String },
    #[serde(rename = "agent-cli-intents-settle")]
    Settle { expected_machine_id: String, expected_session_id: String, keys: Vec<String> },
    #[serde(rename = "agent-cli-intents-attach")]
    Attach { expected_machine_id: String, expected_session_id: String, key: String, receipt: Value },
}

impl Command {
    fn owner(&self) -> (&str, &str) {
        match self {
            Self::Record { expected_machine_id, expected_session_id, .. }
            | Self::List { expected_machine_id, expected_session_id }
            | Self::Settle { expected_machine_id, expected_session_id, .. }
            | Self::Attach { expected_machine_id, expected_session_id, .. } => {
                (expected_machine_id, expected_session_id)
            }
        }
    }
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::OneOf(&COMMANDS)],
        stage: crate::server::FrameStage::AgentCliIntents,
        entry: handle,
    }];

/// Answers a line whose `cmd` is one of [`COMMANDS`] (the route found it by
/// name). The line's one decode is its `Value`, which gives every reply the
/// `id` as written, a refused one too, and then the typed [`Command`].
/// `None` only for a line with no `Value` (a number past `f64`, a lone
/// surrogate); the `Command` parse answers it.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    let id = fields.remove("id");
    if !mux.control_clients.is_unix(client)
        || mux.is_remote_client(client)
        || !origin_gate::is_user(mux, client)
        || !apps::user_origin_allowed(mux, client)
    {
        return Some(reply(writer, id, Err("agent_cli_intents.not_trusted")));
    }
    let Ok(command) = serde_json::from_value::<Command>(Value::Object(fields)) else {
        return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
    };
    let (machine, session) = command.owner();
    let (Ok(machine), Ok(session)) =
        (MachinePublicId::parse(machine.to_owned()), SessionPublicId::parse(session.to_owned()))
    else {
        return Some(reply(writer, id, Err("agent_cli_intents.bad_request")));
    };
    if machine != mux.machine_public_id || session != mux.session_public_id {
        return Some(reply(writer, id, Err("agent_cli_intents.owner_mismatch")));
    }
    let actor = origin_gate::connection_actor(mux, client);
    let result: anyhow::Result<Value> = match command {
        Command::Record { intents, .. } => mux
            .personal_mutation(|registry| registry.record_agent_cli_intents(&actor, &intents))
            .map(|(intents, changed)| json!({"intents":intents,"changed":changed})),
        Command::Settle { keys, .. } => mux
            .personal_mutation(|registry| registry.settle_agent_cli_intents(&actor, &keys))
            .map(|(intents, changed)| json!({"intents":intents,"changed":changed})),
        Command::Attach { key, receipt, .. } => mux
            .personal_mutation(|registry| {
                registry.attach_agent_cli_intent_receipt(&actor, &key, &receipt)
            })
            .map(|(intent, changed)| json!({"intent":intent,"changed":changed})),
        Command::List { .. } => mux
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .list_agent_cli_intents(&actor)
            .map(|intents| json!({"intents":intents})),
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
