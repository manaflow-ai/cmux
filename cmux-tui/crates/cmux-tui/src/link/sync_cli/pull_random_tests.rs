//! Dropbox-style randomized testing of the pull's three-way planner (leo-workspace
//! research/cloud-prior-art-2026-11-04.md section 4, refinement 4; RFD 0007's P1 gate: "10,000
//! seeded trials with no lost edit"). Each trial seeds a tree as the last push left it, edits on
//! this Mac and on the machine, plans every path with the pull's own [`call`] and line merge
//! ([`merge::lines`], [`merge::permissions`]), applies the plan to a model of this Mac, and checks:
//!
//! - nothing is lost: each side's change is on this Mac after the pull, or in the clean merge, or
//!   the path is a named conflict (this Mac's file kept, the machine's left on the machine);
//! - a conflict appears exactly when both sides changed a path differently and the lines did not
//!   merge cleanly, never when both made the same change;
//! - a clean merge holds every line either side added, none either side removed, and every line
//!   neither touched, in order; edits on lines apart always merge cleanly.
//!
//! `CMUX_MERGE_SEED` reruns one seed; `CMUX_MERGE_TRIALS` sets how many trials.

use std::collections::BTreeMap;

use super::merge::{self, Merged};
use super::{Call, Side, call};

/// splitmix64: small, seeded, and the same everywhere.
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
        self.next() % n.max(1)
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }
}

/// One line slot's edit: the base line kept, replaced, deleted, or kept with a line after it.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Replace(String),
    Delete,
    Append(String),
}

/// A text file as lines (each ends in `\n`).
#[derive(Clone, Debug, PartialEq, Eq)]
struct Text(Vec<String>);

impl Text {
    fn bytes(&self) -> Vec<u8> {
        self.0.concat().into_bytes()
    }

    fn apply(&self, ops: &BTreeMap<usize, Op>) -> Self {
        let mut out = Vec::new();
        for (slot, line) in self.0.iter().enumerate() {
            match ops.get(&slot) {
                None => out.push(line.clone()),
                Some(Op::Replace(new)) => out.push(new.clone()),
                Some(Op::Delete) => {}
                Some(Op::Append(new)) => {
                    out.push(line.clone());
                    out.push(new.clone());
                }
            }
        }
        Self(out)
    }
}

/// One path's version on one side.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Version {
    Missing,
    File { text: Text, mode: u32 },
    Link(String),
}

impl Version {
    fn side(&self) -> Side {
        match self {
            Self::Missing => Side::Missing,
            Self::File { text, mode } => Side::File { sha256: text.0.concat(), permissions: *mode },
            Self::Link(target) => Side::Link(target.clone()),
        }
    }
}

/// How one side changed a file, by line slot; empty for no line edit.
type Edits = BTreeMap<usize, Op>;

fn fresh_line(rng: &mut Rng, who: &str) -> String {
    format!("{who}-{:x}\n", rng.next())
}

fn base_version(rng: &mut Rng) -> Version {
    match rng.below(10) {
        0 => Version::Missing,
        1 => Version::Link(format!("target-{}", rng.below(3))),
        _ => {
            let lines = rng.below(10) as usize;
            let text = Text((0..lines).map(|_| fresh_line(rng, "base")).collect());
            Version::File { text, mode: if rng.chance(20) { 0o755 } else { 0o644 } }
        }
    }
}

/// One side's version from `base`, and its line edits when it is a line edit of a base file.
fn edited(rng: &mut Rng, base: &Version, who: &str) -> (Version, Edits) {
    // Untouched most of the time, as in a real folder.
    if rng.chance(45) {
        return (base.clone(), Edits::new());
    }
    match (base, rng.below(10)) {
        (Version::File { .. }, 0) => (Version::Missing, Edits::new()),
        (_, 1) => (Version::Link(format!("target-{}", rng.below(3))), Edits::new()),
        (Version::File { text, mode }, kind) if !text.0.is_empty() && kind < 8 => {
            let mut edits = Edits::new();
            for slot in 0..text.0.len() {
                if rng.chance(25) {
                    let op = match rng.below(3) {
                        0 => Op::Replace(fresh_line(rng, who)),
                        1 => Op::Delete,
                        _ => Op::Append(fresh_line(rng, who)),
                    };
                    edits.insert(slot, op);
                }
            }
            let mode = if rng.chance(15) { mode ^ 0o111 } else { *mode };
            (Version::File { text: text.apply(&edits), mode }, edits)
        }
        // A whole new file (made where there was none, or rewritten).
        _ => {
            let lines = 1 + rng.below(6) as usize;
            let text = Text((0..lines).map(|_| fresh_line(rng, who)).collect());
            (Version::File { text, mode: 0o644 }, Edits::new())
        }
    }
}

/// What the pull leaves at a path.
#[derive(Debug, PartialEq, Eq)]
enum Outcome {
    /// This Mac's version, as it is now.
    Kept,
    /// The machine's version.
    Took,
    /// Both sides' lines, merged.
    Merged(Version),
    /// A named conflict: this Mac's kept, the machine's left on the machine.
    Conflict,
}

fn plan(base: &Version, here: &Version, machine: &Version) -> Outcome {
    let pushed = base.side();
    match call(&pushed, &pushed, &here.side(), &machine.side()) {
        Call::Unchanged | Call::Settle => Outcome::Kept,
        Call::Take => Outcome::Took,
        Call::Both => match (base, here, machine) {
            (
                Version::File { text: b, mode: base_mode },
                Version::File { text: h, mode: here_mode },
                Version::File { text: m, mode: machine_mode },
            ) => {
                let Some(mode) = merge::permissions(*base_mode, *here_mode, *machine_mode) else {
                    return Outcome::Conflict;
                };
                match merge::lines(&b.bytes(), &h.bytes(), &m.bytes(), mode) {
                    Merged::Clean { bytes, permissions } => {
                        let text = String::from_utf8(bytes).unwrap();
                        let lines = text.split_inclusive('\n').map(str::to_string).collect();
                        Outcome::Merged(Version::File { text: Text(lines), mode: permissions })
                    }
                    Merged::Overlap(_) | Merged::Whole => Outcome::Conflict,
                }
            }
            _ => Outcome::Conflict,
        },
    }
}

/// Lines `side` added to the base (in `edits`), and base lines it removed.
fn changed_lines(base: &Text, edits: &Edits) -> (Vec<String>, Vec<String>) {
    let (mut added, mut removed) = (Vec::new(), Vec::new());
    for (slot, op) in edits {
        match op {
            Op::Replace(new) => {
                added.push(new.clone());
                removed.push(base.0[*slot].clone());
            }
            Op::Delete => removed.push(base.0[*slot].clone()),
            Op::Append(new) => added.push(new.clone()),
        }
    }
    (added, removed)
}

/// Checks one path's trial; the failure, described, when an invariant breaks.
fn check(
    base: &Version,
    (here, here_edits): &(Version, Edits),
    (machine, machine_edits): &(Version, Edits),
) -> Result<(), String> {
    let outcome = plan(base, here, machine);
    let here_changed = here != base;
    let machine_changed = machine != base;
    let both_differ = here_changed && machine_changed && here != machine;
    let after = match &outcome {
        Outcome::Kept | Outcome::Conflict => here,
        Outcome::Took => machine,
        Outcome::Merged(merged) => merged,
    };
    // Nothing lost.
    if here_changed && after != here && !matches!(outcome, Outcome::Merged(_)) {
        return Err(format!("this Mac's change was overwritten: {outcome:?}"));
    }
    if machine_changed
        && after != machine
        && !matches!(outcome, Outcome::Merged(_) | Outcome::Conflict)
    {
        return Err(format!("the machine's change was dropped silently: {outcome:?}"));
    }
    // A conflict exactly when both changed differently and the lines did not merge.
    if matches!(outcome, Outcome::Conflict | Outcome::Merged(_)) != both_differ {
        return Err(format!("both_differ {both_differ} but {outcome:?}"));
    }
    if let Outcome::Merged(Version::File { text, .. }) = &outcome {
        let Version::File { text: base_text, .. } = base else {
            return Err("a merge with no base file".into());
        };
        for edits in [here_edits, machine_edits] {
            let (added, removed) = changed_lines(base_text, edits);
            for line in &added {
                if !text.0.contains(line) {
                    return Err(format!("the merge lost an added line {line:?}"));
                }
            }
            for line in &removed {
                if text.0.contains(line) {
                    return Err(format!("the merge brought back a removed line {line:?}"));
                }
            }
        }
        // A whole-file rewrite on either side has no line edits; then only both versions' lines
        // being accounted for is checked, by the merge itself being clean over its base.
        let touched: Vec<usize> = here_edits.keys().chain(machine_edits.keys()).copied().collect();
        let untouched: Vec<&String> = base_text
            .0
            .iter()
            .enumerate()
            .filter(|(slot, _)| !touched.contains(slot))
            .map(|(_, line)| line)
            .collect();
        let kept: Vec<&String> = text.0.iter().filter(|line| untouched.contains(line)).collect();
        if !here_edits.is_empty() && !machine_edits.is_empty() && kept != untouched {
            return Err(format!("untouched lines moved or went: {kept:?} != {untouched:?}"));
        }
    }
    // Edits on lines apart (no slot within one of the other side's) always merge.
    if let (Version::File { text: base_text, .. }, false, false) =
        (base, here_edits.is_empty(), machine_edits.is_empty())
    {
        let apart = here_edits
            .keys()
            .all(|slot| machine_edits.keys().all(|other| slot.abs_diff(*other) > 1));
        let modes_merge = match (base, here, machine) {
            (
                Version::File { mode: b, .. },
                Version::File { mode: h, .. },
                Version::File { mode: m, .. },
            ) => merge::permissions(*b, *h, *m).is_some(),
            _ => false,
        };
        if apart && modes_merge {
            let mut both = here_edits.clone();
            both.extend(machine_edits.clone());
            let want = base_text.apply(&both);
            match &outcome {
                Outcome::Merged(Version::File { text, .. }) if *text == want => {}
                other => return Err(format!("edits on lines apart gave {other:?}, want {want:?}")),
            }
        }
    }
    Ok(())
}

/// One trial: a tree of up to 12 paths, each seeded and edited on both sides.
fn trial(seed: u64) -> Result<(), String> {
    let mut rng = Rng(seed);
    let paths = 1 + rng.below(12);
    for path in 0..paths {
        let base = base_version(&mut rng);
        let here = edited(&mut rng, &base, "mac");
        // Sometimes the machine makes the same change as this Mac.
        let machine = if here.0 != base && rng.chance(10) {
            here.clone()
        } else {
            edited(&mut rng, &base, "vm")
        };
        check(&base, &here, &machine).map_err(|why| {
            format!(
                "seed {seed}, path {path}: {why}\n  base {base:?}\n  mac {:?} {:?}\n  machine {:?} {:?}",
                here.0, here.1, machine.0, machine.1
            )
        })?;
    }
    Ok(())
}

#[test]
fn ten_thousand_seeded_trials_lose_no_edit() {
    if let Some(seed) = std::env::var("CMUX_MERGE_SEED").ok().and_then(|seed| seed.parse().ok()) {
        trial(seed).unwrap();
        return;
    }
    let trials: u64 = std::env::var("CMUX_MERGE_TRIALS")
        .ok()
        .and_then(|trials| trials.parse().ok())
        .unwrap_or(10_000);
    let started = std::time::Instant::now();
    let failures: Vec<String> = (0..trials).filter_map(|seed| trial(seed).err()).take(5).collect();
    eprintln!("{trials} trials in {:?}", started.elapsed());
    assert!(
        failures.is_empty(),
        "{} failing trials, first:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn the_planners_calls_by_hand() {
    let file = |text: &str| Side::File { sha256: text.into(), permissions: 0o644 };
    let (b, h, m) = (file("b"), file("h"), file("m"));
    assert_eq!(call(&b, &b, &h, &b), Call::Unchanged, "only this Mac changed it");
    assert_eq!(call(&b, &b, &b, &m), Call::Take, "only the machine changed it");
    assert_eq!(call(&b, &b, &m, &m), Call::Settle, "both made the same change");
    assert_eq!(call(&b, &b, &h, &m), Call::Both, "both changed it differently");
    assert_eq!(call(&b, &b, &Side::Missing, &m), Call::Both, "deleted here, edited there");
    assert_eq!(call(&Side::Missing, &Side::Missing, &h, &m), Call::Both, "both made it");
}
