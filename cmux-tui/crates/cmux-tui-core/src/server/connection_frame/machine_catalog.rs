//! The verified native app publishes its admitted route projection; readers
//! still use machine.list/get. No paths, credentials, commands or relay reach.

use super::super::client_registry::machine_catalog::Publication;
use super::super::{MessageWriter, Response, origin_gate, send_response};
use crate::Mux;
use crate::resource::MachinePublicId;
use serde::Deserialize;
use serde_json::{Map, Value};
use std::sync::Arc;

/// The owner a `machine-catalog-publish` request names, checked before its
/// publication. spec/sdk-schema.json gives the command these fields plus
/// the publication's.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    expected_machine_id: String,
}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("machine-catalog-publish") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else { return None };
    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some("machine-catalog-publish") {
        return None;
    }
    let id = fields.remove("id");
    let facts = origin_gate::app_connection(mux, client);
    let result = (|| {
        if !mux.control_clients.is_unix(client)
            || mux.is_remote_client(client)
            || !facts.verified_app
            || facts.agent
        {
            return Err("machine_catalog.not_trusted");
        }
        if message.len() > 128 * 1024 {
            return Err("machine_catalog.bad_request");
        }
        let owner: Map<String, Value> =
            fields.remove_entry("expected_machine_id").into_iter().collect();
        let Owner { expected_machine_id } = serde_json::from_value(Value::Object(owner))
            .map_err(|_| "machine_catalog.bad_request")?;
        let expected = MachinePublicId::parse(expected_machine_id)
            .map_err(|_| "machine_catalog.bad_request")?;
        if expected != mux.machine_public_id {
            return Err("machine_catalog.owner_mismatch");
        }
        let publication = Publication::parse(Value::Object(fields), &mux.machine_public_id)?;
        mux.control_clients.publish_machine_catalog(client, publication)
    })();
    let (ok, data, error, error_code) = match result {
        Ok(data) => (true, Some(data), None, None),
        Err(code) => (
            false,
            None,
            Some("Machine catalog publication was refused".to_string()),
            Some(code.to_string()),
        ),
    };
    Some(send_response(writer, Response { id, ok, data, error, error_code, error_delivery: None }))
}
