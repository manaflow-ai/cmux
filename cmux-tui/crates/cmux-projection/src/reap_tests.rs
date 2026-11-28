//! Detector for projection state that outlives its chat (RFD 0007 hard case 8; HQ handbook
//! `docs/handbook/chat-state-outlives-the-chat.md`): a chat's projection state goes once the chat
//! is archived, deleted or its edits are brought back, and a live chat's edits that were never
//! brought back stay.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, SystemTime};

use super::*;
use crate::manifest::{Item, Kind, Manifest};
use crate::overlay::{Overlay, Who};
use crate::state::{BroughtBack, Detached, Released};
use crate::{Fetch, FetchError};

const DAY: Duration = Duration::from_secs(24 * 60 * 60);

fn me() -> Who {
    // SAFETY: getuid and getgid have no preconditions.
    unsafe { Who { uid: libc::getuid(), gid: libc::getgid() } }
}

/// Serves bytes by entry from memory and counts every read.
#[derive(Default)]
struct Mac {
    bytes: HashMap<u32, Vec<u8>>,
    reads: AtomicUsize,
}

impl Fetch for Mac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.reads.fetch_add(1, Ordering::Relaxed);
        let bytes = self.bytes.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        self.reads.fetch_add(1, Ordering::Relaxed);
        entries
            .iter()
            .map(|entry| self.bytes.get(entry).cloned().ok_or(FetchError::Failed))
            .collect()
    }
}

/// A machine's home: `state/projections` and the chats' folders under `work/chats`.
struct Machine {
    home: tempfile::TempDir,
}

impl Machine {
    fn new() -> Self {
        Self { home: tempfile::tempdir().unwrap() }
    }

    fn places(&self) -> Places {
        Places { projections: Some(self.home.path().join("state/projections")) }
    }

    /// A chat's copy folder under the work root (`work/chats/<key>/<copy>/<name>`).
    fn chat_folder(&self, key: &str) -> PathBuf {
        let folder = self.home.path().join("work/chats").join(key).join("0a1b2c3d").join("repo");
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    /// Projects a three-file folder at `at` as `name`, the way the daemon does: a state folder,
    /// its record, an overlay over it.
    fn project(&self, name: &str, at: &Path) -> (PathBuf, Overlay) {
        let files: [(&str, &[u8]); 3] =
            [("README.md", b"readme"), ("src/a.rs", b"fn a() {}"), ("src/b.rs", b"fn b() {}")];
        let items = files
            .iter()
            .map(|(path, bytes)| Item {
                path: (*path).into(),
                kind: Kind::File,
                mode: 0o644,
                size: bytes.len() as u64,
                mtime_ns: 1_700_000_000_000_000_000,
                link: None,
            })
            .collect();
        let manifest = Arc::new(Manifest::build(1, items).unwrap());
        let mut mac = Mac::default();
        for (path, bytes) in files {
            mac.bytes.insert(manifest.resolve(path).unwrap(), bytes.to_vec());
        }
        let state = self.home.path().join("state/projections").join(name);
        fs::create_dir_all(&state).unwrap();
        let now = state::ms_of(SystemTime::now());
        state::update(&state, at, |record| {
            record.created_ms = now;
            record.attached_ms = now;
        })
        .unwrap();
        let overlay = Overlay::open(manifest, &state, Arc::new(mac), (1000, 1000)).unwrap();
        (state, overlay)
    }
}

/// The agent's work in a projection: a read (the cache fills), an edit of a Mac file (a copy-up),
/// a new file, and a delete (a whiteout). Answers the bytes it wrote.
fn edit(overlay: &Overlay) -> u64 {
    let root = overlay.root();
    let readme = overlay.lookup(root, "README.md").unwrap().ino;
    assert_eq!(overlay.read(readme, 0, 100).unwrap(), b"readme");
    let src = overlay.lookup(root, "src").unwrap().ino;
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    let edited = b"fn a() { println!(\"edited on the machine\"); }";
    overlay.write(a, 0, edited).unwrap();
    let new = overlay.create(src, "new.rs", 0o644, me()).unwrap().0.ino;
    let written = vec![b'n'; 4096];
    overlay.write(new, 0, &written).unwrap();
    overlay.unlink(src, "b.rs").unwrap();
    (edited.len() + written.len()) as u64
}

fn chat(id: &str, folder: &Path, archived: bool) -> Chat {
    Chat { id: id.into(), folder: Some(folder.to_path_buf()), archived }
}

fn chats(rows: Vec<Chat>) -> Chats {
    Chats { rows, complete: true }
}

fn run(machine: &Machine, chats: &Chats, after: Duration) -> Report {
    pass(&machine.places(), chats, &Idle, SystemTime::now() + after, &Limits::default())
}

/// The detector: a chat with a projection, edited and then archived. One pass frees its state;
/// nothing the chat wrote is left on the machine.
#[test]
fn an_archived_chats_state_does_not_outlive_it() {
    let machine = Machine::new();
    let at = machine.chat_folder("5f0c");
    let (state, overlay) = machine.project("p-archived", &at);
    let wrote = edit(&overlay);
    drop(overlay);
    // A live chat elsewhere on the machine: the list is the machine's real one.
    let other = machine.chat_folder("9e1d");
    let rows = vec![chat("chat-1", &at, true), chat("chat-2", &other, false)];

    let report = run(&machine, &chats(rows), Duration::ZERO);

    assert!(!state.exists(), "the archived chat's projection state outlived it: {report:?}");
    assert!(!at.exists(), "the archived chat's empty mount point stayed");
    assert!(other.exists(), "a live chat's folder went");
    assert!(report.failed.is_empty(), "{:?}", report.failed);
    let whys: Vec<Why> = report.reclaimed.iter().map(|reclaim| reclaim.why).collect();
    assert_eq!(whys, [Why::Archived]);
    assert!(report.bytes() >= wrote, "freed {} of {wrote}", report.bytes());
    eprintln!("an archived chat freed {} bytes: {:?}", report.bytes(), report.reclaimed);
}

/// Bring Back read the upper layer at a mark: while it is still as read, it goes; one edit after
/// the mark and it stays (that edit is only on the machine).
#[test]
fn a_brought_back_upper_layer_goes_unless_edited_since() {
    let machine = Machine::new();
    let at = machine.chat_folder("b001");
    let (state, overlay) = machine.project("p-back", &at);
    edit(&overlay);
    let mark = state::mark(&state).unwrap();
    state::update(&state, &at, |record| {
        record.brought_back = Some(BroughtBack { ms: 1, mark: mark.clone() });
    })
    .unwrap();
    let root = overlay.root();
    let late = overlay.create(root, "late.txt", 0o644, me()).unwrap().0.ino;
    overlay.write(late, 0, b"written after Bring Back read the upper layer").unwrap();
    let live = chats(vec![chat("chat-b", &at, false)]);
    assert_eq!(verdict(&state, &live, false, SystemTime::now(), ORPHAN_GRACE), None);
    run(&machine, &live, Duration::ZERO);
    assert!(state.join("upper/late.txt").exists(), "an edit made after Bring Back was freed");

    let mark = state::mark(&state).unwrap();
    state::update(&state, &at, |record| {
        record.brought_back = Some(BroughtBack { ms: 2, mark: mark.clone() });
    })
    .unwrap();
    drop(overlay);
    // Freed even with the chat list unread: the record alone says the edits are on the Mac.
    let report = run(&machine, &Chats::unread(), Duration::ZERO);
    assert!(!state.exists(), "a brought-back upper layer outlived Bring Back: {report:?}");
    assert!(at.exists(), "Bring Back removed the chat's folder; the chat may go on there");
    assert_eq!(report.reclaimed[0].why, Why::BroughtBack);
    assert!(report.bytes() > 0);
    eprintln!("Bring Back freed {} bytes", report.bytes());
}

/// A live chat whose edits were never brought back keeps them, however long it waits, and so
/// does any chat when the machine's chat list could not be read, or reads empty.
#[test]
fn a_live_chats_edits_that_were_never_brought_back_stay() {
    let machine = Machine::new();
    let at = machine.chat_folder("11fe");
    let (state, overlay) = machine.project("p-live", &at);
    edit(&overlay);
    drop(overlay);
    let before = state::mark(&state).unwrap();
    let a_year = 365 * DAY;
    for list in [
        chats(vec![chat("chat-live", &at, false)]),
        Chats::unread(),
        Chats { rows: Vec::new(), complete: true },
        Chats { rows: vec![chat("someone-else", Path::new("/elsewhere"), false)], complete: false },
    ] {
        let report = run(&machine, &list, a_year);
        assert!(report.reclaimed.is_empty(), "{list:?} freed {:?}", report.reclaimed);
        assert_eq!(state::mark(&state).unwrap(), before, "a live chat's upper layer changed");
        assert!(state.exists() && at.exists(), "a live chat's projection went: {list:?}");
    }
}

/// State no chat names goes once it is older than the grace, never before, and never while this
/// daemon serves it.
#[test]
fn an_orphan_goes_after_the_grace_and_not_while_mounted() {
    struct Mounted(&'static str);
    impl Live for Mounted {
        fn mounted(&self, name: &str) -> bool {
            name == self.0
        }
        fn end(
            &self,
            name: &str,
            _at: Option<&Path>,
            only_if_idle: bool,
            still_eligible: &dyn Fn() -> bool,
            free: &mut dyn FnMut() -> io::Result<u64>,
        ) -> Option<io::Result<u64>> {
            (!(only_if_idle && self.mounted(name)) && still_eligible()).then(free)
        }
    }
    let machine = Machine::new();
    let at = machine.chat_folder("0dd0");
    let (state, overlay) = machine.project("p-orphan", &at);
    edit(&overlay);
    drop(overlay);
    let list = chats(vec![chat("unrelated", &machine.chat_folder("aaaa"), false)]);
    run(&machine, &list, DAY);
    assert!(state.exists(), "an orphan went inside its grace");
    let places = machine.places();
    let later = SystemTime::now() + ORPHAN_GRACE + DAY;
    let report = pass(&places, &list, &Mounted("p-orphan"), later, &Limits::default());
    assert!(state.exists(), "a projection this daemon serves was freed as an orphan: {report:?}");
    let report = pass(&places, &list, &Idle, later, &Limits::default());
    assert!(!state.exists(), "an orphan outlived its grace: {report:?}");
    assert!(report.reclaimed.iter().any(|reclaim| reclaim.why == Why::Orphan));
}

/// Detach wins the mount lock after the scan selected an archived or orphaned projection.
#[test]
fn detach_between_scan_and_unmount_preserves_edits_and_whiteouts() {
    struct Detaching<'a> {
        state: &'a Path,
        at: &'a Path,
    }

    impl Live for Detaching<'_> {
        fn mounted(&self, _: &str) -> bool {
            false
        }

        fn end(
            &self,
            _: &str,
            _: Option<&Path>,
            _: bool,
            still_eligible: &dyn Fn() -> bool,
            _: &mut dyn FnMut() -> io::Result<u64>,
        ) -> Option<io::Result<u64>> {
            state::update(self.state, self.at, |record| {
                record.detached = Some(Detached { ms: 1, chat: None });
            })
            .unwrap();
            assert!(!still_eligible(), "a stale verdict authorized unmount and cleanup");
            None
        }
    }

    for archived in [false, true] {
        let machine = Machine::new();
        let at = machine.chat_folder("removed");
        let (state, overlay) = machine.project("projection", &at);
        edit(&overlay);
        drop(overlay);
        let before = state::mark(&state).unwrap();
        let folder = if archived { at.clone() } else { machine.chat_folder("other") };
        let list = chats(vec![chat("chat", &folder, archived)]);
        let now = SystemTime::now() + ORPHAN_GRACE + DAY;
        let expected = if archived { Why::Archived } else { Why::Orphan };
        assert_eq!(verdict(&state, &list, false, now, ORPHAN_GRACE), Some(expected));
        let live = Detaching { state: &state, at: &at };
        let report = pass(&machine.places(), &list, &live, now, &Limits::default());
        assert!(report.reclaimed.is_empty());
        assert!(state::read(&state).unwrap().detached.is_some());
        assert_eq!(state::mark(&state).unwrap(), before);
        assert!(at.exists());
    }
}

/// The Mac released the projection (its chat was archived or deleted): it goes at once, mounted
/// or not, with the chat list unread.
#[test]
fn a_released_projection_goes_at_once() {
    let machine = Machine::new();
    let at = machine.chat_folder("de1e");
    let (state, overlay) = machine.project("p-released", &at);
    edit(&overlay);
    drop(overlay);
    state::update(&state, &at, |record| {
        record.released = Some(Released { ms: 1, why: Release::Deleted });
    })
    .unwrap();
    let report = run(&machine, &Chats::unread(), Duration::ZERO);
    assert!(!state.exists(), "a released projection outlived its chat: {report:?}");
    assert_eq!(report.reclaimed[0].why, Why::Deleted);
}

/// One pass frees at most its bound; the rest wait for the next pass.
#[test]
fn a_pass_frees_at_most_its_bound() {
    let machine = Machine::new();
    let mut rows = Vec::new();
    let mut states = Vec::new();
    for at in 0..5 {
        let key = format!("k{at}");
        let folder = machine.chat_folder(&key);
        states.push(machine.project(&format!("p-{key}"), &folder).0);
        rows.push(chat(&key, &folder, true));
    }
    let list = chats(rows);
    let limits = Limits { max_reclaims: 2, ..Limits::default() };
    let first = pass(&machine.places(), &list, &Idle, SystemTime::now(), &limits);
    assert_eq!((first.reclaimed.len(), first.deferred), (2, 3));
    let second = pass(&machine.places(), &list, &Idle, SystemTime::now(), &limits);
    let third = pass(&machine.places(), &list, &Idle, SystemTime::now(), &limits);
    assert_eq!(second.reclaimed.len() + third.reclaimed.len(), 3);
    assert!(states.iter().all(|state| !state.exists()), "a pass left an archived chat's state");
}

/// One projection's cache stays under its cap: the least recently used blob goes, and a read of
/// it later asks the Mac again.
#[test]
fn a_projections_cache_stays_under_its_cap() {
    let machine = Machine::new();
    let at = machine.chat_folder("ca9e");
    let (_, overlay) = machine.project("p-cap", &at);
    // No content store under it (RFD 0065): an evicted blob is gone from the disk.
    let overlay = overlay.with_cache_max(12).with_content_floor(u64::MAX);
    let root = overlay.root();
    let src = overlay.lookup(root, "src").unwrap().ino;
    let readme = overlay.lookup(root, "README.md").unwrap().ino;
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    let b = overlay.lookup(src, "b.rs").unwrap().ino;
    overlay.read(readme, 0, 100).unwrap();
    overlay.read(a, 0, 100).unwrap();
    overlay.read(b, 0, 100).unwrap();
    assert!(overlay.cache_bytes() <= 12, "cache at {} bytes, cap 12", overlay.cache_bytes());
    assert!(overlay.cache_evicted() > 0);
    let asked = overlay.stats().remote_reads;
    assert_eq!(overlay.read(readme, 0, 100).unwrap(), b"readme");
    assert!(overlay.stats().remote_reads > asked, "an evicted blob was served without the Mac");
}

/// A folder removed from its chat mid-turn (`projection.detach`): sealed, unmounted, and its upper
/// layer is the only copy of what the agent wrote there. No chat runs in the removed folder, so
/// the folder rule would call it an orphan; it stays while the chat that removed it lives, every
/// edit made before the seal is in it, and a change after the seal is refused, not lost.
#[test]
fn a_removed_folders_edits_stay_even_when_its_notification_chat_is_gone() {
    let machine = Machine::new();
    let chat_home = machine.chat_folder("c0de");
    let extra = machine.home.path().join("work/extra/repo");
    fs::create_dir_all(&extra).unwrap();
    let (state, overlay) = machine.project("p-removed", &extra);
    edit(&overlay);
    assert!(overlay.seal(Duration::from_secs(1)));
    let root = overlay.root();
    assert_eq!(overlay.create(root, "after.txt", 0o644, me()).err(), Some(libc::EROFS));
    let src = overlay.lookup(root, "src").unwrap().ino;
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    assert_eq!(overlay.write(a, 0, b"late").err(), Some(libc::EROFS));
    assert_eq!(overlay.unlink(src, "a.rs").err(), Some(libc::EROFS));
    assert!(overlay.read(a, 0, 64).unwrap().starts_with(b"fn a() { println!"), "reads stop");
    let mark = state::mark(&state).unwrap();
    drop(overlay);
    state::update(&state, &extra, |record| {
        record.detached =
            Some(Detached { ms: state::ms_of(SystemTime::now()), chat: Some("c1".into()) });
    })
    .unwrap();

    let live = chats(vec![chat("c1", &chat_home, false)]);
    let report = run(&machine, &live, ORPHAN_GRACE * 4);
    assert!(report.reclaimed.is_empty(), "a live chat's removed folder was freed: {report:?}");
    assert_eq!(state::mark(&state).unwrap(), mark, "the kept edits changed");
    assert!(state.join("upper/src/new.rs").exists());

    // Another chat elsewhere keeps the list knowable; the removing chat gone: orphan past grace.
    let other = machine.chat_folder("0the");
    let gone = chats(vec![chat("c2", &other, false)]);
    assert!(run(&machine, &gone, Duration::ZERO).reclaimed.is_empty(), "freed inside the grace");
    let archived = chats(vec![chat("c1", &chat_home, true), chat("c2", &other, false)]);
    assert!(run(&machine, &gone, ORPHAN_GRACE * 4).reclaimed.is_empty());
    assert!(run(&machine, &archived, Duration::ZERO).reclaimed.is_empty());
    assert_eq!(state::mark(&state).unwrap(), mark);
    // An explicit release still reclaims it, even with edits.
    state::update(&state, &extra, |record| {
        record.released = Some(Released { ms: 1, why: Release::Archived });
    })
    .unwrap();
    assert_eq!(run(&machine, &archived, Duration::ZERO).reclaimed.len(), 1);
    assert!(!state.exists());
    assert!(extra.exists(), "release removed the path given up by detach");
}

#[test]
fn detached_cleanup_checks_whiteouts_and_reclaims_an_empty_layer() {
    let machine = Machine::new();
    let extra = machine.chat_folder("extra");
    let (state, overlay) = machine.project("p-whiteout", &extra);
    drop(overlay);
    state::update(&state, &extra, |r| {
        r.detached = Some(Detached { ms: 1, chat: None });
    })
    .unwrap();
    let known = chats(vec![chat("other", &machine.chat_folder("other"), false)]);
    fs::write(state.join("whiteouts"), b"gone\0").unwrap();
    assert!(run(&machine, &known, ORPHAN_GRACE * 4).reclaimed.is_empty());
    fs::write(state.join("whiteouts"), b"").unwrap();
    assert_eq!(run(&machine, &known, ORPHAN_GRACE * 4).reclaimed.len(), 1);
    assert!(!state.exists());
}

/// Detach drains a write that already passed admission before returning, so no admitted edit is
/// lost between the seal and the upper-layer mark.
#[test]
fn seal_waits_for_an_admitted_write_before_returning() {
    let machine = Machine::new();
    let at = machine.chat_folder("drain");
    let (state, overlay) = machine.project("p-drain", &at);
    let overlay = Arc::new(overlay);
    let root = overlay.root();
    let src = overlay.lookup(root, "src").unwrap().ino;
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    let (entered, release) = overlay.pause_next_mutation();

    let writer_overlay = Arc::clone(&overlay);
    let writer = thread::spawn(move || writer_overlay.write(a, 0, b"admitted"));
    entered.recv_timeout(Duration::from_secs(1)).unwrap();

    let (sealed, sealed_rx) = mpsc::channel();
    let sealer_overlay = Arc::clone(&overlay);
    let sealer = thread::spawn(move || {
        assert!(sealer_overlay.seal(Duration::from_secs(5)));
        sealed.send(()).unwrap();
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(1);
    while !overlay.is_sealed() && std::time::Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(overlay.is_sealed());
    let (refused, refused_rx) = mpsc::channel();
    let late = overlay.clone();
    let late_writer = thread::spawn(move || refused.send(late.write(a, 0, b"late")).unwrap());
    assert_eq!(refused_rx.recv_timeout(Duration::from_secs(1)).unwrap(), Err(libc::EROFS));
    late_writer.join().unwrap();
    assert!(sealed_rx.try_recv().is_err(), "admitted edit must still be draining");

    release.send(()).unwrap();
    assert_eq!(writer.join().unwrap(), Ok(8));
    sealed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    sealer.join().unwrap();

    assert!(fs::read(state.join("upper/src/a.rs")).unwrap().starts_with(b"admitted"));
    assert_eq!(overlay.write(a, 0, b"late"), Err(libc::EROFS));
}

/// Concurrent detach callers time out independently without reopening admission or cancelling
/// the admitted edit. A retry can finish once the writer releases its guard.
#[test]
fn a_timed_out_seal_stays_closed_and_retries_after_the_admitted_write() {
    let machine = Machine::new();
    let (state, overlay) = machine.project("p-timeout", &machine.chat_folder("timeout"));
    let overlay = Arc::new(overlay);
    let src = overlay.lookup(overlay.root(), "src").unwrap().ino;
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    let (entered, release) = overlay.pause_next_mutation();
    let writing = overlay.clone();
    let writer = thread::spawn(move || writing.write(a, 0, b"admitted"));
    entered.recv_timeout(Duration::from_secs(1)).unwrap();

    let (finished, finished_rx) = mpsc::channel();
    let sealers: Vec<_> = (0..2)
        .map(|_| {
            let sealing = overlay.clone();
            let finished = finished.clone();
            thread::spawn(move || {
                finished.send(sealing.seal(Duration::from_millis(50))).unwrap();
            })
        })
        .collect();
    for _ in 0..2 {
        assert!(!finished_rx.recv_timeout(Duration::from_secs(1)).unwrap());
    }
    for sealer in sealers {
        sealer.join().unwrap();
    }
    assert!(overlay.is_sealed());
    let (refused, refused_rx) = mpsc::channel();
    let late = overlay.clone();
    let late_writer = thread::spawn(move || refused.send(late.write(a, 0, b"late")).unwrap());
    assert_eq!(refused_rx.recv_timeout(Duration::from_secs(1)).unwrap(), Err(libc::EROFS));
    late_writer.join().unwrap();
    assert!(!overlay.seal(Duration::ZERO));

    release.send(()).unwrap();
    assert_eq!(writer.join().unwrap(), Ok(8));
    assert!(overlay.seal(Duration::ZERO));
    assert!(fs::read(state.join("upper/src/a.rs")).unwrap().starts_with(b"admitted"));
    assert_eq!(overlay.write(a, 0, b"late"), Err(libc::EROFS));
}
