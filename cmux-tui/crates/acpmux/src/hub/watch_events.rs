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
}
impl Cursor {
    fn text(&mut self, text: &str, pattern: Option<&str>) {
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
    let mut found = Vec::new();
    let mut candidates = Vec::new();
    let mut end = None;
    let mut more = false;
    {
        let events: Vec<crate::store::EventRecord> = if let Ok(local) = hub.resolve(key) {
            hub.events(&local.id, c.seq, 256).map_err(|e| RpcError::internal(e.to_string()))?
        } else if let Some((peer, id, _)) = hub.resolve_remote(key) {
            let page = tokio::time::timeout(
                std::time::Duration::from_millis(250),
                peer.request(
                    method::MUX_EVENTS,
                    json!({"sessionId": id, "afterSeq": c.seq, "limit": 256}),
                ),
            )
            .await
            .map_err(|_| RpcError::internal("peer watch page timed out"))??;
            end = page["lastSeq"].as_u64();
            more = page["hasMore"] == true;
            serde_json::from_value(page["events"].clone())
                .map_err(|e| RpcError::internal(format!("watch events: {e}")))?
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
                    if e.msg.pointer("/params/_meta/acpmux/subagent").is_none() =>
                {
                    if !c.reply_open {
                        c.reply.clear();
                        c.reply_open = true;
                    }
                    c.text(
                        e.msg
                            .pointer("/params/update/content/text")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                        w.match_text.as_deref(),
                    );
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
