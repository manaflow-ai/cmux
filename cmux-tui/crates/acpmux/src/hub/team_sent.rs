//! Durable ownership of outbound team receipts, independent of mutable address claims.
use super::*;

impl Hub {
    pub(crate) fn record_team_send(&self, session: &Session, id: &str) -> bool {
        self.append_stored(session, "out", "team_message_sent", json!({"messageId": id}))
            && self.store.flush_session(&session.id).is_ok()
    }

    pub(crate) fn sent_team_message(&self, caller: &str, id: &str) -> bool {
        let Ok(session) = self.resolve(caller) else { return false };
        let mut found = false;
        let result = self.store.scan_kinds(&session.id, &["team_message_sent"], &mut |event| {
            found = event.msg.get("messageId").and_then(Value::as_str) == Some(id);
            !found
        });
        result.is_ok() && found
    }
}
