//! A chat actor driven over the v1 source in process (row 3b, part one): no hook at v1's append,
//! no registry, no daemon.

use super::*;
use crate::store::{CompactMode, EventRecord, ForkView, HistoryRef, LocalStore};
use acpmux_book::checkpoint::Checkpoint;
use acpmux_book::log::{self, CheckpointHead, Log, Options};
use acpmux_book::translate::{self, Change, Harness, State};
use acpmux_core::chat::{ChatActor, ChatConfig};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(super) const ID: &str = "01a1d000-0000-7000-8000-000000000000";

/// A temporary home: v1's store under `sessions`, the book under `book`.
pub(super) struct Home {
    pub dir: tempfile::TempDir,
    pub store: Arc<dyn Store>,
    pub last: Arc<AtomicU64>,
}

impl Home {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn Store> = Arc::new(ForkView::new(Box::new(
            LocalStore::new(dir.path().join("sessions"), 8 << 20).unwrap(),
        )));
        Self { dir, store, last: Arc::default() }
    }

    /// The god fixture's chat of `messages` messages and about `bytes` (`Shape::small`'s and
    /// `Shape::god`'s).
    pub fn with_chat(messages: usize, bytes: u64) -> Self {
        let home = Self::new();
        let (_, last) =
            crate::god_fixture::append_log(home.store.as_ref(), ID, messages, bytes).unwrap();
        home.last.store(last, Ordering::SeqCst);
        home
    }

    pub fn book(&self) -> PathBuf {
        self.dir.path().join("book")
    }

    /// The chat's log as v1 holds it now, read as this daemon life's first open.
    pub fn log(&self) -> V1Log<Arc<dyn Store>> {
        let last = self.last.clone();
        V1Log::new(
            self.store.clone(),
            ID,
            self.last.load(Ordering::SeqCst),
            Arc::new(move || last.load(Ordering::SeqCst)),
        )
    }

    pub fn config(&self, log: &V1Log<Arc<dyn Store>>) -> ChatConfig {
        let mut config =
            ChatConfig::new(ID, self.book(), Harness::V1).with_source_factory(log.factory());
        config.hint_poll = Duration::from_millis(10);
        config
    }

    /// Appends one prompt as v1 does, then raises v1's last seq: no notice is sent.
    pub fn prompt(&self, text: &str) -> u64 {
        let seq = self.last.load(Ordering::SeqCst) + 1;
        let record = EventRecord {
            seq,
            at: seq,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: serde_json::json!({ "text": text }),
            host_seq: None,
        };
        self.store.append(ID, &record).unwrap();
        self.last.store(seq, Ordering::SeqCst);
        seq
    }

    pub fn compact(&self) {
        let staged =
            self.store.stage_compaction(ID, CompactMode::Write { archive: None }).unwrap().unwrap();
        assert!(staged.stats.trimmed > 0, "the fixture has long strings to cut");
        assert!(self.store.commit_compaction(ID, staged).unwrap());
    }
}

/// Runs an actor over `config` until it says `ready`, then stops it.
pub(super) fn catch_up(config: ChatConfig) {
    let actor = ChatActor::spawn(config);
    wait_ready(&actor);
    actor.join();
}

pub(super) fn wait_ready(actor: &ChatActor) {
    let started = Instant::now();
    while !actor.handle.ready() {
        assert!(started.elapsed() < Duration::from_secs(600), "the actor never said ready");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The book's settled records, in seq order: rowId, rev and the first raw place.
pub(super) fn book_rows(book: &Path) -> Vec<(u64, u32, u64)> {
    let (mut log, _) = Log::open(book, Options::default()).unwrap();
    let mut cursor = 0;
    let mut rows = Vec::new();
    loop {
        let batch = log.since(cursor, 1 << 20).unwrap();
        rows.extend(batch.rows.iter().map(|row| (row.row_id, row.rev, row.raw.off)));
        cursor = batch.cursor;
        if !batch.more {
            return rows;
        }
    }
}

/// The book's settled rows with their text.
fn book_texts(book: &Path) -> Vec<(u64, Vec<u8>)> {
    let (mut log, _) = Log::open(book, Options::default()).unwrap();
    let mut cursor = 0;
    let mut rows = Vec::new();
    loop {
        let batch = log.since(cursor, 1 << 20).unwrap();
        let (mut bytes, mut spans) = (Vec::new(), Vec::new());
        log.fill(&batch.rows, &mut bytes, &mut spans).unwrap();
        for (row, span) in batch.rows.iter().zip(spans) {
            rows.push((row.row_id, bytes[span].to_vec()));
        }
        cursor = batch.cursor;
        if !batch.more {
            return rows;
        }
    }
}

/// What `translate` gives for the chat's events as v1 holds them, read through the store a
/// chunk at a time: each settled row and each patch, in order.
pub(super) fn translated(store: &dyn Store) -> Vec<(u64, u32, u64)> {
    let mut state = State::default();
    let mut rows = Vec::new();
    let mut marks = LogMarks::default();
    let mut bytes = Vec::new();
    let mut from = 1;
    loop {
        let stamp = store.log_stamp(ID).unwrap();
        let chunk =
            store.read_log(ID, from, LogFilter::ALL, stamp, &mut marks, &mut bytes).unwrap();
        for line in bytes.split_inclusive(|b| *b == b'\n') {
            let seq = seq_places(line, 0).unwrap().start;
            let line = line.strip_suffix(b"\n").unwrap_or(line);
            for op in translate::translate(&mut state, Harness::V1, seq, 1, line).unwrap() {
                match op.change {
                    Change::Row(row) if !row.open => rows.push((row.id, row.rev, seq)),
                    Change::Patch(row) => rows.push((row.id, row.rev, seq)),
                    _ => {}
                }
            }
        }
        from = chunk.next;
        if chunk.at_end {
            return rows;
        }
    }
}

fn edition(book: &Path) -> u32 {
    CheckpointHead::read(book).unwrap().unwrap().edition
}

fn cursor_stamp(book: &Path) -> u64 {
    let saved = log::saved_checkpoint(book).unwrap().unwrap();
    Checkpoint::from_recovered(&saved).unwrap().cursors[0].stamp
}

#[test]
fn the_book_over_v1_equals_what_translate_gives_for_small() {
    let shape = crate::god_fixture::Shape::small();
    let home = Home::with_chat(shape.god_messages, shape.god_bytes);
    let log = home.log();
    catch_up(home.config(&log));
    let rows = book_rows(&home.book());
    assert!(rows.len() >= shape.god_messages / 2, "{} rows", rows.len());
    assert_eq!(rows, translated(home.store.as_ref()));
    assert_eq!(edition(&home.book()), 1);
    // The source held one chunk at a time and read the log about once.
    let counters = &log.counters;
    assert!(
        counters.held_max.load(Ordering::SeqCst) <= acpmux_core::chat::source::CHUNK_BYTES as u64
    );
    assert!(counters.chunks.load(Ordering::SeqCst) > 4);
    let len = crate::god_fixture::Shape::small().god_bytes;
    assert!(counters.read.load(Ordering::SeqCst) * 5 <= len * 6 + (1 << 20));
}

#[test]
fn ready_comes_only_from_a_read_that_said_at_end_and_the_hint_finds_new_lines() {
    let home = Home::with_chat(200, 2 << 20);
    let log = home.log();
    let (read_tx, read_rx) = std::sync::mpsc::channel::<bool>();
    let (go_tx, go_rx) = std::sync::mpsc::channel::<()>();
    let go_rx = Arc::new(std::sync::Mutex::new(go_rx));
    let inner = log.clone();
    let gated: SourceFactory = Arc::new(move || {
        Ok(Box::new(Gated {
            inner: inner.open()?,
            read_tx: read_tx.clone(),
            go: go_rx.clone(),
            reads: 0,
        }) as Box<dyn RawSource>)
    });
    let mut config = home.config(&log);
    config.source_factory = gated;
    let actor = ChatActor::spawn(config);
    // The first chunk of a 2 MB log is not its end: not ready while the next read waits.
    assert!(!read_rx.recv_timeout(Duration::from_secs(30)).unwrap());
    std::thread::sleep(Duration::from_millis(50));
    assert!(!actor.handle.ready());
    drop(go_tx);
    wait_ready(&actor);
    // Caught up, the actor reads nothing more while the hint stays.
    let chunks = log.counters.chunks.load(Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(log.counters.chunks.load(Ordering::SeqCst), chunks);
    // A line v1 appends now, with no notice sent: the hint moves and the actor reads it.
    let seq = home.prompt("one more thing");
    let started = Instant::now();
    while log.counters.chunks.load(Ordering::SeqCst) == chunks {
        assert!(started.elapsed() < Duration::from_secs(30), "the line was never read");
        std::thread::sleep(Duration::from_millis(5));
    }
    actor.join();
    let rows = book_rows(&home.book());
    assert!(rows.iter().any(|row| row.2 == seq), "the new line's row is in the book");
    assert_eq!(rows, translated(home.store.as_ref()));
}

struct Gated {
    inner: V1Source<Arc<dyn Store>>,
    read_tx: std::sync::mpsc::Sender<bool>,
    go: Arc<std::sync::Mutex<std::sync::mpsc::Receiver<()>>>,
    reads: u64,
}

impl RawSource for Gated {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        self.reads += 1;
        if self.reads == 2 {
            // Waits until the test lets it go (the sender dropped). A test that never does
            // reads on after 30 s, and its assertions on the book name what went wrong.
            let _ = self.go.lock().unwrap().recv_timeout(Duration::from_secs(30));
        }
        let chunk = self.inner.read_chunk(place)?;
        if self.reads == 1 {
            let _ = self.read_tx.send(chunk.at_end);
        }
        Ok(chunk)
    }
    fn holds(&mut self, place: u64) -> io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
}

#[test]
fn a_tail_cut_back_as_a_power_loss_cuts_it_is_the_next_edition_and_equals_v1() {
    let home = Home::with_chat(200, 2 << 20);
    let log = home.log();
    catch_up(home.config(&log));
    let cursor = home.last.load(Ordering::SeqCst) + 1;
    // Another boot: v1's log lost its tail past `kept` (written again into a new store, as the
    // disk holds it after the loss), and other lines took those seqs.
    let kept = cursor - 40;
    let after = Home::new();
    let mut seq = 0;
    home.store
        .scan(ID, 0, &mut |record| {
            if record.seq <= kept {
                after.store.append(ID, &record).unwrap();
                seq = record.seq;
            }
            true
        })
        .unwrap();
    after.last.store(seq, Ordering::SeqCst);
    std::fs::rename(home.book(), after.book()).unwrap();
    let lost = after.log();
    for n in 0..10 {
        after.prompt(&format!("after the loss {n}"));
    }
    assert!(after.last.load(Ordering::SeqCst) + 1 < cursor);
    let mut config = after.config(&lost);
    config.boot_id = config.boot_id.wrapping_add(1).max(1);
    catch_up(config);
    assert_eq!(edition(&after.book()), 2);
    assert_eq!(book_rows(&after.book()), translated(after.store.as_ref()));
    // In the same boot, a later open of a chat whose seqs now run past the cursor holds it.
    let mut source = lost.open().unwrap();
    assert!(source.holds(after.last.load(Ordering::SeqCst) + 1).unwrap());
    assert!(!source.holds(after.last.load(Ordering::SeqCst) + 2).unwrap());
}

#[test]
fn a_journal_restore_cut_changes_the_stamp_and_the_book_is_cut_to_the_next_edition() {
    let home = Home::with_chat(200, 2 << 20);
    let log = home.log();
    catch_up(home.config(&log));
    let last = home.last.load(Ordering::SeqCst);
    let before = home.store.log_stamp(ID).unwrap();
    // A restore takes back what this machine's recovery wrote past `last - 20`, in a running
    // daemon, and new records take the same seqs.
    assert!(home.store.truncate_after(ID, last - 20).unwrap());
    home.last.store(last - 20, Ordering::SeqCst);
    for n in 0..30 {
        home.prompt(&format!("restored {n}"));
    }
    assert_ne!(home.store.log_stamp(ID).unwrap(), before);
    let mut source = log.open().unwrap();
    assert!(source.holds(last + 1).unwrap(), "a later open asks against what the store holds");
    catch_up(home.config(&log));
    assert_eq!(edition(&home.book()), 2);
    assert_eq!(cursor_stamp(&home.book()), home.store.log_stamp(ID).unwrap());
}

#[test]
fn a_chat_v1_compacted_keeps_its_cursor_and_its_rows_text() {
    let home = Home::with_chat(200, 2 << 20);
    let log = home.log();
    catch_up(home.config(&log));
    let texts = book_texts(&home.book());
    let cursor = home.last.load(Ordering::SeqCst) + 1;
    home.compact();
    let mut source = log.open().unwrap();
    assert!(source.holds(cursor).unwrap(), "compaction keeps every seq");
    // The open finds the stamp changed: it cuts at the checkpoint's mark (nothing past it) and
    // takes the next edition; every row stays with its whole text.
    catch_up(home.config(&log));
    assert_eq!(edition(&home.book()), 2);
    assert_eq!(book_texts(&home.book()), texts);
}

#[test]
fn a_rebuild_after_a_compaction_takes_the_next_edition() {
    let home = Home::with_chat(200, 2 << 20);
    let log = home.log();
    catch_up(home.config(&log));
    home.compact();
    // A book left mid rebuild is rebuilt from the first place.
    let mut staging = home.book().into_os_string();
    staging.push(".new");
    std::fs::create_dir_all(PathBuf::from(staging)).unwrap();
    catch_up(home.config(&log));
    assert_eq!(edition(&home.book()), 2);
    assert_eq!(book_rows(&home.book()), translated(home.store.as_ref()));
}

#[test]
fn a_compaction_mid_catch_up_gives_the_next_edition() {
    let home = Home::with_chat(400, 6 << 20);
    let log = home.log();
    let store = home.store.clone();
    let compacted = Arc::new(AtomicBool::new(false));
    let inner = log.clone();
    let flag = compacted.clone();
    let factory: SourceFactory = Arc::new(move || {
        Ok(Box::new(CompactsOnce {
            inner: inner.open()?,
            store: store.clone(),
            done: flag.clone(),
            reads: 0,
        }) as Box<dyn RawSource>)
    });
    let mut config = home.config(&log);
    config.source_factory = factory;
    catch_up(config);
    assert!(compacted.load(Ordering::SeqCst));
    assert_eq!(edition(&home.book()), 2);
    assert_eq!(cursor_stamp(&home.book()), home.store.log_stamp(ID).unwrap());
}

/// Compacts the chat once, between its third and fourth chunk.
struct CompactsOnce {
    inner: V1Source<Arc<dyn Store>>,
    store: Arc<dyn Store>,
    done: Arc<AtomicBool>,
    reads: u64,
}

impl RawSource for CompactsOnce {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        self.reads += 1;
        if self.reads == 4 && !self.done.swap(true, Ordering::SeqCst) {
            let staged = self
                .store
                .stage_compaction(ID, CompactMode::Write { archive: None })
                .unwrap()
                .unwrap();
            assert!(self.store.commit_compaction(ID, staged).unwrap());
        }
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
}

#[test]
fn a_fork_by_reference_whose_chat_was_compacted_reads_a_changed_stamp() {
    let home = Home::with_chat(200, 2 << 20);
    let through = home.last.load(Ordering::SeqCst) / 2;
    let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": "fork", "name": "fork", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "historyFrom": {"session": ID, "throughSeq": through},
    }))
    .unwrap();
    let chat: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "chat", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    home.store.save(&chat).unwrap();
    home.store.save(&meta).unwrap();
    assert_eq!(meta.history_from, Some(HistoryRef { session: ID.into(), through_seq: through }));
    let before = home.store.log_stamp("fork").unwrap();
    // The fork's lines through the seq are the chat's history kinds.
    let mut out = Vec::new();
    home.store
        .read_log("fork", 1, LogFilter::ALL, before, &mut LogMarks::default(), &mut out)
        .unwrap();
    assert!(!out.is_empty());
    home.compact();
    assert_ne!(home.store.log_stamp("fork").unwrap(), before);
}
