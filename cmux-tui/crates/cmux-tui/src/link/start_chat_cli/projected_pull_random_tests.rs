//! A seeded randomized run of the way back: small trees, random edits on both sides over two
//! pulls each, and the two promises checked after every pull: no edit made on this Mac is lost,
//! and every edit the machine made ends up on this Mac, in the file or beside it.

use std::collections::{BTreeMap, BTreeSet};

use super::*;

/// The seeds, fixed: a failure names its seed and trial, and reruns the same way.
const SEEDS: [u64; 4] = [0x5eed_0001, 0x5eed_0002, 0x00c0_ffee, 0xdead_beef];
const TRIALS_PER_SEED: usize = 500;
const PULLS_PER_TRIAL: usize = 2;
const PATHS: [&str; 9] = ["a", "b", "c", "d/a", "d/b", "d/c", "d/e/a", "d/e/b", "d/e/c"];

/// xorshift64*.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// Bytes no other write of the run has (their size varies too).
    fn bytes(&mut self, who: &str) -> Vec<u8> {
        let pad = "x".repeat(usize::try_from(self.below(8)).unwrap());
        format!("{who} {} {pad}", self.next()).into_bytes()
    }
}

fn ancestors(path: &str) -> Vec<String> {
    path.match_indices('/').map(|(at, _)| path[..at].to_owned()).collect()
}

/// The overlay's upper layer for the machine's folder now: every file the machine wrote since
/// the mount, a whiteout for every listed file it deleted, and the folders above them or made.
fn upper_of(machine: &Path, lower: &BTreeSet<&str>, touched: &BTreeSet<&str>) -> Value {
    let mut changes: BTreeMap<String, &str> = BTreeMap::new();
    for path in touched {
        if machine.join(path).is_file() {
            changes.insert((*path).to_owned(), "file");
        }
    }
    for path in lower {
        if !machine.join(path).exists() {
            changes.insert((*path).to_owned(), "delete");
        }
    }
    let lower_dirs: BTreeSet<String> = lower.iter().flat_map(|path| ancestors(path)).collect();
    let listed: Vec<String> = changes.keys().cloned().collect();
    for path in &listed {
        for dir in ancestors(path) {
            changes.insert(dir, "dir");
        }
    }
    for dir in tree(machine) {
        if machine.join(&dir).is_dir() && !lower_dirs.contains(&dir) {
            changes.insert(dir, "dir");
        }
    }
    Value::Array(changes.iter().map(|(path, kind)| change(path, kind)).collect())
}

/// What the conflict copies beside `path` hold.
fn beside(root: &Path, path: &str) -> Vec<Vec<u8>> {
    let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
    let Ok(entries) = std::fs::read_dir(root.join(dir)) else { return Vec::new() };
    entries
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|other| {
            other.starts_with(&format!("{name}.")) && other.ends_with(".cmux-sync-conflict")
        })
        .filter_map(|other| std::fs::read(root.join(dir).join(other)).ok())
        .collect()
}

#[test]
fn no_mac_edit_is_lost_and_every_machine_edit_comes_back() {
    let daemon = Daemon::start();
    let mut trials = 0;
    for seed in SEEDS {
        let mut rng = Rng(seed);
        for trial in 0..TRIALS_PER_SEED {
            one(&daemon, &mut rng, &format!("seed {seed:#x} trial {trial}"));
            trials += 1;
        }
    }
    assert!(trials >= 2000, "{trials}");
}

fn one(daemon: &Daemon, rng: &mut Rng, label: &str) {
    let mut files = Vec::new();
    for path in PATHS {
        if rng.below(2) == 0 {
            files.push((path, rng.bytes("base")));
        }
    }
    let listed: Vec<(&str, &[u8])> = files.iter().map(|(p, b)| (*p, b.as_slice())).collect();
    let f = Fixture::new(daemon, &listed);
    let lower: BTreeSet<&str> = files.iter().map(|(path, _)| *path).collect();
    let mut touched: BTreeSet<&str> = BTreeSet::new();
    let mut wrote: BTreeSet<Vec<u8>> = BTreeSet::new();
    // This Mac's last edit of each path it edited (None: it deleted it).
    let mut mac: BTreeMap<&str, Option<Vec<u8>>> = BTreeMap::new();
    for pull in 0..PULLS_PER_TRIAL {
        let mut machine: BTreeMap<&str, Option<Vec<u8>>> = BTreeMap::new();
        for path in PATHS {
            match rng.below(4) {
                0 => {
                    let bytes = rng.bytes("machine");
                    f.machine_write(path, &bytes);
                    touched.insert(path);
                    wrote.insert(bytes.clone());
                    machine.insert(path, Some(bytes));
                }
                1 if f.machine.join(path).is_file() => {
                    std::fs::remove_file(f.machine.join(path)).unwrap();
                    machine.insert(path, None);
                }
                _ => {}
            }
        }
        for path in PATHS {
            match rng.below(5) {
                0 => {
                    let bytes = rng.bytes("mac");
                    put(&f.root, path, &bytes);
                    mac.insert(path, Some(bytes));
                }
                1 if f.root.join(path).is_file() => {
                    std::fs::remove_file(f.root.join(path)).unwrap();
                    mac.insert(path, None);
                }
                _ => {}
            }
        }
        f.upper(&upper_of(&f.machine, &lower, &touched));
        let summary = f.pull();
        let at = format!("{label} pull {pull}: {summary}");
        assert_eq!(summary["ok"], true, "{at}");
        assert_eq!(summary["refused"], json!([]), "{at}");
        for (path, bytes) in &mac {
            let now = f.mac(path);
            // A delete here that both sides agree on may be followed by a new file the machine
            // makes there: that is a create, not a lost delete.
            let made_after = bytes.is_none() && now.as_ref().is_some_and(|now| wrote.contains(now));
            assert!(now == *bytes || made_after, "this Mac's edit of {path} was lost: {at}");
        }
        let conflicted: BTreeSet<&str> = summary["conflicts"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|conflict| conflict["path"].as_str())
            .collect();
        for (path, bytes) in &machine {
            match bytes {
                Some(bytes) => {
                    let here = f.mac(path).as_ref() == Some(bytes)
                        || beside(&f.root, path).contains(bytes);
                    assert!(here, "the machine's edit of {path} did not come back: {at}");
                }
                None => assert!(
                    f.mac(path).is_none() || conflicted.contains(path),
                    "the machine's delete of {path} was neither applied nor named: {at}"
                ),
            }
        }
    }
}
