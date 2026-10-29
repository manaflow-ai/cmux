//! What one session holds in the daemon's memory, and the trim of it to its tail. Part of
//! `Hub`; see `hub/mod.rs`.
//!
//! A session's transcript is its event log on disk; in memory it keeps its record
//! (`SessionMeta`) and a bounded tail of the running turn: the trailing message text of the
//! error comparison (`stream.rs`, at most 64 KB), the last stderr lines, the queue and the
//! outcomes of recent prompts. [`Session::retained_bytes`] adds them up for the daemon's memory
//! report (bytes per consumer, top sessions); [`Session::trim_to_tail`] gives
//! back their spare capacity, which a long message leaves behind after it ends. Chrome's
//! `MemoryConsumer` model: the report says what each consumer holds, the release frees what it
//! can rebuild (`base/memory_coordinator/memory_consumer.h`). The trim is lossless: it keeps
//! every value and drops only spare capacity, so it may run at any pressure level.

use super::*;
use crate::no_panic::LockExt;

/// Heap bytes of a string as allocated.
fn string_bytes(s: &str, capacity: usize) -> u64 {
    capacity.max(s.len()) as u64
}

impl Session {
    /// The bytes this session holds in memory beyond its log: its record and its tail.
    /// An estimate from lengths and capacities (a record counts as its JSON), never a walk of
    /// the log.
    pub fn retained_bytes(&self) -> u64 {
        let meta = {
            let meta = self.meta.lock_or_recover();
            serde_json::to_vec(&*meta).map_or(0, |json| json.len() as u64)
        };
        let stream = {
            let st = self.stream.lock_or_recover();
            string_bytes(&st.trailing_text, st.trailing_text.capacity())
                + (st.trailing_seqs.capacity() * std::mem::size_of::<u64>()) as u64
                + st.open_message.as_ref().map_or(0, |m| m.len() as u64)
                + st.harness_error.as_ref().map_or(0, |e| e.to_string().len() as u64)
        };
        let stderr: u64 = self
            .stderr_tail
            .lock_or_recover()
            .iter()
            .map(|line| string_bytes(line, line.capacity()))
            .sum();
        let prompts: u64 = self
            .prompts
            .lock_or_recover()
            .iter()
            .map(|(id, outcome)| {
                let answer = outcome.borrow().as_ref().map_or(0, |result| match result {
                    Ok(value) => value.to_string().len(),
                    Err(error) => error.message.len(),
                });
                (id.len() + answer) as u64
            })
            .sum();
        let queue: u64 = self
            .queue
            .lock_or_recover()
            .iter()
            .map(|q| {
                (q.prompt_id.len() + q.turn_id.len() + q.client.len() + q.preview.len()) as u64
            })
            .sum();
        let open_tools: u64 =
            self.open_tools.lock_or_recover().iter().map(|id| id.len() as u64).sum();
        let forum: u64 =
            self.forum_retold.lock_or_recover().iter().map(|k| k.len() as u64).sum::<u64>()
                + self.forum_telling.lock_or_recover().iter().map(|k| k.len() as u64).sum::<u64>();
        meta + stream + stderr + prompts + queue + open_tools + forum
    }

    /// Gives back the spare capacity of this session's tail; every value stays. Returns the
    /// bytes [`Session::retained_bytes`] counts less after it.
    pub fn trim_to_tail(&self) -> u64 {
        let before = self.retained_bytes();
        {
            let mut st = self.stream.lock_or_recover();
            st.trailing_text.shrink_to_fit();
            st.trailing_seqs.shrink_to_fit();
        }
        {
            let mut tail = self.stderr_tail.lock_or_recover();
            tail.iter_mut().for_each(String::shrink_to_fit);
            tail.shrink_to_fit();
        }
        self.prompts.lock_or_recover().shrink_to_fit();
        self.queue.lock_or_recover().shrink_to_fit();
        self.open_tools.lock_or_recover().shrink_to_fit();
        self.forum_retold.lock_or_recover().shrink_to_fit();
        self.forum_telling.lock_or_recover().shrink_to_fit();
        before.saturating_sub(self.retained_bytes())
    }
}

impl Hub {
    /// Every session's [`Session::retained_bytes`], largest first (the memory report's top
    /// sessions take the head).
    pub fn session_retained_bytes(&self) -> Vec<(String, u64)> {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock_or_recover().values().cloned().collect();
        let mut bytes: Vec<(String, u64)> =
            sessions.iter().map(|s| (s.id.clone(), s.retained_bytes())).collect();
        bytes.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        bytes
    }

    /// Trims every session to its tail ([`Session::trim_to_tail`]); the bytes given back. The
    /// release a memory consumer of session state runs under pressure.
    pub fn trim_sessions_to_tail(&self) -> u64 {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock_or_recover().values().cloned().collect();
        sessions.iter().map(|s| s.trim_to_tail()).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a session may hold beyond its log after any amount of streaming.
    const SESSION_BUDGET: u64 = 1 << 20;

    fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir).unwrap();
        Hub::new(cfg, store)
    }

    fn session(hub: &Arc<Hub>, id: &str) -> Arc<Session> {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA,
            "id": id,
            "name": id,
            "harness": "claude",
            "cwd": "/tmp",
            "status": "running",
            "createdAt": 0,
            "updatedAt": 0,
        }))
        .unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock_or_recover().insert(id.to_owned(), session.clone());
        session
    }

    fn update(update: Value) -> Message {
        Message::notification(
            crate::rpc::method::SESSION_UPDATE,
            json!({"sessionId": "agent-1", "update": update}),
        )
    }

    /// 8 MB of answer text in 200 messages of 40 chunks, a tool call between messages: the
    /// session keeps its record and a bounded tail, never the transcript, and a trim leaves no
    /// more spare capacity than the last message's.
    #[tokio::test]
    async fn streaming_megabytes_keeps_a_session_within_its_budget() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-ss");
        let hub = hub_at(dir.path());
        let session = session(&hub, "s-stream");
        let tap = hub.session_tap(&session);
        let chunk = "w".repeat(1024);
        for message in 0..200 {
            for _ in 0..40 {
                let msg = update(json!({
                    "sessionUpdate": "agent_message_chunk",
                    "messageId": format!("m{message}"),
                    "content": {"type": "text", "text": chunk},
                }));
                assert!(tap(Direction::In, &msg, None).is_some());
                if let Message::Notification { params, .. } = &msg {
                    hub.on_update(&session, params.as_ref(), false);
                }
            }
            let call = update(json!({
                "sessionUpdate": "tool_call", "toolCallId": format!("t{message}"),
                "kind": "execute", "status": "completed", "title": "echo",
            }));
            assert!(tap(Direction::In, &call, None).is_some());
        }
        let held = session.retained_bytes();
        assert!(held <= SESSION_BUDGET, "the session holds {held} bytes (budget {SESSION_BUDGET})");
        // The last message ended with its tool call: its text was cleared, its capacity stays.
        assert!(session.stream.lock_or_recover().trailing_text.capacity() >= 40 * 1024);
        assert!(hub.trim_sessions_to_tail() >= 40 * 1024);
        assert_eq!(session.stream.lock_or_recover().trailing_text.capacity(), 0);
        assert_eq!(
            hub.session_retained_bytes(),
            vec![("s-stream".to_owned(), session.retained_bytes())]
        );
    }

    /// A trim keeps every value: the open message's trailing text, the stderr tail and the
    /// queue read the same after it.
    #[tokio::test]
    async fn a_trim_keeps_the_tail() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-ss");
        let hub = hub_at(dir.path());
        let session = session(&hub, "s-keep");
        let tap = hub.session_tap(&session);
        for text in ["one ", "two"] {
            let msg = update(json!({
                "sessionUpdate": "agent_message_chunk", "messageId": "m1",
                "content": {"type": "text", "text": text},
            }));
            assert!(tap(Direction::In, &msg, None).is_some());
        }
        {
            let mut tail = session.stderr_tail.lock_or_recover();
            let mut line = String::with_capacity(4096);
            line.push_str("Not logged in");
            tail.push_back(line);
        }
        session.trim_to_tail();
        assert_eq!(session.stream.lock_or_recover().trailing_text, "one two");
        assert_eq!(session.stream.lock_or_recover().trailing_seqs.len(), 2);
        let tail = session.stderr_tail.lock_or_recover();
        assert_eq!(tail.iter().map(String::as_str).collect::<Vec<_>>(), ["Not logged in"]);
        assert!(tail[0].capacity() < 4096);
    }
}
