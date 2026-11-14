//! The book tee in a hub over a store on disk (row 3b, part two): the hook at v1's append, the
//! drain, the background pass, a purge, and a daemon killed during a catch-up.

use super::*;
use crate::hub::v1_source::tests::{book_rows, saved_cursor, translated_of};
use acpmux_core::chat::source::{Chunk, RawSource};
use acpmux_core::life::Health;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const AT: u64 = 1_791_540_000_000;

/// A home on disk: v1's store and its hub, with the tee installed when `books` is on.
pub(super) struct Home {
    pub dir: PathBuf,
    _temp: Option<tempfile::TempDir>,
    pub hub: Arc<Hub>,
    pub tee: Option<Arc<BookTee>>,
}

impl Home {
    pub fn tee(&self) -> &Arc<BookTee> {
        self.tee.as_ref().unwrap()
    }

    pub fn session(&self, id: &str) -> Arc<Session> {
        self.hub.session_by_id(id).unwrap()
    }

    pub fn book(&self, id: &str) -> PathBuf {
        self.hub.store.session_path(id).unwrap().join(BOOK)
    }

    /// One prompt through v1's append, as a person's prompt goes in: the seq it took.
    pub fn prompt(&self, id: &str, text: &str) -> u64 {
        let session = self.session(id);
        let (record, stored) = self.hub.append_logged(
            &session,
            "mux",
            "user_message",
            serde_json::json!({ "text": text }),
            None,
        );
        assert!(stored);
        record.seq
    }
}

/// Chats `(id, messages, bytes)` written through a store at `dir`, then a hub over them, loaded.
pub(super) async fn home_at(dir: PathBuf, chats: &[(String, usize, u64)], books: bool) -> Home {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&config.store, &dir).unwrap();
    for (n, (id, messages, bytes)) in chats.iter().enumerate() {
        let written = store.session_path(id).is_some_and(|path| path.join("session.json").exists());
        if !written {
            let (_, last) =
                crate::god_fixture::append_log(store.as_ref(), id, *messages, *bytes).unwrap();
            let meta = crate::god_fixture::session_meta(
                id,
                id,
                "/tmp",
                &crate::god_fixture::agent_session_id(n),
                last,
                AT + n as u64,
            );
            store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        }
    }
    let hub = Hub::new_loading(config, store, crate::mailbox::Mailbox::memory());
    let tee = books.then(|| {
        let tee = Arc::new(BookTee::new(Registry::new()));
        hub.install_book_tee(tee.clone());
        tee
    });
    hub.load_store_async().await;
    Home { dir, _temp: None, hub, tee }
}

pub(super) async fn home(chats: &[(String, usize, u64)], books: bool) -> Home {
    let temp = tempfile::tempdir().unwrap();
    let mut home = home_at(temp.path().to_path_buf(), chats, books).await;
    home._temp = Some(temp);
    home
}

fn chat(n: usize) -> String {
    crate::god_fixture::chat_id(n)
}

/// Every `book` folder under `dir`.
fn books_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if entry.file_name() == BOOK {
                    found.push(path.clone());
                }
                stack.push(path);
            }
        }
    }
    found
}

async fn wait_for(what: &str, timeout: Duration, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < timeout, "{what}: not within {timeout:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn cursor(book: &Path) -> Option<u64> {
    acpmux_book::log::saved_checkpoint(book)
        .ok()
        .flatten()
        .and_then(|saved| acpmux_book::checkpoint::Checkpoint::from_recovered(&saved).ok())
        .and_then(|checkpoint| checkpoint.cursors.first().map(|cursor| cursor.place))
}

#[test]
fn v2_makes_a_registry_only_with_books_and_a_store_on_disk() {
    let handle = |surfaces: &[&str], mode| {
        let mut config = crate::config::Config::default();
        config.store.mode = mode;
        config.acpmux_v2 =
            crate::config::V2Surfaces(surfaces.iter().map(|s| (*s).to_owned()).collect());
        crate::daemon::v2_handle(&config)
    };
    use crate::config::StoreMode::{Local, Memory};
    assert!(handle(&[], Local).is_none());
    assert!(handle(&["list"], Local).unwrap().registry().is_none(), "books off");
    assert!(handle(&["books"], Local).unwrap().registry().is_some());
    assert!(handle(&["chat"], Local).unwrap().registry().is_some(), "chat implies books");
    assert!(handle(&["books"], Memory).unwrap().registry().is_none(), "a store in memory");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_books_off_the_hook_does_nothing_and_no_book_is_written() {
    let home = home(&[(chat(0), 40, 64 << 10)], false).await;
    assert!(home.hub.book_tee().is_none(), "no tee, so no set and no registry");
    let last = home.session(&chat(0)).found_at_start;
    for n in 0..20 {
        home.prompt(&chat(0), &format!("books off {n}"));
    }
    // The hint is the tee's alone: with none, v1's append left it where the load put it.
    assert_eq!(home.session(&chat(0)).book_hint.load(Ordering::SeqCst), last);
    assert!(books_under(&home.dir).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_line_v1_appends_marks_its_chat_and_reaches_the_book_through_the_drain() {
    let home = home(&[(chat(0), 40, 64 << 10)], true).await;
    let tee = home.tee().clone();
    let hub = home.hub.clone();
    let drain_task = tokio::spawn({
        let tee = tee.clone();
        async move { drain(&hub, &tee).await }
    });
    let seq = home.prompt(&chat(0), "through the tee");
    assert_eq!(home.session(&chat(0)).book_hint.load(Ordering::SeqCst), seq);
    let book = home.book(&chat(0));
    wait_for("the line's place saved", Duration::from_secs(60), || cursor(&book) == Some(seq + 1))
        .await;
    assert_eq!(tee.pending(), 0);
    assert!(tee.counters.marks.load(Ordering::SeqCst) >= 1);
    // A quiet append (no notice to v1's watchers) marks too.
    let session = home.session(&chat(0));
    let quiet = home.hub.append_quiet(&session, "mux", "status", serde_json::json!({}));
    assert_eq!(session.book_hint.load(Ordering::SeqCst), quiet.seq);
    drain_task.abort();
    assert!(tee.registry().evict(&chat(0)));
    assert_eq!(book_rows(&book), translated_of(home.hub.store.as_ref(), &chat(0)));
}

/// The poll is a 5 s backstop (`HINT_POLL`): a caught-up actor reads each v1 line because the
/// tee told it, well inside that, and its poll never is what woke it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_caught_up_chat_reads_each_line_on_the_tee_s_notice_not_the_backstop_poll() {
    let home = home(&[(chat(0), 40, 64 << 10)], true).await;
    let tee = home.tee().clone();
    let hub = home.hub.clone();
    let drain_task = tokio::spawn({
        let tee = tee.clone();
        async move { drain(&hub, &tee).await }
    });
    let book = home.book(&chat(0));
    let seq = home.prompt(&chat(0), "first");
    wait_for("the first line's place saved", Duration::from_secs(60), || {
        cursor(&book) == Some(seq + 1)
    })
    .await;
    let handle = tee.registry().get(&chat(0)).unwrap();
    assert!(handle.wait_ready().await);
    assert_eq!(acpmux_core::chat::HINT_POLL, Duration::from_secs(5));
    let mut slowest = Duration::ZERO;
    for n in 0..20 {
        let session = home.session(&chat(0));
        let started = Instant::now();
        let seq = home.prompt(&chat(0), &format!("live {n}"));
        // A prompt settles at once, and a settled row past a second of the last checkpoint
        // checkpoints: each line's place is saved without a close.
        wait_for("the line's place saved", Duration::from_secs(4), || {
            session.book_hint.load(Ordering::SeqCst) == seq && cursor(&book) == Some(seq + 1)
        })
        .await;
        slowest = slowest.max(started.elapsed());
        tokio::time::sleep(Duration::from_millis(1_050)).await;
    }
    let wakes = handle.wakes();
    let (notice, poll) =
        (wakes.by_notice.load(Ordering::SeqCst), wakes.by_poll.load(Ordering::SeqCst));
    eprintln!("wakes by notice {notice}, by poll {poll}, slowest line to its book {slowest:?}");
    assert_eq!(poll, 0, "the backstop poll woke the actor {poll} times");
    assert!(notice >= 20, "{notice} wakes by notice for 20 lines");
    assert!(slowest < Duration::from_secs(1), "a line took {slowest:?} to its book");
    drain_task.abort();
    assert!(tee.registry().evict(&chat(0)));
}

/// A source whose reads wait while `gate` holds.
struct Gate {
    inner: Box<dyn RawSource>,
    gate: Arc<std::sync::RwLock<()>>,
}

impl RawSource for Gate {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<Chunk> {
        let _open = self.gate.read().unwrap();
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_notice_to_a_full_mailbox_or_a_failed_chat_is_dropped_and_loses_nothing() {
    let home = home(&[(chat(0), 40, 64 << 10), (chat(1), 40, 64 << 10)], true).await;
    let tee = home.tee().clone();
    // Chat 0's actor waits in a read while 300 notices come: the mailbox holds 256.
    let gate = Arc::new(std::sync::RwLock::new(()));
    let closed = gate.write().unwrap();
    let mut first = config(&home.hub, &tee, &home.session(&chat(0))).unwrap();
    let inner = first.source_factory.clone();
    let shared = gate.clone();
    first.source_factory = Arc::new(move || {
        Ok(Box::new(Gate { inner: inner()?, gate: shared.clone() }) as Box<dyn RawSource>)
    });
    let (handle, _) = tee.registry().start(first).unwrap();
    let mut seq = 0;
    for n in 0..300 {
        seq = home.prompt(&chat(0), &format!("while full {n}"));
        tee.tell(&home.hub, &chat(0));
    }
    assert!(tee.counters.dropped.load(Ordering::SeqCst) > 0, "a full mailbox dropped notices");
    drop(closed);
    // Nothing lost: the hint holds the last seq, and the actor reads up to it.
    let book = home.book(&chat(0));
    wait_for("the last line saved", Duration::from_secs(120), || cursor(&book) == Some(seq + 1))
        .await;
    assert!(handle.ready() && handle.failures() == 0);
    assert!(tee.registry().evict(&chat(0)));
    assert_eq!(cursor(&book), Some(seq + 1), "every line the notices told of is in the book");

    // Chat 1's actor fails at every start: its notices are dropped and none waits in its mailbox.
    let mut failing = config(&home.hub, &tee, &home.session(&chat(1))).unwrap();
    failing.source_factory = Arc::new(|| Err(std::io::Error::other("a source that never opens")));
    failing.supervision = acpmux_core::life::Policy {
        first_wait: Duration::from_millis(1),
        max_wait: Duration::from_millis(2),
        ..Default::default()
    };
    let (failed, _) = tee.registry().start(failing).unwrap();
    wait_for("the chat failed", Duration::from_secs(30), || failed.health() == Health::Failed)
        .await;
    let dropped = tee.counters.dropped.load(Ordering::SeqCst);
    let told = tee.counters.told.load(Ordering::SeqCst);
    for _ in 0..10 {
        home.prompt(&chat(1), "to a failed chat");
        tee.tell(&home.hub, &chat(1));
    }
    assert_eq!(tee.counters.dropped.load(Ordering::SeqCst), dropped + 10);
    assert_eq!(tee.counters.told.load(Ordering::SeqCst), told);
    assert_eq!(failed.queued(), 0, "nothing was put in the failed chat's mailbox");
    assert!(tee.registry().evict(&chat(1)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn three_long_catch_ups_hold_two_permits_and_a_live_line_reaches_its_book_meanwhile() {
    let long = 12 << 20;
    let chats =
        [(chat(0), 800, long), (chat(1), 800, long), (chat(2), 800, long), (chat(3), 8, 16 << 10)];
    let home = home(&chats, true).await;
    let tee = home.tee().clone();
    let hub = home.hub.clone();
    let drain_task = tokio::spawn({
        let tee = tee.clone();
        async move { drain(&hub, &tee).await }
    });
    // The live chat first: it is caught up in one chunk, and follows from then on.
    tee.tell(&home.hub, &chat(3));
    let live = tee.registry().get(&chat(3)).unwrap();
    wait_for("the live chat ready", Duration::from_secs(60), || live.ready()).await;
    let handles: Vec<_> = (0..3)
        .map(|n| {
            tee.tell(&home.hub, &chat(n));
            tee.registry().get(&chat(n)).unwrap()
        })
        .collect();
    let seq = home.prompt(&chat(3), "while three histories are read");
    let book = home.book(&chat(3));
    wait_for("the live line saved", Duration::from_secs(60), || cursor(&book) == Some(seq + 1))
        .await;
    assert!(
        handles.iter().any(|handle| !handle.ready()),
        "the live line reached its book while the histories were still read"
    );
    for handle in &handles {
        let handle = handle.clone();
        wait_for("a history caught up", Duration::from_secs(600), move || handle.ready()).await;
    }
    let history = tee.registry().history();
    assert_eq!(history.held_max(), 2, "two permits held at once, never three");
    assert_eq!(history.held(), 0);
    drain_task.abort();
    for n in 0..4 {
        assert!(tee.registry().evict(&chat(n)));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_pass_catches_up_a_hundred_chats_two_at_a_time_and_passes_over_a_cold_one() {
    let chats: Vec<_> = (0..101).map(|n| (chat(n), 8, 8 << 10)).collect();
    let home = home(&chats, true).await;
    let tee = home.tee().clone();
    // Chat 100 is in v1's cold archive.
    let cold = chat(100);
    let staged = home.hub.store.stage_cold(&cold).unwrap().unwrap();
    assert!(home.hub.store.commit_cold(&cold, staged).unwrap());
    assert!(home.hub.store.is_cold(&cold));
    pass(home.hub.clone(), tee.clone()).await;
    let counters = &tee.counters;
    assert!(counters.pass_done.load(Ordering::SeqCst));
    assert_eq!(counters.pass_live_max.load(Ordering::SeqCst), PASS_ACTORS as u64);
    assert_eq!(counters.pass_live.load(Ordering::SeqCst), 0);
    assert_eq!(counters.pass_closed.load(Ordering::SeqCst), 100, "each closed at ready");
    assert_eq!(counters.pass_cold.load(Ordering::SeqCst), 1);
    assert!(tee.registry().is_empty(), "no actor the pass started is left");
    for n in 0..100 {
        let session = home.session(&chat(n));
        assert_eq!(cursor(&home.book(&chat(n))), Some(session.found_at_start + 1), "chat {n}");
    }
    assert!(home.hub.store.is_cold(&cold), "the archive is still an archive");
    assert!(!home.book(&cold).exists());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_purged_while_its_actor_runs_leaves_no_book_and_no_actor() {
    let home = home(&[(chat(0), 800, 12 << 20)], true).await;
    let tee = home.tee().clone();
    tee.tell(&home.hub, &chat(0));
    let book = home.book(&chat(0));
    wait_for("the book begun", Duration::from_secs(60), || book.join("checkpoint").exists()).await;
    let dir = home.hub.store.session_path(&chat(0)).unwrap();
    let session = home.session(&chat(0));
    home.hub.kill(&session, true).await.unwrap();
    assert!(tee.registry().get(&chat(0)).is_none());
    assert!(!dir.exists(), "the chat's directory is gone");
    // A mark that was in the set before the purge hydrates nothing.
    tee.tell(&home.hub, &chat(0));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(tee.registry().is_empty());
    assert!(!dir.exists() && books_under(&home.dir).is_empty(), "no book outlives its chat");
}

/// The daemon's catch-up of one long chat in a child process, killed at a point of the parent's
/// choosing: it prints `CATCHING_UP` once its actor is reading.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "subprocess helper, driven by the kill test"]
async fn book_tee_kill_worker() {
    let dir = PathBuf::from(std::env::var_os("ACPMUX_TEST_HOME").unwrap());
    let home = home_at(dir, &[(chat(0), 1200, 16 << 20)], true).await;
    let tee = home.tee().clone();
    let pass_task = tokio::spawn(pass(home.hub.clone(), tee.clone()));
    let book = home.book(&chat(0));
    wait_for("the actor reading", Duration::from_secs(60), || {
        tee.registry().get(&chat(0)).is_some() || tee.counters.pass_done.load(Ordering::SeqCst)
    })
    .await;
    println!("CATCHING_UP");
    pass_task.await.unwrap();
    let waits = tee.sources.sync_waits.lock().unwrap().clone();
    println!("SYNC_WAITS {}", serde_json::to_string(&waits).unwrap());
    println!("CAUGHT_UP {}", cursor(&book).unwrap_or(0));
}

/// Runs the worker over `dir`; kills it `after` its catch-up began, or lets it finish. The sync
/// waits it printed, when it finished.
fn run_worker(dir: &Path, after: Option<Duration>) -> Option<Vec<u64>> {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "hub::book_tee::tests::book_tee_kill_worker", "--ignored", "--nocapture"])
        .env("ACPMUX_TEST_HOME", dir)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (send, receive) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = send.send(line);
        }
    });
    let mut waits = None;
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let Ok(line) = receive.recv_timeout(left) else { break };
        if line.contains("CATCHING_UP")
            && let Some(after) = after
        {
            std::thread::sleep(after);
            let _ = child.kill();
            break;
        }
        if let Some(json) = line.strip_prefix("SYNC_WAITS ") {
            waits = serde_json::from_str(json).ok();
        }
    }
    let status = child.wait().unwrap();
    reader.join().unwrap();
    if after.is_none() {
        assert!(status.success(), "the last run finishes");
    }
    waits
}

fn p95(values: &mut [u64]) -> u64 {
    values.sort_unstable();
    values.get((values.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap_or(0)
}

#[test]
fn fifty_daemon_kills_during_a_catch_up_give_the_book_made_with_no_kill() {
    let temp = tempfile::tempdir().unwrap();
    let clean = temp.path().join("clean");
    let mut waits = run_worker(&clean, None).unwrap();
    let expected = book_rows(&the_book(&clean));
    assert!(expected.len() > 100, "{} rows", expected.len());
    let killed = temp.path().join("killed");
    // Points spread over the catch-up by a fixed generator, so a red run is the same run again.
    let mut random = 0x9e37_79b9_7f4a_7c15_u64;
    let mut saved = 0;
    for kill in 0..50 {
        random ^= random << 13;
        random ^= random >> 7;
        random ^= random << 17;
        let after = Duration::from_millis(random % 1500);
        run_worker(&killed, Some(after));
        // Each restart goes on from where the last one saved.
        let now = the_books(&killed).first().map_or(0, |book| saved_cursor_or_zero(book));
        assert!(now >= saved, "kill {kill} after {after:?}: the cursor went back");
        saved = now;
    }
    waits.extend(run_worker(&killed, None).unwrap());
    let book = the_book(&killed);
    assert_eq!(book_rows(&book), expected, "the book after 50 kills equals the one with none");
    eprintln!(
        "pr03b kill: sync_through waits: n={} p95={} ns max={} ns",
        waits.len(),
        p95(&mut waits),
        waits.iter().max().copied().unwrap_or(0)
    );
}

fn saved_cursor_or_zero(book: &Path) -> u64 {
    if book.join("checkpoint").exists() { saved_cursor(book) } else { 0 }
}

/// The one chat's book under `dir`.
fn the_book(dir: &Path) -> PathBuf {
    let books = the_books(dir);
    assert_eq!(books.len(), 1, "{books:?}");
    books.into_iter().next().unwrap()
}

fn the_books(dir: &Path) -> Vec<PathBuf> {
    books_under(dir)
}
