use super::classify::{CallClass, classify_command, is_pure_read};
use super::flush::{ConflictReason, DirMachineFs, MachineFs, Mutation, flush};
use super::replica::{
    DirReplica, NeedsMachine, ReadOutcome, ReplicaRead, ReplicaSource, WriteOutcome, read_text,
    write_text,
};
use super::*;
use std::sync::Arc;

struct Fixture {
    _dir: tempfile::TempDir,
    store: Arc<FileJournalStore>,
    replica: DirReplica,
    machine: DirMachineFs,
    machine_root: std::path::PathBuf,
}

/// A replica and a machine folder that start with the same files.
fn fixture(files: &[(&str, &str)]) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let replica_root = dir.path().join("replica");
    let machine_root = dir.path().join("machine");
    for root in [&replica_root, &machine_root] {
        for (path, text) in files {
            let p = root.join(path);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
    }
    std::fs::create_dir_all(&replica_root).unwrap();
    std::fs::create_dir_all(&machine_root).unwrap();
    Fixture {
        store: Arc::new(FileJournalStore::new(dir.path().join("journal"))),
        replica: DirReplica::new(&replica_root, DirReplica::DEFAULT_MAX_FILE_BYTES),
        machine: DirMachineFs::new(&machine_root),
        machine_root,
        _dir: dir,
    }
}

fn open(f: &Fixture) -> WriteJournal {
    WriteJournal::open(f.store.clone(), "m1").unwrap()
}

fn journaled(o: WriteOutcome) -> u64 {
    match o {
        WriteOutcome::Journaled(seq) => seq,
        other => panic!("expected a journaled write, got {other:?}"),
    }
}

fn machine_text(f: &Fixture, path: &str) -> Option<String> {
    std::fs::read_to_string(f.machine_root.join(path)).ok()
}

#[test]
fn rel_path_normalizes_and_refuses_escapes() {
    assert_eq!(rel_path("./src//a.rs").unwrap(), "src/a.rs");
    assert_eq!(rel_path("src\\b.rs").unwrap(), "src/b.rs");
    assert!(matches!(rel_path("/etc/passwd"), Err(PathError::Absolute(_))));
    assert!(matches!(rel_path("src/../../x"), Err(PathError::Escapes(_))));
    assert!(matches!(rel_path("./"), Err(PathError::Empty)));
    for reserved in [".cmux-journal-1.tmp", "src/.cmux-journal-x"] {
        assert!(matches!(rel_path(reserved), Err(PathError::Reserved(_))), "{reserved}");
    }
    for drive in ["C:/outside/file", "C:outside/file", "a/b:stream"] {
        assert!(matches!(rel_path(drive), Err(PathError::Absolute(_))), "{drive}");
    }
}

#[test]
fn reads_come_from_the_replica_and_see_the_agents_own_writes() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    assert_eq!(read_text(&j, &f.replica, "a.txt").unwrap(), ReadOutcome::Text("one".into()));
    assert_eq!(read_text(&j, &f.replica, "missing.txt").unwrap(), ReadOutcome::NotFound);

    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "new/b.txt", Some("b"), 2).unwrap());
    assert_eq!(read_text(&j, &f.replica, "a.txt").unwrap(), ReadOutcome::Text("two".into()));
    assert_eq!(read_text(&j, &f.replica, "./new/b.txt").unwrap(), ReadOutcome::Text("b".into()));

    journaled(write_text(&mut j, &f.replica, "a.txt", None, 3).unwrap());
    assert_eq!(read_text(&j, &f.replica, "a.txt").unwrap(), ReadOutcome::NotFound);
    // Nothing reached the machine yet.
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("one"));
    assert_eq!(machine_text(&f, "new/b.txt"), None);
    let paths: Vec<_> = j.overlay_paths().into_keys().collect();
    assert_eq!(paths, vec!["a.txt", "new/b.txt"]);
}

#[test]
fn each_entry_records_the_version_it_was_written_against() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("three"), 2).unwrap());
    journaled(write_text(&mut j, &f.replica, "c.txt", Some("c"), 3).unwrap());
    let e = j.entries();
    assert_eq!(e[0].base, Version::of(Some(b"one")));
    assert_eq!(e[1].base, Version::of(Some(b"two")));
    assert_eq!(e[2].base, Version::Absent);
    assert_eq!(e.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![1, 2, 3]);
}

#[test]
fn a_stale_replica_or_a_left_out_file_sends_the_call_to_the_machine() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("big.bin"), vec![b'x'; 64]).unwrap();
    std::fs::write(dir.path().join("bin.dat"), [0xff, 0xfe]).unwrap();
    let replica = DirReplica::new(dir.path(), 16);
    let store = Arc::new(FileJournalStore::new(dir.path().join("j")));
    let mut j = WriteJournal::open(store, "m").unwrap();
    assert_eq!(
        read_text(&j, &replica, "big.bin").unwrap(),
        ReadOutcome::NeedsMachine(NeedsMachine::MachineOnly)
    );
    assert_eq!(
        read_text(&j, &replica, "bin.dat").unwrap(),
        ReadOutcome::NeedsMachine(NeedsMachine::NotText)
    );
    assert_eq!(
        write_text(&mut j, &replica, "big.bin", Some("y"), 1).unwrap(),
        WriteOutcome::NeedsMachine(NeedsMachine::MachineOnly)
    );
    // A file a read calls not text is never written or deleted unseen.
    for edit in [Some("y"), None] {
        assert_eq!(
            write_text(&mut j, &replica, "bin.dat", edit, 1).unwrap(),
            WriteOutcome::NeedsMachine(NeedsMachine::NotText)
        );
    }
    assert!(j.is_empty());

    let generation = replica.generation();
    replica.invalidate();
    assert_eq!(
        read_text(&j, &replica, "anything").unwrap(),
        ReadOutcome::NeedsMachine(NeedsMachine::Stale)
    );
    assert!(j.is_empty());
    assert_eq!(replica.reseeded(), generation + 1);
    assert!(replica.is_fresh());
}

#[cfg(unix)]
#[test]
fn the_replica_never_follows_a_symlink_out_of_its_folder() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("secret"), "s").unwrap();
    let root = dir.path().join("replica");
    std::fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(dir.path().join("secret"), root.join("link")).unwrap();
    std::os::unix::fs::symlink(dir.path(), root.join("up")).unwrap();
    let replica = DirReplica::new(&root, 1024);
    assert_eq!(replica.read("link").unwrap(), replica::ReplicaRead::MachineOnly);
    assert_eq!(replica.read("up/secret").unwrap(), replica::ReplicaRead::MachineOnly);
    let machine = DirMachineFs::new(&root);
    assert!(machine.write(1, "up/secret", b"x", &Version::Absent).is_err());
    assert_eq!(std::fs::read_to_string(dir.path().join("secret")).unwrap(), "s");
}

#[test]
fn a_journal_survives_reopening_and_never_reuses_a_sequence_number() {
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a", Some("1"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "b", Some("2"), 2).unwrap());
    drop(j);
    let mut j = open(&f);
    assert_eq!(j.entries().len(), 2);
    assert_eq!(read_text(&j, &f.replica, "b").unwrap(), ReadOutcome::Text("2".into()));

    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.applied, vec![1, 2]);
    assert!(j.is_empty());
    drop(j);
    let mut j = open(&f);
    assert!(j.is_empty());
    assert_eq!(journaled(write_text(&mut j, &f.replica, "c", Some("3"), 3).unwrap()), 3);
    // Another machine's journal is its own.
    let other = WriteJournal::open(f.store.clone(), "m2").unwrap();
    assert!(other.is_empty());
}

#[test]
fn a_torn_last_line_is_dropped_and_the_next_append_still_reads_back() {
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a", Some("1"), 1).unwrap());
    drop(j);
    let path = f.store.path_for("m1");
    let mut text = std::fs::read_to_string(&path).unwrap();
    text.push_str("{\"entry\":{\"seq\":2,\"pa");
    std::fs::write(&path, text).unwrap();

    let mut j = open(&f);
    assert_eq!(j.entries().len(), 1);
    journaled(write_text(&mut j, &f.replica, "b", Some("2"), 2).unwrap());
    drop(j);
    let j = open(&f);
    assert_eq!(j.entries().iter().map(|e| e.path.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
}

#[test]
fn a_torn_tail_inside_a_utf8_character_still_loads() {
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a", Some("1"), 1).unwrap());
    drop(j);
    let path = f.store.path_for("m1");
    let mut bytes = std::fs::read(&path).unwrap();
    bytes.extend_from_slice(b"{\"entry\":{\"seq\":2,\"path\":\"\xc3");
    std::fs::write(&path, bytes).unwrap();
    let j = open(&f);
    assert_eq!(j.entries().len(), 1);
}

#[test]
fn two_different_entries_under_one_number_are_an_error() {
    let f = fixture(&[]);
    let path = f.store.path_for("m1");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let entry = |p: &str| serde_json::json!({"entry": {"seq": 1, "path": p, "op": {"kind": "delete"}, "base": {"kind": "absent"}, "atMs": 0}});
    std::fs::write(&path, format!("{}\n{}\n", entry("a"), entry("a"))).unwrap();
    assert_eq!(WriteJournal::open(f.store.clone(), "m1").unwrap().entries().len(), 1);
    std::fs::write(&path, format!("{}\n{}\n", entry("a"), entry("b"))).unwrap();
    assert!(WriteJournal::open(f.store.clone(), "m1").is_err());
}

/// A store whose appends write the record and then fail, as an fsync error would.
struct FlakyStore {
    inner: FileJournalStore,
    fail: std::sync::atomic::AtomicBool,
}

impl JournalStore for FlakyStore {
    fn load(&self, machine: &str) -> std::io::Result<JournalState> {
        self.inner.load(machine)
    }
    fn append(&self, machine: &str, entry: &Entry) -> std::io::Result<()> {
        if self.fail.swap(false, std::sync::atomic::Ordering::SeqCst) {
            self.inner.append(machine, entry)?;
            return Err(std::io::Error::other("fsync failed"));
        }
        self.inner.append(machine, entry)
    }
    fn clear_through(&self, machine: &str, seq: u64) -> std::io::Result<()> {
        self.inner.clear_through(machine, seq)
    }
}

#[test]
fn a_failed_append_never_lets_a_later_write_reuse_its_number() {
    let f = fixture(&[]);
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(FlakyStore {
        inner: FileJournalStore::new(dir.path()),
        fail: std::sync::atomic::AtomicBool::new(true),
    });
    let mut j = WriteJournal::open(store.clone(), "m").unwrap();
    assert!(write_text(&mut j, &f.replica, "a", Some("lost?"), 1).is_err());
    // Refused until reopened, so nothing can take seq 1.
    assert!(write_text(&mut j, &f.replica, "b", Some("b"), 2).is_err());
    let mut j = WriteJournal::open(store, "m").unwrap();
    let seq = journaled(write_text(&mut j, &f.replica, "b", Some("b"), 3).unwrap());
    assert!(j.entries().iter().filter(|e| e.seq == seq).count() == 1);
    assert_eq!(j.entries().last().map(|e| e.path.as_str()), Some("b"));
}

#[test]
fn the_file_store_cuts_back_a_record_whose_append_failed() {
    // FileJournalStore's own rollback: a failed append leaves the file as it was.
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a", Some("1"), 1).unwrap());
    let before = std::fs::read(f.store.path_for("m1")).unwrap();
    drop(j);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let path = f.store.path_for("m1");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
        let mut j = open(&f);
        let failed = write_text(&mut j, &f.replica, "b", Some("2"), 2);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        // Root may write anyway; only judge the rollback when the append really failed.
        if failed.is_err() {
            assert_eq!(std::fs::read(&path).unwrap(), before);
        }
    }
}

#[test]
fn a_corrupt_middle_line_is_an_error_not_a_silent_drop() {
    let f = fixture(&[]);
    let path = f.store.path_for("m1");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "not json\n{\"cleared\":{\"through\":0}}\n").unwrap();
    assert!(WriteJournal::open(f.store.clone(), "m1").is_err());
}

#[test]
fn a_stored_path_outside_the_folder_is_refused_on_open() {
    let f = fixture(&[]);
    let path = f.store.path_for("m1");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let line = serde_json::json!({"entry": {"seq": 1, "path": "../x", "op": {"kind": "delete"}, "base": {"kind": "absent"}, "atMs": 0}});
    std::fs::write(&path, format!("{line}\n")).unwrap();
    assert!(WriteJournal::open(f.store.clone(), "m1").is_err());
}

#[test]
fn flush_applies_in_order_on_the_machine() {
    let f = fixture(&[("a.txt", "one"), ("gone.txt", "x")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("three"), 2).unwrap());
    journaled(write_text(&mut j, &f.replica, "dir/new.txt", Some("n"), 3).unwrap());
    journaled(write_text(&mut j, &f.replica, "gone.txt", None, 4).unwrap());
    let report = flush(&mut j, &f.machine).unwrap();
    assert!(report.is_clean(), "{report:?}");
    assert_eq!(report.applied, vec![1, 2, 3, 4]);
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("three"));
    assert_eq!(machine_text(&f, "dir/new.txt").as_deref(), Some("n"));
    assert_eq!(machine_text(&f, "gone.txt"), None);
    assert!(j.is_empty());
}

#[test]
fn a_file_changed_on_the_machine_fails_that_edit_and_later_edits_to_it() {
    let f = fixture(&[("a.txt", "one"), ("b.txt", "b")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "b.txt", Some("b2"), 2).unwrap());
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("three"), 3).unwrap());
    // A process on the machine thawed and wrote a.txt before the flush.
    std::fs::write(f.machine_root.join("a.txt"), "theirs").unwrap();

    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.applied, vec![2]);
    assert_eq!(report.conflicts.len(), 2);
    let first = &report.conflicts[0];
    assert_eq!(first.seq, 1);
    assert_eq!(first.machine_copy.as_deref(), Some("theirs"));
    assert_eq!(
        first.reason,
        ConflictReason::ChangedOnMachine {
            expected: Version::of(Some(b"one")),
            found: Version::of(Some(b"theirs")),
        }
    );
    assert!(first.message().contains("a.txt changed on the machine since your edit"));
    assert!(first.message().contains("theirs"));
    assert_eq!(report.conflicts[1].reason, ConflictReason::EarlierEditFailed { seq: 1 });
    // The machine's copy is kept; the other file applied; the journal is settled.
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("theirs"));
    assert_eq!(machine_text(&f, "b.txt").as_deref(), Some("b2"));
    assert!(j.is_empty());
}

#[test]
fn a_new_file_that_appeared_on_the_machine_is_a_conflict() {
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "n.txt", Some("mine"), 1).unwrap());
    std::fs::write(f.machine_root.join("n.txt"), "theirs").unwrap();
    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.conflicts.len(), 1);
    assert_eq!(machine_text(&f, "n.txt").as_deref(), Some("theirs"));
}

#[test]
fn replaying_a_flush_that_already_applied_writes_nothing_twice() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("three"), 2).unwrap());
    journaled(write_text(&mut j, &f.replica, "b.txt", Some("b"), 3).unwrap());
    // An earlier flush applied every entry, then died before clearing the journal.
    std::fs::write(f.machine_root.join("a.txt"), "three").unwrap();
    std::fs::write(f.machine_root.join("b.txt"), "b").unwrap();
    let report = flush(&mut j, &f.machine).unwrap();
    assert!(report.is_clean(), "{report:?}");
    assert_eq!(report.already, vec![1, 2, 3]);
    assert!(report.applied.is_empty());
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("three"));
}

/// A machine whose writes fail for one path.
struct Failing<'a> {
    inner: &'a DirMachineFs,
    bad: &'a str,
}

impl MachineFs for Failing<'_> {
    fn read(&self, path: &str) -> std::io::Result<Option<Vec<u8>>> {
        self.inner.read(path)
    }
    fn write(
        &self,
        seq: u64,
        path: &str,
        bytes: &[u8],
        expected: &Version,
    ) -> std::io::Result<Mutation> {
        if path == self.bad {
            return Err(std::io::Error::other("disk full"));
        }
        self.inner.write(seq, path, bytes, expected)
    }
    fn remove(&self, seq: u64, path: &str, expected: &Version) -> std::io::Result<Mutation> {
        self.inner.remove(seq, path, expected)
    }
    fn make_durable(&self, path: &str) -> std::io::Result<()> {
        self.inner.make_durable(path)
    }
}

/// Records which paths the flush made durable without writing them.
struct Recording<'a> {
    inner: &'a DirMachineFs,
    synced: std::sync::Mutex<Vec<String>>,
}

impl MachineFs for Recording<'_> {
    fn read(&self, path: &str) -> std::io::Result<Option<Vec<u8>>> {
        self.inner.read(path)
    }
    fn write(
        &self,
        seq: u64,
        path: &str,
        bytes: &[u8],
        expected: &Version,
    ) -> std::io::Result<Mutation> {
        self.inner.write(seq, path, bytes, expected)
    }
    fn remove(&self, seq: u64, path: &str, expected: &Version) -> std::io::Result<Mutation> {
        self.inner.remove(seq, path, expected)
    }
    fn make_durable(&self, path: &str) -> std::io::Result<()> {
        self.synced.lock().unwrap().push(path.to_owned());
        self.inner.make_durable(path)
    }
}

/// A machine where a guest process saves `path` right after the flush reads it, before the
/// flush's own write or remove: the interleaving a conditional mutation must catch.
struct Racing<'a> {
    inner: &'a DirMachineFs,
    root: &'a std::path::Path,
    path: &'a str,
    guest: &'a str,
    raced: std::sync::atomic::AtomicBool,
}

impl MachineFs for Racing<'_> {
    fn read(&self, path: &str) -> std::io::Result<Option<Vec<u8>>> {
        let now = self.inner.read(path)?;
        if path == self.path && !self.raced.swap(true, std::sync::atomic::Ordering::SeqCst) {
            std::fs::write(self.root.join(path), self.guest)?;
        }
        Ok(now)
    }
    fn write(
        &self,
        seq: u64,
        path: &str,
        bytes: &[u8],
        expected: &Version,
    ) -> std::io::Result<Mutation> {
        self.inner.write(seq, path, bytes, expected)
    }
    fn remove(&self, seq: u64, path: &str, expected: &Version) -> std::io::Result<Mutation> {
        self.inner.remove(seq, path, expected)
    }
    fn make_durable(&self, path: &str) -> std::io::Result<()> {
        self.inner.make_durable(path)
    }
}

#[test]
fn a_save_between_the_flush_read_and_its_mutation_is_a_conflict_not_an_overwrite() {
    // Replace, remove and create, each raced by a guest save.
    for (start, edit) in [(Some("one"), Some("agent")), (Some("one"), None), (None, Some("agent"))]
    {
        let files: Vec<(&str, &str)> = start.map(|s| ("a.txt", s)).into_iter().collect();
        let f = fixture(&files);
        let mut j = open(&f);
        journaled(write_text(&mut j, &f.replica, "a.txt", edit, 1).unwrap());
        journaled(write_text(&mut j, &f.replica, "a.txt", Some("later"), 2).unwrap());
        let machine = Racing {
            inner: &f.machine,
            root: &f.machine_root,
            path: "a.txt",
            guest: "guest save",
            raced: std::sync::atomic::AtomicBool::new(false),
        };
        let report = flush(&mut j, &machine).unwrap();
        assert!(report.applied.is_empty(), "{start:?} {edit:?}: {report:?}");
        assert_eq!(report.conflicts.len(), 2, "{report:?}");
        assert!(matches!(
            report.conflicts.first().map(|c| (&c.reason, c.machine_copy.as_deref())),
            Some((ConflictReason::ChangedOnMachine { .. }, Some("guest save")))
        ));
        assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("guest save"));
    }
}

#[cfg(unix)]
#[test]
fn a_linked_folder_root_is_refused_for_reads_and_flushes() {
    let f = fixture(&[("a.txt", "one")]);
    let outside = f._dir.path().join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("a.txt"), "secret").unwrap();
    let link = f._dir.path().join("link");
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    let replica = DirReplica::new(&link, DirReplica::DEFAULT_MAX_FILE_BYTES);
    assert!(replica.read("a.txt").is_err());
    let machine = DirMachineFs::new(&link);
    assert!(machine.read("a.txt").is_err());
    assert!(machine.write(1, "a.txt", b"x", &Version::of(Some(b"secret"))).is_err());
    assert!(machine.remove(1, "a.txt", &Version::of(Some(b"secret"))).is_err());
    assert_eq!(std::fs::read_to_string(outside.join("a.txt")).unwrap(), "secret");
}

/// A store that keeps nothing: for numbering tests.
struct NullStore;

impl JournalStore for NullStore {
    fn load(&self, _: &str) -> std::io::Result<JournalState> {
        Ok(JournalState { cleared_through: u64::MAX - 2, entries: Vec::new() })
    }
    fn append(&self, _: &str, _: &Entry) -> std::io::Result<()> {
        Ok(())
    }
    fn clear_through(&self, _: &str, _: u64) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn sequence_numbers_run_out_instead_of_repeating() {
    let mut j = WriteJournal::open(Arc::new(NullStore), "m").unwrap();
    assert_eq!(j.record("a", Op::Delete, Version::Absent, 1).unwrap(), u64::MAX - 1);
    assert!(j.record("a", Op::Delete, Version::Absent, 2).is_err());
    assert_eq!(j.entries().len(), 1);
}

/// The file names in the machine folder `dir`, sorted.
fn names(dir: &std::path::Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    v.sort();
    v
}

#[cfg(unix)]
#[test]
fn a_second_save_during_the_swap_back_is_kept_not_deleted() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("agent"), 1).unwrap());
    let root = f.machine_root.clone();
    // The second save lands after the first swap, before the swap back.
    let fs = DirMachineFs::new(&f.machine_root).with_hook(move |stage| {
        if stage == "swapped" {
            std::fs::write(root.join("a.txt"), "guest 2").unwrap();
        }
    });
    let machine = Racing {
        inner: &fs,
        root: &f.machine_root,
        path: "a.txt",
        guest: "guest 1",
        raced: std::sync::atomic::AtomicBool::new(false),
    };
    let report = flush(&mut j, &machine).unwrap();
    assert!(report.applied.is_empty(), "{report:?}");
    assert_eq!(report.conflicts.len(), 1, "{report:?}");
    // Both machine saves are still on disk; the agent's bytes are gone.
    let mut texts: Vec<String> = names(&f.machine_root)
        .iter()
        .map(|n| std::fs::read_to_string(f.machine_root.join(n)).unwrap())
        .collect();
    texts.sort();
    assert_eq!(texts, vec!["guest 1".to_owned(), "guest 2".to_owned()]);
    assert!(names(&f.machine_root).contains(&"a.txt.journal-conflict-1".to_owned()));
}

#[cfg(unix)]
#[test]
fn a_save_after_the_swap_is_a_later_write_that_wins() {
    // The contract: the swap is when the agent's write happens. A machine save after it
    // replaces the agent's bytes, exactly as a later write would on a running machine.
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("agent"), 1).unwrap());
    let root = f.machine_root.clone();
    let fs = DirMachineFs::new(&f.machine_root).with_hook(move |stage| {
        if stage == "swapped" {
            std::fs::write(root.join("a.txt"), "later").unwrap();
        }
    });
    let report = flush(&mut j, &fs).unwrap();
    assert_eq!(report.applied, vec![1], "{report:?}");
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("later"));
    assert_eq!(names(&f.machine_root), vec!["a.txt".to_owned()]);
}

#[cfg(unix)]
#[test]
fn a_flush_that_died_after_its_swap_puts_the_machine_copy_back_and_reports_it() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("agent"), 1).unwrap());
    // The state a crash right after the swap leaves when the machine had saved "guest" first.
    std::fs::write(f.machine_root.join("a.txt"), "agent").unwrap();
    std::fs::write(f.machine_root.join(".cmux-journal-1.tmp"), "guest").unwrap();
    let report = flush(&mut j, &f.machine).unwrap();
    assert!(report.already.is_empty() && report.applied.is_empty(), "{report:?}");
    assert!(matches!(
        report.conflicts.first().map(|c| c.machine_copy.as_deref()),
        Some(Some("guest"))
    ));
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("guest"));
    assert_eq!(names(&f.machine_root), vec!["a.txt".to_owned()]);
}

#[cfg(unix)]
#[test]
fn a_flush_that_died_after_a_clean_swap_counts_as_applied() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("agent"), 1).unwrap());
    std::fs::write(f.machine_root.join("a.txt"), "agent").unwrap();
    std::fs::write(f.machine_root.join(".cmux-journal-1.tmp"), "one").unwrap();
    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.already, vec![1], "{report:?}");
    assert_eq!(names(&f.machine_root), vec!["a.txt".to_owned()]);
}

#[cfg(unix)]
#[test]
fn a_remove_that_died_after_moving_a_machine_save_aside_puts_it_back() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", None, 1).unwrap());
    std::fs::remove_file(f.machine_root.join("a.txt")).unwrap();
    std::fs::write(f.machine_root.join(".cmux-journal-1.aside"), "guest").unwrap();
    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.conflicts.len(), 1, "{report:?}");
    assert_eq!(machine_text(&f, "a.txt").as_deref(), Some("guest"));
    assert_eq!(names(&f.machine_root), vec!["a.txt".to_owned()]);
}

/// A replica that something on the machine invalidates while a read is in flight.
struct InvalidatedDuringRead(DirReplica);

impl ReplicaSource for InvalidatedDuringRead {
    fn generation(&self) -> u64 {
        self.0.generation()
    }
    fn is_fresh(&self) -> bool {
        self.0.is_fresh()
    }
    fn read(&self, path: &str) -> std::io::Result<ReplicaRead> {
        let r = self.0.read(path);
        self.0.invalidate();
        r
    }
}

#[test]
fn a_replica_invalidated_during_a_read_is_stale_for_reads_and_writes() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    let replica = InvalidatedDuringRead(f.replica);
    assert_eq!(
        read_text(&j, &replica, "a.txt").unwrap(),
        ReadOutcome::NeedsMachine(NeedsMachine::Stale)
    );
    replica.0.reseeded();
    assert_eq!(
        write_text(&mut j, &replica, "a.txt", Some("x"), 1).unwrap(),
        WriteOutcome::NeedsMachine(NeedsMachine::Stale)
    );
    assert!(j.is_empty());
}

#[test]
fn an_entry_found_already_applied_is_made_durable_before_it_is_cleared() {
    let f = fixture(&[("a.txt", "one")]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "deep/new/b.txt", Some("b"), 2).unwrap());
    std::fs::write(f.machine_root.join("a.txt"), "two").unwrap();
    let machine = Recording { inner: &f.machine, synced: std::sync::Mutex::new(Vec::new()) };
    let report = flush(&mut j, &machine).unwrap();
    assert_eq!(report.already, vec![1]);
    assert_eq!(report.applied, vec![2]);
    assert_eq!(*machine.synced.lock().unwrap(), vec!["a.txt".to_owned()]);
    assert_eq!(machine_text(&f, "deep/new/b.txt").as_deref(), Some("b"));
}

#[test]
fn an_io_error_stops_the_flush_and_keeps_the_rest_for_the_next_try() {
    let f = fixture(&[]);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "a", Some("1"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "b", Some("2"), 2).unwrap());
    journaled(write_text(&mut j, &f.replica, "c", Some("3"), 3).unwrap());
    let report = flush(&mut j, &Failing { inner: &f.machine, bad: "b" }).unwrap();
    assert_eq!(report.applied, vec![1]);
    assert_eq!(report.stopped.as_ref().map(|s| s.0), Some(2));
    assert_eq!(j.entries().iter().map(|e| e.seq).collect::<Vec<_>>(), vec![2, 3]);
    drop(j);
    let mut j = open(&f);
    assert_eq!(j.entries().len(), 2);
    let report = flush(&mut j, &f.machine).unwrap();
    assert_eq!(report.applied, vec![2, 3]);
    assert_eq!(machine_text(&f, "c").as_deref(), Some("3"));
}

#[test]
fn pure_reads_are_classified_reads() {
    for cmd in [
        "ls -la src",
        "cat README.md",
        "git log --oneline -20",
        "git show HEAD~1 --stat",
        "git diff -p origin/main",
        "git status --short && git branch --show-current",
        "grep -rn 'fn main' src | head -20",
        "rg -n \"a b\" crates",
        "find . -name 'x.rs' -type f",
        "tail -n 50 log.txt",
        "wc -l src/lib.rs",
    ] {
        assert_eq!(classify_command(cmd), CallClass::Read, "{cmd}");
    }
}

#[test]
fn anything_that_could_run_or_write_is_an_exec() {
    for cmd in [
        "",
        "cargo test",
        "cat a > b",
        "cat a >> b",
        "cat < a",
        "echo $(rm -rf x)",
        "cat `whoami`",
        "ls; rm x",
        "ls & rm x",
        "ls || rm x",
        "ls\nrm x",
        "FOO=1 ls",
        "git -c core.pager=sh log",
        "git -C other log",
        "git commit -m x",
        "git checkout main",
        "git fetch",
        "git branch new-branch",
        "git branch -D old",
        "git diff --output=out.txt",
        "git diff --ext-diff",
        "git grep -O x",
        "git log --textconv",
        "git cat-file --filters HEAD:a",
        "rg --hostname-bin ./helper --hyperlink-format default x a",
        "find . -delete",
        "find . -exec rm {} ;",
        "rg --pre ./run.sh x",
        "sort -o out a",
        "tail -f log",
        "tail -nf 10 log",
        "sort -ofile a",
        "sort -T /tmp big.txt",
        "sort --outp=file a",
        "git diff --outp=f",
        "git grep -nO x",
        "cat ~/secret",
        "cat *.rs",
        "grep \"$HOME\" a",
        "grep 'a|b' f",
        "cat 'unterminated",
        "sudo cat a",
        "python3 -c 'print(1)'",
    ] {
        assert!(!is_pure_read(cmd), "{cmd:?} must be an exec");
    }
}

#[test]
fn the_flag_is_off_by_default_and_round_trips() {
    let config = crate::config::Config::default();
    assert!(!config.write_journal.enabled);
    let mut value = serde_json::to_value(&config).unwrap();
    assert!(value.get("writeJournal").is_none());
    value["writeJournal"] = serde_json::json!({"enabled": true});
    let on: crate::config::Config = serde_json::from_value(value).unwrap();
    assert!(on.write_journal.enabled);
    let mut off = serde_json::to_value(&config).unwrap();
    off["writeJournal"] = serde_json::json!({});
    let off: crate::config::Config = serde_json::from_value(off).unwrap();
    assert!(!off.write_journal.enabled);
}

#[cfg(unix)]
#[test]
fn a_replacement_is_staged_no_more_readable_than_the_file_it_replaces() {
    use std::os::unix::fs::PermissionsExt;
    let f = fixture(&[("secret.txt", "one"), ("run.sh", "echo one")]);
    let set = |n: &str, m: u32| {
        std::fs::set_permissions(f.machine_root.join(n), std::fs::Permissions::from_mode(m))
            .unwrap();
    };
    set("secret.txt", 0o600);
    set("run.sh", 0o755);
    let mut j = open(&f);
    journaled(write_text(&mut j, &f.replica, "secret.txt", Some("two"), 1).unwrap());
    journaled(write_text(&mut j, &f.replica, "run.sh", Some("echo two"), 2).unwrap());
    let root = f.machine_root.clone();
    let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = seen.clone();
    // The staged copy, with the agent's bytes already in it, before it takes the file's place.
    let fs = DirMachineFs::new(&f.machine_root).with_hook(move |stage| {
        if stage == "staged" {
            for e in std::fs::read_dir(&root).unwrap() {
                let e = e.unwrap();
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with(STAGING_PREFIX) {
                    let mode = e.metadata().unwrap().permissions().mode() & 0o7777;
                    log.lock().unwrap().push(mode);
                }
            }
        }
    });
    let report = flush(&mut j, &fs).unwrap();
    assert!(report.conflicts.is_empty(), "{report:?}");
    assert_eq!(*seen.lock().unwrap(), vec![0o600, 0o755]);
    let mode =
        |n: &str| std::fs::metadata(f.machine_root.join(n)).unwrap().permissions().mode() & 0o7777;
    assert_eq!((mode("secret.txt"), mode("run.sh")), (0o600, 0o755));
    assert_eq!(machine_text(&f, "secret.txt").as_deref(), Some("two"));
}
