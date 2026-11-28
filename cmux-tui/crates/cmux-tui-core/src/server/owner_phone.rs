//! `owner-phone`: the phone the Cloud machine's cmux link admitted after its
//! PhoneChat owner check, stamped on the unix stream it opens to this socket
//! for that phone ([`cmux_link::owner_phone`], RFD 0135 gate 4). The stream's
//! Cloud mobile prompts carry it to acpmux as `_meta.acpmux.ownerPhone`
//! (`agent_session_attach.rs`), which treats the phone as the owner's own
//! paired phone under D13, never with Full access.
//!
//! Only a unix connection takes a stamp, only one, and never one with a signed
//! carrier role (a teammate's or the session host's carrier stream); a stamped
//! connection takes no carrier role after it either. The phone is read back
//! only while the connection is a phone carrier (`phone_carrier_client`), so a
//! stamp on a connection that never declares the phone's capability counts
//! for nothing. As with `carrier_role.rs`, a same-user process already has the
//! owner's full rights here; the stamp, with the capability, lowers them.

use serde_json::Map;

use super::*;

/// The stamp's reply, or `None` for any other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &line_value::LineValue<'_>,
    writer: &MessageWriter,
) -> Option<bool> {
    if line.cmd() != Some(cmux_link::owner_phone::COMMAND) {
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
    let device = cmux_link::owner_phone::parse(fields).ok_or("owner_phone.malformed")?;
    let mut state = mux.control_clients.state.lock().map_err(|_| "owner_phone.unavailable")?;
    let record = state.clients.get_mut(&client).ok_or("owner_phone.unavailable")?;
    if !matches!(record.transport, ClientTransport::Unix) {
        return Err("owner_phone.not_unix");
    }
    if record.native_vm_kind.is_some() {
        return Err("owner_phone.carrier_stream");
    }
    if record.owner_phone.is_some() {
        return Err("owner_phone.already_stamped");
    }
    record.owner_phone = Some(device);
    Ok(())
}

impl Mux {
    /// The owner-checked phone stamped on `client`, while it is a phone carrier.
    pub(super) fn owner_phone(&self, client: u64) -> Option<String> {
        if !self.phone_carrier_client(client) {
            return None;
        }
        let state = self.control_clients.state.lock().ok()?;
        state.clients.get(&client)?.owner_phone.clone()
    }
}

#[cfg(test)]
#[path = "owner_phone_tests.rs"]
mod tests;
