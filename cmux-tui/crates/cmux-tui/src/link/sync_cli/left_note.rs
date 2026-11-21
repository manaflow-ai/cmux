//! The note a first pass ([`super::size_cap`]) leaves at the top of its copy on the machine: what
//! stayed on this Mac, by folder and the largest files, with sizes, and how the chat's agent gets
//! one (`cmux link access request PATH`). acpmux on the machine gives the note to the chat's agent
//! with its first message (`acpmux::left_on_mac`), so the agent asks for a file of the Mac, or asks
//! the person, instead of searching the machine for it or taking it for missing
//! (cmuxterm-hq#11697, item 2).
//!
//! Its name ([`acpmux::left_on_mac::NOTE`]) starts with `.cmux-sync`: no pull brings it back to
//! this Mac and no share sends it. A push that is no first pass deletes it, so a copy sent whole
//! later says nothing stayed behind.
//!
//! A first pass of `~/Projects` may leave hundreds of thousands of files: the note groups them by
//! their top folder (a repository's history as its own `NAME/.git/` group), largest first, lists
//! at most [`FOLDERS`] groups and [`FILES`] largest files, and sums the rest, so it stays a few
//! kilobytes however much stayed.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap};
use std::fmt::Write as _;
use std::path::Path;

/// The note's name at the top of the copy on the machine.
pub(super) const NAME: &str = acpmux::left_on_mac::NOTE;

/// The most folder groups the note lists; the rest are summed in one line.
const FOLDERS: usize = 40;
/// The most single files the note lists, largest first.
const FILES: usize = 15;

/// What a first pass left on this Mac and what it sent, counted as it is decided.
#[derive(Clone, Debug, Default)]
pub(super) struct LeftOnMac {
    files: u64,
    bytes: u64,
    sent_files: u64,
    sent_bytes: u64,
    /// Files and bytes by group ([`group`]), and whether the group is a repository's history.
    groups: BTreeMap<String, (u64, u64, bool)>,
    /// The largest files left, smallest on top (at most [`FILES`]).
    largest: BinaryHeap<Reverse<(u64, String)>>,
    /// The listing stopped at the copy's file limit: more stayed than was counted.
    stopped: bool,
}

impl LeftOnMac {
    pub(super) fn new(stopped: bool) -> Self {
        Self { stopped, ..Self::default() }
    }

    /// `relative`, `bytes` long, stayed on this Mac.
    pub(super) fn left(&mut self, relative: &str, bytes: u64) {
        self.files += 1;
        self.bytes = self.bytes.saturating_add(bytes);
        let (key, history) = group(relative);
        let entry = self.groups.entry(key).or_insert((0, 0, history));
        entry.0 += 1;
        entry.1 = entry.1.saturating_add(bytes);
        self.largest.push(Reverse((bytes, relative.to_owned())));
        if self.largest.len() > FILES {
            self.largest.pop();
        }
    }

    /// A file of `bytes` went in the first pass.
    pub(super) fn sent(&mut self, bytes: u64) {
        self.sent_files += 1;
        self.sent_bytes = self.sent_bytes.saturating_add(bytes);
    }

    /// The note, in Markdown: `local` is the folder on this Mac, `remote_root` its copy.
    pub(super) fn text(&self, local: &Path, remote_root: &str) -> String {
        let local = local.display();
        let mut out = String::new();
        let _ = writeln!(out, "# What stayed on the Mac\n");
        let _ = writeln!(
            out,
            "`{remote_root}` on this Cloud machine is a first pass of `{local}` on the person's Mac. \
             That folder is more than a Cloud chat copies whole, so the copy sent its {} smallest \
             files ({}) and no repository history. {} ({}) stayed on the Mac{}. They exist there; \
             they are not missing.\n",
            self.sent_files,
            human(self.sent_bytes),
            plural(self.files, "file"),
            human(self.bytes),
            if self.stopped {
                ", and more the listing did not reach (it stops at the most files a copy lists)"
            } else {
                ""
            },
        );
        let _ = writeln!(
            out,
            "To get one, run `cmux link access request {local}/PATH` (PATH as listed below) and the \
             person is asked; or ask the person. Do not search this machine for them.\n"
        );
        let _ = writeln!(out, "## Folders and files left on the Mac, largest first\n");
        let mut groups: Vec<(&String, &(u64, u64, bool))> = self.groups.iter().collect();
        groups.sort_by(|a, b| b.1.1.cmp(&a.1.1).then_with(|| a.0.cmp(b.0)));
        for (key, (files, bytes, history)) in groups.iter().take(FOLDERS) {
            let what = if *history { ", repository history" } else { "" };
            let _ = writeln!(out, "- `{key}`: {}, {}{what}", plural(*files, "file"), human(*bytes));
        }
        if let Some(rest) = groups.get(FOLDERS..).filter(|rest| !rest.is_empty()) {
            let files: u64 = rest.iter().map(|(_, (files, _, _))| files).sum();
            let bytes: u64 = rest.iter().map(|(_, (_, bytes, _))| bytes).sum();
            let _ = writeln!(
                out,
                "- and {} more: {}, {}",
                rest.len(),
                plural(files, "file"),
                human(bytes)
            );
        }
        let mut largest: Vec<&(u64, String)> =
            self.largest.iter().map(|Reverse(file)| file).collect();
        largest.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        if !largest.is_empty() {
            let _ = writeln!(out, "\n## Largest files left on the Mac\n");
            for (bytes, relative) in largest {
                let _ = writeln!(out, "- `{relative}`: {}", human(*bytes));
            }
        }
        out
    }
}

/// The group `relative` is listed under: a repository's history (`.git` at any depth) as the path
/// to and with that `.git/`, else its top folder (`NAME/`), else the file itself.
fn group(relative: &str) -> (String, bool) {
    let parts: Vec<&str> = relative.split('/').collect();
    let history = parts.iter().position(|part| *part == ".git").and_then(|at| parts.get(..=at));
    if let Some(history) = history {
        return (format!("{}/", history.join("/")), true);
    }
    match relative.split_once('/') {
        Some((top, _)) => (format!("{top}/"), false),
        None => (relative.to_owned(), false),
    }
}

fn plural(count: u64, noun: &str) -> String {
    if count == 1 { format!("1 {noun}") } else { format!("{count} {noun}s") }
}

/// `bytes` as a person reads it (decimal units, as Finder shows them).
fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["KB", "MB", "GB", "TB", "PB"];
    if bytes < 1000 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS.get(unit).copied().unwrap_or("PB"))
}

#[cfg(test)]
#[path = "left_note_tests.rs"]
mod tests;
