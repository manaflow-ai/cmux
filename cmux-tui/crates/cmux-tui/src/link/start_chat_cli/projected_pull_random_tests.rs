//! A seeded randomized run of the way back: small trees, random edits on both sides over two
//! pulls each, in some trials the machine moving the folder `d/e` before the last pull (to a
//! name this Mac ignores, sometimes), and the promises checked after every pull: no edit made on
//! this Mac is lost; every edit the machine made ends up on this Mac, in the file or beside it,
//! or is named; and no file's bytes are lost: every file this Mac had before the pull that the
//! machine did not change is still here at its old path, at its moved path, or beside one.

use std::collections::{BTreeMap, BTreeSet};

use super::*;

/// The seeds, fixed: a failure names its seed and trial, and reruns the same way.
const SEEDS: [u64; 4] = [0x5eed_0001, 0x5eed_0002, 0x00c0_ffee, 0xdead_beef];
const TRIALS_PER_SEED: usize = 500;
const PULLS_PER_TRIAL: usize = 2;
const PATHS: [&str; 9] = ["a", "b", "c", "d/a", "d/b", "d/c", "d/e/a", "d/e/b", "d/e/c"];
/// The folder a trial may move, and where to: `d/e.bak` is ignored on this Mac.
const MOVED: &str = "d/e";
const TARGETS: [&str; 2] = ["d/f", "d/e.bak"];

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

/// Where `path` is on the machine after the move `moved` (`from`, `to`), if there was one.
fn mapped(path: &str, moved: Option<(&str, &str)>) -> String {
    let Some((from, to)) = moved else { return path.to_owned() };
    match path.strip_prefix(from) {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{to}{rest}"),
        _ => path.to_owned(),
    }
}

/// The overlay's upper layer for the machine's folder now: every file the machine wrote since
/// the mount, a whiteout for every listed file it deleted, the folders above them or made, and
/// for a moved folder the projection listed, a redirect at its new path and a whiteout at its
/// old one (what the upper layer held below it moves with it).
fn upper_of(
    machine: &Path,
    lower: &BTreeSet<&str>,
    touched: &BTreeSet<&str>,
    moved: Option<(&str, &str)>,
) -> Value {
    let mut changes: BTreeMap<String, Value> = BTreeMap::new();
    for path in touched {
        let at = mapped(path, moved);
        if machine.join(&at).is_file() {
            changes.insert(at.clone(), change(&at, "file"));
        }
    }
    for path in lower {
        let at = mapped(path, moved);
        if !machine.join(&at).exists() {
            changes.insert(at.clone(), change(&at, "delete"));
        }
    }
    let lower_dirs: BTreeSet<String> = lower.iter().flat_map(|path| ancestors(path)).collect();
    if let Some((from, to)) = moved
        && lower_dirs.contains(from)
    {
        let redirect = json!({ "path": to, "kind": "redirect", "from": format!("/{from}") });
        changes.insert(to.to_owned(), redirect);
        changes.insert(from.to_owned(), change(from, "delete"));
    }
    let listed: Vec<String> = changes.keys().cloned().collect();
    for path in &listed {
        for dir in ancestors(path) {
            changes.entry(dir.clone()).or_insert_with(|| change(&dir, "dir"));
        }
    }
    let shown_dirs: BTreeSet<String> = lower_dirs.iter().map(|dir| mapped(dir, moved)).collect();
    for dir in tree(machine) {
        if machine.join(&dir).is_dir() && !shown_dirs.contains(&dir) {
            changes.entry(dir.clone()).or_insert_with(|| change(&dir, "dir"));
        }
    }
    Value::Array(changes.into_values().collect())
}

/// Whether `path`, or a folder above it, is named in the summary's conflicts or refusals.
fn named(summary: &Value, path: &str) -> bool {
    let mut at: Vec<String> = ancestors(path);
    at.push(path.to_owned());
    ["conflicts", "refused"].iter().any(|key| {
        summary[*key]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|entry| entry["path"].as_str())
            .any(|named| at.iter().any(|path| path == named))
    })
}

/// Every file in this Mac's folder (git's own left out), with its bytes.
fn files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    tree(root)
        .into_iter()
        .filter(|path| path != ".git" && !path.starts_with(".git/"))
        .filter_map(|path| std::fs::read(root.join(&path)).ok().map(|bytes| (path, bytes)))
        .collect()
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
    let target = match rng.below(4) {
        0 => TARGETS.first().copied(),
        1 => TARGETS.get(1).copied(),
        _ => None,
    };
    let ignoring = target.is_some_and(|to| to.ends_with(".bak"));
    let mut base = Vec::new();
    for path in PATHS {
        if rng.below(2) == 0 {
            base.push((path, rng.bytes("base")));
        }
    }
    let listed: Vec<(&str, &[u8])> = base.iter().map(|(p, b)| (*p, b.as_slice())).collect();
    let f = Fixture::made(daemon, &listed, |root| {
        if ignoring {
            let status = Command::new("git").arg("init").arg("-q").arg(root).status().unwrap();
            assert!(status.success());
            put(root, ".gitignore", b"*.bak\n");
        }
    });
    let lower: BTreeSet<&str> = base.iter().map(|(path, _)| *path).collect();
    let mut touched: BTreeSet<&str> = BTreeSet::new();
    let mut wrote: BTreeSet<Vec<u8>> = BTreeSet::new();
    // Every path the machine wrote or deleted in this trial.
    let mut changed: BTreeSet<&str> = BTreeSet::new();
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
                    changed.insert(path);
                    wrote.insert(bytes.clone());
                    machine.insert(path, Some(bytes));
                }
                1 if f.machine.join(path).is_file() => {
                    std::fs::remove_file(f.machine.join(path)).unwrap();
                    changed.insert(path);
                    machine.insert(path, None);
                }
                _ => {}
            }
        }
        let last = pull + 1 == PULLS_PER_TRIAL;
        let moved = target.filter(|_| last && f.machine.join(MOVED).is_dir()).map(|to| (MOVED, to));
        if let Some((from, to)) = moved {
            std::fs::rename(f.machine.join(from), f.machine.join(to)).unwrap();
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
        f.upper(&upper_of(&f.machine, &lower, &touched, moved));
        let before = files(&f.root);
        let summary = f.pull();
        let at = format!("{label} pull {pull}: {summary}");
        assert_eq!(summary["ok"], true, "{at}");
        // Only a move onto an ignored name refuses anything: what it brings, and its origin.
        let kept = moved.is_some_and(|(_, to)| to.ends_with(".bak"));
        for (path, reason) in refused(&summary) {
            let why = (reason == "ignored" && kept && path.starts_with("d/e.bak"))
                || (reason == "origin_kept" && kept && path.starts_with(MOVED));
            assert!(why, "{path} refused as {reason}: {at}");
        }
        for (path, bytes) in &before {
            if changed.contains(path.as_str()) {
                continue;
            }
            let there = mapped(path, moved);
            let here = [path.as_str(), there.as_str()].iter().any(|place| {
                f.mac(place).as_ref() == Some(bytes) || beside(&f.root, place).contains(bytes)
            });
            assert!(here, "the bytes this Mac had at {path} were lost: {at}");
        }
        for (path, bytes) in &mac {
            let now = f.mac(path);
            // A delete here that both sides agree on may be followed by a new file the machine
            // makes there: that is a create, not a lost delete.
            let made_after = bytes.is_none() && now.as_ref().is_some_and(|now| wrote.contains(now));
            assert!(now == *bytes || made_after, "this Mac's edit of {path} was lost: {at}");
        }
        for (path, bytes) in &machine {
            let there = mapped(path, moved);
            match bytes {
                Some(bytes) => {
                    let here = f.mac(&there).as_ref() == Some(bytes)
                        || beside(&f.root, &there).contains(bytes)
                        || (kept && named(&summary, &there));
                    assert!(here, "the machine's edit of {path} did not come back: {at}");
                }
                None => assert!(
                    f.mac(path).is_none() || named(&summary, path),
                    "the machine's delete of {path} was neither applied nor named: {at}"
                ),
            }
        }
    }
}
