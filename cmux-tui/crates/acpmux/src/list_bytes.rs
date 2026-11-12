//! What each client is sent of the session list: replies to `_acpmux/watch` and
//! `_acpmux/sessions`, by the name its `initialize` gave (`clientInfo.name`) and the connection's
//! origin, as counts and bytes since this daemon started. `_acpmux/status` reports them as
//! `listReplies`, so a client that reads the whole list again and again is named, with its rate
//! (two status reads a minute apart). A whole list of a busy Mac was 31 MB, sent about seven times a
//! minute (2026-11-11) with no client named; this is that detector.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde_json::{Value, json};

/// At most this many clients remembered (a name comes from the client).
const CLIENTS: usize = 128;

#[derive(Default, Clone, Copy)]
struct Count {
    replies: u64,
    bytes: u64,
    largest: u64,
}

/// The counts; [`global`] is this daemon's.
pub struct ListBytes {
    by_client: Mutex<BTreeMap<String, Count>>,
}

impl ListBytes {
    pub const fn new() -> Self {
        Self { by_client: Mutex::new(BTreeMap::new()) }
    }

    /// A list reply of `bytes` went to `client` (its name and origin, `"name (origin)"`).
    pub fn observe(&self, client: &str, bytes: usize) {
        let mut by = self.by_client.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let key = if by.contains_key(client) || by.len() < CLIENTS { client } else { "(other)" };
        let count = by.entry(key.to_owned()).or_default();
        count.replies += 1;
        count.bytes += bytes as u64;
        count.largest = count.largest.max(bytes as u64);
    }

    /// `listReplies` in `_acpmux/status`: each client's replies, bytes and largest reply.
    pub fn status(&self) -> Value {
        let by = self.by_client.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let clients: serde_json::Map<String, Value> = by
            .iter()
            .map(|(k, c)| {
                (k.clone(), json!({"replies": c.replies, "bytes": c.bytes, "largest": c.largest}))
            })
            .collect();
        Value::Object(clients)
    }
}

impl Default for ListBytes {
    fn default() -> Self {
        Self::new()
    }
}

static GLOBAL: ListBytes = ListBytes::new();

/// This daemon's counts.
pub fn global() -> &'static ListBytes {
    &GLOBAL
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_client_is_counted_by_name_with_its_largest_reply() {
        let lists = ListBytes::new();
        lists.observe("cmux-next-turn-states (local)", 31 << 20);
        lists.observe("cmux-next-turn-states (local)", 1 << 20);
        lists.observe("cmux-react-agent-pane (app)", 2048);
        let status = lists.status();
        assert_eq!(status["cmux-next-turn-states (local)"]["replies"], 2);
        assert_eq!(status["cmux-next-turn-states (local)"]["bytes"], (32u64 << 20));
        assert_eq!(status["cmux-next-turn-states (local)"]["largest"], (31u64 << 20));
        assert_eq!(status["cmux-react-agent-pane (app)"]["replies"], 1);
    }

    #[test]
    fn past_its_client_cap_the_rest_count_as_other() {
        let lists = ListBytes::new();
        for i in 0..CLIENTS + 5 {
            lists.observe(&format!("c{i}"), 10);
        }
        let status = lists.status();
        assert_eq!(status.as_object().map(|o| o.len()), Some(CLIENTS + 1));
        assert_eq!(status["(other)"]["replies"], 5);
    }
}
