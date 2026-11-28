//! The name table under a rename: a rename re-keys the moved path and the names below it only,
//! at a cost that does not grow with the names the upper folder holds (a build tree of 100k
//! files, each rename of a cargo or git temp file).

use std::collections::BTreeMap;
use std::time::Instant;

use super::tests::Fake;
use super::*;
use crate::manifest::Item;

fn me() -> Who {
    // SAFETY: getuid and getgid have no preconditions.
    unsafe { Who { uid: libc::getuid(), gid: libc::getgid() } }
}

fn overlay(state: &Path) -> Overlay {
    let items = vec![Item {
        path: "README.md".into(),
        kind: Kind::File,
        mode: 0o644,
        size: 6,
        mtime_ns: 1,
        link: None,
    }];
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mut fake = Fake::default();
    fake.bytes.insert(manifest.resolve("README.md").unwrap(), b"readme".to_vec());
    Overlay::open(manifest, state, Arc::new(fake), (me().uid, me().gid)).unwrap()
}

/// Splitmix64: random paths with no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// Names that sort next to a folder's `<name>/` prefix: `a`, `a-b`, `a.b`, `a/b`, `a0`, `ab`.
fn random_path(rng: &mut Rng) -> String {
    const PARTS: [&str; 8] = ["a", "a-b", "a.b", "a0", "ab", "b", "é", "a/"];
    let depth = 1 + rng.below(4);
    let mut path = String::new();
    for at in 0..depth {
        if at > 0 {
            path.push('/');
        }
        path.push_str(PARTS[rng.below(PARTS.len() as u64) as usize].trim_end_matches('/'));
    }
    path
}

/// Model check: the ordered range walk finds exactly the names a whole-table filter (the old
/// walk) finds, on random tables with names that sort beside the prefix.
#[test]
fn names_below_matches_a_whole_table_filter() {
    let mut rng = Rng(7);
    for _ in 0..2_000 {
        let mut table: BTreeMap<String, u64> = BTreeMap::new();
        for ino in 0..rng.below(40) {
            table.insert(random_path(&mut rng), ino);
        }
        let from = random_path(&mut rng);
        let prefix = format!("{from}/");
        let mut old: Vec<(String, u64)> = table
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .map(|(path, ino)| (path.clone(), *ino))
            .collect();
        old.sort();
        assert_eq!(names_below(&table, &prefix), old, "prefix {prefix:?} in {table:?}");
    }
}

/// A moved upper folder keeps every number below it under the new names; names that sort beside
/// it (`out-x`, `out0`, `out.d`) keep theirs where they are.
#[test]
fn a_moved_folder_keeps_the_numbers_below_it_and_leaves_its_neighbours() {
    let state = tempfile::tempdir().unwrap();
    let overlay = overlay(state.path());
    let root = overlay.root();
    let out = overlay.mkdir(root, "out", 0o755, me()).unwrap().ino;
    let deep = overlay.mkdir(out, "deep", 0o755, me()).unwrap().ino;
    let below: Vec<u64> = (0..5)
        .map(|n| overlay.create(deep, &format!("f{n}"), 0o644, me()).unwrap().0.ino)
        .collect();
    let beside: Vec<(String, u64)> = ["out-x", "out0", "out.d"]
        .iter()
        .map(|name| (name.to_string(), overlay.create(root, name, 0o644, me()).unwrap().0.ino))
        .collect();
    overlay.rename(root, "out", root, "moved", 0).unwrap();
    assert_eq!(overlay.lookup(root, "out"), Err(ENOENT));
    let moved = overlay.lookup(root, "moved").unwrap().ino;
    assert_eq!(moved, out);
    let deep_now = overlay.lookup(moved, "deep").unwrap().ino;
    assert_eq!(deep_now, deep);
    for (n, ino) in below.iter().enumerate() {
        assert_eq!(overlay.lookup(deep_now, &format!("f{n}")).unwrap().ino, *ino);
        assert_eq!(overlay.path_of(*ino).unwrap(), format!("moved/deep/f{n}"));
    }
    for (name, ino) in beside {
        assert_eq!(overlay.lookup(root, &name).unwrap().ino, ino);
        assert_eq!(overlay.path_of(ino).unwrap(), name);
    }
}

fn bench_selected() -> bool {
    std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1")
}

/// p50 and p95 microseconds of one file rename beside `names` upper-only names (a build tree).
fn rename_cost(names: usize) -> (f64, f64) {
    let state = tempfile::tempdir().unwrap();
    let overlay = overlay(state.path());
    let root = overlay.root();
    let target = overlay.mkdir(root, "target", 0o755, me()).unwrap().ino;
    let folders: Vec<u64> = (0..100)
        .map(|n| overlay.mkdir(target, &format!("d{n:03}"), 0o755, me()).unwrap().ino)
        .collect();
    for n in 0..names {
        let (_, handle) =
            overlay.create(folders[n % folders.len()], &format!("obj{n}.o"), 0o644, me()).unwrap();
        overlay.release(handle);
    }
    let work = overlay.mkdir(root, "work", 0o755, me()).unwrap().ino;
    let mut samples = Vec::new();
    for n in 0..300 {
        let tmp = format!("tmp{n}");
        let (_, handle) = overlay.create(work, &tmp, 0o644, me()).unwrap();
        overlay.release(handle);
        let since = Instant::now();
        overlay.rename(work, &tmp, work, &format!("out{n}"), 0).unwrap();
        samples.push(since.elapsed().as_secs_f64() * 1e6);
    }
    samples.sort_by(f64::total_cmp);
    (samples[samples.len() / 2], samples[samples.len() * 95 / 100])
}

/// `CMUX_STRESS=1 cargo test -p cmux-projection --release stress_bench_rename -- --nocapture`.
/// Budget: one rename beside 100k names costs under 2x the rename beside 10k (it walked every
/// name before: ~10x).
#[test]
fn stress_bench_rename_beside_a_build_tree() {
    if !bench_selected() {
        eprintln!("skipped: set CMUX_STRESS=1");
        return;
    }
    let (small_p50, small_p95) = rename_cost(10_000);
    let (big_p50, big_p95) = rename_cost(100_000);
    println!(
        "STRESS-OVERLAY-RENAME {{\"names_10k\":{{\"p50_us\":{small_p50:.1},\"p95_us\":{small_p95:.1}}},\
         \"names_100k\":{{\"p50_us\":{big_p50:.1},\"p95_us\":{big_p95:.1}}},\"ratio_p50\":{:.2}}}",
        big_p50 / small_p50
    );
    assert!(
        big_p50 < small_p50 * 2.0 + 20.0,
        "a rename beside 100k names took {big_p50:.1} us at p50, {small_p50:.1} us beside 10k"
    );
}
