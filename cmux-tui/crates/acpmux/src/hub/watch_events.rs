//! Journal cursors make lag/reconnect reconciliation lossless. Only named chats
//! are read, only after a hub event, registration, or daemon startup.
use super::Hub;
use super::watches::{Watch, summary};
use crate::rpc::{RpcError, method};
use crate::server::wait::Until;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cursor {
    pub seq: u64,
    pub initial: Option<Value>,
    pub reply: String,
    pub tail: String,
    pub matched: bool,
    pub last_resolve: String,
    pub last_candidate: String,
    pub reply_open: bool,
    pub turn_mark: String,
    pub unread: bool,
    pub permission_wakes: std::collections::BTreeSet<String>,
    pub await_fresh: bool,
    pub forum: Option<ForumSelector>,
    /// None migrates pre-reconciliation watches without replaying historical posts.
    pub forum_heads: Option<std::collections::BTreeMap<String, String>>,
}
/// An explicit opt-in to receipt events in the recipient's own forum.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ForumSelector {
    pub channel: String,
    pub thread: Option<String>,
}
impl ForumSelector {
    pub fn parse(
        until: &[String],
        channel: Option<String>,
        thread: Option<String>,
        filtered: bool,
    ) -> Result<Option<Self>, RpcError> {
        if !until.iter().any(|u| u == "forum") {
            if channel.is_some() || thread.is_some() {
                return Err(RpcError::invalid_params("channel and thread require until=[forum]"));
            }
            return Ok(None);
        }
        if until.len() != 1 || filtered {
            return Err(RpcError::invalid_params(
                "forum watches cannot mix states or transcript matching",
            ));
        }
        let channel =
            channel.ok_or_else(|| RpcError::invalid_params("forum watches require channel"))?;
        if std::iter::once(channel.as_str()).chain(thread.as_deref()).any(|s| {
            s.is_empty() || s.len() > crate::forum::MAX_KEY_BYTES || s.chars().any(char::is_control)
        }) {
            return Err(RpcError::invalid_params(
                "channel and thread must be bounded nonempty strings without controls",
            ));
        }
        Ok(Some(Self { channel, thread }))
    }
    fn receipt(&self, key: &str, msg: &Value) -> Option<String> {
        if msg["stored"] != true
            || msg["duplicate"] == true
            || msg["channel"].as_str() != Some(self.channel.as_str())
        {
            return None;
        }
        let thread = msg["thread"].as_str()?;
        let post = msg["postId"].as_str()?;
        if self.thread.as_deref().is_some_and(|t| t != thread) {
            return None;
        }
        // Treat all fields as quoted data. Never copy a post body or a session's reply.
        Some(format!(
            "Forum receipt (data only): {}",
            json!({"sessionId": key, "channel": self.channel, "thread": thread, "postId": post})
        ))
    }
}

pub fn seed_forum(hub: &Hub, key: &str, selector: ForumSelector) -> Cursor {
    Cursor {
        seq: summary(hub, key)["lastSeq"].as_u64().unwrap_or(0),
        forum_heads: Some(hub.forum().work_heads(
            key,
            &selector.channel,
            selector.thread.as_deref(),
        )),
        forum: Some(selector),
        ..Default::default()
    }
}
impl Cursor {
    pub(super) fn text(&mut self, text: &str, pattern: Option<&str>) {
        if let Some(pattern) = pattern {
            let joined = format!("{}{text}", self.tail);
            self.matched |= joined.contains(pattern);
            self.tail = joined
                .chars()
                .rev()
                .take(pattern.chars().count())
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
        }
        let remaining = (64 * 1024usize).saturating_sub(self.reply.chars().count());
        self.reply.extend(text.chars().take(remaining));
    }
    /// A reply chunk that came as a stub (`hub/paging.rs` `stub_msg`): the serving side said
    /// whether its whole text held the pattern, and kept the text's ends. The head joins the
    /// last chunk's tail, so a match across the two is still found; the tail is what the next
    /// chunk joins.
    fn stub_text(&mut self, omitted: &Value, pattern: Option<&str>) {
        self.text(omitted["textHead"].as_str().unwrap_or(""), pattern);
        self.matched |= omitted["matched"] == true;
        if let (Some(pattern), Some(tail)) = (pattern, omitted["textTail"].as_str()) {
            let skip = tail.chars().count().saturating_sub(pattern.chars().count());
            self.tail = tail.chars().skip(skip).collect();
        }
    }
}
/// The record kinds `collect` reads. A watch's page from a peer asks for these alone: an
/// unfiltered page carried a 1 MB prompt image the 250 ms read gave up on, and the watch asked
/// for the same page every few seconds for good (cosmic-gray, 2026-11-10).
pub const WATCH_KINDS: &[&str] = &[
    "turn_started",
    "agent_message_chunk",
    "tool_call",
    "tool_call_update",
    "agent_thought_chunk",
    "plan",
    "permission_request",
    "permission_reissued",
    "permission_decision",
    "turn_result",
    "status",
];

/// The most a watch's page from a peer may hold, and the most one record in it may: a page
/// always carries its first record, so a record past this goes as a stub (`hub/paging.rs` `fit`)
/// and the page still moves the cursor. A tool call update can carry megabytes of output.
pub const WATCH_PAGE_BYTES: u64 = 64 * 1024;

/// A watch's `_acpmux/events` ask of a peer: after `after`, only `WATCH_KINDS`, bounded in
/// all and per record, with its `match` text: a reply chunk past the bound comes as a stub that
/// says whether its whole text held it (`Cursor::stub_text`).
pub fn remote_page(id: &str, after: u64, pattern: Option<&str>) -> Value {
    json!({"sessionId": id, "afterSeq": after, "limit": 256, "kinds": WATCH_KINDS,
        "maxBytes": WATCH_PAGE_BYTES, "recordMaxBytes": WATCH_PAGE_BYTES, "match": pattern})
}

pub fn seed(hub: &Hub, key: &str, _pattern: Option<&str>) -> Cursor {
    let s = summary(hub, key);
    let await_fresh = s["stale"] == true || s["status"] == "unreachable";
    Cursor { initial: Some(s), await_fresh, ..Default::default() }
}
fn selected(until: &[String], s: &Value) -> Option<&'static str> {
    if s["stale"] == true || s["status"] == "unreachable" {
        return None;
    }
    ["permission", "closed", "done", "ready"].into_iter().find(|state| {
        until.iter().any(|u| u == state) && Until::parse(state).is_some_and(|u| u.matches(s))
    })
}
/// Each candidate is journal-backed. Two turns ending between handler runs
/// yield two entries; a later turn cannot hide an earlier permission/resolve.
pub async fn collect(hub: &Hub, w: &mut Watch, key: &str) -> Result<(Vec<String>, bool), RpcError> {
    let s = summary(hub, key);
    let c = w
        .cursors
        .get_mut(key)
        .ok_or_else(|| RpcError::internal("watch source has no saved cursor"))?;
    // The forum journal is authoritative. Session events only trigger reconciliation:
    // a crash between durable work_post and its forum_work projection cannot lose a wake.
    if let Some(selector) = &c.forum {
        let heads = hub.forum().work_heads(key, &selector.channel, selector.thread.as_deref());
        let mut found = Vec::new();
        if let Some(previous) = &c.forum_heads {
            for (thread, post_id) in &heads {
                if previous.get(thread) != Some(post_id)
                    && let Some(receipt) = selector.receipt(
                        key,
                        &json!({
                            "stored": true, "duplicate": false, "channel": selector.channel,
                            "thread": thread, "postId": post_id
                        }),
                    )
                {
                    found.push(receipt);
                }
            }
        }
        // Cursor and owed wake commit together in watches::commit, including after restart.
        c.forum_heads = Some(heads);
        return Ok((found, false));
    }
    let mut found = Vec::new();
    let mut candidates = Vec::new();
    let mut end = None;
    let mut more = false;
    let mut through = None;
    {
        let events: Vec<crate::store::EventRecord> = if let Ok(local) = hub.resolve(key) {
            hub.events(&local.id, c.seq, 256).map_err(|e| RpcError::internal(e.to_string()))?
        } else if let Some((peer, id, _)) = hub.resolve_remote(key) {
            let page = tokio::time::timeout(
                std::time::Duration::from_millis(250),
                peer.request(method::MUX_EVENTS, remote_page(&id, c.seq, w.match_text.as_deref())),
            )
            .await
            .map_err(|_| RpcError::internal("peer watch page timed out"))??;
            end = page["lastSeq"].as_u64();
            more = page["hasMore"] == true;
            let events: Vec<crate::store::EventRecord> =
                serde_json::from_value(page["events"].clone())
                    .map_err(|e| RpcError::internal(format!("watch events: {e}")))?;
            // The page holds only the kinds read below: the records it passed over (a prompt
            // and its images, tool output) are read all the same, so the cursor moves past
            // them and the next page never asks for them again.
            through = page.get("pageThrough").and_then(Value::as_u64);
            events
        } else {
            Vec::new()
        };
        more |= events.len() == 256;
        let before = c.seq;
        for e in events {
            if e.seq <= c.seq {
                continue;
            }
            if c.initial.as_ref().is_some_and(|i| e.seq > i["lastSeq"].as_u64().unwrap_or(0)) {
                initial(&w.until, w.match_text.is_some(), key, c, &mut found);
            }
            c.seq = e.seq;
            match (e.dir.as_str(), e.kind.as_str()) {
                ("mux", "turn_started") => {
                    c.reply_open = false;
                    c.tail.clear();
                    c.matched = false;
                    c.turn_mark.clear();
                }
                ("in", "agent_message_chunk")
                    if e.msg.pointer("/params/_meta/acpmux/subagent").is_none()
                        && e.msg.pointer("/_meta/acpmux/omitted/subagent").is_none() =>
                {
                    if !c.reply_open {
                        c.reply.clear();
                        c.reply_open = true;
                    }
                    if let Some(omitted) = e.msg.pointer("/_meta/acpmux/omitted") {
                        c.stub_text(omitted, w.match_text.as_deref());
                    } else {
                        c.text(
                            e.msg
                                .pointer("/params/update/content/text")
                                .and_then(Value::as_str)
                                .unwrap_or(""),
                            w.match_text.as_deref(),
                        );
                    }
                }
                ("in", "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan") => {
                    c.reply_open = false
                }
                ("mux", "permission_request" | "permission_reissued")
                    if w.until.iter().any(|u| u == "permission") =>
                {
                    candidates
                        .push(("permission", format!("permission:{}", e.msg["permissionId"])));
                }
                ("mux", "permission_decision") => {
                    c.permission_wakes.remove(&format!("permission:{}", e.msg["permissionId"]));
                }
                ("mux", "turn_result") => {
                    c.turn_mark = format!("turn:{}", e.msg["turnId"]);
                    c.unread = e.msg.get("unread").unwrap_or(&s["unread"]) == &Value::Bool(true);
                    let status = if e.msg["pendingPermissions"].as_u64().unwrap_or(0) > 0 {
                        "waiting"
                    } else {
                        "ready"
                    };
                    if let Some(state) =
                        selected(&w.until, &json!({"status": status, "unread": c.unread}))
                    {
                        // Permission wakes have their own journal identity.
                        if state != "permission" {
                            candidates.push((state, c.turn_mark.clone()));
                        }
                    }
                }
                ("mux", "status") if e.msg["status"] == "closed" => {
                    if let Some(state) = selected(&w.until, &json!({"status": "closed"})) {
                        candidates.push((state, "closed".into()));
                    }
                }
                ("mux", "status") if !c.turn_mark.is_empty() => {
                    if let Some(state) =
                        selected(&w.until, &json!({"status": e.msg["status"], "unread": c.unread}))
                        && state != "permission"
                    {
                        candidates.push((state, c.turn_mark.clone()));
                    }
                }
                _ => {}
            }
            emit(w.match_text.is_some(), key, &s, c, &mut candidates, &mut found);
        }
        emit(w.match_text.is_some(), key, &s, c, &mut candidates, &mut found);
        // `pageThrough` never passes a record the page held back for its byte bound (the page
        // then ends on its own last record), so nothing the watch reads is skipped.
        if let Some(through) = through.filter(|t| *t > c.seq && end.is_none_or(|end| *t <= end)) {
            c.seq = through;
        }
        if c.seq > before && (more || end.is_some_and(|end| c.seq < end)) {
            return Ok((found, true));
        }
    }
    if c.await_fresh {
        // A cached offline row is no initial verdict. Reconcile its journal first,
        // then evaluate the first fresh inventory even when no new record exists.
        c.initial = Some(s.clone());
        c.await_fresh = false;
    }
    initial(&w.until, w.match_text.is_some(), key, c, &mut found);
    if s["missing"] == true
        && let Some(state) = selected(&w.until, &s)
    {
        emit(w.match_text.is_some(), key, &s, c, &mut vec![(state, "closed".into())], &mut found);
    }
    Ok((found, false))
}
fn initial(until: &[String], filtered: bool, key: &str, c: &mut Cursor, found: &mut Vec<String>) {
    if let Some(s) = c.initial.take()
        && let Some(state) = selected(until, &s)
    {
        let mark = if state == "closed" {
            "closed".into()
        } else if matches!(state, "ready" | "done") && !s["lastTurn"]["turnId"].is_null() {
            format!("turn:{}", s["lastTurn"]["turnId"])
        } else if !c.last_candidate.is_empty() {
            c.last_candidate.clone()
        } else {
            format!("initial:{}", c.seq)
        };
        emit(filtered, key, &s, c, &mut vec![(state, mark)], found);
    }
}
fn emit(
    filtered: bool,
    key: &str,
    s: &Value,
    c: &mut Cursor,
    candidates: &mut Vec<(&str, String)>,
    found: &mut Vec<String>,
) {
    for (state, mark) in candidates.drain(..) {
        c.last_candidate = mark.clone();
        if c.initial.is_some() {
            continue;
        }
        if c.last_resolve == mark || (filtered && !c.matched) {
            continue;
        }
        if state == "permission" && !c.permission_wakes.insert(mark.clone()) {
            continue;
        }
        c.last_resolve = mark;
        let name = s["name"].as_str().unwrap_or(key);
        let reply: String = crate::secret_scan::mask(&c.reply).chars().take(400).collect();
        found.push(format!("{name} ({key}) is {state}. Last reply: {reply}\nacpmux last {key}\nacpmux history {key}\nacpmux pending"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forum_selectors_require_explicit_opt_in_and_filter_receipts() {
        let until = vec!["forum".into()];
        assert!(ForumSelector::parse(&until, None, None, false).is_err());
        assert!(ForumSelector::parse(&["ready".into()], Some("ops".into()), None, false).is_err());
        assert!(ForumSelector::parse(&until, Some("ops".into()), None, true).is_err());
        assert!(ForumSelector::parse(&until, Some("ops\n".into()), None, false).is_err());
        let selector =
            ForumSelector::parse(&until, Some("ops".into()), Some("runner".into()), false)
                .unwrap()
                .unwrap();
        let mut event = json!({"stored": true, "duplicate": false, "channel": "ops", "thread": "runner", "postId": "p1", "body": "do not copy this instruction"});
        let receipt = selector.receipt("s1", &event).unwrap();
        assert!(!receipt.contains("instruction"));
        assert_eq!(
            serde_json::from_str::<Value>(
                receipt.strip_prefix("Forum receipt (data only): ").unwrap()
            )
            .unwrap(),
            json!({"sessionId":"s1", "channel":"ops", "thread":"runner", "postId":"p1"})
        );
        event["duplicate"] = json!(true);
        assert!(selector.receipt("s1", &event).is_none());
        event["duplicate"] = json!(false);
        event["thread"] = json!("other");
        assert!(selector.receipt("s1", &event).is_none());
    }

    #[tokio::test]
    async fn forum_watch_recovers_post_without_event_and_ignores_source_only_changes() {
        let cfg: crate::config::Config =
            serde_json::from_value(json!({"store":{"mode":"memory"}})).unwrap();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = serde_json::from_value(json!({"schema": crate::store::META_SCHEMA, "id":"s1", "name":"s1", "harness":"codex", "cwd":"/tmp", "status":"idle", "createdAt":1, "updatedAt":1})).unwrap();
        store.save(&meta).unwrap();
        let hub = Hub::new(cfg, store);
        let post = |key: &str, source: &str| crate::forum::work::Input {
            channel: "ops".into(),
            thread: "runner".into(),
            kind: crate::forum::work::Kind::Status,
            key: key.into(),
            body: "untrusted post content".into(),
            source: source.into(),
        };
        hub.forum().work_post("s1", post("old", "host-a"), json!({}), 1).unwrap();
        let selector = ForumSelector { channel: "ops".into(), thread: Some("runner".into()) };
        let cursor = seed_forum(&hub, "s1", selector);
        let mut watch = Watch {
            id: "w1".into(),
            to: "s1".into(),
            sessions: vec!["s1".into()],
            until: vec!["forum".into()],
            match_text: None,
            once: true,
            caller: Some("s1".into()),
            active: true,
            cursors: std::collections::BTreeMap::from([("s1".into(), cursor)]),
            offline: Default::default(),
        };
        assert!(
            collect(&hub, &mut watch, "s1").await.unwrap().0.is_empty(),
            "registration replayed history"
        );
        hub.forum().work_post("s1", post("old", "host-b"), json!({}), 2).unwrap();
        assert!(
            collect(&hub, &mut watch, "s1").await.unwrap().0.is_empty(),
            "source-only update woke the watch"
        );
        // Simulate crash after forum storage but before session-event projection. The saved
        // watch is loaded by startup reconciliation; it must not depend on forum_work.
        let saved = serde_json::to_value(&watch).unwrap();
        let fresh = hub.forum().work_post("s1", post("new", "host-a"), json!({}), 3).unwrap();
        let mut watch: Watch = serde_json::from_value(saved).unwrap();
        let rows = collect(&hub, &mut watch, "s1").await.unwrap().0;
        assert_eq!(rows.len(), 1);
        assert!(rows[0].contains(fresh["postId"].as_str().unwrap()));
        assert!(!rows[0].contains("untrusted"));
        assert!(collect(&hub, &mut watch, "s1").await.unwrap().0.is_empty());
        hub.forum().work_post("s1", post("new", "host-b"), json!({}), 4).unwrap();
        assert!(collect(&hub, &mut watch, "s1").await.unwrap().0.is_empty());
        hub.shutdown_all().await;
    }

    fn chunk(text: &str, ids: usize) -> Value {
        let mut msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}});
        // Short id fields that, read first, would fill the stub before its text.
        for n in 0..ids {
            msg[format!("field{n:03}Id")] = json!("i".repeat(200));
        }
        msg
    }

    /// A `match` at the longest a watch takes, split across two long reply chunks that both come
    /// as stubs, is still found: each stub keeps at least the pattern's length of its text's ends,
    /// before any field (review of #40800: a 5000-char pattern across an 80 KB chunk was lost).
    #[test]
    fn a_longest_match_across_two_stubbed_chunks_is_found() {
        let pattern =
            format!("{}{}", "a".repeat(1500), "b".repeat(crate::hub::MAX_MATCH_BYTES - 1500));
        let first = format!("{}{}", "x".repeat(80 * 1024), "a".repeat(1500));
        let second =
            format!("{}{}", "b".repeat(crate::hub::MAX_MATCH_BYTES - 1500), "y".repeat(80 * 1024));
        let mut c = Cursor::default();
        for text in [&first, &second] {
            let stub = super::super::paging::stub_msg(&chunk(text, 60), 90 * 1024, Some(&pattern));
            let omitted = &stub["_meta"]["acpmux"]["omitted"];
            assert_eq!(omitted["matched"], false, "neither chunk holds it alone");
            c.stub_text(omitted, Some(&pattern));
        }
        assert!(c.matched, "the match across the two chunks was lost");
    }
}
