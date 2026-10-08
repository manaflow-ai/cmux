const CRITICAL_QUEUE_CAPACITY: usize = 256;

use super::*;
use crate::session::{OutboundFrame, OutboundSink};
use notify::Watcher as _;
use serde_json::Value;

#[cfg(unix)]
#[test]
fn repeated_teardown_attempts_hit_the_hard_worker_cap() {
    let slots = Arc::new(Semaphore::new(WATCH_TEARDOWN_CONCURRENCY));
    let mut owners = Vec::new();
    let mut rejected = 0;
    for _ in 0..(WATCH_TEARDOWN_CONCURRENCY * 3) {
        let watcher = notify::RecommendedWatcher::new(|_| {}, notify::Config::default())
            .expect("create test watcher");
        match WatcherOwner::new_with_slots(watcher, Arc::clone(&slots)) {
            Ok(owner) => owners.push(owner),
            Err(_) => rejected += 1,
        }
    }
    assert_eq!(owners.len(), WATCH_TEARDOWN_CONCURRENCY);
    assert_eq!(rejected, WATCH_TEARDOWN_CONCURRENCY * 2);
    drop(owners);
}

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

async fn next_frame(
    critical: &mut Receiver<OutboundFrame>,
    watch: &mut Receiver<OutboundFrame>,
    what: &str,
) -> Value {
    let frame = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::select! { biased; frame = critical.recv() => frame, frame = watch.recv() => frame }
    })
    .await
    .unwrap_or_else(|_| panic!("no {what} frame within 10s"))
    .expect("channel open");
    serde_json::from_str(&frame.text).expect("valid frame json")
}

/// Rewrites `name` under `root` until a watch frame reports it. A new
/// macOS FSEvents stream has no "armed" signal and never reports a write
/// made before it starts, so one write after a fixed pause loses the
/// event whenever the host is slow to start the stream. Each rewrite is a
/// fresh change, so a live watch reports one of them within a debounce
/// window; a retired watch reports none and the deadline fails the test.
async fn write_until_reported(
    critical: &mut Receiver<OutboundFrame>,
    watch: &mut Receiver<OutboundFrame>,
    root: &Path,
    name: &str,
    what: &str,
) -> Value {
    let reported = |value: &Value| {
        value["type"] == "fs_watch_event"
            && value["changes"]
                .as_array()
                .is_some_and(|changes| changes.iter().any(|change| change["path"] == name))
    };
    tokio::time::timeout(Duration::from_secs(20), async {
        let mut attempt = 0_u32;
        loop {
            attempt += 1;
            std::fs::write(root.join(name), format!("attempt {attempt}\n")).expect("write");
            let rewrite = tokio::time::sleep(DEBOUNCE_MAX_LATENCY * 2);
            tokio::pin!(rewrite);
            loop {
                let frame = tokio::select! {
                    biased;
                    frame = critical.recv() => frame,
                    frame = watch.recv() => frame,
                    () = &mut rewrite => break,
                };
                let frame = frame.expect("channel open");
                let value: Value = serde_json::from_str(&frame.text).expect("valid frame json");
                if reported(&value) {
                    return value;
                }
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no {what} reporting {name} within 20s"))
}

async fn wait_for_opening_to_finish(registry: &WatchRegistry, watch_id: &str) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let finished = registry
                .sessions
                .lock()
                .map(|state| state.get(watch_id).map(|slot| slot.opening.is_none()).unwrap_or(true))
                .unwrap_or(true);
            if finished {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("watch setup did not finish");
}

#[cfg(unix)]
#[tokio::test]
async fn watch_streams_debounced_changes_for_a_write() {
    let root = scratch("stream");
    std::fs::write(root.join("seed.txt"), "seed\n").expect("seed");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);
    registry.open(open_frame("w1", &root), None);
    let opened = next_frame(&mut critical, &mut watch, "opened").await;
    assert_eq!(opened["type"], "fs_watch_opened");
    assert_eq!(opened["watchId"], "w1");
    assert_eq!(opened["root"].as_str(), root.to_str());
    let event = write_until_reported(&mut critical, &mut watch, &root, "fresh.txt", "change").await;
    assert_eq!(event["watchId"], "w1");
    registry.close("w1");
}

#[cfg(unix)]
#[tokio::test]
async fn invalid_replacement_preserves_the_existing_watch() {
    let root = scratch("invalid-replacement");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);

    registry.open(open_frame("same", &root), None);
    let opened = next_frame(&mut critical, &mut watch, "first opened").await;
    assert_eq!(opened["type"], "fs_watch_opened");

    let mut invalid = open_frame("same", &root);
    invalid.root = Some(root.join("missing").to_string_lossy().into_owned());
    registry.open(invalid, None);
    let refusal = next_frame(&mut critical, &mut watch, "replacement refusal").await;
    assert_eq!(refusal["type"], "fs_watch_error");
    assert_eq!(refusal["code"], "not_found");

    // Validation happens before registry mutation. A change in the
    // original root proves that the refused replacement kept it active.
    write_until_reported(
        &mut critical,
        &mut watch,
        &root,
        "still-watched.txt",
        "existing watch event",
    )
    .await;
    registry.close("same");
}

#[cfg(unix)]
#[tokio::test]
async fn pending_openings_count_toward_the_session_cap() {
    let root = scratch("pending-cap");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);

    // `open` reserves synchronously and only then yields to its setup
    // coordinator. Filling all slots back-to-back therefore exercises the
    // cap while every setup is still pending.
    for index in 0..WATCH_MAX_SESSIONS {
        registry.open(open_frame(&format!("pending-{index}"), &root), None);
    }
    let mut over_cap = open_frame("pending-over-cap", &root);
    over_cap.root = Some(root.to_string_lossy().into_owned());
    registry.open(over_cap, None);

    let mut saw_limit = false;
    for _ in 0..=WATCH_MAX_SESSIONS {
        let frame = next_frame(&mut critical, &mut watch, "pending cap response").await;
        if frame["type"] == "fs_watch_error" && frame["code"] == "watch_limit" {
            saw_limit = true;
            break;
        }
    }
    assert!(saw_limit, "a pending opening must consume a watch slot");
}

#[cfg(unix)]
#[tokio::test]
async fn failed_opened_enqueue_preserves_the_existing_watch() {
    let root = scratch("opened-queue-full");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);

    registry.open(open_frame("same", &root), None);
    let opened = next_frame(&mut critical, &mut watch, "first opened").await;
    assert_eq!(opened["type"], "fs_watch_opened");
    let old_generation = registry
        .sessions
        .lock()
        .expect("state")
        .get("same")
        .and_then(|slot| slot.active.as_ref())
        .map(|active| active.generation)
        .expect("active watch");

    // Keep the critical queue full while the replacement prepares. The
    // replacement must not retire the old watch when its acknowledgement
    // cannot be admitted.
    for _ in 0..256 {
        assert!(registry.outbound.try_critical_text("{}".to_owned()).is_ok());
    }
    registry.open(open_frame("same", &root), None);
    wait_for_opening_to_finish(&registry, "same").await;
    let current_generation = registry
        .sessions
        .lock()
        .expect("state")
        .get("same")
        .and_then(|slot| slot.active.as_ref())
        .map(|active| active.generation);
    assert_eq!(current_generation, Some(old_generation));

    // The 256 filler frames still in the critical queue are skipped.
    let frame = write_until_reported(
        &mut critical,
        &mut watch,
        &root,
        "still-watched.txt",
        "event from the old watch after the queue failure",
    )
    .await;
    assert_eq!(frame["watchId"], "same");
    registry.close("same");
}

#[tokio::test]
async fn completed_watch_invalidates_queued_frames() {
    let sessions = Arc::new(Mutex::new(HashMap::new()));
    let live = Arc::new(AtomicBool::new(true));
    let cancellation = CancellationToken::new();
    let task = tokio::spawn(async {});
    sessions.lock().unwrap().insert(
        "finished".to_owned(),
        WatchSlot {
            active: Some(ActiveWatch {
                generation: 1,
                live: Arc::clone(&live),
                cancellation,
                abort: task.abort_handle(),
            }),
            opening: None,
        },
    );
    finish_active("finished", 1, Arc::clone(&sessions));
    assert!(!live.load(Ordering::Acquire));
    assert!(sessions.lock().unwrap().is_empty());
}

#[tokio::test]
async fn failed_open_keeps_its_error_frame_live_until_delivery() {
    let (sink, mut critical, _) = OutboundSink::channels();
    let sessions = Arc::new(Mutex::new(HashMap::new()));
    let live = Arc::new(AtomicBool::new(true));
    let cancellation = CancellationToken::new();
    sessions.lock().unwrap().insert(
        "failed".to_owned(),
        WatchSlot {
            active: None,
            opening: Some(Opening {
                generation: 1,
                live: Arc::clone(&live),
                cancellation: cancellation.clone(),
                abort: None,
            }),
        },
    );
    let task = tokio::spawn(finish_open_failure(
        OpenContext {
            watch_id: "failed".to_owned(),
            generation: 1,
            live,
            cancellation,
            sessions: Arc::clone(&sessions),
            outbound: sink,
        },
        wire::WorkspaceErrorCode::Failed,
        None,
    ));
    let mut frame = critical.recv().await.expect("failure frame");
    assert!(frame.live.is_some(), "failure keeps its opening liveness token until delivery");
    let value: Value = serde_json::from_str(&frame.text).expect("failure json");
    assert_eq!(value["code"], "failed");
    assert!(value["message"].is_null(), "internal failure copy stays out of the wire frame");
    frame.ack.take().expect("failure delivery ack").send(()).expect("ack receiver");
    task.await.expect("failure task");
}

#[tokio::test]
async fn failed_open_waits_for_critical_capacity() {
    let (sink, mut critical, _) = OutboundSink::channels();
    for _ in 0..CRITICAL_QUEUE_CAPACITY {
        sink.try_critical_text("{}".to_owned()).expect("fill critical queue");
    }
    let sessions = Arc::new(Mutex::new(HashMap::new()));
    let live = Arc::new(AtomicBool::new(true));
    let cancellation = CancellationToken::new();
    sessions.lock().unwrap().insert(
        "saturated".to_owned(),
        WatchSlot {
            active: None,
            opening: Some(Opening {
                generation: 1,
                live: Arc::clone(&live),
                cancellation: cancellation.clone(),
                abort: None,
            }),
        },
    );
    let task = tokio::spawn(finish_open_failure(
        OpenContext {
            watch_id: "saturated".to_owned(),
            generation: 1,
            live,
            cancellation,
            sessions: Arc::clone(&sessions),
            outbound: sink,
        },
        wire::WorkspaceErrorCode::Failed,
        None,
    ));
    tokio::task::yield_now().await;
    assert!(!task.is_finished(), "failure waits instead of dropping under queue pressure");

    let _ = critical.recv().await.expect("filler frame");
    let mut terminal = loop {
        let frame = critical.recv().await.expect("terminal failure frame");
        let value: Value = serde_json::from_str(&frame.text).expect("frame json");
        if value["type"] == "fs_watch_error" {
            break frame;
        }
    };
    terminal.ack.take().expect("terminal delivery ack").send(()).expect("ack receiver");
    task.await.expect("failure task");
    assert!(sessions.lock().unwrap().is_empty(), "opening is cleared after delivery");
}

#[tokio::test]
async fn saturated_watch_bytes_reports_a_terminal_error() {
    let (sink, mut critical, _watch) = OutboundSink::channels();
    let payload = "x".repeat(2 << 20);
    let mut filled = 0;
    while filled < 8 && sink.try_watch_text(payload.clone()).is_ok() {
        filled += 1;
    }
    assert!(filled >= 3, "watch bytes must admit multiple frames");
    assert!(filled < 8, "watch bytes must stop before global bytes are exhausted");
    let cancellation = CancellationToken::new();
    let live = Arc::new(AtomicBool::new(true));
    let mut report = Box::pin(report_watch_failure("saturated", &sink, &cancellation, &live));
    let frame = tokio::select! {
        frame = critical.recv() => frame.expect("terminal error frame"),
        _ = &mut report => panic!("terminal report returned before delivery ack"),
    };
    let value: Value = serde_json::from_str(&frame.text).expect("error json");
    assert_eq!(value["type"], "fs_watch_error");
    assert_eq!(value["watchId"], "saturated");
    assert_eq!(value["code"], "failed");
    assert!(value["message"].is_null(), "terminal copy is localized by the client");
    frame.ack.expect("terminal delivery ack").send(()).expect("ack receiver");
    report.await;
}

#[cfg(unix)]
#[tokio::test]
async fn watch_refuses_typed_and_respects_the_session_cap() {
    let root = scratch("refuse");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);
    // A root outside the allowed list refuses path_forbidden.
    let mut outside = open_frame("w-out", &root);
    outside.root = Some("/etc".to_owned());
    registry.open(outside, None);
    let refusal = next_frame(&mut critical, &mut watch, "refusal").await;
    assert_eq!(refusal["type"], "fs_watch_error");
    assert_eq!(refusal["code"], "path_forbidden");
    assert_eq!(refusal["message"], "path is forbidden by the workspace policy");
    assert!(
        !refusal.to_string().contains(&root.to_string_lossy().to_string()),
        "watch refusal must not disclose the local workspace path"
    );
    // Session cap: the 17th watch refuses watch_limit.
    for index in 0..WATCH_MAX_SESSIONS {
        registry.open(open_frame(&format!("w{index}"), &root), None);
        let opened = next_frame(&mut critical, &mut watch, "opened").await;
        assert_eq!(opened["type"], "fs_watch_opened", "watch {index}");
    }
    let mut over_cap = open_frame("w-past-cap", &root);
    over_cap.root = Some(root.to_string_lossy().into_owned());
    registry.open(over_cap, None);
    let capped = next_frame(&mut critical, &mut watch, "watch_limit").await;
    assert_eq!(capped["type"], "fs_watch_error");
    assert_eq!(capped["code"], "watch_limit");
}

#[cfg(not(unix))]
#[tokio::test]
async fn scoped_watch_answers_typed_unsupported() {
    let root = scratch("unsupported-scope");
    let (sink, mut critical, mut watch) = OutboundSink::channels();
    let registry = WatchRegistry::new(sink);
    registry.open(open_frame("w-unsupported", &root), None);
    let refusal = next_frame(&mut critical, &mut watch, "unsupported refusal").await;
    assert_eq!(refusal["type"], "fs_watch_error");
    assert_eq!(refusal["watchId"], "w-unsupported");
    assert_eq!(refusal["code"], "unsupported_verb");
}

#[test]
fn bursts_merge_and_cap_with_overflow() {
    let root = scratch("merge");
    let matcher = build_ignore_matcher(&root);
    let mut changes = Vec::new();
    let mut index = HashMap::new();
    let mut saw_ignore = false;
    let created = notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
        .add_path(root.join("a.txt"));
    let modified = notify::Event::new(notify::EventKind::Modify(notify::event::ModifyKind::Data(
        notify::event::DataChange::Content,
    )))
    .add_path(root.join("a.txt"));
    collect_changes(&root, &matcher, &created, &mut changes, &mut index, &mut saw_ignore);
    collect_changes(&root, &matcher, &modified, &mut changes, &mut index, &mut saw_ignore);
    assert_eq!(changes.len(), 1, "one path, one change");
    assert_eq!(changes[0].kind, wire::FsWatchChangeKind::Created, "created wins");
    // .git churn never leaks.
    let git_noise = notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
        .add_path(root.join(".git/index.lock"));
    collect_changes(&root, &matcher, &git_noise, &mut changes, &mut index, &mut saw_ignore);
    assert_eq!(changes.len(), 1);
    // A rename pair carries oldPath.
    let renamed = notify::Event::new(notify::EventKind::Modify(notify::event::ModifyKind::Name(
        notify::event::RenameMode::Both,
    )))
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
    let ignored = notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::File))
        .add_path(root.join("dist/bundle.js"));
    collect_changes(&root, &matcher, &ignored, &mut changes, &mut index, &mut saw_ignore);
    assert!(changes.is_empty(), "gitignored churn stays quiet: {changes:?}");
    let gitignore_edit = notify::Event::new(notify::EventKind::Modify(
        notify::event::ModifyKind::Data(notify::event::DataChange::Content),
    ))
    .add_path(root.join(".gitignore"));
    collect_changes(&root, &matcher, &gitignore_edit, &mut changes, &mut index, &mut saw_ignore);
    assert_eq!(changes.len(), 1, "the ignore file itself reports");
    assert!(saw_ignore, "and schedules a matcher rebuild");
}

#[test]
fn bounded_notify_queue_marks_overflow_without_losing_the_marker() {
    let (sender, mut receiver) = channel::<u8>(1);
    let overflowed = AtomicBool::new(false);
    let notify = Notify::new();
    try_enqueue_notify_event(&sender, &overflowed, &notify, 1);
    try_enqueue_notify_event(&sender, &overflowed, &notify, 2);
    assert!(overflowed.load(Ordering::Acquire));
    assert_eq!(receiver.try_recv().expect("first event"), 1);
    assert!(receiver.try_recv().is_err());
    assert!(overflowed.swap(false, Ordering::AcqRel));
    assert!(!overflowed.load(Ordering::Acquire));
}
