//! `carrier-role`: the role a Cloud machine's session host stamps on each
//! carrier `mux-control` stream it opens to this socket
//! ([`cmux_link::carrier_role`]). The stamp is the grant's signed `vmk`, and
//! it becomes this connection's signed role (`native_vm_kind`), which
//! `agent_host_gate` reads before the caller's own `vm_kind` word.
//!
//! Only a unix connection takes a stamp, and only one: a second stamp, or one
//! on a connection that already has a signed role, is refused and changes
//! nothing. The stamp only takes rights away (a same-user process already has
//! the owner's rights here), so nothing else proves who wrote it.

use serde_json::Map;

use super::*;

/// The stamp's reply, or `None` for any other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &line_value::LineValue<'_>,
    writer: &MessageWriter,
) -> Option<bool> {
    if line.cmd() != Some(cmux_link::carrier_role::COMMAND) {
        return None;
    }
    let mut fields = line.object()?.clone();
    fields.remove("cmd");
    let id = fields.remove("id");
    let response = match stamp(mux, client, &fields) {
        Ok(()) => json!({"id": id, "ok": true, "data": {}}),
        Err(code) => json!({"id": id, "ok": false, "error": code, "error_code": code}),
    };
    Some(writer.send_control(&response).is_ok())
}

fn stamp(mux: &Mux, client: u64, fields: &Map<String, Value>) -> Result<(), &'static str> {
    let role = cmux_link::carrier_role::parse(fields).ok_or("carrier_role.malformed")?;
    let mut state = mux.control_clients.state.lock().map_err(|_| "carrier_role.unavailable")?;
    let record = state.clients.get_mut(&client).ok_or("carrier_role.unavailable")?;
    if !matches!(record.transport, ClientTransport::Unix) {
        return Err("carrier_role.not_unix");
    }
    if record.native_vm_kind.is_some() {
        return Err("carrier_role.already_stamped");
    }
    record.native_vm_kind = Some(role);
    Ok(())
}

#[cfg(test)]
#[path = "carrier_role_tests.rs"]
mod tests;
