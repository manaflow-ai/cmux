//! The launch snapshot (`launch-snapshot-v1`): a small read-only file with
//! the last settled tree (`list-workspaces`), the personal state
//! (`list-personal`) and the native frontend projections, next to the session registry, so a frontend can draw the
//! last known layout before it connects and then swap to live state. The
//! daemon never reads it back: it is a cache of the registry and the live
//! tree, never a second source of truth.
//!
//! The writer is event-driven. It sleeps on the event bus until the tree,
//! the layout, the personal state or a projection changes (a title change alone does not wake
//! it; titles are those of the last write), then writes once changes settle
//! (`settle` after the last one, `max_delay` after the first at the latest):
//! one computed deadline per burst and no timer while idle. Each write goes
//! to a temporary file that is renamed over the old one, owner-only.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::thread::JoinHandle;

use super::*;
use crate::MuxEventReceiver;

/// The file name inside the session's state directory.
pub const LAUNCH_SNAPSHOT_FILE: &str = "launch-snapshot.json";
const LAUNCH_SNAPSHOT_SCHEMA_VERSION: u32 = 1;
/// A snapshot larger than this drops its projections, then is not written.
const MAX_LAUNCH_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
/// Failed writes back off (a full disk must not turn into a write loop).
const WRITE_RETRY_INITIAL: Duration = Duration::from_secs(1);
const WRITE_RETRY_MAX: Duration = Duration::from_secs(60);

/// When the writer writes after a change.
#[derive(Debug, Clone, Copy)]
pub struct LaunchSnapshotTiming {
    /// Quiet time after the last change.
    pub settle: Duration,
    /// Longest wait after the first unwritten change, so a terminal whose
    /// title changes all the time still gets its layout written.
    pub max_delay: Duration,
}

impl Default for LaunchSnapshotTiming {
    fn default() -> Self {
        Self { settle: Duration::from_millis(500), max_delay: Duration::from_secs(3) }
    }
}

/// The writer thread. Dropping it stops the thread and clears the path from
/// `identify`.
pub struct LaunchSnapshotWriter {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    events: Arc<Mutex<MuxEventReceiver>>,
    writes: Arc<AtomicU64>,
    mux: Weak<Mux>,
    thread: Option<JoinHandle<()>>,
}

impl LaunchSnapshotWriter {
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Completed writes, for tests and diagnostics.
    pub fn writes(&self) -> u64 {
        self.writes.load(Ordering::Acquire)
    }

    /// Stop the thread and wait for it.
    pub fn stop(mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    fn signal_stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.events.lock().unwrap().close();
        if let Some(mux) = self.mux.upgrade() {
            mux.set_launch_snapshot_path(None);
        }
    }
}

impl Drop for LaunchSnapshotWriter {
    fn drop(&mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Start the writer with the default timing. None for a session without a
/// durable registry (nothing to relaunch into).
pub fn start_launch_snapshot_writer(
    mux: &Arc<Mux>,
) -> std::io::Result<Option<LaunchSnapshotWriter>> {
    start_launch_snapshot_writer_with(mux, LaunchSnapshotTiming::default())
}

pub fn start_launch_snapshot_writer_with(
    mux: &Arc<Mux>,
    timing: LaunchSnapshotTiming,
) -> std::io::Result<Option<LaunchSnapshotWriter>> {
    let Some(directory) = mux.session_state_directory() else { return Ok(None) };
    let path = directory.join(LAUNCH_SNAPSHOT_FILE);
    let stop = Arc::new(AtomicBool::new(false));
    let writes = Arc::new(AtomicU64::new(0));
    let events = Arc::new(Mutex::new(mux.subscribe_launch_snapshot()));
    let weak = Arc::downgrade(mux);
    let thread_path = path.clone();
    let thread_stop = stop.clone();
    let thread_writes = writes.clone();
    let shared_events = events.clone();
    let mut thread_events = events.lock().unwrap().clone();
    let thread =
        std::thread::Builder::new().name("mux-launch-snapshot".into()).spawn(move || {
            // Write once at start, so a relaunch finds the current layout even
            // if nothing changes while this daemon runs.
            let mut dirty_since = Some(Instant::now());
            let mut last_change =
                Instant::now().checked_sub(timing.settle).unwrap_or_else(Instant::now);
            let mut retry = WRITE_RETRY_INITIAL;
            let mut retry_at: Option<Instant> = None;
            loop {
                if thread_stop.load(Ordering::Acquire) {
                    break;
                }
                let now = Instant::now();
                let due = dirty_since.map(|first| {
                    let settled = last_change + timing.settle;
                    let latest = first + timing.max_delay;
                    let due = settled.min(latest);
                    retry_at.map_or(due, |retry_at| due.max(retry_at))
                });
                if let Some(due) = due
                    && now >= due
                {
                    let Some(mux) = weak.upgrade() else { break };
                    match write_launch_snapshot(&mux, &thread_path) {
                        Ok(()) => {
                            thread_writes.fetch_add(1, Ordering::AcqRel);
                            dirty_since = None;
                            retry = WRITE_RETRY_INITIAL;
                            retry_at = None;
                        }
                        Err(error) => {
                            mux.report_internal_diagnostic("launch snapshot not written");
                            eprintln!("cmux-tui: launch snapshot not written: {error:#}");
                            retry_at = Some(Instant::now() + retry);
                            retry = (retry * 2).min(WRITE_RETRY_MAX);
                        }
                    }
                    drop(mux);
                    continue;
                }
                let event = match due {
                    Some(due) => thread_events.recv_timeout(due.saturating_duration_since(now)),
                    None => thread_events.recv().map_err(|_| RecvTimeoutError::Disconnected),
                };
                match event {
                    Ok(_) => {
                        // Coalesce everything already queued into this change.
                        while thread_events.try_recv().is_ok() {}
                        last_change = Instant::now();
                        dirty_since.get_or_insert(last_change);
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => {
                        if thread_stop.load(Ordering::Acquire) {
                            break;
                        }
                        // The mailbox overflowed: resubscribe and write again.
                        let Some(mux) = weak.upgrade() else { break };
                        thread_events = mux.subscribe_launch_snapshot();
                        *shared_events.lock().unwrap() = thread_events.clone();
                        last_change = Instant::now();
                        dirty_since.get_or_insert(last_change);
                    }
                }
            }
        })?;
    mux.set_launch_snapshot_path(Some(path.clone()));
    Ok(Some(LaunchSnapshotWriter {
        path,
        stop,
        events,
        writes,
        mux: Arc::downgrade(mux),
        thread: Some(thread),
    }))
}

fn launch_snapshot_value(mux: &Mux, include_projections: bool) -> anyhow::Result<Value> {
    let tree = list_workspaces_reply(mux)?;
    let (registry_id, generation) = mux.registry_identity();
    // Rooms, pins and personal groups filter and group the sidebar, so a
    // provisional sidebar drawn without them regroups when live data lands.
    // Room default env can hold credentials; the sidebar does not need it.
    let personal = match mux.personal_snapshot() {
        Ok(personal) => {
            let mut personal = serde_json::to_value(personal)?;
            for profile in personal["profiles"].as_array_mut().into_iter().flatten() {
                if let Some(defaults) = profile["defaults"].as_object_mut() {
                    defaults.remove("env");
                }
            }
            personal
        }
        Err(error) => {
            eprintln!("cmux-tui: launch snapshot without personal state: {error:#}");
            Value::Null
        }
    };
    let projections = if include_projections {
        serde_json::to_value(mux.launch_snapshot_frontend_projections()?)?
    } else {
        json!([])
    };
    Ok(json!({
        "schema_version": LAUNCH_SNAPSHOT_SCHEMA_VERSION,
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "session": mux.session,
        "registry_id": registry_id,
        "generation": generation,
        "written_at_ms": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or_default(),
        "tree": tree,
        "personal": personal,
        "frontend_projections": projections,
    }))
}

fn write_launch_snapshot(mux: &Mux, path: &Path) -> anyhow::Result<()> {
    let mut bytes = serde_json::to_vec(&launch_snapshot_value(mux, true)?)?;
    if bytes.len() > MAX_LAUNCH_SNAPSHOT_BYTES {
        bytes = serde_json::to_vec(&launch_snapshot_value(mux, false)?)?;
    }
    anyhow::ensure!(
        bytes.len() <= MAX_LAUNCH_SNAPSHOT_BYTES,
        "launch snapshot exceeds {MAX_LAUNCH_SNAPSHOT_BYTES} bytes"
    );
    let directory = path.parent().context("launch snapshot path has no directory")?;
    let temporary = directory.join(format!("{LAUNCH_SNAPSHOT_FILE}.{}.tmp", std::process::id()));
    let result = (|| -> anyhow::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        drop(file);
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cmux-launch-snapshot-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ))
    }

    fn read_snapshot(path: &Path) -> Option<Value> {
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    /// Waits until the snapshot file satisfies `accept` (the writer settles
    /// on its own schedule; tests may wait).
    fn wait_for_snapshot(path: &Path, accept: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(snapshot) = read_snapshot(path)
                && accept(&snapshot)
            {
                return snapshot;
            }
            assert!(Instant::now() < deadline, "snapshot never matched: {:?}", read_snapshot(path));
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn workspace_names(snapshot: &Value) -> Vec<String> {
        snapshot["tree"]["workspaces"]
            .as_array()
            .map(|workspaces| {
                workspaces
                    .iter()
                    .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn cmux_next_launch_snapshot_follows_the_tree_after_it_settles() {
        let root = temp_root("tree");
        let mux =
            Mux::open_persistent("launch-snapshot-tree", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
            },
        )
        .unwrap()
        .expect("a persistent session has a snapshot path");
        let path = writer.path().to_path_buf();
        assert_eq!(path.file_name().unwrap(), "launch-snapshot.json");
        assert_eq!(mux.launch_snapshot_path().as_deref(), Some(path.as_path()));

        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert!(
            identify["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|capability| capability == LAUNCH_SNAPSHOT_CAPABILITY)
        );
        assert_eq!(identify["launch_snapshot_path"], json!(path.to_string_lossy()));

        let placement = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
        let snapshot = wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot).contains(&"first".to_string())
        });
        assert_eq!(snapshot["schema_version"], json!(1));
        assert_eq!(snapshot["app"], json!("cmux-tui"));
        assert_eq!(snapshot["session"], json!("launch-snapshot-tree"));
        let (registry_id, generation) = mux.registry_identity();
        assert_eq!(snapshot["registry_id"], json!(registry_id));
        assert_eq!(snapshot["generation"], json!(generation));
        assert!(snapshot["written_at_ms"].as_u64().is_some());
        // The tree is the list-workspaces reply, so frontends decode it with
        // the decoder they already have.
        let listed = run_command(&mux, json!({"cmd":"list-workspaces"}));
        assert_eq!(snapshot["tree"]["workspaces"], listed["workspaces"]);

        assert!(mux.rename_workspace(placement.workspace, "renamed".into()));
        wait_for_snapshot(&path, |snapshot| {
            workspace_names(snapshot) == vec!["renamed".to_string()]
        });

        // Written atomically: no temporary file is left next to it.
        let leftovers = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry.file_name().to_string_lossy().starts_with("launch-snapshot.json.")
            })
            .count();
        assert_eq!(leftovers, 0);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "tab titles and paths are private to the user");
        }

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_carries_frontend_projections() {
        let root = temp_root("projection");
        let mux =
            Mux::open_persistent("launch-snapshot-projection", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
            },
        )
        .unwrap()
        .unwrap();
        run_command(
            &mux,
            json!({
                "cmd":"put-frontend-projection",
                "frontend":"cmux-next",
                "scope":"personal",
                "subject_key":"windows",
                "schema_version":1,
                "projection":{"windows":[{"id":"w1","workspace_keys":[]}]},
                "origin":"test",
                "mutation_id":"launch-snapshot-projection",
            }),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["frontend_projections"].as_array().is_some_and(|projections| {
                projections.iter().any(|projection| projection["subject_key"] == "windows")
            })
        });
        let projection = snapshot["frontend_projections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|projection| projection["subject_key"] == "windows")
            .unwrap()
            .clone();
        assert_eq!(projection["frontend"], "cmux-next");
        assert_eq!(projection["scope"], "personal");
        assert_eq!(projection["projection"]["windows"][0]["id"], "w1");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_carries_personal_state() {
        let root = temp_root("personal");
        let mux =
            Mux::open_persistent("launch-snapshot-personal", SurfaceOptions::default(), &root)
                .unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            LaunchSnapshotTiming {
                settle: Duration::from_millis(50),
                max_delay: Duration::from_millis(500),
            },
        )
        .unwrap()
        .unwrap();
        wait_for_snapshot(writer.path(), |snapshot| snapshot["personal"].is_object());
        // A personal change alone (no tree change) rewrites the snapshot.
        run_command(
            &mux,
            json!({"cmd":"create-profile","profile":"prof_work","name":"Work",
                   "defaults":{"cwd":"/tmp","env":{"TOKEN":"secret"}}}),
        );
        let snapshot = wait_for_snapshot(writer.path(), |snapshot| {
            snapshot["personal"]["profiles"]
                .as_array()
                .is_some_and(|profiles| profiles.iter().any(|profile| profile["id"] == "prof_work"))
        });
        let work = snapshot["personal"]["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .find(|profile| profile["id"] == "prof_work")
            .unwrap();
        assert_eq!(work["defaults"]["cwd"], "/tmp");
        assert!(work["defaults"].get("env").is_none(), "room env stays out of the file");
        assert_eq!(
            snapshot["personal"]["personal_revision"],
            run_command(&mux, json!({"cmd":"list-personal"}))["personal_revision"]
        );

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_writes_nothing_while_nothing_changes() {
        let root = temp_root("idle");
        let mux =
            Mux::open_persistent("launch-snapshot-idle", SurfaceOptions::default(), &root).unwrap();
        let writer = start_launch_snapshot_writer_with(
            &mux,
            // A settle window well above one rename keeps the burst inside it
            // on a loaded runner.
            LaunchSnapshotTiming {
                settle: Duration::from_millis(250),
                max_delay: Duration::from_secs(2),
            },
        )
        .unwrap()
        .unwrap();
        // The first write happens at start, so a relaunch finds a file.
        wait_for_snapshot(writer.path(), |_| true);
        let settled = writer.writes();
        assert!(settled >= 1);
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(writer.writes(), settled, "an idle session must not rewrite its snapshot");

        mux.create_empty_workspace(Some("burst".into()), None, None).unwrap();
        for index in 0..20 {
            let workspace = mux.with_state(|state| state.workspaces[0].id);
            mux.rename_workspace(workspace, format!("burst-{index}"));
        }
        wait_for_snapshot(writer.path(), |snapshot| {
            workspace_names(snapshot) == vec!["burst-19".to_string()]
        });
        // 21 changes settle into a few writes, never one per change. The
        // bound leaves room for a slow runner splitting the burst.
        let burst = writer.writes() - settled;
        assert!(burst <= 5, "writes: {burst} for 21 changes");

        drop(writer);
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cmux_next_launch_snapshot_has_no_path_without_a_persistent_registry() {
        let mux = Mux::new_for_test("launch-snapshot-memory", SurfaceOptions::default());
        assert!(start_launch_snapshot_writer(&mux).unwrap().is_none());
        assert_eq!(mux.launch_snapshot_path(), None);
        let identify = run_command(&mux, json!({"cmd":"identify"}));
        assert_eq!(identify["launch_snapshot_path"], Value::Null);
    }

    fn run_command(mux: &Arc<Mux>, request: Value) -> Value {
        let command: Command = serde_json::from_value(request).unwrap();
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        handle_command(mux, 0, command, &writer).unwrap()
    }
}
