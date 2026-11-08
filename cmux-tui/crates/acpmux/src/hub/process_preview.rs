//! Part of `processes.rs`. A running background process's preview: the
//! loopback URL a dev server (`npm run dev`, `cargo run`, `rails s`) prints
//! in its own output, once a TCP connect to that port on loopback is
//! accepted. The record carries it as `preview: {url, port}`
//! (`docs/background-processes.md`), and the chat shows it as a link.
//!
//! Only the chat's own processes are read, through the output files their
//! harness names (Claude Code's; Codex names none, so its processes get no
//! preview): no process scanning and no ports table (`cmux-local-url`). The
//! tap starts the watches (`tap.rs`), and the tap runs where the agent host
//! runs: this machine, whose files and loopback these are.
//!
//! A watch reads the file after each wait of [`CHECKS`], about a minute in
//! all. It stops at the first preview, once the process no longer runs, or
//! after its last check: a server that prints its URL later gets none.

use super::*;
use cmux_local_url::Candidate;
use std::sync::Weak;
use std::time::Duration;

/// The waits before each check of a watch: 59.5 s in all.
const CHECKS: [Duration; 7] = [
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(16),
    Duration::from_secs(28),
];

/// Ports one check probes, the newest printed first; each costs up to two
/// 150 ms connects.
const PROBES: usize = 8;

/// First path segments of an API rather than a page: such a URL previews `/`.
const API_SEGMENTS: [&str; 6] = ["api", "graphql", "rpc", "health", "healthz", "_health"];

/// The preview `candidate` gives: every host but `localhost` and `127.0.0.1`
/// (a wildcard `0.0.0.0`, `*` or `[::]`, and `[::1]`, which Puma prints) becomes
/// `localhost`, the loopback the chat's preview opens (URL+AgentPanePreview.swift
/// takes only those two), and an API path (`/api`, `/v1`, `/graphql`...) becomes `/`.
pub(super) fn preview_of(candidate: &Candidate) -> ProcessPreview {
    let (scheme, rest) = candidate.url.split_once("://").unwrap_or(("http", &*candidate.url));
    let path = rest.find('/').and_then(|at| rest.get(at..)).unwrap_or("/");
    let path = if api_path(path) { "/" } else { path };
    let host = match candidate.host.as_str() {
        "127.0.0.1" => "127.0.0.1",
        _ => "localhost",
    };
    let url = format!("{scheme}://{host}:{}{path}", candidate.port);
    ProcessPreview { url, port: candidate.port }
}

/// Whether `path`'s first segment names an API: one of [`API_SEGMENTS`], or a
/// version (`v1`, `v2`...).
fn api_path(path: &str) -> bool {
    let first = path.trim_start_matches('/').split(['/', '?', '#']).next().unwrap_or("");
    let first = first.to_ascii_lowercase();
    let digits = |n: &str| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit());
    first.strip_prefix('v').is_some_and(digits) || API_SEGMENTS.contains(&first.as_str())
}

/// The previews `output` names, the newest printed first, at most
/// [`PROBES`]: its terminal escapes are stripped first (Vite colors the port).
pub(super) fn previews_in(output: &[u8]) -> Vec<(u16, ProcessPreview)> {
    let text = String::from_utf8_lossy(output);
    let text = cmux_local_url::strip_ansi(&text);
    let mut found = cmux_local_url::candidates(&text);
    found.truncate(PROBES);
    found.iter().map(|c| (c.port, preview_of(c))).collect()
}

/// The first of `previews` whose port accepts a loopback connect. The
/// connects block, so they run on the blocking pool.
pub(super) async fn first_listening(
    previews: Vec<(u16, ProcessPreview)>,
) -> Option<ProcessPreview> {
    if previews.is_empty() {
        return None;
    }
    tokio::task::spawn_blocking(move || {
        previews
            .into_iter()
            .find(|(port, _)| cmux_local_url::probe(*port).is_some())
            .map(|(_, preview)| preview)
    })
    .await
    .ok()
    .flatten()
}

/// One check: the preview the last 64 KiB of `file` names and a connect
/// confirms, if any. An unreadable file has none.
async fn find_preview(file: &str) -> Option<ProcessPreview> {
    let (data, _, _) = read_output(Some(file), None, TAIL_DEFAULT).await.ok()?;
    first_listening(previews_in(&data)).await
}

/// A watch's checks (module docs). Stops at the first preview, when the
/// process no longer runs (or the hub or chat is gone), or after the last of
/// [`CHECKS`]: it never checks more than that many times.
async fn watch(hub: &Weak<Hub>, chat: &Weak<Session>, id: &str, file: &str) {
    for wait in CHECKS {
        tokio::time::sleep(wait).await;
        let (Some(hub), Some(chat)) = (hub.upgrade(), chat.upgrade()) else { return };
        if !hub.process_runs(&chat, id) {
            return;
        }
        if let Some(preview) = find_preview(file).await {
            hub.set_preview(&chat, id, preview);
            return;
        }
    }
}

impl Hub {
    /// Starts a preview watch for each of the session's running processes
    /// that has an output file, no preview and no watch yet (module docs).
    /// Called after each of its shell updates (`tap.rs`).
    pub(crate) fn watch_previews(self: &Arc<Self>, session: &Arc<Session>) {
        let start: Vec<(String, String)> = {
            let mut guard = self.process_table(session);
            let table = &mut *guard;
            let mut start = Vec::new();
            for &at in &table.running {
                let Some(p) = table.processes.get(at) else { continue };
                let Some(file) = p.output_file.as_ref().filter(|_| p.preview.is_none()) else {
                    continue;
                };
                if table.watching.insert(p.id.clone()) {
                    start.push((p.id.clone(), file.clone()));
                }
            }
            start
        };
        for (id, file) in start {
            let (hub, chat) = (Arc::downgrade(self), Arc::downgrade(session));
            tokio::spawn(async move {
                watch(&hub, &chat, &id, &file).await;
                // The watch is over: a later update may start another (none
                // does while the process keeps its preview).
                if let Some(chat) = chat.upgrade() {
                    chat.processes.lock().unwrap_or_else(|e| e.into_inner()).watching.remove(&id);
                }
            });
        }
    }

    /// An adopted host's processes, read again from the log (`rebuild_processes`), with a
    /// watch for each still running one that has no preview: a server whose watch ended with
    /// the daemon before it found one is read again (`hosts.rs` `recover_work`).
    pub(crate) fn recover_processes(self: &Arc<Self>, session: &Arc<Session>) {
        self.rebuild_processes(session);
        self.watch_previews(session);
    }

    /// Whether the process `id` still runs.
    fn process_runs(&self, session: &Session, id: &str) -> bool {
        self.process_table(session).find_id(id).is_some_and(|p| p.state == ProcessState::Running)
    }

    /// Records the preview of the process `id`, if it still runs and has
    /// none, as one logged `process_update` (the path `note_process` takes).
    fn set_preview(&self, session: &Session, id: &str, preview: ProcessPreview) {
        let process = {
            let mut table = self.process_table(session);
            let Some(at) = table.by_id.get(id).copied() else { return };
            let Some(p) = table.processes.get_mut(at) else { return };
            if p.state != ProcessState::Running || p.preview.is_some() {
                return;
            }
            p.preview = Some(preview);
            p.logged = false;
            table.log(at)
        };
        self.append(session, "mux", "process_update", json!({"process": process}));
    }
}
