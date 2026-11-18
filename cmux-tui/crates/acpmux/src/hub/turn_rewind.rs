//! Back to before this turn for a chat on this machine (`agents.turnCheckpoints`, off by default):
//! the files and the conversation as they were before a prompt, with Undo.
//!
//! Checkpoints: with the setting on, each turn first takes a repository checkpoint of the chat's
//! folder through the session host's checkpoint store (`cmux git checkpoint create`, cmux-tui-core
//! `git_ops/checkpoint.rs`), before its prompt reaches the agent. The turn's `turn_result` then
//! names it (`rewindCheckpointId`), or says why there is none (`rewindCheckpointError`: not a git
//! repository, the session host unreachable). A prompt whose turn ended with either field is one
//! the page offers to rewind. The capture never holds the prompt for long and never fails it: past
//! its bound the turn goes on without one.
//!
//! Rewind (`_acpmux/rewind`, `server/rewind.rs`, `acpmux session rewind`):
//! - files: `cmux git checkpoint restore` of that checkpoint, which first takes a safety checkpoint
//!   of the folder as it is now (the Undo). Refused while another chat on this machine is working
//!   in the same repository: its next edit would land on the restored files.
//! - conversation: a fork of the chat before the prompt, through the harness's own transcript cut
//!   (Claude, Codex: `fork_before.rs`, as Edit and resend); any other harness is refused with
//!   `fork.unsupported` and the files can still be reset alone. The original chat stays as it was,
//!   a sibling of the rewound one, so Undo of the conversation is opening it again.
//!
//! Undo (`_acpmux/rewind_undo`): a restore of the safety checkpoint.

use super::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::SessionStatus;
use serde_json::{Map, Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

/// The setting that turns the checkpoints on (schemas/settings/source, off by default).
pub const SETTING: &str = "agents.turnCheckpoints";

/// The longest a turn's start waits on its checkpoint.
const CAPTURE_LIMIT: Duration = Duration::from_secs(20);
/// The longest a restore (or its dry run) may take.
const RESTORE_LIMIT: Duration = Duration::from_secs(120);
/// The most paths a dry run names (`files.total` counts them all).
const PATHS_SHOWN: usize = 200;

/// Whether the setting is on now (read at each turn, as the other agent settings are).
pub(crate) fn on() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING).and_then(|v| v.as_bool()) == Some(true)
        }
        _ => false,
    }
}

/// A refusal the page and the CLI read by its `data.reason`.
pub(crate) fn refused(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// The `cmux` CLI that reaches this machine's session host (`CMUX_BIN`, else `cmux` on PATH), as
/// `cloud_repo_mcp.rs` runs it. Its socket comes from acpmux's own environment
/// (`CMUX_TUI_SOCKET`), which the child inherits.
fn cmux_binary() -> std::ffi::OsString {
    std::env::var_os("CMUX_BIN").filter(|v| !v.is_empty()).unwrap_or_else(|| "cmux".into())
}

/// What one `cmux --json git checkpoint ...` call answered: its result, or its refusal's reason
/// and message.
#[derive(Debug)]
pub(crate) enum Answer {
    Ok(Value),
    Refused { reason: String, message: String },
}

/// Runs `cmux --json git checkpoint ARGS --path CWD`, bounded by `limit`.
async fn checkpoint_cli(cwd: &Path, args: &[&str], limit: Duration) -> Answer {
    // A mutation whose answer did not come may have happened: the same idempotency key asked
    // again answers what it did (the session host's ledger), and never does it twice.
    match checkpoint_cli_once(cwd, args, limit).await {
        Answer::Refused { reason, .. } if reason == "unavailable" => {
            checkpoint_cli_once(cwd, args, limit).await
        }
        answer => answer,
    }
}

async fn checkpoint_cli_once(cwd: &Path, args: &[&str], limit: Duration) -> Answer {
    let mut command = tokio::process::Command::new(cmux_binary());
    command
        .kill_on_drop(true)
        .arg("--json")
        .args(["git", "checkpoint"])
        .args(args)
        .arg("--path")
        .arg(cwd)
        .current_dir(cwd)
        .stdin(std::process::Stdio::null());
    let output = match tokio::time::timeout(limit, command.output()).await {
        Err(_) => {
            return Answer::Refused {
                reason: "unavailable".into(),
                message: "the session host did not answer in time".into(),
            };
        }
        Ok(Err(e)) => {
            return Answer::Refused {
                reason: "unavailable".into(),
                message: format!("cmux could not run: {e}"),
            };
        }
        Ok(Ok(output)) => output,
    };
    read_answer(output.status.success(), &output.stdout, &output.stderr)
}

/// The CLI's answer: on success its JSON (a resource reply's `result` when wrapped); on failure
/// the refusal's `reason` (`details.reason`, the resource catalog's `operation.failed` shape) and
/// message, from whichever stream carried the JSON.
pub(crate) fn read_answer(success: bool, stdout: &[u8], stderr: &[u8]) -> Answer {
    let parse = |bytes: &[u8]| serde_json::from_slice::<Value>(bytes).ok();
    if success && let Some(v) = parse(stdout) {
        // A mutation's reply is `{value, generation, revision, replayed}`, perhaps under
        // `result`: the operation's own fields are in `value`.
        let result = v.get("result").filter(|r| r.is_object()).cloned().unwrap_or(v);
        let value = result.get("value").filter(|r| r.is_object()).cloned().unwrap_or(result);
        return Answer::Ok(value);
    }
    let v = parse(stdout).filter(|v| v.get("error").is_some()).or_else(|| parse(stderr));
    let error = v.as_ref().map(|v| v.get("error").cloned().unwrap_or_else(|| v.clone()));
    let text = |e: &Value, path: &str| e.pointer(path).and_then(Value::as_str).map(str::to_owned);
    let reason = error
        .as_ref()
        .and_then(|e| {
            text(e, "/details/reason")
                .or_else(|| text(e, "/data/reason"))
                .or_else(|| text(e, "/reason"))
                .or_else(|| text(e, "/code"))
        })
        .unwrap_or_else(|| "unavailable".into());
    let message = error
        .as_ref()
        // An `operation.failed` names its reason as its message; its words are in
        // `details.extra.message`.
        .and_then(|e| {
            text(e, "/details/extra/message")
                .or_else(|| text(e, "/message"))
                .or_else(|| text(e, "/userMessage"))
        })
        .unwrap_or_else(|| {
            let raw = String::from_utf8_lossy(if stderr.is_empty() { stdout } else { stderr });
            raw.trim().chars().take(400).collect()
        });
    Answer::Refused { reason, message }
}

/// The `turn_result` fields for a checkpoint answer: its id, or why there is none.
pub(crate) fn checkpoint_fields(answer: &Answer) -> Map<String, Value> {
    let mut fields = Map::new();
    match answer {
        Answer::Ok(v) => match v.get("checkpoint_id").and_then(Value::as_str) {
            Some(id) => {
                fields.insert("rewindCheckpointId".into(), json!(id));
            }
            None => {
                fields.insert("rewindCheckpointError".into(), json!("no checkpoint id"));
            }
        },
        Answer::Refused { message, .. } => {
            fields.insert("rewindCheckpointError".into(), json!(message));
        }
    }
    fields
}

impl Hub {
    /// With the setting on, the checkpoint before turn `turn_id`'s prompt, kept on the session
    /// for its `turn_result` ([`Hub::turn_checkpoint_fields`]). Off: nothing, and nothing waits.
    pub(super) async fn take_turn_checkpoint(&self, session: &Session, turn_id: &str) {
        if !tokio::task::spawn_blocking(on).await.unwrap_or(false) {
            return;
        }
        let cwd = session.meta().cwd.clone();
        let fields = if crate::git_state::repo_root(&cwd).is_none() {
            let mut fields = Map::new();
            fields.insert("rewindCheckpointError".into(), json!("not a git repository"));
            fields
        } else {
            let key = format!("acpmux-turn-{turn_id}");
            let args = [
                "create",
                "--untracked",
                "eligible",
                "--reason",
                "turn",
                "--idempotency-key",
                key.as_str(),
            ];
            checkpoint_fields(&checkpoint_cli(&cwd, &args, CAPTURE_LIMIT).await)
        };
        *session.turn_checkpoint.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((turn_id.to_owned(), fields));
    }

    /// The checkpoint fields of turn `turn_id`, taken once: its `turn_result` carries them.
    pub(super) fn turn_checkpoint_fields(
        &self,
        session: &Session,
        turn_id: &str,
    ) -> Map<String, Value> {
        let mut slot = session.turn_checkpoint.lock().unwrap_or_else(|e| e.into_inner());
        match slot.take() {
            Some((turn, fields)) if turn == turn_id => fields,
            // Another turn's: it stays for that turn's end.
            other => {
                *slot = other;
                Map::new()
            }
        }
    }

    /// The prompt a rewind names (by `promptId`, or by the seq of its `user_message`): its id,
    /// text, and what its turn's `turn_result` recorded of the checkpoint before it.
    fn rewind_prompt(
        &self,
        session: &Session,
        prompt: &PromptKey,
    ) -> Result<RewindPrompt, RpcError> {
        let mut found: Option<RewindPrompt> = None;
        let mut turn: Option<String> = None;
        self.store
            .scan(&session.id, 0, &mut |event| {
                if event.dir != "mux" {
                    return true;
                }
                match event.kind.as_str() {
                    "user_message" if found.is_none() => {
                        let id = event.msg.get("promptId").and_then(Value::as_str);
                        let matches = match prompt {
                            PromptKey::Id(want) => id == Some(want.as_str()),
                            PromptKey::Seq(seq) => event.seq == *seq,
                        };
                        if matches && let Some(id) = id {
                            found = Some(RewindPrompt {
                                prompt_id: id.to_owned(),
                                text: event
                                    .msg
                                    .get("text")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned(),
                                checkpoint: None,
                                ended: false,
                            });
                            turn =
                                event.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                        }
                    }
                    "turn_result" => {
                        if let (Some(f), Some(t)) = (found.as_mut(), turn.as_deref())
                            && event.msg.get("turnId").and_then(Value::as_str) == Some(t)
                        {
                            f.ended = true;
                            f.checkpoint = match (
                                event.msg.get("rewindCheckpointId").and_then(Value::as_str),
                                event.msg.get("rewindCheckpointError").and_then(Value::as_str),
                            ) {
                                (Some(id), _) => Some(Ok(id.to_owned())),
                                (None, Some(why)) => Some(Err(why.to_owned())),
                                (None, None) => None,
                            };
                            return false;
                        }
                    }
                    _ => {}
                }
                true
            })
            .map_err(|e| RpcError::internal(e.to_string()))?;
        found.ok_or_else(|| refused("unknown_prompt", "no prompt of this chat matches"))
    }

    /// Chats on this machine working in `session`'s repository now (a turn running or waiting on
    /// the person), the chat itself and its sub-sessions included: a reset of the files would be
    /// overwritten by, or overwrite, their work.
    fn chats_sharing(&self, session: &Session, root: &Path) -> Vec<Value> {
        self.session_handles()
            .into_iter()
            .filter(|other| {
                matches!(other.status(), SessionStatus::Running | SessionStatus::Waiting)
            })
            .filter_map(|other| {
                let meta = other.meta();
                let theirs = crate::git_state::repo_root(&meta.cwd)?;
                (theirs == root || theirs.starts_with(root) || root.starts_with(&theirs))
                    .then(|| json!({"sessionId": other.id, "title": meta.name}))
            })
            .collect()
    }

    /// `_acpmux/rewind`: see the module comment. `dry_run` answers what a rewind would do and
    /// changes nothing.
    pub(crate) async fn rewind(
        self: &Arc<Self>,
        session: &Arc<Session>,
        request: RewindRequest,
        fork: Fork<'_>,
    ) -> Result<Value, RpcError> {
        let (hub, source, key) = (self.clone(), session.clone(), request.prompt.clone());
        let prompt = tokio::task::spawn_blocking(move || hub.rewind_prompt(&source, &key))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))??;
        if !prompt.ended {
            return Err(refused("turn_running", "that prompt's turn has not ended"));
        }
        let cwd = session.meta().cwd.clone();
        let conversation = {
            let harness = session.meta().harness;
            let config = self.config.read().await;
            config.profile(&harness).and_then(|p| crate::config::turn_cut(&harness, p)).is_some()
        };
        let files =
            self.rewind_files_plan(session, &cwd, &prompt, request.dry_run || request.files).await;
        if request.dry_run {
            let mut reply = json!({
                "promptId": prompt.prompt_id,
                "conversation": if conversation { json!("native") } else { Value::Null },
                "files": Value::Null,
            });
            match files {
                FilesPlan::Ready { checkpoint, preview } => {
                    let paths: Vec<Value> = preview
                        .get("files")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(|f| f.get("path").cloned())
                        .take(PATHS_SHOWN)
                        .collect();
                    reply["files"] = json!({
                        "checkpointId": checkpoint,
                        "total": preview.get("files_total").and_then(Value::as_u64).unwrap_or(paths.len() as u64),
                        "paths": paths,
                        "baseChanged": preview.get("base_changed").and_then(Value::as_bool).unwrap_or(false),
                        "complete": preview.get("complete").and_then(Value::as_bool).unwrap_or(true),
                    });
                }
                FilesPlan::Blocked(blocked) => reply["filesBlocked"] = blocked,
            }
            return Ok(reply);
        }
        if !request.conversation && !request.files {
            return Err(RpcError::invalid_params("rewind the conversation, the files, or both"));
        }
        if request.conversation && !conversation {
            return Err(refused(
                "fork.unsupported",
                "this chat's agent cannot go back to before a prompt; reset the files alone",
            ));
        }
        // The files first: a refused restore leaves the conversation as it was.
        let mut undo = json!({"sessionId": session.id});
        let mut restored = 0;
        if request.files {
            let checkpoint = match files {
                FilesPlan::Ready { checkpoint, .. } => checkpoint,
                FilesPlan::Blocked(blocked) => {
                    let reason = blocked["reason"].as_str().unwrap_or("unavailable");
                    let message =
                        blocked["message"].as_str().unwrap_or("the files cannot be reset");
                    return Err(refused(reason, message).with_data(blocked.clone()));
                }
            };
            let key = format!("acpmux-rewind-{}", uuid::Uuid::now_v7());
            let args = ["restore", checkpoint.as_str(), "--idempotency-key", key.as_str()];
            match checkpoint_cli(&cwd, &args, RESTORE_LIMIT).await {
                Answer::Ok(v) => {
                    restored = v.get("files_total").and_then(Value::as_u64).unwrap_or(0);
                    if let Some(safety) = v.get("safety_checkpoint_id").and_then(Value::as_str) {
                        undo["safetyCheckpointId"] = json!(safety);
                    }
                }
                Answer::Refused { reason, message } => return Err(refused(&reason, message)),
            }
        }
        let mut reply = json!({"undo": undo, "filesRestored": restored});
        if request.conversation {
            match fork(session.clone(), prompt.prompt_id.clone()).await {
                Ok(new) => {
                    reply["sessionId"] = json!(new.id);
                    reply["prompt"] = json!({"text": prompt.text});
                }
                Err(e) => {
                    // The conversation stayed: put the files back too, so nothing half happened.
                    if let Some(safety) = reply["undo"]["safetyCheckpointId"].as_str() {
                        let _ = self.rewind_undo_at(&cwd, safety).await;
                    }
                    return Err(e);
                }
            }
        }
        Ok(reply)
    }

    /// Whether `prompt`'s files can be reset now, and the dry run's answer when they can.
    async fn rewind_files_plan(
        &self,
        session: &Session,
        cwd: &Path,
        prompt: &RewindPrompt,
        wanted: bool,
    ) -> FilesPlan {
        let blocked = |reason: &str, message: &str| {
            FilesPlan::Blocked(json!({"reason": reason, "message": message}))
        };
        let checkpoint = match &prompt.checkpoint {
            None => return blocked("no_checkpoint", "no checkpoint was saved before this turn"),
            Some(Err(why)) if why == "not a git repository" => {
                return blocked("not_git", "this chat's folder is not a git repository");
            }
            Some(Err(why)) => return blocked("no_checkpoint", why),
            Some(Ok(id)) => id.clone(),
        };
        let Some(root) = crate::git_state::repo_root(cwd) else {
            return blocked("not_git", "this chat's folder is not a git repository");
        };
        let shared = self.chats_sharing(session, &root);
        if !shared.is_empty() {
            return FilesPlan::Blocked(json!({
                "reason": "shared",
                "message": "another chat is working in this folder",
                "sharedWith": shared,
            }));
        }
        if !wanted {
            return FilesPlan::Ready { checkpoint, preview: Value::Null };
        }
        let key = format!("acpmux-rewind-preview-{}", uuid::Uuid::now_v7());
        let args = ["restore", checkpoint.as_str(), "--dry-run", "--idempotency-key", key.as_str()];
        match checkpoint_cli(cwd, &args, RESTORE_LIMIT).await {
            Answer::Ok(preview) => {
                if preview.get("base_changed").and_then(Value::as_bool) == Some(true) {
                    return blocked(
                        "base_changed",
                        "the branch has moved since this turn (a commit or checkout)",
                    );
                }
                FilesPlan::Ready { checkpoint, preview }
            }
            Answer::Refused { reason, message } => {
                FilesPlan::Blocked(json!({"reason": reason, "message": message}))
            }
        }
    }

    /// `_acpmux/rewind_undo`: the folder of `session` back to its safety checkpoint.
    pub(crate) async fn rewind_undo(
        &self,
        session: &Session,
        safety: &str,
    ) -> Result<Value, RpcError> {
        let cwd = session.meta().cwd.clone();
        if let Some(root) = crate::git_state::repo_root(&cwd) {
            let shared = self.chats_sharing(session, &root);
            if !shared.is_empty() {
                return Err(refused("shared", "a chat is working in this folder")
                    .with_data(json!({"reason": "shared", "sharedWith": shared})));
            }
        }
        let (restored, again) = self.rewind_undo_at(&cwd, safety).await?;
        // Undo's own safety checkpoint: `--undo` with it puts the rewind back.
        Ok(json!({"filesRestored": restored, "safetyCheckpointId": again}))
    }

    async fn rewind_undo_at(
        &self,
        cwd: &Path,
        safety: &str,
    ) -> Result<(u64, Option<String>), RpcError> {
        // Undo puts back what the rewind replaced, whatever HEAD did since.
        let key = format!("acpmux-rewind-undo-{safety}");
        let args = ["restore", safety, "--allow-base-change", "--idempotency-key", key.as_str()];
        match checkpoint_cli(cwd, &args, RESTORE_LIMIT).await {
            Answer::Ok(v) => Ok((
                v.get("files_total").and_then(Value::as_u64).unwrap_or(0),
                v.get("safety_checkpoint_id").and_then(Value::as_str).map(str::to_owned),
            )),
            Answer::Refused { reason, message } => Err(refused(&reason, message)),
        }
    }
}

/// The conversation's rewind: a fork of the chat before prompt id (the server's
/// `session/fork` with `beforePromptId`, with its admission), answering the new chat.
pub(crate) type Fork<'a> = Box<
    dyn FnOnce(
            Arc<Session>,
            String,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<Arc<Session>, RpcError>> + Send + 'a>,
        > + Send
        + 'a,
>;

/// Which prompt a rewind names.
#[derive(Debug, Clone)]
pub(crate) enum PromptKey {
    Id(String),
    Seq(u64),
}

/// `_acpmux/rewind`'s request.
#[derive(Debug, Clone)]
pub(crate) struct RewindRequest {
    pub prompt: PromptKey,
    pub conversation: bool,
    pub files: bool,
    pub dry_run: bool,
}

#[derive(Debug)]
struct RewindPrompt {
    prompt_id: String,
    text: String,
    /// The checkpoint its turn recorded, or why there is none; None: its turn recorded neither.
    checkpoint: Option<Result<String, String>>,
    ended: bool,
}

enum FilesPlan {
    Ready { checkpoint: String, preview: Value },
    Blocked(Value),
}

#[cfg(test)]
#[path = "turn_rewind_tests.rs"]
mod tests;
