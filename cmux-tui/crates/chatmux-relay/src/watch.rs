//! fs_watch stream family (relay wire v6): `fs_watch_open` starts a
//! recursive, gitignore-aware watch under a scoped root and streams
//! debounced `fs_watch_event` frames until `fs_watch_close` or the socket
//! drops. Designed like the pty_* frames: errors are typed
//! (`fs_watch_error`), never socket closes. Backend: the `notify` crate
//! (FSEvents/inotify/ReadDirectoryChanges).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};

use crate::relay_wire as wire;
use crate::workspace::{Refusal, Scope, WORKSPACE_FRAME_VERSION, slash_path};

/// Concurrent watch sessions per machine (WORKSPACE_WATCH_MAX_SESSIONS).
pub const WATCH_MAX_SESSIONS: usize = 16;
/// Most changes one event frame may carry (WORKSPACE_WATCH_MAX_CHANGES); a
/// burst past this sets `overflow` and the client re-pulls the tree.
pub const WATCH_MAX_CHANGES: usize = 256;

/// Quiet window before a burst flushes, and the ceiling one flush may lag
/// behind the first change in its burst.
const DEBOUNCE_QUIET: Duration = Duration::from_millis(150);
const DEBOUNCE_MAX_LATENCY: Duration = Duration::from_millis(500);

type Sessions = Arc<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>>;

pub struct WatchRegistry {
    outbound: UnboundedSender<String>,
    sessions: Sessions,
}

impl Drop for WatchRegistry {
    fn drop(&mut self) {
        // The socket died with this registry; the Worker re-opens watches
        // on the next connection.
        if let Ok(mut sessions) = self.sessions.lock() {
            for (_, task) in sessions.drain() {
                task.abort();
            }
        }
    }
}

fn watch_error_frame(watch_id: &str, code: wire::WorkspaceErrorCode, message: &str) -> String {
    serde_json::to_string(&wire::RelayFsWatchError {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagFsWatchError::FsWatchError,
        watch_id: watch_id.to_owned(),
        code,
        message: Some(message.to_owned()),
    })
    .unwrap_or_else(|_| String::new())
}

impl WatchRegistry {
    pub fn new(outbound: UnboundedSender<String>) -> WatchRegistry {
        WatchRegistry { outbound, sessions: Arc::new(Mutex::new(HashMap::new())) }
    }

    pub fn refuse(&self, watch_id: &str, code: wire::WorkspaceErrorCode, message: &str) {
        let _ = self.outbound.send(watch_error_frame(watch_id, code, message));
    }

    pub fn close(&self, watch_id: &str) {
        if let Ok(mut sessions) = self.sessions.lock()
            && let Some(task) = sessions.remove(watch_id)
        {
            task.abort();
        }
    }

    /// Resolve + scope the root, answer `fs_watch_opened`, then stream.
    /// Watching is read-only: observe trust is admitted.
    pub fn open(&self, frame: wire::RelayFsWatchOpen, local_roots: Option<&[String]>) {
        let watch_id = frame.watch_id.clone();
        let root = match watch_root(&frame, local_roots) {
            Ok(root) => root,
            Err(refusal) => {
                self.refuse(&watch_id, refusal.code, &refusal.message);
                return;
            }
        };
        let at_capacity = self
            .sessions
            .lock()
            .map(|sessions| sessions.len() >= WATCH_MAX_SESSIONS)
            .unwrap_or(true);
        if at_capacity {
            self.refuse(
                &watch_id,
                wire::WorkspaceErrorCode::WatchLimit,
                &format!("this machine already streams {WATCH_MAX_SESSIONS} watches"),
            );
            return;
        }
        let opened = serde_json::to_string(&wire::RelayFsWatchOpened {
            version: WORKSPACE_FRAME_VERSION,
            r#type: wire::TagFsWatchOpened::FsWatchOpened,
            watch_id: watch_id.clone(),
            root: root.to_string_lossy().into_owned(),
        })
        .unwrap_or_else(|_| String::new());
        let _ = self.outbound.send(opened);
        let outbound = self.outbound.clone();
        let sessions = Arc::clone(&self.sessions);
        let task_id = watch_id.clone();
        let task = tokio::spawn(async move {
            run_watch(&task_id, &root, &outbound).await;
            if let Ok(mut sessions) = sessions.lock() {
                sessions.remove(&task_id);
            }
        });
        if let Ok(mut sessions) = self.sessions.lock()
            && let Some(previous) = sessions.insert(watch_id, task)
        {
            previous.abort();
        }
    }
}

fn watch_root(
    frame: &wire::RelayFsWatchOpen,
    local_roots: Option<&[String]>,
) -> Result<PathBuf, Refusal> {
    let scope = Scope::build(frame.allowed_roots.as_deref(), local_roots)?;
    let root = match &frame.root {
        Some(raw) => scope.resolve(raw, false)?,
        None => scope.existing_workdir()?,
    };
    if root.is_dir() {
        Ok(root)
    } else {
        Err(Refusal::new(
            wire::WorkspaceErrorCode::NotFound,
            format!("{} is not a directory", root.display()),
        ))
    }
}

// ---------------------------------------------------------------------------
// The watch task: notify events -> debounce -> gitignore filter -> frames
// ---------------------------------------------------------------------------

async fn run_watch(watch_id: &str, root: &Path, outbound: &UnboundedSender<String>) {
    use notify::Watcher as _;
    let (event_tx, mut event_rx) = unbounded_channel::<Result<notify::Event, notify::Error>>();
    let mut watcher = match notify::recommended_watcher(move |event| {
        let _ = event_tx.send(event);
    }) {
        Ok(watcher) => watcher,
        Err(error) => {
            let _ = outbound.send(watch_error_frame(
                watch_id,
                wire::WorkspaceErrorCode::Failed,
                &format!("could not start the watcher: {error}"),
            ));
            return;
        }
    };
    if let Err(error) = watcher.watch(root, notify::RecursiveMode::Recursive) {
        let _ = outbound.send(watch_error_frame(
            watch_id,
            wire::WorkspaceErrorCode::Failed,
            &format!("could not watch {}: {error}", root.display()),
        ));
        return;
    }
    let mut matcher = build_ignore_matcher(root);
    loop {
        let Some(first) = event_rx.recv().await else { break };
        let mut burst = vec![first];
        drain_burst(&mut event_rx, &mut burst).await;
        let mut fatal: Option<notify::Error> = None;
        let mut overflow = false;
        let mut changes: Vec<wire::FsWatchChange> = Vec::new();
        let mut change_index: HashMap<String, usize> = HashMap::new();
        let mut saw_ignore_file = false;
        for event in burst {
            match event {
                Ok(event) => {
                    if event.need_rescan() {
                        overflow = true;
                    }
                    collect_changes(
                        root,
                        &matcher,
                        &event,
                        &mut changes,
                        &mut change_index,
                        &mut saw_ignore_file,
                    );
                }
                Err(error) => fatal = Some(error),
            }
        }
        if changes.len() > WATCH_MAX_CHANGES {
            changes.truncate(WATCH_MAX_CHANGES);
            overflow = true;
        }
        if !changes.is_empty() || overflow {
            let frame = serde_json::to_string(&wire::RelayFsWatchEvent {
                version: WORKSPACE_FRAME_VERSION,
                r#type: wire::TagFsWatchEvent::FsWatchEvent,
                watch_id: watch_id.to_owned(),
                changes,
                overflow: overflow.then_some(true),
            })
            .unwrap_or_else(|_| String::new());
            if outbound.send(frame).is_err() {
                break;
            }
        }
        if saw_ignore_file {
            matcher = build_ignore_matcher(root);
        }
        if let Some(error) = fatal {
            let _ = outbound.send(watch_error_frame(
                watch_id,
                wire::WorkspaceErrorCode::Failed,
                &format!("the watcher died: {error}"),
            ));
            break;
        }
    }
    drop(watcher);
}

async fn drain_burst(
    event_rx: &mut UnboundedReceiver<Result<notify::Event, notify::Error>>,
    burst: &mut Vec<Result<notify::Event, notify::Error>>,
) {
    let flush_at = tokio::time::Instant::now() + DEBOUNCE_MAX_LATENCY;
    loop {
        let now = tokio::time::Instant::now();
        if now >= flush_at {
            return;
        }
        let quiet = DEBOUNCE_QUIET.min(flush_at - now);
        match tokio::time::timeout(quiet, event_rx.recv()).await {
            Ok(Some(event)) => burst.push(event),
            Ok(None) | Err(_) => return,
        }
    }
}

/// Gitignore filter matching fs_tree's semantics: every .gitignore/.ignore
/// under the root (plus git's own exclude file), .git itself always
/// filtered separately. Rebuilt when an ignore file changes.
fn build_ignore_matcher(root: &Path) -> ignore::gitignore::Gitignore {
    let mut builder = ignore::gitignore::GitignoreBuilder::new(root);
    let exclude = root.join(".git/info/exclude");
    if exclude.is_file() {
        let _ = builder.add(exclude);
    }
    let mut walker = ignore::WalkBuilder::new(root);
    walker
        .hidden(false)
        .follow_links(false)
        .filter_entry(|entry| entry.file_name() != std::ffi::OsStr::new(".git"));
    let mut seen = 0_usize;
    for entry in walker.build() {
        let Ok(entry) = entry else { continue };
        seen += 1;
        if seen > 50_000 {
            break;
        }
        let name = entry.file_name();
        if (name == ".gitignore" || name == ".ignore")
            && entry.file_type().is_some_and(|kind| kind.is_file())
        {
            let _ = builder.add(entry.path());
        }
    }
    builder.build().unwrap_or_else(|_| ignore::gitignore::Gitignore::empty())
}

fn relative_watch_path(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    if relative.components().any(|part| part.as_os_str() == ".git") {
        return None;
    }
    let text = slash_path(relative);
    if text.is_empty() { None } else { Some(text) }
}

fn record(
    changes: &mut Vec<wire::FsWatchChange>,
    change_index: &mut HashMap<String, usize>,
    change: wire::FsWatchChange,
) {
    match change_index.get(&change.path) {
        Some(&index) => {
            let existing = &mut changes[index];
            // Merge within one burst: created-then-modified stays created;
            // anything ending deleted is deleted; a rename target wins.
            existing.kind = match (existing.kind, change.kind) {
                (wire::FsWatchChangeKind::Created, wire::FsWatchChangeKind::Modified) => {
                    wire::FsWatchChangeKind::Created
                }
                (_, kind) => kind,
            };
            if change.old_path.is_some() {
                existing.old_path = change.old_path;
            }
        }
        None => {
            change_index.insert(change.path.clone(), changes.len());
            changes.push(change);
        }
    }
}

fn collect_changes(
    root: &Path,
    matcher: &ignore::gitignore::Gitignore,
    event: &notify::Event,
    changes: &mut Vec<wire::FsWatchChange>,
    change_index: &mut HashMap<String, usize>,
    saw_ignore_file: &mut bool,
) {
    use notify::EventKind;
    use notify::event::{ModifyKind, RenameMode};
    let admit = |path: &Path, relative: &str| -> bool {
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        if name == ".gitignore" || name == ".ignore" {
            return true;
        }
        let is_dir = path.is_dir();
        !matcher.matched_path_or_any_parents(relative, is_dir).is_ignore()
    };
    let mut push = |path: &Path, kind: wire::FsWatchChangeKind, old: Option<&Path>| {
        let Some(relative) = relative_watch_path(root, path) else { return };
        if path.file_name().is_some_and(|name| name == ".gitignore" || name == ".ignore") {
            *saw_ignore_file = true;
        }
        if !admit(path, &relative) {
            return;
        }
        let old_path = old.and_then(|old| relative_watch_path(root, old));
        record(changes, change_index, wire::FsWatchChange { path: relative, kind, old_path });
    };
    match event.kind {
        EventKind::Create(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Created, None);
            }
        }
        EventKind::Remove(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Deleted, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) if event.paths.len() == 2 => {
            push(&event.paths[1], wire::FsWatchChangeKind::Renamed, Some(&event.paths[0]));
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::From)) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Deleted, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Created, None);
            }
        }
        EventKind::Modify(ModifyKind::Name(_)) | EventKind::Any | EventKind::Other => {
            // FSEvents reports both halves of a rename as Name(Any) with
            // one path each: probe the disk to tell which half this is.
            for path in &event.paths {
                let kind = if path.symlink_metadata().is_ok() {
                    wire::FsWatchChangeKind::Created
                } else {
                    wire::FsWatchChangeKind::Deleted
                };
                push(path, kind, None);
            }
        }
        EventKind::Modify(_) => {
            for path in &event.paths {
                push(path, wire::FsWatchChangeKind::Modified, None);
            }
        }
        EventKind::Access(_) => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn scratch(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("chatmux-watch-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("scratch dir");
        std::fs::canonicalize(&path).expect("canonical scratch")
    }

    fn open_frame(watch_id: &str, root: &Path) -> wire::RelayFsWatchOpen {
        wire::RelayFsWatchOpen {
            version: WORKSPACE_FRAME_VERSION,
            r#type: wire::TagFsWatchOpen::FsWatchOpen,
            watch_id: watch_id.to_owned(),
            root: None,
            actor_id: "user_1".to_owned(),
            trust: wire::TrustLevel::Observe,
            allowed_roots: Some(vec![root.to_string_lossy().into_owned()]),
        }
    }

    async fn next_frame(rx: &mut UnboundedReceiver<String>, what: &str) -> Value {
        let text = tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .unwrap_or_else(|_| panic!("no {what} frame within 10s"))
            .expect("channel open");
        serde_json::from_str(&text).expect("valid frame json")
    }

    #[tokio::test]
    async fn watch_streams_debounced_changes_for_a_write() {
        let root = scratch("stream");
        std::fs::write(root.join("seed.txt"), "seed\n").expect("seed");
        let (tx, mut rx) = unbounded_channel::<String>();
        let registry = WatchRegistry::new(tx);
        registry.open(open_frame("w1", &root), None);
        let opened = next_frame(&mut rx, "opened").await;
        assert_eq!(opened["type"], "fs_watch_opened");
        assert_eq!(opened["watchId"], "w1");
        assert_eq!(opened["root"].as_str(), root.to_str());
        // Give the watcher backend a beat to arm before mutating.
        tokio::time::sleep(Duration::from_millis(400)).await;
        std::fs::write(root.join("fresh.txt"), "hello\n").expect("write");
        let event = loop {
            let frame = next_frame(&mut rx, "change").await;
            assert_eq!(frame["type"], "fs_watch_event");
            let changes = frame["changes"].as_array().expect("changes").clone();
            if changes.iter().any(|change| change["path"] == "fresh.txt") {
                break frame;
            }
        };
        assert_eq!(event["watchId"], "w1");
        registry.close("w1");
    }

    #[tokio::test]
    async fn watch_refuses_typed_and_respects_the_session_cap() {
        let root = scratch("refuse");
        let (tx, mut rx) = unbounded_channel::<String>();
        let registry = WatchRegistry::new(tx);
        // A root outside the allowed list refuses path_forbidden.
        let mut outside = open_frame("w-out", &root);
        outside.root = Some("/etc".to_owned());
        registry.open(outside, None);
        let refusal = next_frame(&mut rx, "refusal").await;
        assert_eq!(refusal["type"], "fs_watch_error");
        assert_eq!(refusal["code"], "path_forbidden");
        // Session cap: the 17th watch refuses watch_limit.
        for index in 0..WATCH_MAX_SESSIONS {
            registry.open(open_frame(&format!("w{index}"), &root), None);
            let opened = next_frame(&mut rx, "opened").await;
            assert_eq!(opened["type"], "fs_watch_opened", "watch {index}");
        }
        registry.open(open_frame("w-past-cap", &root), None);
        let capped = next_frame(&mut rx, "watch_limit").await;
        assert_eq!(capped["type"], "fs_watch_error");
        assert_eq!(capped["code"], "watch_limit");
    }

    #[test]
    fn bursts_merge_and_cap_with_overflow() {
        let root = scratch("merge");
        let matcher = build_ignore_matcher(&root);
        let mut changes = Vec::new();
        let mut index = HashMap::new();
        let mut saw_ignore = false;
        let created =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join("a.txt"));
        let modified = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Data(notify::event::DataChange::Content),
        ))
        .add_path(root.join("a.txt"));
        collect_changes(&root, &matcher, &created, &mut changes, &mut index, &mut saw_ignore);
        collect_changes(&root, &matcher, &modified, &mut changes, &mut index, &mut saw_ignore);
        assert_eq!(changes.len(), 1, "one path, one change");
        assert_eq!(changes[0].kind, wire::FsWatchChangeKind::Created, "created wins");
        // .git churn never leaks.
        let git_noise =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join(".git/index.lock"));
        collect_changes(&root, &matcher, &git_noise, &mut changes, &mut index, &mut saw_ignore);
        assert_eq!(changes.len(), 1);
        // A rename pair carries oldPath.
        let renamed = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Name(notify::event::RenameMode::Both),
        ))
        .add_path(root.join("a.txt"))
        .add_path(root.join("b.txt"));
        collect_changes(&root, &matcher, &renamed, &mut changes, &mut index, &mut saw_ignore);
        let rename = changes.iter().find(|change| change.path == "b.txt").expect("rename");
        assert_eq!(rename.kind, wire::FsWatchChangeKind::Renamed);
        assert_eq!(rename.old_path.as_deref(), Some("a.txt"));
    }

    #[test]
    fn gitignored_paths_are_filtered_but_ignore_files_pass() {
        let root = scratch("ignore");
        std::fs::write(root.join(".gitignore"), "dist/\n").expect("gitignore");
        std::fs::create_dir_all(root.join(".git")).expect("fake repo marker");
        std::fs::create_dir_all(root.join("dist")).expect("dist");
        let matcher = build_ignore_matcher(&root);
        let mut changes = Vec::new();
        let mut index = HashMap::new();
        let mut saw_ignore = false;
        let ignored =
            notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
                .add_path(root.join("dist/bundle.js"));
        collect_changes(&root, &matcher, &ignored, &mut changes, &mut index, &mut saw_ignore);
        assert!(changes.is_empty(), "gitignored churn stays quiet: {changes:?}");
        let gitignore_edit = notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Data(notify::event::DataChange::Content),
        ))
        .add_path(root.join(".gitignore"));
        collect_changes(
            &root,
            &matcher,
            &gitignore_edit,
            &mut changes,
            &mut index,
            &mut saw_ignore,
        );
        assert_eq!(changes.len(), 1, "the ignore file itself reports");
        assert!(saw_ignore, "and schedules a matcher rebuild");
    }
}
