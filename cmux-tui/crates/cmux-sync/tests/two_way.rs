//! Two-way folder sync between a Mac and a VM on the three-tree rule (RFD 0140 section 5): every
//! row of the table, both orders of events, ends in the same tree on both sides; a restart in the
//! middle of a sync keeps the synced revision; and a seeded random schedule never diverges or loses
//! an edit.

use std::collections::BTreeMap;

use cmux_sync::two_way::{self, CONFLICT_SUFFIX, Content, MemStore, Op, Revision, Tree};
use sha2::{Digest as _, Sha256};

/// File contents by hash; text merges by line with a real diff3.
#[derive(Default)]
struct Blobs(BTreeMap<String, Vec<u8>>);

impl Blobs {
    fn put(&mut self, bytes: &[u8]) -> String {
        let hash: String = Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect();
        self.0.insert(hash.clone(), bytes.to_vec());
        hash
    }
    fn text(&self, hash: &str) -> &str {
        std::str::from_utf8(&self.0[hash]).unwrap()
    }
}

impl Content for Blobs {
    fn is_text(&self, hash: &str) -> bool {
        !self.0[hash].contains(&0)
    }
    fn merge(&mut self, base: Option<&str>, local: &str, remote: &str) -> Option<String> {
        let base = base.map(|h| self.text(h).to_owned()).unwrap_or_default();
        let merged = diffy::merge(&base, self.text(local), self.text(remote)).ok()?;
        Some(self.put(merged.as_bytes()))
    }
}

/// A Mac, a VM and the store both read.
struct Pair {
    mac: Tree,
    vm: Tree,
    store: MemStore,
    blobs: Blobs,
}

const PAIR: &str = "mac:/Users/me/proj<->vm:/root/proj";

impl Pair {
    fn new(files: &[(&str, &str)]) -> Self {
        let mut blobs = Blobs::default();
        let tree: Tree =
            files.iter().map(|(p, c)| (p.to_string(), blobs.put(c.as_bytes()))).collect();
        let mut store = MemStore::default();
        two_way::commit(&mut store, PAIR, &tree);
        Self { mac: tree.clone(), vm: tree, store, blobs }
    }

    fn edit(&mut self, on: Side, path: &str, content: Option<&[u8]>) {
        let hash = content.map(|c| self.blobs.put(c));
        let tree = match on {
            Side::Mac => &mut self.mac,
            Side::Vm => &mut self.vm,
        };
        match hash {
            Some(h) => tree.insert(path.to_owned(), h),
            None => tree.remove(path),
        };
    }

    /// One full sync: load synced from the store, decide, apply both sides, commit.
    fn sync(&mut self) -> two_way::Round {
        let synced = two_way::load(&self.store, PAIR).unwrap();
        let round = two_way::round(&synced, &self.mac, &self.vm, &mut self.blobs);
        two_way::apply(&mut self.mac, &round.local_ops);
        two_way::apply(&mut self.vm, &round.remote_ops);
        two_way::commit(&mut self.store, PAIR, &round.synced);
        round
    }

    fn settled(&mut self) {
        assert_eq!(self.mac, self.vm, "both sides hold the same tree");
        assert_eq!(two_way::load(&self.store, PAIR).unwrap(), self.mac, "synced is that tree");
        let again = self.sync();
        assert!(
            again.local_ops.is_empty() && again.remote_ops.is_empty(),
            "a second sync does nothing"
        );
    }

    fn read(&self, path: &str) -> Option<String> {
        self.mac.get(path).map(|h| self.blobs.text(h).to_owned())
    }
}

#[derive(Clone, Copy, Debug)]
enum Side {
    Mac,
    Vm,
}

type Edit<'a> = (Side, &'a str, Option<&'a [u8]>);

/// Runs the two edits in both orders, then a sync; checks both runs settle to the same tree and
/// returns it with the first run's round.
fn both_orders(start: &[(&str, &str)], a: Edit<'_>, b: Edit<'_>) -> (Pair, two_way::Round) {
    let mut first = Pair::new(start);
    first.edit(a.0, a.1, a.2);
    first.edit(b.0, b.1, b.2);
    let round = first.sync();
    first.settled();

    let mut second = Pair::new(start);
    second.edit(b.0, b.1, b.2);
    second.edit(a.0, a.1, a.2);
    second.sync();
    second.settled();
    assert_eq!(first.mac, second.mac, "the order of the edits does not change the result");
    (first, round)
}

const START: &[(&str, &str)] = &[("a.txt", "one\ntwo\nthree\n"), ("keep.txt", "x\n")];

#[test]
fn row_same_same_nothing() {
    let mut pair = Pair::new(START);
    let round = pair.sync();
    assert!(round.local_ops.is_empty() && round.remote_ops.is_empty());
    pair.settled();
}

#[test]
fn row_changed_same_pushes_to_the_vm() {
    let (pair, round) = both_orders(
        START,
        (Side::Mac, "a.txt", Some(b"one\nTWO\nthree\n")),
        (Side::Mac, "new.txt", Some(b"hi\n")),
    );
    assert!(round.local_ops.is_empty());
    assert_eq!(round.remote_ops.len(), 2);
    assert_eq!(pair.read("a.txt").unwrap(), "one\nTWO\nthree\n");
    assert_eq!(pair.read("new.txt").unwrap(), "hi\n");
}

#[test]
fn row_same_changed_applies_on_the_mac() {
    let (pair, round) =
        both_orders(START, (Side::Vm, "a.txt", None), (Side::Vm, "made-on-vm.txt", Some(b"vm\n")));
    assert!(round.remote_ops.is_empty());
    assert!(round.local_ops.contains(&Op::Delete { path: "a.txt".into() }));
    assert_eq!(pair.read("a.txt"), None);
    assert_eq!(pair.read("made-on-vm.txt").unwrap(), "vm\n");
}

#[test]
fn row_both_changed_alike_records_synced() {
    let same: &[u8] = b"one\nboth\nthree\n";
    let (pair, round) =
        both_orders(START, (Side::Mac, "a.txt", Some(same)), (Side::Vm, "a.txt", Some(same)));
    assert!(round.local_ops.is_empty() && round.remote_ops.is_empty());
    assert_eq!(pair.read("a.txt").unwrap(), "one\nboth\nthree\n");
}

#[test]
fn row_both_changed_differently_text_merges_three_way() {
    let (pair, round) = both_orders(
        START,
        (Side::Mac, "a.txt", Some(b"ONE\ntwo\nthree\n")),
        (Side::Vm, "a.txt", Some(b"one\ntwo\nTHREE\n")),
    );
    assert_eq!(round.merged, vec!["a.txt".to_string()]);
    assert!(round.conflicts.is_empty());
    assert_eq!(pair.read("a.txt").unwrap(), "ONE\ntwo\nTHREE\n");
}

#[test]
fn row_both_changed_differently_overlap_keeps_a_conflict_file() {
    let (pair, round) = both_orders(
        START,
        (Side::Mac, "a.txt", Some(b"one\nmac\nthree\n")),
        (Side::Vm, "a.txt", Some(b"one\nvm\nthree\n")),
    );
    assert_eq!(round.conflicts, vec!["a.txt".to_string()]);
    assert_eq!(pair.read("a.txt").unwrap(), "one\nvm\nthree\n");
    assert_eq!(pair.read(&format!("a.txt{CONFLICT_SUFFIX}")).unwrap(), "one\nmac\nthree\n");
}

#[test]
fn row_both_changed_differently_binary_keeps_a_conflict_file() {
    let (pair, round) = both_orders(
        &[("img.bin", "\0base")],
        (Side::Mac, "img.bin", Some(b"\0mac")),
        (Side::Vm, "img.bin", Some(b"\0vm")),
    );
    assert_eq!(round.conflicts, vec!["img.bin".to_string()]);
    assert!(round.merged.is_empty());
    assert_eq!(pair.read("img.bin").unwrap(), "\0vm");
    assert_eq!(pair.read(&format!("img.bin{CONFLICT_SUFFIX}")).unwrap(), "\0mac");
}

#[test]
fn row_deleted_changed_is_a_conflict_not_a_delete() {
    let (pair, round) =
        both_orders(START, (Side::Mac, "a.txt", None), (Side::Vm, "a.txt", Some(b"vm edit\n")));
    assert_eq!(round.conflicts, vec!["a.txt".to_string()]);
    assert_eq!(pair.read("a.txt").unwrap(), "vm edit\n");
}

#[test]
fn row_changed_deleted_is_a_conflict_not_a_delete() {
    let (pair, round) =
        both_orders(START, (Side::Mac, "a.txt", Some(b"mac edit\n")), (Side::Vm, "a.txt", None));
    assert_eq!(round.conflicts, vec!["a.txt".to_string()]);
    assert_eq!(pair.read("a.txt").unwrap(), "mac edit\n");
}

#[test]
fn row_deleted_deleted_records_synced() {
    let (pair, round) = both_orders(START, (Side::Mac, "a.txt", None), (Side::Vm, "a.txt", None));
    assert!(round.local_ops.is_empty() && round.remote_ops.is_empty());
    assert_eq!(pair.read("a.txt"), None);
    assert!(!two_way::load(&pair.store, PAIR).unwrap().contains_key("a.txt"));
}

#[test]
fn a_sync_between_the_two_edits_converges_too() {
    // Mac edits, sync, VM edits, sync; and the other way round: both settle, no conflict.
    for (a, b) in [(Side::Mac, Side::Vm), (Side::Vm, Side::Mac)] {
        let mut pair = Pair::new(START);
        pair.edit(a, "a.txt", Some(b"first\n"));
        pair.sync();
        pair.edit(b, "a.txt", Some(b"second\n"));
        let round = pair.sync();
        assert!(round.conflicts.is_empty());
        pair.settled();
        assert_eq!(pair.read("a.txt").unwrap(), "second\n");
    }
}

#[test]
fn a_conflict_file_name_already_taken_gets_the_next_one() {
    let taken = format!("a.txt{CONFLICT_SUFFIX}");
    let mut pair = Pair::new(&[("a.txt", "base\n"), (taken.as_str(), "older conflict\n")]);
    pair.edit(Side::Mac, "a.txt", Some(b"mac\n"));
    pair.edit(Side::Vm, "a.txt", Some(b"vm\n"));
    pair.sync();
    pair.settled();
    assert_eq!(pair.read(&taken).unwrap(), "older conflict\n");
    assert_eq!(pair.read(&format!("{taken}-2")).unwrap(), "mac\n");
}

#[test]
fn a_restart_mid_sync_keeps_the_synced_revision() {
    let mut pair = Pair::new(START);
    pair.edit(Side::Mac, "a.txt", Some(b"mac\n"));
    pair.edit(Side::Vm, "made-on-vm.txt", Some(b"vm\n"));
    // The round runs and the Mac's ops land, then the daemon dies before the VM's ops and before
    // the head moves.
    let synced = two_way::load(&pair.store, PAIR).unwrap();
    let round = two_way::round(&synced, &pair.mac, &pair.vm, &mut pair.blobs);
    two_way::apply(&mut pair.mac, &round.local_ops);
    // The store's bytes survive the restart; a new daemon reads the same head.
    let store_after_restart = pair.store.clone();
    pair.store = store_after_restart;
    assert_eq!(two_way::load(&pair.store, PAIR).unwrap(), synced, "the old head is still whole");
    let again = pair.sync();
    assert!(again.conflicts.is_empty(), "what already landed reads as agreed, not as a conflict");
    pair.settled();
    assert_eq!(pair.read("a.txt").unwrap(), "mac\n");
    assert_eq!(pair.read("made-on-vm.txt").unwrap(), "vm\n");
}

#[test]
fn a_crash_between_revision_and_head_leaves_the_old_head() {
    let mut pair = Pair::new(START);
    let old = pair.store.heads[PAIR].clone();
    pair.edit(Side::Mac, "a.txt", Some(b"mac\n"));
    let synced = two_way::load(&pair.store, PAIR).unwrap();
    let round = two_way::round(&synced, &pair.mac, &pair.vm, &mut pair.blobs);
    // The revision is written, the head is not.
    let revision = Revision { tree: round.synced };
    two_way::Store::put(&mut pair.store, &revision.id(), revision.encode());
    assert_eq!(pair.store.heads[PAIR], old);
    pair.sync();
    pair.settled();
}

#[test]
fn a_damaged_revision_is_an_error_not_an_empty_base() {
    let mut pair = Pair::new(START);
    let head = pair.store.heads[PAIR].clone();
    pair.store.blobs.get_mut(&head).unwrap().push(b'!');
    assert!(two_way::load(&pair.store, PAIR).is_err());
    pair.store.blobs.remove(&head);
    assert!(two_way::load(&pair.store, PAIR).is_err());
}

#[test]
fn revisions_round_trip_any_path() {
    let tree: Tree = [("a\nb", "h1"), ("plain", "h2"), ("ünï:cødé", "h3")]
        .into_iter()
        .map(|(p, h)| (p.to_owned(), h.to_owned()))
        .collect();
    let revision = Revision { tree };
    assert_eq!(Revision::decode(&revision.encode()).unwrap(), revision);
    assert_eq!(revision.id(), Revision::decode(&revision.encode()).unwrap().id());
}

/// A small seeded generator, so the schedule is the same on every run.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

#[test]
fn seeded_schedules_never_diverge_or_lose_an_edit() {
    let paths = ["a.txt", "b.txt", "c.bin", "d/e.txt"];
    for seed in 1..=300u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut pair = Pair::new(&[("a.txt", "1\n2\n3\n4\n"), ("b.txt", "b\n")]);
        // Every content either side ever held last before a sync must still exist after it,
        // at its path or in a conflict file (an edit is never lost).
        for step in 0..40 {
            let side = if rng.below(2) == 0 { Side::Mac } else { Side::Vm };
            let path = paths[rng.below(paths.len() as u64) as usize];
            match rng.below(6) {
                0 => pair.edit(side, path, None),
                _ => {
                    let line = rng.below(4);
                    let mut body: Vec<u8> = (0..4)
                        .map(|i| {
                            if i == line {
                                format!("{seed}-{step}\n")
                            } else {
                                format!("{}\n", i + 1)
                            }
                        })
                        .collect::<String>()
                        .into_bytes();
                    if path.ends_with(".bin") {
                        body.insert(0, 0);
                    }
                    pair.edit(side, path, Some(&body));
                }
            }
            if rng.below(4) == 0 {
                // Each side's own edits since the last sync (content that differs from synced).
                let synced = two_way::load(&pair.store, PAIR).unwrap();
                let edits: Vec<(String, String)> = pair
                    .mac
                    .iter()
                    .chain(pair.vm.iter())
                    .filter(|(p, h)| synced.get(*p) != Some(*h))
                    .map(|(p, h)| (p.clone(), h.clone()))
                    .collect();
                let round = pair.sync();
                pair.settled();
                let after: std::collections::BTreeSet<&String> = pair.mac.values().collect();
                for (path, hash) in &edits {
                    // A clean line merge replaces both versions with the merged one.
                    assert!(
                        after.contains(hash) || round.merged.contains(path),
                        "seed {seed} step {step}: the edit to {path} was lost"
                    );
                }
            }
        }
        pair.sync();
        pair.settled();
    }
}
