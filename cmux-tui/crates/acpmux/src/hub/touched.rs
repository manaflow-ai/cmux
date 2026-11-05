//! Part of `Hub`; see `hub/mod.rs`. Who else is working on these files (`touched_files.rs`):
//! the index each session's tool calls build, the notice a session gets when another live
//! session edits a file it edited, and the `_acpmux/who_else` answer.
//!
//! The index: each `tool_call` or `tool_call_update` that names files adds them to the
//! session's `touched_files` ([`absorb`]), keyed by repository and path there. History a load
//! replays adds nothing: it was indexed when it ran.
//!
//! The notice: when a session edits a file that another live session on this machine (not one
//! of its own tree) edited in the last [`NOTICE_WINDOW_MS`], acpmux steers one notice into the
//! editor's running turn naming the other session, and one into the other session's turn when
//! it runs too ([`Hub::notice_overlaps`]). Once per pair of sessions: a session hears about
//! another once, whatever file they share next. A session that is idle hears nothing now; it
//! hears when it next edits one of the files. A session whose agent does not steer gets none.
//!
//! The answer: [`Hub::who_else`] ranks this machine's sessions against a query and, unless the
//! query came from a peer, asks each connected peer the same query (already keyed, so the peer
//! reads no path of the caller's) and merges their rows with `host` set. Only the local socket
//! may name raw files or a folder: a Web, app or peer caller names a session, a topic or keyed
//! files (`remote_guard.rs`: a remote connection never reads a path of its choice).

use super::*;
use crate::path_canon::canonical_path;
use crate::touched_files::{self as tf, Candidate, Query, TouchedFile};
use std::time::Duration;

/// How recent another session's edit must be for the notice: six hours.
pub const NOTICE_WINDOW_MS: u64 = 6 * 60 * 60 * 1000;
/// Who the notice is from, as the transcript shows it.
const NOTICE_SENDER: &str = "acpmux who-else";
/// The notice's provenance kind: hub-set, never a client's, as the turn cap's is. It carries a
/// tool notice's fields (`notice`, `fromName`), so it reads as one, but it is acpmux's own word,
/// not another agent's message, so it steers into the person's turn as the turn cap's notice does
/// (an agent's message waits for that turn to end, `turns.rs` `persons_held`).
pub const NOTICE_KIND: &str = "who_else";
/// How long a peer may take to answer before the answer goes on without it.
const PEER_DEADLINE: Duration = Duration::from_secs(5);
/// The most rows one answer carries.
const MAX_ROWS: usize = 50;

/// Notes the files a `tool_call` or `tool_call_update` names into `m.touched_files`, and queues
/// each file it edits for [`Hub::notice_overlaps`]. Nothing for replayed history.
pub(super) fn absorb(session: &Session, update: &Value, m: &mut SessionMeta, replayed: bool) {
    if replayed {
        return;
    }
    let (paths, edited) = tf::paths_of(update);
    if paths.is_empty() {
        return;
    }
    let edited = edited.unwrap_or(false);
    let at = crate::store::now_ms();
    let mut queued = vec![];
    for path in paths {
        let Some(abs) = canonical_path(&path, Some(&m.cwd)) else { continue };
        let (repo, path) = tf::key_of(&abs);
        if edited {
            queued.push((repo.clone(), path.clone()));
        }
        tf::merge(&mut m.touched_files, TouchedFile { repo, path, edited, at, edited_at: 0 });
    }
    if !queued.is_empty() {
        session.touch_queue.lock().unwrap_or_else(|e| e.into_inner()).extend(queued);
    }
}

/// The notice's words for a session that shares files with `other` (an answer row).
fn notice_body(other: &Value) -> String {
    let name = other.get("name").and_then(Value::as_str).unwrap_or("another session");
    format!(
        "{}\nAnother live session edits the same files. Check with it before changing them: \
         `acpmux send {name} -` (or the acpmux `send` tool). `acpmux who-else` lists everyone.",
        tf::row_line(other)
    )
}

impl Hub {
    /// Every session on this machine as a who-else candidate, with its meta read once.
    fn candidates(&self) -> Vec<(Arc<Session>, Candidate)> {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        sessions
            .into_iter()
            .map(|s| {
                let m = s.meta();
                let c = self.candidate(&m);
                (s, c)
            })
            .collect()
    }

    fn candidate(&self, m: &SessionMeta) -> Candidate {
        let repo = tf::repo_of(&m.cwd);
        Candidate {
            session_id: m.id.clone(),
            root: self.lineage_of(m).map_or_else(|| m.id.clone(), |l| l.root),
            name: m.name.clone(),
            title: m.title.clone(),
            last_prompt: m.last_prompt.clone(),
            harness: m.harness.clone(),
            status: m.status.to_string(),
            cwd: m.cwd.to_string_lossy().into_owned(),
            repo: repo.as_ref().map(|r| r.id.clone()),
            worktree: repo.as_ref().map(|r| r.root.to_string_lossy().into_owned()),
            default_branch: repo.and_then(|r| r.default_branch),
            branch: self.git_branch_now(m),
            pull_requests: m.pull_requests.clone(),
            updated_at: m.updated_at,
            files: m.touched_files.clone(),
        }
    }

    /// Steers the notice into `session` and each other live session that edited a file it just
    /// edited ([`absorb`] queued them), once per pair. Called after each update it applies.
    pub(super) fn notice_overlaps(self: &Arc<Self>, session: &Arc<Session>) {
        let edited: Vec<(String, String)> =
            std::mem::take(&mut *session.touch_queue.lock().unwrap_or_else(|e| e.into_inner()));
        if edited.is_empty() {
            return;
        }
        let now = crate::store::now_ms();
        let since = now.saturating_sub(NOTICE_WINDOW_MS);
        // Only the sessions that edited one of these files lately are read whole: an edit costs
        // a look at each session's index under its lock, not a copy of every session's meta.
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let all: Vec<(Arc<Session>, Candidate)> = sessions
            .into_iter()
            .filter(|s| !Arc::ptr_eq(s, session))
            .filter_map(|s| {
                let m = {
                    let m = s.meta.lock().unwrap_or_else(|e| e.into_inner());
                    let shares = m.touched_files.iter().any(|f| {
                        f.edited_since(since)
                            && edited.iter().any(|(r, p)| *r == f.repo && *p == f.path)
                    });
                    shares.then(|| m.clone())?
                };
                let c = self.candidate(&m);
                Some((s, c))
            })
            .collect();
        if all.is_empty() {
            return;
        }
        let me = self.candidate(&session.meta());
        let query = Query {
            files: edited
                .iter()
                .map(|(repo, path)| TouchedFile {
                    repo: repo.clone(),
                    path: path.clone(),
                    edited: true,
                    at: 0,
                    edited_at: 0,
                })
                .collect(),
            since,
            exclude_root: Some(me.root.clone()),
            ..Query::default()
        };
        for (other, c) in &all {
            if !matches!(c.status.as_str(), "running" | "waiting" | "ready" | "idle") {
                continue;
            }
            let Some(row) = tf::row(&query, c, now) else { continue };
            // Only an edit on their side: a session that only read the file is not editing it.
            if row.get("editedInCommon").and_then(Value::as_u64).unwrap_or(0) == 0 {
                continue;
            }
            self.overlap_notice(session, &other.id, &row);
            // The other side hears about this session: its row against the other's files.
            let back = Query {
                files: c.files.iter().filter(|f| f.edited_since(query.since)).cloned().collect(),
                since: query.since,
                exclude_root: Some(c.root.clone()),
                ..Query::default()
            };
            if let Some(mine) = tf::row(&back, &me, now) {
                self.overlap_notice(other, &session.id, &mine);
            }
        }
    }

    /// Steers the notice about session `other_id` (`row`) into `to`'s running turn, once for
    /// that pair. Nothing when `to` runs no turn or its agent does not steer.
    fn overlap_notice(self: &Arc<Self>, to: &Arc<Session>, other_id: &str, row: &Value) {
        if !to.steering.load(Ordering::SeqCst) {
            return;
        }
        let Some(turn) = to.turn() else { return };
        if !to.overlaps_told.lock().unwrap_or_else(|e| e.into_inner()).insert(other_id.to_owned()) {
            return;
        }
        let name = row.get("name").and_then(Value::as_str).unwrap_or("another session");
        let first = row
            .pointer("/files/0/path")
            .and_then(Value::as_str)
            .map(|p| p.rsplit('/').next().unwrap_or(p).to_owned())
            .unwrap_or_default();
        let mut title = format!("{name} also edits {first}");
        if title.chars().count() > crate::prompt_provenance::MAX_NOTICE_TITLE_CHARS {
            title = title.chars().take(crate::prompt_provenance::MAX_NOTICE_TITLE_CHARS).collect();
        }
        let links: Vec<Value> = row
            .get("pullRequests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|u| u.starts_with("https://"))
            .take(crate::prompt_provenance::MAX_NOTICE_LINKS)
            .map(|u| json!({"url": u}))
            .collect();
        let mut notice = json!({"sender": NOTICE_SENDER, "severity": "info", "title": title});
        if !links.is_empty() {
            set(&mut notice, "links", Value::Array(links));
        }
        let text = crate::prompt_provenance::notice_text(&notice, &notice_body(row));
        let mut provenance = crate::prompt_provenance::notice(&notice, &to.id);
        set(&mut provenance, "kind", json!(NOTICE_KIND));
        set(&mut provenance, "whoElse", row.clone());
        let opts = notice_options(&turn.turn_id, other_id, provenance);
        let blocks = vec![json!({"type": "text", "text": text})];
        let (hub, to, other) = (self.clone(), to.clone(), other_id.to_owned());
        tokio::spawn(async move {
            if let Err(e) = hub.prompt_with(&to, blocks, "acpmux", true, opts).await {
                // Not heard: the next shared edit may try again.
                to.overlaps_told.lock().unwrap_or_else(|e| e.into_inner()).remove(&other);
                tracing::info!(session = %to.id, "who-else notice not steered: {}", e.message);
            }
        });
    }

    /// The query `params` ask (`_acpmux/who_else`). `local`: the caller is the local socket, the
    /// only one whose raw `files` and `cwd` are read from disk.
    fn who_else_query(&self, params: &Value, local: bool) -> Result<Query, RpcError> {
        if let Some(q) = params.get("query").filter(|q| q.is_object()) {
            return serde_json::from_value(q.clone())
                .map_err(|e| RpcError::invalid_params(format!("query: {e}")));
        }
        let now = crate::store::now_ms();
        let since_ms =
            params.get("sinceMs").and_then(Value::as_u64).unwrap_or(tf::DEFAULT_SINCE_MS);
        let mut q = Query {
            topic: params.get("topic").and_then(Value::as_str).map(str::to_owned),
            since: now.saturating_sub(since_ms),
            ..Query::default()
        };
        let asker = match params.get("sessionId").and_then(Value::as_str) {
            Some(id) => Some(self.resolve_here(id)?),
            None => None,
        };
        let asker = asker.map(|s| self.candidate(&s.meta()));
        let raw = |k: &str| params.get(k).filter(|_| local);
        let cwd: Option<PathBuf> = raw("cwd")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .or_else(|| asker.as_ref().map(|a| PathBuf::from(&a.cwd)));
        for f in
            raw("files").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str)
        {
            if let Some(abs) = canonical_path(f, cwd.as_deref()) {
                let (repo, path) = tf::key_of(&abs);
                q.files.push(TouchedFile { repo, path, edited: false, at: 0, edited_at: 0 });
            }
        }
        // Keyed files any caller may name: `[{repo, path}]`.
        if let Some(keys) = params.get("keys").filter(|k| k.is_array()) {
            let keys: Vec<TouchedFile> = serde_json::from_value(keys.clone())
                .map_err(|e| RpcError::invalid_params(format!("keys: {e}")))?;
            q.files.extend(keys);
        }
        let named = !q.files.is_empty() || q.topic.is_some();
        if let Some(a) = &asker {
            q.exclude_root = Some(a.root.clone());
            if !named {
                // Nothing named: what the asker itself edited (else read) lately.
                let recent: Vec<&TouchedFile> =
                    a.files.iter().filter(|f| f.at >= q.since).collect();
                let since = q.since;
                let edit = |f: &&TouchedFile| f.edited_since(since);
                let edited = recent.iter().any(edit);
                q.files = recent.into_iter().filter(|f| edit(f) || !edited).cloned().collect();
            }
        }
        if !named {
            match (&asker, raw("cwd").is_some()) {
                (Some(a), false) => {
                    (q.repo, q.worktree, q.branch) =
                        (a.repo.clone(), a.worktree.clone(), a.branch.clone());
                }
                _ => {
                    if let Some(repo) = cwd.as_deref().and_then(tf::repo_of) {
                        q.branch = crate::git_state::GitState::read(&repo.root).branch;
                        q.worktree = Some(repo.root.to_string_lossy().into_owned());
                        q.repo = Some(repo.id);
                    }
                }
            }
        }
        if q.files.is_empty() && q.topic.is_none() && q.worktree.is_none() && q.repo.is_none() {
            return Err(RpcError::invalid_params(
                "name files, a topic, a folder or a session: nothing to look for".to_owned(),
            ));
        }
        Ok(q)
    }

    /// `_acpmux/who_else`: the sessions here, and on each connected peer unless `peers` is false
    /// or the caller is a peer, that work on what the query names, best first.
    pub async fn who_else(
        &self,
        params: &Value,
        local: bool,
        from_peer: bool,
    ) -> Result<Value, RpcError> {
        let q = self.who_else_query(params, local)?;
        let now = crate::store::now_ms();
        let mut rows: Vec<Value> =
            self.candidates().iter().filter_map(|(_, c)| tf::row(&q, c, now)).collect();
        let mut unreached: Vec<Value> = vec![];
        let ask_peers = !from_peer && params.get("peers").and_then(Value::as_bool) != Some(false);
        if ask_peers {
            let peers: Vec<Arc<crate::peer::Peer>> =
                self.peers.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
            let forward = json!({"query": q, "peers": false});
            let asks = peers.into_iter().map(|p| {
                let forward = forward.clone();
                async move {
                    let answer = tokio::time::timeout(
                        PEER_DEADLINE,
                        p.request(crate::rpc::method::MUX_WHO_ELSE, forward),
                    )
                    .await;
                    (p.name.clone(), answer)
                }
            });
            for (name, answer) in futures::future::join_all(asks).await {
                match answer {
                    Ok(Ok(v)) => {
                        for mut r in
                            v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default()
                        {
                            let session =
                                r.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
                            set(&mut r, "host", json!(name));
                            set(&mut r, "ref", json!(format!("{name}/{session}")));
                            rows.push(r);
                        }
                    }
                    Ok(Err(e)) => unreached.push(json!({"host": name, "error": e.message})),
                    Err(_) => unreached.push(json!({"host": name, "error": "no answer in 5 s"})),
                }
            }
        }
        for r in rows.iter_mut().filter(|r| r.get("ref").is_none()) {
            let name = r.get("name").cloned().unwrap_or(Value::Null);
            set(r, "ref", name);
        }
        tf::rank(&mut rows);
        let more = rows.len().saturating_sub(MAX_ROWS);
        rows.truncate(MAX_ROWS);
        let text: Vec<String> = rows.iter().map(tf::row_line).collect();
        let shown: Vec<String> = q.files.iter().take(20).map(|f| f.path.clone()).collect();
        Ok(json!({
            "schema": "acpmux.who-else.v1",
            "query": {"files": shown, "fileCount": q.files.len(), "topic": q.topic, "branch": q.branch, "worktree": q.worktree},
            "sessions": rows,
            "more": more,
            "unreached": unreached,
            "lines": text,
        }))
    }
}

/// Sets `key` of the object `v` (nothing when `v` is not an object).
/// The notice's prompt options: steered into turn `turn_id` or nowhere. A turn that ended before
/// the steer ran refuses it (`turns.rs`), so the notice never lands in the next turn; that turn
/// hears it at its next shared edit.
fn notice_options(turn_id: &str, other_id: &str, provenance: Value) -> PromptOptions {
    PromptOptions {
        prompt_id: Some(format!("who-else-{turn_id}-{other_id}")),
        resend: true,
        steer_only: true,
        interrupt_turn: Some(turn_id.to_owned()),
        provenance: Some(provenance),
        ..PromptOptions::default()
    }
}

fn set(v: &mut Value, key: &str, value: Value) {
    if let Some(o) = v.as_object_mut() {
        o.insert(key.to_owned(), value);
    }
}

#[cfg(test)]
#[path = "touched_tests.rs"]
mod tests;
