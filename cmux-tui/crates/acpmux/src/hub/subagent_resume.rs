//! Resume a Claude subagent that was stopped (Leo, 2026-11-12: "WHY CANT WE RESTART AGENTS THAT
//! WERE STOPPED!??!?!?!? THAT'S A STUPID ARTIFICIAL SOUNDING LIMITATION"; "THAT'S WHAT
//! ACPMUX/CMUX-NEXT NEEDS TO BOLT ONTO CLAUDE CODE STUFF").
//!
//! Claude Code refuses to resume a stopped subagent: SendMessage to it answers "was stopped and
//! won't be resumed". Its transcript is still on disk, and acpmux recorded its brief (the Agent
//! call's input) when it started. So acpmux brings it back itself:
//!
//! - A top-level subagent of a Claude Code chat that ended `cancelled` (Claude Code's
//!   `task_notification` `stopped`, a `task_updated` `killed`, a stopped turn's foreground
//!   subagent) or was lost with its harness process ([`Hub::subagents_lost`]) is resumable while
//!   acpmux knows its brief (its spawn's `prompt`) and the chat is open. Its entry in
//!   `_meta.acpmux.subagents` then carries `resumable: true` (capability `subagent-resume-v1`).
//! - `_acpmux/retry {sessionId, subagentId}` (the row's Resume, `acpmux retry --subagent`) on such
//!   a subagent sends the parent chat one prompt (provenance `{kind: "subagent_resume",
//!   subagentId, agentId?, name?}`), queued behind a running turn, never refused busy. It tells the
//!   chat's agent to start the subagent again with the Agent tool, the same `subagent_type`,
//!   `description` and `run_in_background`, and a prompt given verbatim between markers: the
//!   original brief, then a section on the earlier run, with its transcript's path and a bounded
//!   digest of its last steps read from that transcript ([`digest`]), so it continues from its last
//!   step instead of starting over. The prompt carries [`marker`]`(<old id>)`.
//! - When the new Agent call starts with that marker in its prompt, acpmux logs one entry for the
//!   new subagent with `resumes: <old id>` and one for the old, `running` again with `resumedBy:
//!   <new id>` and `resumable: false`; when the new run ends, the old entry gets its end state
//!   too, so the old row reads as the same helper running on and finishing. The report itself reaches the parent as any background
//!   subagent's does: the new run is the parent's own Agent call.
//! - What acpmux keeps in memory is a cache: a brief or an end it does not hold (a daemon restart
//!   since) is read from the chat's log, which keeps every spawn's `prompt`.

use super::auto_resume::retry_turn::RetryBy;
use super::{Hub, PromptOptions, Session, SessionStatus};
use crate::protocol::session::{RetryKind, RetryResult};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

/// The provenance kind of the prompt that asks the chat's agent to start a stopped subagent again.
pub const PROVENANCE_KIND: &str = "subagent_resume";

/// Most subagents a chat keeps a brief for; the oldest goes first.
const MAX_BRIEFS: usize = 256;

/// The most of a transcript the digest reads, from its end.
const TRANSCRIPT_TAIL: u64 = 512 << 10;

/// About the most characters the digest of a transcript holds.
const DIGEST_CHARS: usize = 6000;

/// The longest tool input and tool result one digest line quotes.
const INPUT_CHARS: usize = 200;
const RESULT_CHARS: usize = 300;

/// The words the seeded prompt carries so acpmux knows the new run for the old one.
pub(super) fn marker(old: &str) -> String {
    format!("[acpmux-resume:{old}]")
}

/// The old subagent id a prompt's [`marker`] names: the last one, since a resumed run's brief
/// already carries the marker of the run it resumed.
fn marked(prompt: &str) -> Option<&str> {
    let at = prompt.rfind("[acpmux-resume:")? + "[acpmux-resume:".len();
    let end = prompt[at..].find(']')?;
    Some(&prompt[at..at + end]).filter(|id| !id.is_empty())
}

/// What acpmux recorded of one top-level subagent: its brief, and how it stands.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Brief {
    pub name: Option<String>,
    pub task: Option<String>,
    pub kind: Option<String>,
    pub prompt: Option<String>,
    pub model: Option<String>,
    pub background: bool,
    pub agent_id: Option<String>,
    /// Its last state: `running`, `completed`, `failed`, `cancelled` or `disconnected`.
    pub state: String,
    /// The run that resumed it, once one did.
    pub resumed_by: Option<String>,
    /// The subagent it resumes, for a run a Resume started.
    pub resumes: Option<String>,
}

impl Brief {
    /// Folds one `_meta.acpmux.subagents` entry of it in.
    fn apply(&mut self, e: &Value) {
        let text = |k: &str| e.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        for (key, slot) in [
            ("name", &mut self.name),
            ("task", &mut self.task),
            ("kind", &mut self.kind),
            ("prompt", &mut self.prompt),
            ("model", &mut self.model),
            ("agentId", &mut self.agent_id),
            ("resumedBy", &mut self.resumed_by),
            ("resumes", &mut self.resumes),
        ] {
            if let Some(v) = text(key) {
                *slot = Some(v.to_owned());
            }
        }
        if e.get("background") == Some(&Value::Bool(true)) {
            self.background = true;
        }
        if let Some(state) = text("state") {
            self.state = state.to_owned();
        }
    }

    /// It ended without finishing, was not resumed, and acpmux has its brief.
    fn resumable(&self) -> bool {
        matches!(self.state.as_str(), "cancelled" | "disconnected")
            && self.resumed_by.is_none()
            && self.prompt.is_some()
    }
}

/// Each chat's top-level subagents acpmux saw, by id, oldest first; and the (chat, subagent)
/// pairs whose Resume prompt is out, from its send until its turn ends, so a second Resume (another
/// surface, another device) is refused busy instead of starting the helper twice.
#[derive(Default)]
pub(crate) struct Resumes(
    Mutex<HashMap<String, Vec<(String, Brief)>>>,
    Mutex<HashSet<(String, String)>>,
);

impl Resumes {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Vec<(String, Brief)>>> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Folds `e` into subagent `id`'s brief: the brief after it, and the one before.
    fn apply(&self, session: &str, id: &str, e: &Value) -> (Option<Brief>, Brief) {
        let mut all = self.lock();
        let subs = all.entry(session.to_owned()).or_default();
        let at = subs.iter().position(|(i, _)| i == id);
        let before = at.map(|at| subs[at].1.clone());
        let at = at.unwrap_or_else(|| {
            if subs.len() >= MAX_BRIEFS {
                subs.remove(0);
            }
            subs.push((id.to_owned(), Brief::default()));
            subs.len() - 1
        });
        subs[at].1.apply(e);
        (before, subs[at].1.clone())
    }

    fn forget(&self, session: &str) {
        self.lock().remove(session);
    }
}

/// The brief `id` names (by its id or its agent id) from the chat's log, oldest record first.
fn brief_from_log(records: &[crate::store::EventRecord], id: &str) -> Option<(String, Brief)> {
    let mut found: Option<(String, Brief)> = None;
    for e in records {
        let entries = e.msg.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array);
        for entry in entries.into_iter().flatten() {
            if !entry.get("parent").is_some_and(Value::is_null) {
                continue;
            }
            let Some(eid) = entry.get("id").and_then(Value::as_str) else { continue };
            let agent = entry.get("agentId").and_then(Value::as_str);
            let named = eid == id
                || agent == Some(id)
                || found
                    .as_ref()
                    .is_some_and(|(f, b)| f == eid && b.agent_id.as_deref() == Some(id));
            if !named && found.as_ref().is_none_or(|(f, _)| f != eid) {
                continue;
            }
            let slot = found.get_or_insert_with(|| (eid.to_owned(), Brief::default()));
            if slot.0 == eid {
                slot.1.apply(entry);
            }
        }
    }
    found
}

/// The last steps of a subagent's transcript (Claude Code's `agent-<id>.jsonl` lines), newest
/// last, at most about [`DIGEST_CHARS`]: its words, its tool calls with their input cut short,
/// and their results cut short. Lines that do not read are passed over.
pub(super) fn digest(text: &str) -> String {
    let clip = |s: &str, n: usize| -> String {
        let one: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
        if one.chars().count() > n {
            format!("{}…", one.chars().take(n).collect::<String>())
        } else {
            one
        }
    };
    let mut steps: Vec<String> = Vec::new();
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let role = v.get("type").and_then(Value::as_str).unwrap_or_default();
        let content = v.pointer("/message/content");
        let blocks: Vec<Value> = match content {
            Some(Value::Array(blocks)) => blocks.clone(),
            Some(Value::String(s)) => vec![json!({"type": "text", "text": s})],
            _ => continue,
        };
        for b in blocks {
            let kind = b.get("type").and_then(Value::as_str).unwrap_or_default();
            match (role, kind) {
                ("assistant", "text") => {
                    let t = b.get("text").and_then(Value::as_str).unwrap_or_default();
                    if !t.trim().is_empty() {
                        steps.push(format!("- said: {}", clip(t, 800)));
                    }
                }
                ("assistant", "tool_use") => {
                    let name = b.get("name").and_then(Value::as_str).unwrap_or("tool");
                    let input = b.get("input").map(Value::to_string).unwrap_or_default();
                    steps.push(format!("- called {name}: {}", clip(&input, INPUT_CHARS)));
                }
                ("user", "tool_result") => {
                    let out = match b.get("content") {
                        Some(Value::String(s)) => s.clone(),
                        Some(Value::Array(parts)) => parts
                            .iter()
                            .filter_map(|p| p.get("text").and_then(Value::as_str))
                            .collect::<Vec<_>>()
                            .join(" "),
                        _ => String::new(),
                    };
                    let err = b.get("is_error") == Some(&Value::Bool(true));
                    let label = if err { "error" } else { "result" };
                    steps.push(format!("  {label}: {}", clip(&out, RESULT_CHARS)));
                }
                _ => {}
            }
        }
    }
    let mut kept = Vec::new();
    let mut size = 0;
    for step in steps.iter().rev() {
        if size + step.len() > DIGEST_CHARS && !kept.is_empty() {
            break;
        }
        size += step.len() + 1;
        kept.push(step.as_str());
    }
    let cut = kept.len() < steps.len();
    kept.reverse();
    let mut out = kept.join("\n");
    if cut {
        out.insert_str(0, "(earlier steps left out)\n");
    }
    out
}

/// The transcript of agent `agent` of one of the chat's Claude sessions under `home`, and its last
/// [`TRANSCRIPT_TAIL`] bytes. Blocking.
fn read_transcript(home: &Path, sessions: &[String], agent: &str) -> Option<(PathBuf, String)> {
    use std::io::{Read, Seek, SeekFrom};
    if !super::subagent_transcript::plain_id(agent) {
        return None;
    }
    for session in sessions.iter().filter(|s| super::subagent_transcript::plain_id(s)) {
        let Some(own) = crate::adopt::find_claude(home, session) else { continue };
        let Some(project) = own.parent() else { continue };
        let name = format!("agent-{agent}.jsonl");
        let parts: Vec<OsString> = vec![session.into(), "subagents".into(), name.clone().into()];
        let Ok(mut file) = super::media_read::open_regular_below(project, &parts) else {
            continue;
        };
        let size = file.metadata().map(|m| m.len()).unwrap_or(0);
        if size > TRANSCRIPT_TAIL {
            file.seek(SeekFrom::Start(size - TRANSCRIPT_TAIL)).ok()?;
        }
        let mut bytes = Vec::new();
        file.take(TRANSCRIPT_TAIL).read_to_end(&mut bytes).ok()?;
        let mut text = String::from_utf8_lossy(&bytes).into_owned();
        // A cut first line does not read: drop it.
        if size > TRANSCRIPT_TAIL
            && let Some(at) = text.find('\n')
        {
            text.drain(..=at);
        }
        return Some((project.join(session).join("subagents").join(name), text));
    }
    None
}

/// The prompt the chat's agent gets: start subagent `old` again, seeded.
pub(super) fn resume_text(old: &str, brief: &Brief, transcript: Option<(&Path, &str)>) -> String {
    let description = brief.task.as_deref().or(brief.name.as_deref()).unwrap_or("Resumed helper");
    let kind = brief.kind.as_deref().unwrap_or("general-purpose");
    let mut seeded = String::new();
    seeded.push_str(brief.prompt.as_deref().unwrap_or_default());
    seeded.push_str("\n\n## Continuing an earlier run\n");
    seeded.push_str(
        "You are resuming an earlier run of this same task that was stopped before it finished. \
         Continue from its last step: do not redo work it already finished, check the state it \
         left (branches, files, pull requests) before acting, and report back as the original \
         run would have.\n",
    );
    match transcript {
        Some((path, text)) => {
            seeded.push_str(&format!("Its full transcript: {}\n", path.display()));
            let steps = digest(text);
            if !steps.is_empty() {
                seeded.push_str("Its last steps:\n");
                seeded.push_str(&steps);
                seeded.push('\n');
            }
        }
        None => {
            seeded.push_str("Its transcript could not be found; rebuild its state from disk.\n")
        }
    }
    seeded.push_str(&marker(old));
    let name = brief.name.as_deref().map(|n| format!("\"{n}\" ")).unwrap_or_default();
    let agent = brief.agent_id.as_deref().map(|a| format!(" (agent id {a})")).unwrap_or_default();
    format!(
        "Your subagent {name}{agent} was stopped before it finished. Claude Code will not \
         resume a stopped agent with SendMessage, so start it again now with the Agent tool: \
         subagent_type \"{kind}\", description \"{description}\", run_in_background {bg}, and \
         as its prompt exactly the text between the markers below, unchanged. Do nothing else \
         for it.\n\n<<<RESUME PROMPT\n{seeded}\nRESUME PROMPT>>>",
        bg = brief.background,
    )
}

fn refused(reason: &str, why: &str) -> RpcError {
    RpcError::invalid_params(format!("{reason}: {why}")).with_data(json!({"reason": reason}))
}

impl Hub {
    /// Reads one live update's top-level subagent entries (`observe_subagents`): briefs, ends,
    /// and the new run a Resume started.
    pub(super) fn observe_resumable(&self, session: &Arc<Session>, events: &[Value]) {
        for e in events.iter().filter(|e| e.get("parent").is_some_and(Value::is_null)) {
            // acpmux's own entries change nothing here.
            if e.get("resumable").is_some() || e.get("retryable").is_some() {
                continue;
            }
            let Some(id) = e.get("id").and_then(Value::as_str) else { continue };
            let (before, now) = self.subagent_resumes.apply(&session.id, id, e);
            let state = now.state.clone();
            // A new run a Resume started: linked to the run it continues.
            let spawned = before.is_none() && state == "running";
            if spawned
                && let Some(old) = now.prompt.as_deref().and_then(marked).map(str::to_owned)
                && old != id
            {
                let link = json!({"resumes": old});
                self.subagent_resumes.apply(&session.id, id, &link);
                self.subagent_resumes.apply(&session.id, &old, &json!({"resumedBy": id}));
                self.append_resume_entry(
                    session,
                    id,
                    "running",
                    json!({"resumes": old, "resumable": false}),
                );
                // The old row runs again as this run: the same helper in the parent's list.
                self.subagent_resumes.apply(&session.id, &old, &json!({"state": "running"}));
                self.append_resume_entry(
                    session,
                    &old,
                    "running",
                    json!({"resumedBy": id, "resumable": false}),
                );
                continue;
            }
            let was = before.as_ref().map(|b| b.state.as_str());
            if was == Some(state.as_str()) {
                continue;
            }
            // The run a Resume started ended: the old row ends with it.
            if state != "running"
                && let Some(old) = now.resumes.clone()
            {
                self.subagent_resumes.apply(&session.id, &old, &json!({"state": state}));
                self.append_resume_entry(
                    session,
                    &old,
                    &state,
                    json!({"resumedBy": id, "resumable": false}),
                );
            }
            if now.resumable() {
                self.append_resume_entry(session, id, &state, json!({"resumable": true}));
            }
        }
    }

    /// The harness process ended and its background subagents with it (`work_below.rs`
    /// `end_background_subagents`): each top-level one acpmux saw running ends `disconnected`,
    /// resumable when acpmux has its brief.
    pub(super) fn subagents_lost(&self, session: &Session) {
        let running: Vec<(String, Brief)> = {
            let all = self.subagent_resumes.lock();
            let subs = all.get(&session.id).into_iter().flatten();
            subs.filter(|(_, b)| b.state == "running" && b.background).cloned().collect()
        };
        for (id, _) in running {
            let (_, now) =
                self.subagent_resumes.apply(&session.id, &id, &json!({"state": "disconnected"}));
            let extra = json!({"resumable": now.resumable(), "reason": "harness_exit"});
            self.append_resume_entry(session, &id, "disconnected", extra);
        }
    }

    /// A chat closed: nothing of it resumes.
    pub(super) fn forget_resumable(&self, session: &Session) {
        self.subagent_resumes.forget(&session.id);
    }

    /// Logs one acpmux entry for subagent `id`: `{id, parent: null, state, ...extra}`.
    fn append_resume_entry(&self, session: &Session, id: &str, state: &str, extra: Value) {
        let mut entry = json!({"id": id, "parent": null, "state": state});
        if let (Some(entry), Some(extra)) = (entry.as_object_mut(), extra.as_object()) {
            entry.extend(extra.clone());
        }
        let update = json!({"jsonrpc": "2.0", "method": crate::rpc::method::SESSION_UPDATE,
            "params": {"sessionId": session.id,
                "update": {"sessionUpdate": "subagent_state_update", "subagentSessionId": id,
                    "state": state},
                "_meta": {"acpmux": {"subagents": [entry]}}}});
        self.append(session, "in", "subagent_state_update", update);
    }

    /// The stopped subagent `subagent` names (its id or agent id), with its brief: from memory,
    /// else from the chat's log. None when it is not one acpmux can resume.
    pub(super) async fn resumable_subagent(
        self: &Arc<Self>,
        session: &Arc<Session>,
        subagent: &str,
    ) -> Option<(String, Brief)> {
        let cached = {
            let all = self.subagent_resumes.lock();
            all.get(&session.id).and_then(|subs| {
                subs.iter()
                    .find(|(id, b)| id == subagent || b.agent_id.as_deref() == Some(subagent))
                    .cloned()
            })
        };
        let found = match cached {
            Some(found) if found.1.prompt.is_some() => Some(found),
            _ => {
                let (hub, sid, named) = (self.clone(), session.id.clone(), subagent.to_owned());
                tokio::task::spawn_blocking(move || {
                    let mut records = Vec::new();
                    let kinds = ["subagent_spawned", "subagent_state_update", "subagent_progress"];
                    let _ = hub.store.scan_kinds(&sid, &kinds, &mut |e| {
                        records.push(e);
                        true
                    });
                    brief_from_log(&records, &named)
                })
                .await
                .ok()
                .flatten()
            }
        };
        found.filter(|(_, b)| b.resumable())
    }

    /// Resumes stopped subagent `id` (the module doc): sends the parent its seeded prompt, queued
    /// behind a running turn, and answers once it is accepted.
    pub(super) async fn resume_subagent(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: String,
        brief: Brief,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        if session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed {
            return Err(refused("retry.nothing_failed", "the chat closed"));
        }
        self.retry_allowed(session, &by).await?;
        let key = (session.id.clone(), id.clone());
        if !self
            .subagent_resumes
            .1
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(key.clone())
        {
            return Err(refused("retry.busy", "a Resume of this subagent is already out"));
        }
        let result = self.send_resume(session, id, brief, by, key.clone()).await;
        if result.is_err() {
            self.resume_done(&key);
        }
        result
    }

    /// The Resume of `key` is over: its prompt was refused, or its turn ended.
    fn resume_done(&self, key: &(String, String)) {
        self.subagent_resumes
            .1
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(key);
    }

    async fn send_resume(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: String,
        brief: Brief,
        by: RetryBy,
        key: (String, String),
    ) -> Result<Value, RpcError> {
        let transcript = match brief.agent_id.clone() {
            Some(agent) => {
                let meta = session.meta();
                let sessions: Vec<String> = meta.claude_session_ids().map(str::to_owned).collect();
                match super::subagent_transcript::claude_home(self, &meta).await {
                    Some(home) => tokio::task::spawn_blocking(move || {
                        read_transcript(&home, &sessions, &agent)
                    })
                    .await
                    .ok()
                    .flatten(),
                    None => None,
                }
            }
            None => None,
        };
        let text =
            resume_text(&id, &brief, transcript.as_ref().map(|(p, t)| (p.as_path(), t.as_str())));
        let mut provenance = json!({"kind": PROVENANCE_KIND, "subagentId": id});
        for (key, value) in [("agentId", &brief.agent_id), ("name", &brief.name)] {
            if let (Some(p), Some(v)) = (provenance.as_object_mut(), value) {
                p.insert(key.to_owned(), json!(v));
            }
        }
        if let (Some(p), Some(from)) = (provenance.as_object_mut(), by.from) {
            p.insert("from".to_owned(), json!(from));
        }
        let tool = id.rsplit('/').next().unwrap_or(&id).to_owned();
        let prompt_id = format!("subagent-resume-{tool}-{}", crate::store::now_ms());
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |v| {
            let _ = tx.send(v);
        });
        let opts = PromptOptions {
            control: by.control,
            trust_gate: by.trust_gate,
            full_access_device: by.full_access_device,
            provenance: Some(provenance),
            prompt_id: Some(prompt_id.clone()),
            on_accepted: Some(on_accepted),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        let (hub, s) = (self.clone(), session.clone());
        // The turn runs on: only acceptance is awaited.
        let task = self.scope.spawn_named("subagent-resume", async move {
            let result = hub.prompt_with(&s, blocks, "acpmux", false, opts).await;
            hub.resume_done(&key);
            result
        });
        let accepted = match rx.await {
            Ok(v) => v,
            Err(_) => match task.await {
                Ok(Ok(v)) => v,
                Ok(Err(e)) => return Err(e),
                Err(e) => return Err(RpcError::internal(e.to_string())),
            },
        };
        let turn_id = accepted.get("turnId").and_then(Value::as_str).map(str::to_owned);
        let result = RetryResult { prompt_id, turn_id, kind: RetryKind::Subagent };
        Ok(serde_json::to_value(result).unwrap_or(Value::Null))
    }
}

#[cfg(test)]
#[path = "subagent_resume_tests.rs"]
mod tests;
