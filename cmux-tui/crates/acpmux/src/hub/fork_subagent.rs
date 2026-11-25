//! Part of `Hub`; see `hub/mod.rs`. A subagent forked into a chat of its own
//! (`acp.session.fork` with `subagentId`, capability [`CAPABILITY`]), and a fork that starts on a
//! model or in a permission mode the caller picks ([`ForkStart`]).
//!
//! Leo, 2026-11-22: "so for subagents, actually, are their permissions/model locked right then
//! and there? does it make sense to be able to reveal the fork or whatever switching model
//! behaviour for it?" A running subagent's model and permissions cannot be changed: Codex copies
//! them into the child's config at spawn (codex-rs `multi_agents_common.rs`), and Claude's
//! built-in agents bubble to the parent's live mode. So the honest switch is a fork of the
//! subagent's own context into a chat the person controls.
//!
//! The fork's conversation is the subagent's own, never the chat's:
//!
//! - Claude Code: its sidechain transcript (`<project>/<session>/subagents/agent-<id>.jsonl`
//!   under one of the chat's own Claude sessions, which is what makes it this chat's), copied
//!   beside the chat's transcript as a main conversation of its own (`isSidechain` false, its
//!   `sessionId` the copy's) that the fork's Claude resumes.
//! - Codex: the child's thread (its id is the subagent's id), a rollout whose `session_meta`
//!   names one of the chat's threads as its parent (directly or through other children), copied
//!   under a thread id of the fork's own as a top-level thread.
//! - Any other harness keeps its subagents inside its own process: refused, with the reason.
//!
//! A running subagent forks through its last settled step: the copy ends before a tool call
//! that has no result yet, so the fork's agent never resumes a call it cannot answer. The fork's
//! rows are read from the copy (`adopt_replay`), so its chat shows the subagent's turns, once,
//! and nothing of the chat's.

use super::*;
use std::io::{BufRead, BufReader, Read, Write};

/// Listed by `acpmux capabilities`: `acp.session.fork` takes `subagentId` and `mode`, and
/// `model` without `harness`.
pub const CAPABILITY: &str = "acp.session.fork.subagent.v1";

/// Listed in `initialize`'s `_meta.acpmux.features`: a fork of a subagent, or one that starts
/// in a mode or on a model of the chat's own harness, goes only to a peer that lists it
/// (`peer_forward.rs`): an older build ignores those fields and would fork the whole chat.
pub const FEATURE: &str = "sessionForkSubagent";

/// The largest subagent transcript a fork copies.
const MAX_TRANSCRIPT: u64 = 64 << 20;

/// How many parent links a Codex child may sit below the chat's own thread.
const MAX_CODEX_DEPTH: usize = 8;

/// How many sidechain files a fork reads the first prompt of, to find a running Claude
/// subagent acpmux knows no agent id for yet.
const MAX_SIDECHAINS: usize = 512;

/// What a fork starts as, beyond the chat it comes from: a subagent's own conversation, a model
/// of the chat's harness, a permission mode. Default: an ordinary fork.
#[derive(Debug, Clone, Default)]
pub struct ForkStart {
    /// The subagent to fork (`subagentId`): its `_meta.acpmux.subagents` id or its agent id.
    pub subagent: Option<String>,
    /// The model to start on, of the chat's own harness (a switch's model is `Retarget`'s).
    pub model: Option<String>,
    /// The permission mode to start in, one the harness lists.
    pub mode: Option<String>,
    /// The person asked on this Mac: a mode that does not ask widens a narrower policy first,
    /// as their own mode pick does (`policy_mode.rs`).
    pub person: bool,
}

impl ForkStart {
    /// `session/fork`'s `_meta.acpmux.subagentId`, `mode` and (without `harness`) `model`.
    pub fn from_params(params: &Value, person: bool) -> Result<Self, RpcError> {
        let text = |key: &str, max: usize| -> Result<Option<String>, RpcError> {
            match params.pointer(&format!("/_meta/acpmux/{key}")) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if !s.trim().is_empty() && s.len() <= max => {
                    Ok(Some(s.clone()))
                }
                Some(_) => Err(RpcError::invalid_params(format!(
                    "_meta.acpmux.{key} must be a nonempty string of at most {max} bytes"
                ))),
            }
        };
        let subagent = text("subagentId", 256)?;
        if let Some(id) = &subagent
            && !id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:".contains(&b))
        {
            return Err(super::fork_before::refused(
                "fork.subagent_unknown",
                "subagentId names no subagent of this chat",
            ));
        }
        let mode = text("mode", 128)?;
        let harness = params.pointer("/_meta/acpmux/harness").is_some_and(|v| !v.is_null());
        // With a harness the model is the switch's (`fork_through::retarget` checked it).
        let model = if harness { None } else { text("model", 256)? };
        Ok(Self { subagent, model, mode, person })
    }

    /// An ordinary fork: nothing to start differently.
    pub fn is_plain(&self) -> bool {
        self.subagent.is_none() && self.model.is_none() && self.mode.is_none()
    }
}

/// What the chat's log says of one subagent: the fields its entries carry.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct Entry {
    pub id: String,
    pub agent_id: Option<String>,
    pub name: Option<String>,
    pub prompt: Option<String>,
    pub state: Option<String>,
}

/// The subagent `named` (its id or its agent id) from the chat's `_meta.acpmux.subagents`
/// entries, oldest record first, at any depth.
pub(super) fn entry_from_records(records: &[EventRecord], named: &str) -> Option<Entry> {
    let entries = || {
        records
            .iter()
            .filter_map(|e| {
                e.msg.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array)
            })
            .flatten()
    };
    let text = |e: &Value, k: &str| {
        e.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_owned)
    };
    let id = entries().find_map(|e| {
        let id = text(e, "id")?;
        (id == named || text(e, "agentId").as_deref() == Some(named)).then_some(id)
    })?;
    let mut found = Entry { id: id.clone(), ..Entry::default() };
    for e in entries().filter(|e| text(e, "id").as_deref() == Some(id.as_str())) {
        for (key, slot) in [
            ("agentId", &mut found.agent_id),
            ("name", &mut found.name),
            ("prompt", &mut found.prompt),
            ("state", &mut found.state),
        ] {
            if let Some(v) = text(e, key) {
                *slot = Some(v);
            }
        }
        if found.name.is_none() {
            found.name = text(e, "task");
        }
    }
    Some(found)
}

/// A subagent's conversation, copied for its fork.
pub(super) struct SubagentCopy {
    /// The id the chat's log names it by, else the one asked for.
    pub subagent_id: String,
    /// Claude's agent id (the sidechain's), or the Codex child's thread id.
    pub agent_id: String,
    pub name: Option<String>,
    /// The copy's session (Claude) or thread (Codex) id, which the fork's agent resumes.
    pub copy: String,
    /// Where the copy is, removed again if the fork is not made.
    pub file: PathBuf,
    /// The copy's turns, the fork's rows.
    pub turns: Vec<crate::adopt_replay::PastTurn>,
    /// Steps of a running subagent the copy left out (a tool call with no result yet).
    pub cut: bool,
}

fn unknown(named: &str) -> RpcError {
    super::fork_before::refused(
        "fork.subagent_unknown",
        &format!("no subagent {named} in this chat, or its transcript is not stored"),
    )
}

fn unreadable(why: impl std::fmt::Display) -> RpcError {
    super::fork_before::refused("fork.subagent_unreadable", &why.to_string())
}

/// Reads at most [`MAX_TRANSCRIPT`] of `file`, or refuses a bigger one.
fn read_bounded(mut file: std::fs::File) -> Result<String, RpcError> {
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if size > MAX_TRANSCRIPT {
        return Err(super::fork_before::refused(
            "fork.subagent_too_large",
            "the subagent's transcript is larger than 64 MiB",
        ));
    }
    let mut text = String::new();
    file.read_to_string(&mut text).map_err(unreadable)?;
    Ok(text)
}

/// The tool calls a record opens and the ones it settles: Claude's `tool_use` and
/// `tool_result` blocks, Codex's calls and their outputs by `call_id`.
fn note_calls(record: &Value, open: &mut Vec<String>) {
    let id = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    if let Some(Value::Array(blocks)) = record.pointer("/message/content") {
        for b in blocks {
            match b.get("type").and_then(Value::as_str) {
                Some("tool_use") => open.extend(id(b, "id")),
                Some("tool_result") => {
                    let done = id(b, "tool_use_id");
                    open.retain(|o| Some(o) != done.as_ref());
                }
                _ => {}
            }
        }
    }
    if record.get("type").and_then(Value::as_str) == Some("response_item")
        && let Some(payload) = record.get("payload")
    {
        match payload.get("type").and_then(Value::as_str) {
            Some("function_call" | "custom_tool_call" | "local_shell_call") => {
                open.extend(id(payload, "call_id"));
            }
            Some("function_call_output" | "custom_tool_call_output") => {
                let done = id(payload, "call_id");
                open.retain(|o| Some(o) != done.as_ref());
            }
            _ => {}
        }
    }
}

/// A Claude subagent's sidechain transcript as a main conversation of session `new_id`: each
/// line under that id, no longer a sidechain or any agent's, through its last line with no tool
/// call left open. Returns the copy and whether lines after that were left out.
pub(super) fn claude_sidechain_copy(text: &str, new_id: &str) -> anyhow::Result<(String, bool)> {
    let mut lines = Vec::new();
    let mut open = Vec::new();
    let (mut settled, mut prompts_settled, mut prompts) = (0, 0, 0usize);
    for line in text.lines() {
        let Ok(mut record) = serde_json::from_str::<Value>(line) else { continue };
        let Some(object) = record.as_object_mut() else { continue };
        if object.get("sessionId").is_some_and(Value::is_string) {
            object.insert("sessionId".into(), Value::String(new_id.to_owned()));
        }
        if object.contains_key("isSidechain") {
            object.insert("isSidechain".into(), Value::Bool(false));
        }
        object.remove("agentId");
        let is_prompt = object.get("type").and_then(Value::as_str) == Some("user")
            && match object.get("message").and_then(|m| m.get("content")) {
                Some(Value::String(_)) => true,
                Some(Value::Array(blocks)) => !blocks
                    .iter()
                    .any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result")),
                _ => false,
            };
        prompts += usize::from(is_prompt);
        note_calls(&record, &mut open);
        lines.push(serde_json::to_string(&record)?);
        if open.is_empty() {
            settled = lines.len();
            prompts_settled = prompts;
        }
    }
    anyhow::ensure!(prompts_settled > 0, "the subagent has no settled step to fork yet");
    let cut = settled < lines.len();
    lines.truncate(settled);
    Ok((lines.join("\n") + "\n", cut))
}

/// The thread a Codex rollout's `session_meta` payload names as its parent: a spawned child's
/// (`parent_thread_id`, or its `source.subagent.thread_spawn`).
pub(super) fn codex_parent(payload: &Value) -> Option<&str> {
    payload.get("parent_thread_id").and_then(Value::as_str).or_else(|| {
        payload.pointer("/source/subagent/thread_spawn/parent_thread_id").and_then(Value::as_str)
    })
}

/// A Codex child's rollout as top-level thread `new_id`: its `session_meta` names the new
/// thread, forked from the child, with no parent and no agent role, through its last record with
/// no call left open. Returns the copy and whether records after that were left out.
pub(super) fn codex_child_copy(
    text: &str,
    child: &str,
    new_id: &str,
) -> anyhow::Result<(String, bool)> {
    let mut lines = Vec::new();
    let mut open = Vec::new();
    let (mut settled, mut met, mut users, mut users_settled) = (0, false, 0usize, 0usize);
    for line in text.lines() {
        let Ok(mut record) = serde_json::from_str::<Value>(line) else { continue };
        if record.get("type").and_then(Value::as_str) == Some("session_meta")
            && let Some(payload) = record.get_mut("payload").and_then(Value::as_object_mut)
            && payload.get("id").and_then(Value::as_str) == Some(child)
        {
            // Its history before its own records is kept in another rollout: a copy of this
            // one would resume without it.
            anyhow::ensure!(
                payload.get("history_base").is_none_or(Value::is_null),
                "the subagent's history is kept in its parent's rollout"
            );
            payload.insert("id".into(), Value::String(new_id.to_owned()));
            payload.insert("session_id".into(), Value::String(new_id.to_owned()));
            payload.insert("forked_from_id".into(), Value::String(child.to_owned()));
            for key in ["parent_thread_id", "agent_nickname", "agent_role", "agent_path"] {
                payload.remove(key);
            }
            payload.insert("source".into(), Value::String("vscode".into()));
            payload.insert("thread_source".into(), Value::String("user".into()));
            met = true;
        }
        users += usize::from(
            record.get("type").and_then(Value::as_str) == Some("response_item")
                && record.pointer("/payload/type").and_then(Value::as_str) == Some("message")
                && record.pointer("/payload/role").and_then(Value::as_str) == Some("user"),
        );
        note_calls(&record, &mut open);
        lines.push(serde_json::to_string(&record)?);
        if open.is_empty() {
            settled = lines.len();
            users_settled = users;
        }
    }
    anyhow::ensure!(met, "the rollout does not name thread {child}");
    anyhow::ensure!(users_settled > 0, "the subagent has no settled step to fork yet");
    let cut = settled < lines.len();
    lines.truncate(settled);
    Ok((lines.join("\n") + "\n", cut))
}

/// The `session_meta` payload of a Codex rollout: its first lines.
fn codex_meta(file: &Path) -> Option<Value> {
    let reader = BufReader::new(std::fs::File::open(file).ok()?);
    reader.lines().take(20).map_while(Result::ok).find_map(|line| {
        let record: Value = serde_json::from_str(&line).ok()?;
        (record.get("type").and_then(Value::as_str) == Some("session_meta"))
            .then(|| record.get("payload").cloned())
            .flatten()
    })
}

/// Codex thread `child`'s rollout, if it is a child of one of `threads` (the chat's own),
/// directly or through other children.
fn codex_child_of(home: &Path, child: &str, threads: &[String]) -> Result<PathBuf, RpcError> {
    if !crate::adopt::is_bare_id(child) || threads.iter().any(|t| t == child) {
        return Err(unknown(child));
    }
    let file = crate::adopt::find_codex(home, child).ok_or_else(|| unknown(child))?;
    let mut at = file.clone();
    for _ in 0..MAX_CODEX_DEPTH {
        let meta = codex_meta(&at).ok_or_else(|| unknown(child))?;
        let parent = codex_parent(&meta).ok_or_else(|| unknown(child))?;
        if threads.iter().any(|t| t == parent) {
            return Ok(file);
        }
        if !crate::adopt::is_bare_id(parent) {
            break;
        }
        at = crate::adopt::find_codex(home, parent).ok_or_else(|| unknown(child))?;
    }
    Err(unknown(child))
}

/// The first prompt of a Claude sidechain file.
fn first_prompt(file: &Path) -> Option<String> {
    let reader = BufReader::new(std::fs::File::open(file).ok()?);
    reader.lines().take(20).map_while(Result::ok).find_map(|line| {
        let record: Value = serde_json::from_str(&line).ok()?;
        if record.get("type").and_then(Value::as_str) != Some("user") {
            return None;
        }
        match record.pointer("/message/content")? {
            Value::String(s) => Some(s.clone()),
            Value::Array(blocks) => {
                let text: String = blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|b| b.get("text").and_then(Value::as_str))
                    .collect();
                (!text.is_empty()).then_some(text)
            }
            _ => None,
        }
    })
}

/// A Claude subagent's sidechain under one of the chat's own sessions: by its agent id (the
/// entry's, or the one asked for), else (a running subagent, whose agent id acpmux learns only
/// when it ends) the newest sidechain whose first prompt is the entry's brief. Returns the
/// project folder, the file and the agent id.
fn claude_sidechain(
    home: &Path,
    sessions: &[String],
    named: &str,
    entry: Option<&Entry>,
) -> Result<(PathBuf, std::fs::File, String), RpcError> {
    let plain = super::subagent_transcript::plain_id;
    let agents: Vec<&str> = entry
        .and_then(|e| e.agent_id.as_deref())
        .into_iter()
        .chain(Some(named))
        .filter(|a| plain(a))
        .collect();
    let mut brief_match: Option<(std::time::SystemTime, PathBuf, String, String)> = None;
    for session in sessions.iter().filter(|s| plain(s)) {
        let Some(own) = crate::adopt::find_claude(home, session) else { continue };
        let Some(project) = own.parent() else { continue };
        for agent in &agents {
            let parts: Vec<std::ffi::OsString> =
                vec![session.into(), "subagents".into(), format!("agent-{agent}.jsonl").into()];
            if let Ok(file) = super::media_read::open_regular_below(project, &parts) {
                return Ok((project.to_path_buf(), file, (*agent).to_owned()));
            }
        }
        let Some(brief) = entry.and_then(|e| e.prompt.as_deref()) else { continue };
        let dir = project.join(session).join("subagents");
        for path in std::fs::read_dir(&dir).into_iter().flatten().flatten().take(MAX_SIDECHAINS) {
            let name = path.file_name().to_string_lossy().into_owned();
            let Some(agent) = name.strip_prefix("agent-").and_then(|n| n.strip_suffix(".jsonl"))
            else {
                continue;
            };
            if !plain(agent) || first_prompt(&path.path()).as_deref() != Some(brief) {
                continue;
            }
            let at = path.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
            if brief_match.as_ref().is_none_or(|(t, ..)| at > *t) {
                brief_match = Some((at, project.to_path_buf(), session.clone(), agent.to_owned()));
            }
        }
    }
    let (_, project, session, agent) = brief_match.ok_or_else(|| unknown(named))?;
    let parts: Vec<std::ffi::OsString> =
        vec![session.into(), "subagents".into(), format!("agent-{agent}.jsonl").into()];
    let file = super::media_read::open_regular_below(&project, &parts)?;
    Ok((project, file, agent))
}

/// Writes `text` as a new file `path`, never over one.
fn write_new(path: &Path, text: &str) -> Result<(), RpcError> {
    let mut file = crate::home_fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(unreadable)?;
    file.write_all(text.as_bytes()).map_err(unreadable)
}

impl Hub {
    /// Copies subagent `named` of `session` for its fork: its own conversation, as the fork's
    /// agent resumes it, and the rows it shows. Refused for a harness that keeps its subagents
    /// in its process, for a subagent the chat does not own, and for one with no settled step.
    pub(super) async fn subagent_copy(
        self: &Arc<Self>,
        session: &Arc<Session>,
        named: &str,
        fork_env: &std::collections::BTreeMap<String, String>,
        turn_cut: Option<crate::config::TurnCut>,
    ) -> Result<SubagentCopy, RpcError> {
        use crate::config::TurnCut;
        let meta = session.meta();
        let Some(cut) = turn_cut else {
            return Err(super::fork_before::refused(
                "fork.subagent_harness",
                &format!(
                    "{} keeps its subagents inside its own process, so one cannot be forked; Claude Code and Codex subagents can",
                    meta.harness
                ),
            ));
        };
        let entry = {
            let (hub, sid, named) = (self.clone(), session.id.clone(), named.to_owned());
            tokio::task::spawn_blocking(move || {
                let mut records = Vec::new();
                let kinds = ["subagent_spawned", "subagent_state_update", "subagent_progress"];
                let _ = hub.store.scan_kinds(&sid, &kinds, &mut |e| {
                    records.push(e);
                    true
                });
                entry_from_records(&records, &named)
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
        };
        let homes = self.harness_homes().with_env(&[fork_env]);
        let new_id = uuid::Uuid::now_v7().to_string();
        let named = named.to_owned();
        let handoff = session.input_handoff.clone().lock_owned().await;
        let made = tokio::task::spawn_blocking(move || -> Result<SubagentCopy, RpcError> {
            let (agent_id, family, text, copy_path) = match cut {
                TurnCut::Claude => {
                    let sessions: Vec<String> =
                        meta.claude_session_ids().map(str::to_owned).collect();
                    let (project, file, agent) =
                        claude_sidechain(&homes.claude, &sessions, &named, entry.as_ref())?;
                    let text = read_bounded(file)?;
                    let path = project.join(format!("{new_id}.jsonl"));
                    (agent, "claude", text, path)
                }
                TurnCut::Codex => {
                    let threads: Vec<String> = meta
                        .agent_session_id
                        .iter()
                        .chain(meta.previous_agent_session_ids.iter())
                        .cloned()
                        .collect();
                    let child = entry
                        .as_ref()
                        .map(|e| e.id.as_str())
                        .filter(|id| crate::adopt::is_bare_id(id))
                        .unwrap_or(&named)
                        .to_owned();
                    let file = codex_child_of(&homes.codex, &child, &threads)?;
                    let text = read_bounded(std::fs::File::open(&file).map_err(unreadable)?)?;
                    let name = file.file_name().and_then(|n| n.to_str()).unwrap_or_default();
                    let stem = name.strip_suffix(&format!("{child}.jsonl")).ok_or_else(|| {
                        unreadable(format!("unexpected Codex rollout name {name}"))
                    })?;
                    let path = file.with_file_name(format!("{stem}{new_id}.jsonl"));
                    (child, "codex", text, path)
                }
            };
            let (copy, cut) = match family {
                "claude" => claude_sidechain_copy(&text, &new_id),
                _ => codex_child_copy(&text, &agent_id, &new_id),
            }
            .map_err(unreadable)?;
            write_new(&copy_path, &copy)?;
            let turns = crate::adopt_replay::read(family, &copy_path);
            Ok(SubagentCopy {
                subagent_id: entry.as_ref().map_or_else(|| named.clone(), |e| e.id.clone()),
                agent_id,
                name: entry.and_then(|e| e.name),
                copy: new_id,
                file: copy_path,
                turns,
                cut,
            })
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        drop(handoff);
        made
    }

    /// Writes a subagent fork's rows: the copy's turns, as an adopted chat's are (`adoption.rs`),
    /// under the fork's append lock, counted in no cost (they are the subagent's turns).
    pub(super) fn append_subagent_turns(
        &self,
        fork: &Arc<Session>,
        turns: &[crate::adopt_replay::PastTurn],
    ) -> bool {
        let agent_sid = fork.meta().agent_session_id.unwrap_or_default();
        let _order = fork.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.catch_up_locked(fork);
        for (i, turn) in turns.iter().enumerate() {
            let ids = (format!("subagent-{i}"), format!("subagent-prompt-{i}"));
            let mut turn_seq = 0;
            for record in super::native_history::turn_records(turn, &agent_sid, &ids.0, &ids.1) {
                let mut msg = record.msg;
                if record.names_turn {
                    msg.set("turnSeq", json!(turn_seq));
                }
                let (copy, stored) = self.append_at_locked(
                    fork,
                    record.dir,
                    record.kind,
                    msg,
                    None,
                    record.at,
                    false,
                    false,
                );
                if !stored {
                    return false;
                }
                if record.kind == "turn_started" {
                    turn_seq = copy.seq;
                }
            }
        }
        true
    }

    /// The fork starts on the picked model and in the picked mode, before the reply: its agent
    /// up, then each set, or the error (the caller closes the fork).
    pub(super) async fn apply_fork_start(
        self: &Arc<Self>,
        fork: &Arc<Session>,
        start: &ForkStart,
    ) -> Result<(), RpcError> {
        self.child_for(fork).await?;
        if let Some(model) = &start.model {
            Box::pin(self.set_model(fork, model))
                .await
                .map_err(|e| RpcError::invalid_params(format!("model {model:?}: {}", e.message)))?;
        }
        if let Some(mode) = &start.mode {
            check_mode(&fork.meta(), mode)?;
            if start.person {
                let params = json!({"modeId": mode});
                Box::pin(self.person_widens_policy_for(fork, method::SESSION_SET_MODE, &params))
                    .await;
            }
            Box::pin(self.set_mode(fork, mode)).await?;
        }
        Ok(())
    }
}

/// Mode `mode` is one the chat's harness lists, or the refusal naming those it does.
pub(super) fn check_mode(meta: &SessionMeta, mode: &str) -> Result<(), RpcError> {
    let modes = super::permission_modes::of_session(meta);
    let ids: Vec<&str> = modes
        .as_ref()
        .and_then(|m| m.get("availableModes"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .collect();
    if ids.contains(&mode) {
        return Ok(());
    }
    let why = if ids.is_empty() {
        format!("{} lists no permission modes, so the fork cannot start in {mode:?}", meta.harness)
    } else {
        format!("{} has no mode {mode:?}; it has {}", meta.harness, ids.join(", "))
    };
    Err(super::fork_before::refused("fork.mode_unknown", &why))
}

#[cfg(test)]
#[path = "fork_subagent_tests.rs"]
mod tests;
