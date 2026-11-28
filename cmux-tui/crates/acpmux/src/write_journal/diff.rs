//! The diff of a paused machine for the app and phone (RFD 0144 piece 2), with no wake.
//!
//! Two parts, each against a base the daemon holds:
//! - at pause, [`capture`] keeps the working tree's `git diff HEAD` and its untracked files, read
//!   once while nothing runs on the machine (the seed leaves `.git` out, so this is the only time
//!   the daemon can read it);
//! - while paused, [`diff`] adds one patch per file the agent changed since (the journal laid
//!   over the replica), against the file as the pause left it.
//!
//! A part the daemon cannot give says why (`notGit`, `tooLarge`, `timedOut`), and the client
//! wakes the machine for that part as before.

use super::replica::{NeedsMachine, ReplicaRead, ReplicaSource};
use super::seed::SeededReplica;
use super::{Op, WriteJournal};
use cmux_process::{Command, Stdio};
use std::io::{self, Read, Seek};
use std::path::Path;
use std::time::Duration;

/// Longest one `git` call at pause may take: a pause must not wait on a huge tree.
const GIT_BOUND: Duration = Duration::from_secs(10);
/// Largest `git diff HEAD` kept, and largest diff of journaled files one reply carries.
pub const MAX_DIFF_BYTES: usize = 4 << 20;
/// Most untracked names kept.
pub const MAX_UNTRACKED: usize = 5_000;

/// What the pause read from git.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PauseDiff {
    Captured {
        /// `git diff HEAD`, unified, no colour.
        text: String,
        /// Untracked, not ignored, relative to the machine's folder, in name order.
        untracked: Vec<String>,
        untracked_truncated: bool,
    },
    /// Why only the machine can say: `notGit`, `tooLarge`, `timedOut`, `failed`.
    Missing(&'static str),
}

enum Git {
    Out(Vec<u8>),
    Missing(&'static str),
}

fn git(root: &Path, args: &[&str]) -> Git {
    let Ok(mut out) = tempfile::tempfile() else { return Git::Missing("failed") };
    let Ok(stdout) = out.try_clone() else { return Git::Missing("failed") };
    let child = Command::new("git")
        .args(["-c", "core.fsmonitor=false", "-c", "core.quotepath=off"])
        .args(args)
        .current_dir(root)
        // A read must not take or write the index lock of a tree the agent comes back to.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else { return Git::Missing("failed") };
    match child.wait_timeout(GIT_BOUND) {
        Ok(Some(s)) if s.success() => {}
        Ok(Some(_)) => return Git::Missing("failed"),
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            return Git::Missing("timedOut");
        }
    }
    let mut bytes = Vec::new();
    if out.rewind().is_err() || out.read_to_end(&mut bytes).is_err() {
        return Git::Missing("failed");
    }
    Git::Out(bytes)
}

/// Reads the diff of the git work tree at `root` against `HEAD`. Blocking, at most
/// 3 × [`GIT_BOUND`]; call it while the machine is paused.
pub fn capture(root: &Path) -> PauseDiff {
    match git(root, &["rev-parse", "--is-inside-work-tree"]) {
        Git::Out(b) if b.trim_ascii() == b"true" => {}
        Git::Out(_) | Git::Missing("failed") => return PauseDiff::Missing("notGit"),
        Git::Missing(why) => return PauseDiff::Missing(why),
    }
    let text = match git(
        root,
        &["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-textconv", "--relative", "--"],
    ) {
        Git::Out(b) if b.len() > MAX_DIFF_BYTES => return PauseDiff::Missing("tooLarge"),
        // Lossy: a binary file's diff is git's one-line note, never raw bytes.
        Git::Out(b) => String::from_utf8_lossy(&b).into_owned(),
        Git::Missing(why) => return PauseDiff::Missing(why),
    };
    let names = match git(root, &["ls-files", "--others", "--exclude-standard", "-z", "--", "."]) {
        Git::Out(b) => b,
        Git::Missing(why) => return PauseDiff::Missing(why),
    };
    let mut untracked: Vec<String> = names
        .split(|b| *b == 0)
        .filter(|n| !n.is_empty())
        .map(|n| String::from_utf8_lossy(n).into_owned())
        .collect();
    untracked.sort();
    let untracked_truncated = untracked.len() > MAX_UNTRACKED;
    untracked.truncate(MAX_UNTRACKED);
    PauseDiff::Captured { text, untracked, untracked_truncated }
}

/// The diff a paused machine's reply carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffOutcome {
    Diff {
        at_pause: PauseDiff,
        /// One unified patch per journaled path (`a/` is the file as paused, `b/` as now).
        since_pause: String,
        /// The journaled paths, in name order.
        changed: Vec<String>,
        /// `since_pause` was cut at [`MAX_DIFF_BYTES`].
        truncated: bool,
    },
    NeedsMachine(NeedsMachine),
}

fn patch(path: &str, old: Option<&str>, new: Option<&str>) -> String {
    let mut options = diffy::DiffOptions::new();
    options
        .set_original_filename(if old.is_some() { format!("a/{path}") } else { "/dev/null".into() })
        .set_modified_filename(if new.is_some() {
            format!("b/{path}")
        } else {
            "/dev/null".into()
        });
    options.create_patch(old.unwrap_or(""), new.unwrap_or("")).to_string()
}

/// The paused machine's diff: what the pause captured, then the journal's changes over the
/// replica. Blocking (the replica's files).
pub fn diff(
    journal: &WriteJournal,
    replica: &SeededReplica,
    at_pause: &PauseDiff,
) -> io::Result<DiffOutcome> {
    let generation = replica.generation();
    if !replica.is_fresh() {
        return Ok(DiffOutcome::NeedsMachine(NeedsMachine::Stale));
    }
    let mut since_pause = String::new();
    let mut changed = Vec::new();
    let mut truncated = false;
    for (path, entry) in journal.overlay_paths() {
        let old = match replica.read(path)? {
            ReplicaRead::Present(b) => match String::from_utf8(b) {
                Ok(t) => Some(t),
                Err(_) => return Ok(DiffOutcome::NeedsMachine(NeedsMachine::NotText)),
            },
            ReplicaRead::Absent => None,
            ReplicaRead::MachineOnly => {
                return Ok(DiffOutcome::NeedsMachine(NeedsMachine::MachineOnly));
            }
        };
        let new = match &entry.op {
            Op::Write { content } => Some(content.as_str()),
            Op::Delete => None,
        };
        if old.as_deref() == new {
            continue;
        }
        changed.push(path.to_owned());
        if truncated {
            continue;
        }
        let one = patch(path, old.as_deref(), new);
        if since_pause.len().saturating_add(one.len()) > MAX_DIFF_BYTES {
            truncated = true;
        } else {
            since_pause.push_str(&one);
        }
    }
    if !replica.is_fresh() || replica.generation() != generation {
        return Ok(DiffOutcome::NeedsMachine(NeedsMachine::Stale));
    }
    Ok(DiffOutcome::Diff { at_pause: at_pause.clone(), since_pause, changed, truncated })
}
