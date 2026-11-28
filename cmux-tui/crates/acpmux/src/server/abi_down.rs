//! A connection whose hello named an older ABI revision (`abi_compat.rs`): its events and replies
//! written down to that revision just before they go out. Split from `mod.rs` (huge-files gate).

use super::Conn;
use crate::rpc::Message;
use serde_json::Value;
use std::sync::Arc;
use std::sync::atomic::Ordering;

impl Conn {
    /// `msg` written down to the older ABI revision this connection's hello named
    /// (`abi_compat.rs`); none when it reads this build's messages, or no rule changes `msg`.
    /// `reply_to` names a reply's request, whose rules a result follows.
    pub(super) fn written_down(&self, msg: &Message, reply_to: Option<&str>) -> Option<Message> {
        let to = self.abi_down.load(Ordering::Relaxed);
        if to == 0 {
            return None;
        }
        let kind = match msg {
            Message::Notification { method, .. } | Message::Request { method, .. } => {
                format!("event:{method}")
            }
            Message::Response { .. } => format!("response:{}", reply_to?),
        };
        if !crate::abi_compat::changes(&kind, to) {
            return None;
        }
        let mut copy = msg.clone();
        let changed = match &mut copy {
            Message::Notification { method, params: Some(params) }
            | Message::Request { method, params: Some(params), .. } => {
                crate::abi_compat::down_event(method, to, params)
            }
            Message::Response { result: Some(result), .. } => {
                reply_to.is_some_and(|m| crate::abi_compat::down_result(m, to, result))
            }
            _ => false,
        };
        changed.then_some(copy)
    }

    /// [`Self::written_down`] of a shared `session/update` line, parsed only when a rule
    /// changes that event for this connection's revision.
    pub(super) fn written_down_line(&self, line: &str) -> Option<String> {
        // perf-hot: one atomic load for a connection at this build's revision (every one today).
        let to = self.abi_down.load(Ordering::Relaxed);
        if to == 0 {
            return None;
        }
        let kind = format!("event:{}", crate::rpc::method::SESSION_UPDATE);
        if !crate::abi_compat::changes(&kind, to) {
            return None;
        }
        let mut value: Value = serde_json::from_str(line).ok()?;
        let params = value.get_mut("params")?;
        crate::abi_compat::down_event(crate::rpc::method::SESSION_UPDATE, to, params)
            .then(|| value.to_string())
    }

    /// An already serialized `result` of a `method` request, written down like
    /// [`Self::written_down`]; the same `Arc` when nothing changes.
    pub(super) fn written_down_result(
        &self,
        method: Option<&str>,
        result: Arc<String>,
    ) -> Arc<String> {
        let to = self.abi_down.load(Ordering::Relaxed);
        let Some(method) = method.filter(|_| to != 0) else { return result };
        if !crate::abi_compat::changes(&format!("response:{method}"), to) {
            return result;
        }
        let Ok(mut value) = serde_json::from_str::<Value>(&result) else { return result };
        if !crate::abi_compat::down_result(method, to, &mut value) {
            return result;
        }
        Arc::new(value.to_string())
    }
}
