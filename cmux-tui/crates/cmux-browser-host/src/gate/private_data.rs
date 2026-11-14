//! The gate's part of the private-data record (crate::private_data_log):
//! a session's `cookies.clear` and `cookies.restore` that succeed get one
//! entry in the session's policy log, one `browser.privateData` event on
//! the session's event path and one entry in the host log the person reads.
//! Entries carry the op, site, counts and restore id; never a cookie value.

use super::{Gate, now_ms, push_log};
use crate::private_data_log::{EVENT, PrivateDataLog};
use crate::protocol::DriverEvent;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

impl Gate {
    /// Writes this session's private-data entries to the host's log too.
    pub fn with_private_data_log(mut self, log: Arc<PrivateDataLog>) -> Gate {
        self.private_data = log;
        self
    }

    /// Records a `cookies.clear` or `cookies.restore` the engine answered
    /// (`answer`, before masking). Other methods record nothing.
    pub(super) fn note_private_data(&self, method: &str, params: &Value, answer: &Value) {
        let mut entry = match method {
            "cookies.clear" => json!({
                "op": method,
                "site": answer["site"],
                "cookies": answer["cleared"].as_u64().unwrap_or(0),
                "restoreId": answer["restoreId"],
            }),
            "cookies.restore" => json!({
                "op": method,
                "site": answer["site"],
                "cookies": answer["restored"].as_u64().unwrap_or(0),
                "kept": answer["kept"].as_u64().unwrap_or(0),
                "expired": answer["expired"].as_u64().unwrap_or(0),
                "restoreId": params["restoreId"],
            }),
            _ => return,
        };
        let target = params.get("targetId").and_then(Value::as_str);
        if let Some(target) = target {
            entry.set("targetId", json!(target));
        }
        self.record_private_data(entry, target);
    }

    /// Writes one private-data entry (op, site, counts, restore id; never a
    /// value) to the session's policy log, the host log and the session's
    /// event path (`browser.privateData`).
    pub(super) fn record_private_data(&self, mut entry: Value, target: Option<&str>) {
        entry.set("at", json!(now_ms()));
        let entry = self.mask_for_target(target, &entry);
        push_log(&self.log, entry.clone());
        let session = self.inputs.as_ref().map(|inputs| inputs.session_id().to_owned());
        let mut host_entry = entry.clone();
        host_entry.set("session", json!(session));
        self.private_data.push(host_entry);
        // Agent activity: the session's event path, like automation.input.
        let mut payload = json!({"v": 1, "session_id": session});
        if let (Some(payload), Some(entry)) = (payload.as_object_mut(), entry.as_object()) {
            payload.extend(entry.clone());
        }
        let event = DriverEvent { name: EVENT.to_owned(), payload };
        if let Some(inputs) = &self.inputs {
            inputs.send(event, &|event| self.driver.send_session_event(event));
        }
    }
}

#[cfg(test)]
mod tests;
