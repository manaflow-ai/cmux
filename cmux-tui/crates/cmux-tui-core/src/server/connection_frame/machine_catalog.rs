//! The verified native app publishes its admitted route projection; readers
//! still use machine.list/get. No paths, credentials, commands or relay reach.

use super::super::client_registry::machine_catalog::Publication;
use super::super::routes::{Route, RouteLine, RouteName};
use super::super::{FrameStage, Response, origin_gate, send_response};
use crate::resource::MachinePublicId;
use serde_json::Value;

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact("machine-catalog-publish")],
    stage: FrameStage::MachineCatalog,
    entry: handle,
}];

/// Answers a `machine-catalog-publish` line (the route found it by its
/// `cmd`). The line's one decode is its `Value`, which gives every reply the
/// `id` as written, a refused one too, and then the publication. `None`
/// only for a line with no `Value` (a number past `f64`, a lone surrogate);
/// the `Command` parse answers it.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    fields.remove("cmd");
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
        let expected = fields
            .remove("expected_machine_id")
            .and_then(|value| value.as_str().map(str::to_owned))
            .ok_or("machine_catalog.bad_request")?;
        let expected =
            MachinePublicId::parse(expected).map_err(|_| "machine_catalog.bad_request")?;
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
