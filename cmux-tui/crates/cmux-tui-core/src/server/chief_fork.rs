//! `chief.profile.create` with `fork` (spec `ChiefFork`): the new Chief starts
//! from another Chief's memory, cut at one of its conversation messages (the
//! person's "Fork to New Chief" in Home) or at this moment (a Chief that forks
//! itself with its `chiefs` tool).
//!
//! The memory format is the brain's, so the brain binary does the copy
//! (`optchat-chief memory fork`, optchat-host db/fork.rs); the daemon decides
//! who may fork what, finds the source's home and the message, and puts the
//! copy in the new Chief's brain directory BEFORE the record is written. The
//! supervisor starts a brain on the create, and that brain must open the
//! forked memory, never an empty one; so the id is taken first
//! (`chief_registry::new_id`) and the record is written with it.
//!
//! Rules:
//! - A Chief forks only itself (its own memory is its to give); the owner and
//!   the person's page (with the gesture a create needs anyway) fork any Chief
//!   of this home, the default Chief included.
//! - The message must be in a conversation the source takes part in.
//! - The copy is the new Chief's alone: rows and files, no link. The source's
//!   host state (its conversation, turns, subagents) is not copied.
//! - A failed write after the copy removes the copy (`Prepared::discard`).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{Mux, ResourceError};
use crate::chief_brains;
use crate::chief_registry::{self, ChiefStore, DEFAULT_CHIEF};

/// The longest a fork's copy may take: the registry waits for it (a create
/// is rare; a memory of 100,000 entries copies in a few seconds).
const COPY_DEADLINE: Duration = Duration::from_secs(120);
const OPERATION: &str = "chief.profile.create";

/// What `fork` asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Fork {
    /// The source Chief's id.
    pub source: String,
    /// The message to cut after; None: now.
    pub message: Option<(String, u64)>,
}

/// A fork whose memory is in place, waiting for its record.
#[derive(Debug)]
pub(super) struct Prepared {
    /// The id the record must be written with (its brain directory holds the copy).
    pub id: String,
    /// The record's `forked_from`.
    pub forked_from: Value,
    home: PathBuf,
}

impl Prepared {
    /// The record was not written with this id (refused, failed, or a
    /// replay of an earlier create): the copy goes, so no brain directory
    /// is left without its Chief.
    pub(super) fn discard(self) {
        if let Err(error) = std::fs::remove_dir_all(&self.home)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!(
                "cmux-tui: chief fork: removing the unused copy {}: {error}",
                self.home.display()
            );
        }
    }
}

/// The request's `fork`, checked for shape (the spec's `ChiefFork`); None
/// when there is none.
pub(super) fn requested(fields: &Map<String, Value>) -> Result<Option<Fork>, ResourceError> {
    let Some(fork) = fields.get("fork") else { return Ok(None) };
    let invalid = |why: &str| ResourceError::validation_invalid(Some("fork"), why.to_owned());
    let fork = fork.as_object().ok_or_else(|| invalid("fork must be an object"))?;
    if let Some(unknown) =
        fork.keys().find(|k| !matches!(k.as_str(), "chief" | "conversation" | "seq"))
    {
        return Err(invalid(&format!("fork has no field {unknown}")));
    }
    let source = fork
        .get("chief")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|c| !c.is_empty() && c.len() <= 64)
        .ok_or_else(|| invalid("fork.chief must be a Chief id"))?
        .to_owned();
    let conversation = match fork.get("conversation") {
        None | Some(Value::Null) => None,
        Some(Value::String(c)) if !c.trim().is_empty() && c.len() <= 128 => Some(c.clone()),
        Some(_) => return Err(invalid("fork.conversation must be a conversation id")),
    };
    // The spec's uint32 travels as a number (or, from some SDKs, a decimal string).
    let seq = match fork.get("seq") {
        None | Some(Value::Null) => None,
        Some(Value::Number(n)) => {
            Some(n.as_u64().ok_or_else(|| invalid("fork.seq must be a seq"))?)
        }
        Some(Value::String(s)) => {
            Some(s.parse::<u64>().map_err(|_| invalid("fork.seq must be a seq"))?)
        }
        Some(_) => return Err(invalid("fork.seq must be a seq")),
    };
    let message = match (conversation, seq) {
        (Some(c), Some(s)) if s >= 1 => Some((c, s)),
        (None, None) => None,
        _ => return Err(invalid("fork needs conversation and seq together (or neither: now)")),
    };
    Ok(Some(Fork { source, message }))
}

/// The source's profile, grant and engine for every field the create omits:
/// a fork is the same Chief from that point on, under its own name. The
/// picture is not copied (two Chiefs that look alike are hard to tell apart),
/// and neither is `locked` (the person's switch, per record).
pub(super) fn inherit(
    store: &ChiefStore,
    fork: &Fork,
    profile: &mut Map<String, Value>,
) -> Result<(), ResourceError> {
    let source = store
        .get(&fork.source)
        .map_err(|e| refused(format!("reading Chief {}: {e:#}", fork.source)))?
        .ok_or_else(|| refused(format!("no Chief {} here", fork.source)))?;
    let mut put = |key: &str, value: Value| {
        profile.entry(key.to_owned()).or_insert(value);
    };
    put("role", json!(source.role));
    put("personality", json!(source.personality));
    put("instructions", json!(source.instructions));
    put("tools", json!(source.tools));
    put("harnesses", json!(source.harnesses));
    put("self_edit", json!(source.self_edit));
    for (key, value) in [
        ("harness", &source.engine.harness),
        ("model", &source.engine.model),
        ("effort", &source.engine.effort),
    ] {
        if let Some(value) = value.as_ref().filter(|v| !v.is_empty()) {
            put(key, json!(value));
        }
    }
    Ok(())
}

fn refused(why: impl Into<String>) -> ResourceError {
    ResourceError::operation_failed(OPERATION, "fork_refused", json!({"message": why.into()}))
}

/// Checks who may fork what, resolves the source's home and message, and
/// copies the memory into the new Chief's brain directory. `by` is the
/// calling Chief (None: the person). Runs under the registry lock (lock
/// order: registry, then conversations, as `chief.profile.adopt`).
pub(super) fn prepare(
    mux: &Mux,
    store: &ChiefStore,
    fork: &Fork,
    by: Option<&str>,
) -> Result<Prepared, ResourceError> {
    let (home, executable) = chief_brains::configured_home_and_brain().ok_or_else(|| {
        refused("this cmux runs no Chief brains here, so it cannot hold a forked memory")
    })?;
    if let Some(me) = by
        && me != fork.source
    {
        return Err(refused("a Chief may fork only itself; the person forks other Chiefs"));
    }
    let source = store
        .get(&fork.source)
        .map_err(|e| refused(format!("reading Chief {}: {e:#}", fork.source)))?
        .ok_or_else(|| refused(format!("no Chief {} here", fork.source)))?;
    let source_home = if source.id == DEFAULT_CHIEF {
        home.clone()
    } else {
        let dir = chief_brains::brain_home(&home, &source.id);
        // Another id with the same tail would be another Chief's memory.
        let owner = std::fs::read_to_string(dir.join("chief-id")).unwrap_or_default();
        if owner.trim() != source.id {
            return Err(refused(format!(
                "{} has no memory on this Mac yet (its brain never ran here)",
                source.display_name
            )));
        }
        dir
    };
    if !source_home.join("optchat").join("memory.sqlite3").is_file() {
        return Err(refused(format!("{} has no memory yet", source.display_name)));
    }
    let point = match &fork.message {
        None => None,
        Some((conversation, seq)) => Some(message_point(mux, &source.id, conversation, *seq)?),
    };
    let id = chief_registry::new_id().map_err(|e| refused(format!("{e:#}")))?;
    let target = chief_brains::brain_home(&home, &id);
    if target.exists() {
        return Err(refused("the new Chief's directory exists already; try again"));
    }
    let by_text = by.unwrap_or("person");
    let mut args: Vec<String> = vec![
        "memory".into(),
        "fork".into(),
        "--mux-home".into(),
        path_arg(&source_home)?,
        "--to-home".into(),
        path_arg(&target)?,
        "--chief".into(),
        source.id.clone(),
        "--name".into(),
        source.display_name.clone(),
        "--by".into(),
        by_text.to_owned(),
        "--json".into(),
    ];
    if let Some((key, at)) = &point {
        args.extend(["--key".into(), key.clone(), "--at".into(), at.clone()]);
    }
    let prepared_home = target.clone();
    let output = match run_copy(&executable, &args) {
        Ok(output) => output,
        Err(why) => {
            let _ = std::fs::remove_dir_all(&prepared_home);
            return Err(refused(why));
        }
    };
    let cut = output.get("cut").and_then(Value::as_u64).unwrap_or(0);
    let mut forked_from = json!({
        "chief": source.id,
        "name": source.display_name,
        "cut": cut,
        "by": by_text,
        "at": cmux_conversation::format_rfc3339_millis(now_ms()),
    });
    if let Some((conversation, seq)) = &fork.message {
        forked_from["conversation"] = json!(conversation);
        forked_from["seq"] = json!(seq);
    }
    Ok(Prepared { id, forked_from, home: prepared_home })
}

/// The memory key and commit time of message `seq` of `conversation`, a
/// conversation `chief` takes part in.
fn message_point(
    mux: &Mux,
    chief: &str,
    conversation: &str,
    seq: u64,
) -> Result<(String, String), ResourceError> {
    let found = mux.with_conversations(|store| {
        let Some(head) = store.head(conversation)? else { return Ok(None) };
        let member = head.participants.iter().any(|p| p.id == chief);
        let message = store.history(conversation, seq.saturating_add(1), 1)?;
        Ok(Some((member, message.into_iter().find(|m| m.seq == seq))))
    });
    match found {
        Err(e) => Err(refused(format!("reading the conversation: {e:#}"))),
        Ok(None) => Err(refused(format!("no conversation {conversation}"))),
        Ok(Some((false, _))) => Err(refused("that Chief does not take part in this conversation")),
        Ok(Some((true, None))) => Err(refused(format!("no message #{seq} in this conversation"))),
        Ok(Some((true, Some(message)))) => {
            Ok((format!("{conversation}#{seq}"), message.created_at))
        }
    }
}

fn path_arg(path: &Path) -> Result<String, ResourceError> {
    path.to_str().map(str::to_owned).ok_or_else(|| refused("the Chief home path is not UTF-8"))
}

/// Runs the brain's `memory fork` and returns its JSON answer, or why not.
/// The child is killed when it outlives [`COPY_DEADLINE`] (the registry lock
/// is held meanwhile).
fn run_copy(executable: &Path, args: &[String]) -> Result<Value, String> {
    let child = Command::new(executable)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("starting the memory copy: {e}"))?;
    let pid = child.id();
    #[cfg(not(unix))]
    let _ = pid;
    let (done, finished) = mpsc::channel();
    std::thread::Builder::new()
        .name("chief-fork-copy".into())
        .spawn(move || {
            let _ = done.send(child.wait_with_output());
        })
        .map_err(|e| format!("starting the memory copy: {e}"))?;
    let output = match finished.recv_timeout(COPY_DEADLINE) {
        Ok(output) => output.map_err(|e| format!("the memory copy: {e}"))?,
        Err(_) => {
            #[cfg(unix)]
            // SAFETY: kill(2) on the pid of the child this function started,
            // which the waiting thread has not reaped (no answer came yet).
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGKILL);
            }
            let _ = finished.recv_timeout(Duration::from_secs(5));
            return Err("the memory copy took too long and was stopped".into());
        }
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let why = stderr.trim().trim_start_matches("optchat-chief memory: ").trim();
        return Err(if why.is_empty() { "the memory copy failed".into() } else { why.to_owned() });
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.lines().rev().find(|l| l.trim_start().starts_with('{')).unwrap_or("");
    serde_json::from_str(line).map_err(|e| format!("the memory copy answered no result ({e})"))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn a_fork_now_names_only_its_source() {
        let got = requested(&fields(json!({"fork": {"chief": "agent_x"}}))).unwrap();
        assert_eq!(got, Some(Fork { source: "agent_x".into(), message: None }));
    }

    #[test]
    fn a_fork_at_a_message_needs_both_conversation_and_seq() {
        let got = requested(&fields(
            json!({"fork": {"chief": "agent_x", "conversation": "c1", "seq": 7}}),
        ))
        .unwrap();
        assert_eq!(got, Some(Fork { source: "agent_x".into(), message: Some(("c1".into(), 7)) }));
        for bad in [
            json!({"fork": {"chief": "agent_x", "seq": 7}}),
            json!({"fork": {"chief": "agent_x", "conversation": "c1"}}),
            json!({"fork": {"chief": "agent_x", "conversation": "c1", "seq": 0}}),
            json!({"fork": {"chief": ""}}),
            json!({"fork": {"chief": "agent_x", "extra": 1}}),
            json!({"fork": "agent_x"}),
        ] {
            assert!(requested(&fields(bad.clone())).is_err(), "{bad}");
        }
    }

    #[test]
    fn no_fork_is_a_blank_chief() {
        assert_eq!(requested(&fields(json!({"display_name": "A"}))).unwrap(), None);
    }
}
