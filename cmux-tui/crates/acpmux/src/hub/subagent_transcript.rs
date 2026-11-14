//! `_acpmux/subagent_transcript`: one subagent's transcript, a page at a time, read from the
//! files Claude Code writes for one of this daemon's chats. A workflow's agents never stream into
//! the chat, and a run can have a thousand, so the pane pulls the one a person opens instead of
//! acpmux pushing them all into the chat's log. The reply goes to the caller only: no page is
//! ever written to the chat's log.
//!
//! Where: the chat's Claude store (its profile's `CLAUDE_CONFIG_DIR`, else `~/.claude`) holds its
//! session as `projects/<project>/<session>.jsonl` (`adopt::find_claude`) and its subagents
//! under `projects/<project>/<session>/subagents`: a workflow agent's as
//! `workflows/<runId>/agent-<agentId>.jsonl`, a background agent's as `agent-<agentId>.jsonl`.
//! Only this chat's recorded Claude session folders and readable fork ancestors are tried.
//! Neither a workflow index nor a sibling session folder grants access.
//!
//! The caller names plain ids, never a path, and nothing the harness says becomes one: the
//! project folder comes from the store, and the file is opened below it one component at a time
//! without following a link or crossing a mount (`media_read::open_regular_below`).
//!
//! The store is the one the chat's agent runs with: its profile's env as the spawn builds it
//! (defaults, preset, chat store and session env, `~` expanded: `Hub::spawn_profile_for`).
//!
//! A page is the lines before `before` (the end when absent), or with `after` the lines from it
//! on (a live view's next lines): at most `limit` lines and about `PAGE_BYTES` of updates, with
//! at least one line. `start` and `end` are the cursors of the next older and newer pages. A
//! transcript over `FILE_BYTES` is read from its last `FILE_BYTES` (`truncated`), and its line
//! numbers count from there. Up to `REPLAY_BEFORE` lines before a page are replayed with it,
//! off the runtime, so its calls pair with their results.

use super::Hub;
use super::media_read::refused;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::ffi::OsString;
use std::fs::File;
use std::path::PathBuf;

/// Lines a page holds unless the request asks for fewer, and the most it may ask for.
const PAGE_LINES: usize = 200;
const MAX_LINES: usize = 500;
/// The most of a transcript read.
const FILE_BYTES: u64 = 32 << 20;
/// About the most a page's updates hold, serialized; one line's past it go as an `omitted` stub.
const PAGE_BYTES: usize = 4 << 20;
/// The most of a transcript parsed for one page, the page and the lines replayed before it.
const PARSE_BYTES: usize = 16 << 20;
/// The most lines indexed: a transcript of more is read from its last ones (`truncated`).
const INDEXED_LINES: usize = 1 << 20;

/// Lines before a page replayed with it, so a call there pairs with its result on the page.
const REPLAY_BEFORE: usize = 1000;

/// Transcript reads running at once on this daemon: each replays a transcript, which is CPU work.
static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// The `initialize` feature of a daemon that serves `_acpmux/subagent_transcript`; a peer that
/// does not list it is never sent one (`peer_forward.rs`).
pub const FEATURE: &str = "subagentTranscript";

pub(crate) async fn handle(hub: &std::sync::Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(params)?)?;
    if session.purged.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(RpcError::invalid_params("no such chat"));
    }
    let meta = session.meta();
    // The store the chat's agent runs with, from its profile's env as the spawn builds it.
    let (profile, defaults) = {
        let cfg = hub.config.read().await;
        let profile =
            super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                .map_err(RpcError::invalid_params)?;
        (profile, cfg.defaults_for(&meta.harness))
    };
    let profile = hub.spawn_profile_for(&meta, &profile, &defaults.env).await?;
    if profile.kind != crate::config::HarnessKind::ClaudeStdio {
        return Err(refused(
            "transcript.harness",
            "only a Claude Code chat has subagent transcripts",
        ));
    }
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let agent = text("agentId")
        .filter(|id| plain_id(id))
        .ok_or_else(|| refused("transcript.id", "agentId must be a plain id"))?
        .to_owned();
    let run = match text("runId") {
        Some(run) if run.strip_prefix("wf_").is_some_and(plain_id) => Some(run.to_owned()),
        Some(_) => return Err(refused("transcript.id", "runId must be a workflow run id (wf_…)")),
        None => None,
    };
    let home = crate::harness_config::config_dir("CLAUDE_CONFIG_DIR", ".claude", &[&profile.env])
        .ok_or_else(|| refused("transcript.none", "the chat's Claude store is not known"))?;
    let _turn = READS.acquire().await.map_err(|e| RpcError::internal(e.to_string()))?;
    let sessions = readable_claude_sessions(hub, meta, home).await;
    let number =
        |key: &str| params.get(key).and_then(Value::as_u64).and_then(|v| usize::try_from(v).ok());
    let limit = number("limit").unwrap_or(PAGE_LINES).clamp(1, MAX_LINES);
    let (before, after) = (number("before"), number("after"));
    let (text, truncated) =
        tokio::task::spawn_blocking(move || read(&sessions, run.as_deref(), &agent))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))??;
    let total = text.lines.len();
    let (start, end) = window(total, limit, before, after);
    let (start, end, from) = text.bounded(start, end, after.is_some());
    // Parsed and replayed off the runtime: a page and the lines before it are CPU work. A line
    // over `PAGE_BYTES` is never parsed: it goes as an `omitted` stub (`fit`).
    let per_line = tokio::task::spawn_blocking(move || {
        let replayed: Vec<Value> = (from..end).map(|at| text.message(at)).collect();
        let huge: Vec<Option<usize>> =
            (start..end).map(|at| Some(text.len_of(at)).filter(|n| *n > PAGE_BYTES)).collect();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let mut per_line = runtime.block_on(crate::claude_stdio::agent_transcript::replay(
            &replayed,
            start - from,
            from == 0 && !truncated,
        ));
        for (updates, bytes) in per_line.iter_mut().zip(huge) {
            if let Some(bytes) = bytes {
                *updates = vec![omitted(bytes)];
            }
        }
        Ok::<_, RpcError>(per_line)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))??;
    let (start, end, updates) = fit(per_line, start, end, after.is_some());
    Ok(json!({"updates": updates, "lines": total, "start": start, "end": end,
        "truncated": truncated}))
}

/// Bound corrupted/imported ancestry as well as cycles. Forks clear `lineage`; only their
/// explicit parent IDs grant ancestry. Exact local IDs also enforce the peer-origin contract:
/// a peer (including a paired device) gains no local ancestor access from a remote cached chat.
/// No name/prefix resolution, peer forwarding, event payload or workflow index participates.
async fn readable_claude_sessions(
    hub: &std::sync::Arc<Hub>,
    mut meta: crate::store::SessionMeta,
    home: PathBuf,
) -> Vec<(PathBuf, String)> {
    const MAX_FORK_DEPTH: usize = 64;
    let mut home = Some(home);
    let mut visited = std::collections::HashSet::new();
    let mut folders = std::collections::HashSet::new();
    let mut allowed = Vec::new();
    for _ in 0..MAX_FORK_DEPTH {
        if !visited.insert(meta.id.clone()) {
            break;
        }
        if let Some(home) = home {
            for id in meta.claude_session_ids().filter(|id| plain_id(id)) {
                let folder = (home.clone(), id.to_owned());
                if folders.insert(folder.clone()) {
                    allowed.push(folder);
                }
            }
        }
        let Some(parent) = meta.parent_id.as_ref().filter(|_| meta.fork_seq.is_some()) else {
            break;
        };
        let ancestor = hub.sessions.lock().ok().and_then(|sessions| sessions.get(parent).cloned());
        let Some(ancestor) = ancestor else { break };
        if ancestor.purged.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        if !super::fork_transcript_auth::verified_parent(hub, &meta, &ancestor).await {
            break;
        }
        meta = ancestor.meta();
        // Each ancestor uses its own configured store. An unreadable or non-Claude ancestor
        // contributes no folders; walking its parent still permits a readable grandparent.
        home = ancestor_claude_home(hub, &meta).await;
    }
    allowed
}

/// The Claude store a chat's agent runs with (its profile's env as the spawn builds it); none
/// for a chat that is not a Claude Code one. `hub/native_history.rs` reads a chat's own
/// transcript from it.
pub(super) async fn claude_home(hub: &Hub, meta: &crate::store::SessionMeta) -> Option<PathBuf> {
    ancestor_claude_home(hub, meta).await
}

async fn ancestor_claude_home(hub: &Hub, meta: &crate::store::SessionMeta) -> Option<PathBuf> {
    let (profile, defaults) = {
        let cfg = hub.config.read().await;
        let profile =
            super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                .ok()?;
        (profile, cfg.defaults_for(&meta.harness))
    };
    let profile = hub.spawn_profile_for(meta, &profile, &defaults.env).await.ok()?;
    if profile.kind != crate::config::HarnessKind::ClaudeStdio {
        return None;
    }
    crate::harness_config::config_dir("CLAUDE_CONFIG_DIR", ".claude", &[&profile.env])
}

/// An id that names one folder or file and nothing else: ASCII letters, digits, `-` and `_`.
pub(super) fn plain_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A transcript as read: its bytes and the byte range of each of its lines, so only the lines a
/// page needs are ever parsed.
struct Text {
    bytes: Vec<u8>,
    /// Each line's start and length in `bytes`: a 32 MiB read fits `u32`.
    lines: Vec<(u32, u32)>,
}

impl Text {
    fn len_of(&self, at: usize) -> usize {
        self.lines.get(at).map_or(0, |(_, len)| *len as usize)
    }

    /// Line `at` as the replay reads it: a `user` or `assistant` message, else null (the replay
    /// passes over it). A line over `PAGE_BYTES` is never parsed.
    fn message(&self, at: usize) -> Value {
        let line = self
            .lines
            .get(at)
            .filter(|(_, len)| *len as usize <= PAGE_BYTES)
            .and_then(|(start, len)| self.bytes.get(*start as usize..(*start + *len) as usize));
        line.and_then(|line| serde_json::from_slice::<Value>(line).ok())
            .filter(|line| {
                matches!(line.get("type").and_then(Value::as_str), Some("user" | "assistant"))
            })
            .unwrap_or(Value::Null)
    }

    /// The page `start..end` cut to `PARSE_BYTES` of source (a forward page keeps its first lines,
    /// one read back its last, at least one), and where its replay starts: up to `REPLAY_BEFORE`
    /// lines before it, within the same budget.
    fn bounded(&self, mut start: usize, mut end: usize, forward: bool) -> (usize, usize, usize) {
        let mut bytes: usize = (start..end).map(|at| self.len_of(at)).sum();
        while bytes > PARSE_BYTES && end - start > 1 {
            if forward {
                end -= 1;
                bytes -= self.len_of(end);
            } else {
                bytes -= self.len_of(start);
                start += 1;
            }
        }
        let mut from = start;
        while from > 0
            && start - from < REPLAY_BEFORE
            && bytes + self.len_of(from - 1) <= PARSE_BYTES
        {
            from -= 1;
            bytes += self.len_of(from);
        }
        (start, end, from)
    }
}

/// The transcript, and whether only its end was read (it was longer than `FILE_BYTES`, or had more
/// than `INDEXED_LINES` lines). Blocking.
fn read(
    sessions: &[(PathBuf, String)],
    run: Option<&str>,
    agent: &str,
) -> Result<(Text, bool), RpcError> {
    for (home, session) in sessions {
        let Some(own) = crate::adopt::find_claude(home, session) else { continue };
        let Some(project) = own.parent() else { continue };
        let mut parts: Vec<OsString> = vec![session.into(), "subagents".into()];
        if let Some(run) = run {
            parts.extend(["workflows".into(), run.into()]);
        }
        parts.push(format!("agent-{agent}.jsonl").into());
        if let Ok(file) = super::media_read::open_regular_below(project, &parts) {
            return lines_of(file);
        }
    }
    Err(refused("transcript.missing", "no such transcript"))
}

/// The opened transcript's lines, from its last `FILE_BYTES` when it is longer and its last
/// `INDEXED_LINES` lines when it has more, and whether either cut it. A line the byte cut fell
/// inside is left out; one it fell just before is kept.
fn lines_of(mut file: File) -> Result<(Text, bool), RpcError> {
    use std::io::{Read, Seek, SeekFrom};
    let unreadable = |_| refused("transcript.unreadable", "the transcript could not be read");
    let size = file.metadata().map_err(unreadable)?.len();
    let truncated = size > FILE_BYTES;
    // One byte before the window says whether its first line is whole.
    let lead = u64::from(truncated);
    if truncated {
        file.seek(SeekFrom::Start(size - FILE_BYTES - lead)).map_err(unreadable)?;
    }
    let mut bytes = Vec::new();
    file.take(FILE_BYTES + lead).read_to_end(&mut bytes).map_err(unreadable)?;
    let mut at = 0;
    if truncated {
        at = match bytes.first() {
            Some(b'\n') => 1,
            _ => bytes.iter().position(|b| *b == b'\n').map_or(bytes.len(), |end| end + 1),
        };
    }
    // The last `INDEXED_LINES` lines at most: a file of millions of short lines keeps a bounded index.
    let mut lines = std::collections::VecDeque::new();
    let mut dropped = false;
    while at < bytes.len() {
        let end = bytes.get(at..).and_then(|rest| rest.iter().position(|b| *b == b'\n'));
        let end = end.map_or(bytes.len(), |n| at + n);
        if end > at {
            let (start, len) = (u32::try_from(at), u32::try_from(end - at));
            if let (Ok(start), Ok(len)) = (start, len) {
                lines.push_back((start, len));
            }
            if lines.len() > INDEXED_LINES {
                lines.pop_front();
                dropped = true;
            }
        }
        at = end + 1;
    }
    Ok((Text { bytes, lines: lines.into() }, truncated || dropped))
}

/// The stub a line goes as when no reply could carry it: what it left out, and how much.
fn omitted(bytes: usize) -> Value {
    json!({"sessionUpdate": "omitted",
        "_meta": {"acpmux": {"omitted": {"bytes": bytes, "reason": "too_large"}}}})
}

/// The lines a page holds of `total`: `limit` from `after` on, else `limit` before `before`.
fn window(
    total: usize,
    limit: usize,
    before: Option<usize>,
    after: Option<usize>,
) -> (usize, usize) {
    match after {
        Some(after) => (after.min(total), after.saturating_add(limit).min(total)),
        None => {
            let end = before.unwrap_or(total).min(total);
            (end.saturating_sub(limit), end)
        }
    }
}

/// The page cut to about `PAGE_BYTES` of updates, at least one line: a page read forward
/// (`after`) keeps its first lines, one read back its last, so neither cursor skips a line. A line
/// whose updates alone pass `PAGE_BYTES` goes as one `omitted` stub saying how much it held, so a
/// reply always fits a message and its cursors always move on.
fn fit(
    per_line: Vec<Vec<Value>>,
    start: usize,
    end: usize,
    forward: bool,
) -> (usize, usize, Vec<Value>) {
    let per_line: Vec<Vec<Value>> = per_line
        .into_iter()
        .map(|updates| {
            let bytes: usize = updates.iter().map(|u| u.to_string().len()).sum();
            if bytes <= PAGE_BYTES { updates } else { vec![omitted(bytes)] }
        })
        .collect();
    let sizes: Vec<usize> =
        per_line.iter().map(|ups| ups.iter().map(|u| u.to_string().len()).sum()).collect();
    let mut kept = 0;
    let mut size = 0;
    let order: Box<dyn Iterator<Item = &usize>> =
        if forward { Box::new(sizes.iter()) } else { Box::new(sizes.iter().rev()) };
    for line in order {
        if kept > 0 && size + line > PAGE_BYTES {
            break;
        }
        size += line;
        kept += 1;
    }
    let (start, end, skip) =
        if forward { (start, start + kept, 0) } else { (end - kept, end, per_line.len() - kept) };
    let updates = per_line.into_iter().skip(skip).take(kept).flatten().collect();
    (start, end, updates)
}

#[cfg(test)]
mod tests;
