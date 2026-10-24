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
//! A run started before the chat's Claude session forked (an earlier session id) is under that
//! session's folder, so a run not under the chat's own is looked for under its project's other
//! sessions.
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
use std::path::Path;

/// Lines a page holds unless the request asks for fewer, and the most it may ask for.
const PAGE_LINES: usize = 200;
const MAX_LINES: usize = 500;
/// The most of a transcript read.
const FILE_BYTES: u64 = 32 << 20;
/// About the most a page's updates hold, serialized.
const PAGE_BYTES: usize = 4 << 20;

/// Lines before a page replayed with it, so a call there pairs with its result on the page.
const REPLAY_BEFORE: usize = 1000;

/// Transcript reads running at once on this daemon: each replays a transcript, which is CPU work.
static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

/// The `initialize` feature of a daemon that serves `_acpmux/subagent_transcript`; a peer that
/// does not list it is never sent one (`peer_forward.rs`).
pub const FEATURE: &str = "subagentTranscript";

pub(crate) async fn handle(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
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
    let session_id = meta
        .agent_session_id
        .clone()
        .filter(|id| plain_id(id))
        .ok_or_else(|| refused("transcript.none", "the chat has no agent session yet"))?;
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
    let number =
        |key: &str| params.get(key).and_then(Value::as_u64).and_then(|v| usize::try_from(v).ok());
    let limit = number("limit").unwrap_or(PAGE_LINES).clamp(1, MAX_LINES);
    let (before, after) = (number("before"), number("after"));
    let _turn = READS.acquire().await.map_err(|e| RpcError::internal(e.to_string()))?;
    let (lines, truncated) =
        tokio::task::spawn_blocking(move || read(&home, &session_id, run.as_deref(), &agent))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))??;
    let total = lines.len();
    let (start, end) = window(total, limit, before, after);
    // Replayed off the runtime: a page and the lines before it are CPU work.
    let from = start.saturating_sub(REPLAY_BEFORE);
    let replayed: Vec<Value> = lines.into_iter().take(end).skip(from).collect();
    let per_line = tokio::task::spawn_blocking(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .map_err(|e| RpcError::internal(e.to_string()))?;
        Ok::<_, RpcError>(runtime.block_on(crate::claude_stdio::agent_transcript::replay(
            &replayed,
            start - from,
            from == 0 && !truncated,
        )))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))??;
    let (start, end, updates) = fit(per_line, start, end, after.is_some());
    Ok(json!({"updates": updates, "lines": total, "start": start, "end": end,
        "truncated": truncated}))
}

/// An id that names one folder or file and nothing else: ASCII letters, digits, `-` and `_`.
fn plain_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The transcript's message lines, and whether it was longer than `FILE_BYTES`. Blocking.
fn read(
    home: &Path,
    session: &str,
    run: Option<&str>,
    agent: &str,
) -> Result<(Vec<Value>, bool), RpcError> {
    let missing = || refused("transcript.missing", "no such transcript");
    let own = crate::adopt::find_claude(home, session).ok_or_else(missing)?;
    let project = own.parent().ok_or_else(missing)?;
    let mut sessions = vec![session.to_owned()];
    if run.is_some() {
        let mut others: Vec<String> = std::fs::read_dir(project)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name != session && plain_id(name))
            .collect();
        others.sort();
        sessions.extend(others);
    }
    for folder in sessions {
        let mut parts: Vec<OsString> = vec![folder.into(), "subagents".into()];
        if let Some(run) = run {
            parts.extend(["workflows".into(), run.into()]);
        }
        parts.push(format!("agent-{agent}.jsonl").into());
        if let Ok(file) = super::media_read::open_regular_below(project, &parts) {
            return lines_of(file);
        }
    }
    Err(missing())
}

/// The `user` and `assistant` lines of the opened transcript, from its last `FILE_BYTES` when
/// it is longer (the first, cut line left out), and whether it was.
fn lines_of(mut file: File) -> Result<(Vec<Value>, bool), RpcError> {
    use std::io::{Read, Seek, SeekFrom};
    let unreadable = |_| refused("transcript.unreadable", "the transcript could not be read");
    let size = file.metadata().map_err(unreadable)?.len();
    let truncated = size > FILE_BYTES;
    if truncated {
        file.seek(SeekFrom::Start(size - FILE_BYTES)).map_err(unreadable)?;
    }
    let mut bytes = Vec::new();
    file.take(FILE_BYTES).read_to_end(&mut bytes).map_err(unreadable)?;
    let lines = bytes
        .split(|b| *b == b'\n')
        .skip(usize::from(truncated))
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .filter(|line| {
            matches!(line.get("type").and_then(Value::as_str), Some("user" | "assistant"))
        })
        .collect();
    Ok((lines, truncated))
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
/// (`after`) keeps its first lines, one read back its last, so neither cursor skips a line.
fn fit(
    per_line: Vec<Vec<Value>>,
    start: usize,
    end: usize,
    forward: bool,
) -> (usize, usize, Vec<Value>) {
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
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A Claude store with chat session `s1` (forked from `s0`) in project `-work`.
    fn store(name: &str) -> PathBuf {
        let home = std::env::temp_dir()
            .join(format!("acpmux-subagent-transcript-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let project = home.join("projects/-work");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("s1.jsonl"), "{}\n").unwrap();
        home
    }

    fn write(dir: &Path, agent: &str, lines: usize) {
        std::fs::create_dir_all(dir).unwrap();
        let mut text = String::new();
        text.push_str(&json!({"type": "user", "message": {"content": "Review PR #1"}}).to_string());
        text.push('\n');
        text.push_str(&json!({"type": "attachment"}).to_string());
        text.push('\n');
        for n in 1..lines {
            let line = json!({"type": "assistant", "message": {"content": [{"type": "text", "text": format!("step {n}")}]}});
            text.push_str(&line.to_string());
            text.push('\n');
        }
        std::fs::write(dir.join(format!("agent-{agent}.jsonl")), text).unwrap();
    }

    #[test]
    fn a_workflow_agent_is_read_under_the_chats_session_or_one_it_forked_from() {
        let home = store("where");
        let project = home.join("projects/-work");
        write(&project.join("s1/subagents/workflows/wf_new"), "a01", 3);
        write(&project.join("s0/subagents/workflows/wf_old"), "a02", 2);
        write(&project.join("s1/subagents"), "b01", 2);
        assert_eq!(read(&home, "s1", Some("wf_new"), "a01").unwrap().0.len(), 3);
        assert_eq!(read(&home, "s1", Some("wf_old"), "a02").unwrap().0.len(), 2);
        assert_eq!(read(&home, "s1", None, "b01").unwrap().0.len(), 2);
        // A background agent is the chat's own: never another session's.
        write(&project.join("s0/subagents"), "b02", 2);
        assert!(read(&home, "s1", None, "b02").is_err());
        let _ = std::fs::remove_dir_all(home);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_in_the_store_is_never_followed() {
        let home = store("links");
        let project = home.join("projects/-work");
        write(&home.join("elsewhere"), "a01", 2);
        let runs = project.join("s1/subagents/workflows/wf_x");
        std::fs::create_dir_all(&runs).unwrap();
        std::os::unix::fs::symlink(
            home.join("elsewhere/agent-a01.jsonl"),
            runs.join("agent-a01.jsonl"),
        )
        .unwrap();
        std::os::unix::fs::symlink(
            home.join("elsewhere"),
            project.join("s1/subagents/workflows/wf_y"),
        )
        .unwrap();
        assert!(read(&home, "s1", Some("wf_x"), "a01").is_err());
        assert!(read(&home, "s1", Some("wf_y"), "a01").is_err());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn ids_are_plain_names() {
        for bad in ["", "..", "a/b", "a.b", "a\\b", &"x".repeat(129)] {
            assert!(!plain_id(bad), "{bad}");
        }
        assert!(plain_id("a013d7b1c450e54d3") && plain_id("01a16c41-5f18-7b41"));
    }

    #[test]
    fn pages_walk_back_and_forward_without_skipping_a_line() {
        assert_eq!(window(10, 4, None, None), (6, 10));
        assert_eq!(window(10, 4, Some(6), None), (2, 6));
        assert_eq!(window(10, 4, Some(2), None), (0, 2));
        assert_eq!(window(10, 4, None, Some(8)), (8, 10));
        assert_eq!(window(10, 4, None, Some(12)), (10, 10));
        let big = |n: usize| vec![json!({"text": "x".repeat(n)})];
        let lines = vec![big(3 << 20), big(3 << 20), big(10)];
        // Read back: the newest lines that fit; the older one is the next page's.
        let (start, end, updates) = fit(lines.clone(), 4, 7, false);
        assert_eq!((start, end, updates.len()), (5, 7, 2));
        // Read forward: the oldest lines that fit; the next read starts where this one ended.
        let (start, end, updates) = fit(lines, 4, 7, true);
        assert_eq!((start, end, updates.len()), (4, 5, 1));
    }

    #[test]
    fn a_long_transcript_is_read_from_its_end() {
        let home = store("long");
        let dir = home.join("projects/-work/s1/subagents");
        std::fs::create_dir_all(&dir).unwrap();
        let line = json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "x".repeat(1 << 20)}]}}).to_string();
        let text: String = (0..40).map(|_| format!("{line}\n")).collect();
        std::fs::write(dir.join("agent-b09.jsonl"), text).unwrap();
        let (lines, truncated) = read(&home, "s1", None, "b09").unwrap();
        assert!(truncated);
        assert!(lines.len() < 40 && lines.len() >= 30, "{}", lines.len());
        let _ = std::fs::remove_dir_all(home);
    }
}
