//! The gate's part of the private-data record (crate::private_data_log):
//! a session's `cookies.clear` and `cookies.restore` that succeed get one
//! entry in the session's policy log, one `browser.privateData` event on
//! the session's event path and one entry in the host log the person reads.
//! Entries carry the op, site, counts and restore id; never a cookie value.

use super::{Gate, now_ms, push_log};
use crate::private_data_log::{EVENT, PrivateDataLog};
use crate::protocol::DriverEvent;
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
            entry["targetId"] = json!(target);
        }
        entry["at"] = json!(now_ms());
        let entry = self.mask_for_target(target, &entry);
        push_log(&self.log, entry.clone());
        let session = self.inputs.as_ref().map(|inputs| inputs.session_id().to_owned());
        let mut host_entry = entry.clone();
        host_entry["session"] = json!(session);
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
mod tests {
    use super::super::{Gate, Grants};
    use crate::driver::Driver;
    use crate::private_data_log::{EVENT, PrivateDataLog};
    use crate::protocol::{DriverError, DriverEvent};
    use crate::vm::VmHost;
    use serde_json::{Value, json};
    use std::sync::{Arc, Mutex};

    /// An engine whose cookie ops answer like the headless driver's.
    struct CookieEngine;

    impl Driver for CookieEngine {
        fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
            match (method, params["restoreId"].as_str()) {
                ("cookies.clear", _) => Ok(json!({
                    "cleared": 2, "site": "a.test", "restoreId": "host:0123456789abcdef0123456789abcdef"
                })),
                ("cookies.restore", Some("host:0123456789abcdef0123456789abcdef")) => {
                    Ok(json!({"restored": 1, "kept": 1, "expired": 0, "site": "a.test"}))
                }
                ("cookies.restore", _) => Err(DriverError::invalid("no cookie backup")),
                _ => Ok(json!({"value": "s3cret-cookie"})),
            }
        }

        fn capabilities(&self) -> Vec<&'static str> {
            Vec::new()
        }
    }

    #[test]
    fn cookie_clears_and_restores_are_logged_for_the_session_the_host_and_agent_activity() {
        let events: Arc<Mutex<Vec<DriverEvent>>> = Arc::default();
        let seen = events.clone();
        let sink: crate::driver::EventSink =
            Arc::new(move |event| seen.lock().unwrap().push(event));
        let host_log = Arc::new(PrivateDataLog::default());
        let gate = Gate::new(Arc::new(CookieEngine), Grants::default())
            .with_input_events("agent-s", sink)
            .with_private_data_log(host_log.clone());
        let id = "host:0123456789abcdef0123456789abcdef";
        gate.driver_call("cookies.clear", json!({"targetId": "T", "name": "sid"})).unwrap();
        gate.driver_call("cookies.restore", json!({"restoreId": id})).unwrap();
        // A refused restore and other calls log nothing.
        gate.driver_call("cookies.restore", json!({"restoreId": "host:gone"})).unwrap_err();
        gate.driver_call("cookies.get", json!({"urls": ["https://a.test/"]})).unwrap();

        let expect = [("cookies.clear", 2), ("cookies.restore", 1)];
        let session_log = gate.native("policy", json!({"op": "log", "args": {}})).unwrap();
        let session_log = session_log.as_array().unwrap();
        assert_eq!(session_log.len(), 2, "{session_log:?}");
        let host_entries = host_log.entries();
        assert_eq!(host_entries.len(), 2, "{host_entries:?}");
        let events = events.lock().unwrap();
        let activity: Vec<&DriverEvent> = events.iter().filter(|e| e.name == EVENT).collect();
        assert_eq!(activity.len(), 2, "{events:?}");
        for (i, (op, count)) in expect.into_iter().enumerate() {
            for entry in [&session_log[i], &host_entries[i], &activity[i].payload] {
                assert_eq!(entry["op"], op, "{entry}");
                assert_eq!(entry["site"], "a.test", "{entry}");
                assert_eq!(entry["cookies"], count, "{entry}");
                assert_eq!(entry["restoreId"], id, "{entry}");
                assert!(entry["at"].as_u64().is_some(), "{entry}");
                assert!(!entry.to_string().contains("s3cret"), "{entry}");
            }
            assert_eq!(host_entries[i]["session"], "agent-s");
            assert_eq!(activity[i].payload["session_id"], "agent-s");
        }
        assert_eq!(session_log[0]["targetId"], "T");
        assert_eq!(session_log[1]["kept"], 1);
        assert!(session_log.iter().all(|entry| entry.get("blocked").is_none()));
    }
}
