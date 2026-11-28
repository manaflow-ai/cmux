//! What Move to Cloud's done toast says about how the folder got to the machine (hq RFD 0066 piece
//! 1, "Say what happened"): copied, not cloned, when the push took the streamed copy, and what it
//! left on this Mac, by name and grouped by why: secrets, ignored and build output the machine
//! rebuilds, big files. Read from `cmux link seed push`'s answer line (`mode`, `skipped_files`,
//! the copy's `skipped_counts`, `fallback_why`; cmux-tui `link/seed_cli.rs`). Pure: the app shows
//! these words and decides nothing.
//!
//! A clone (or a projection) that left nothing behind has nothing to say ([`read`] is none), so the
//! toast reads as it always has.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// How the folder reached the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum How {
    /// The machine cloned the GitHub remote and this Mac sent what it lacks (`seed`, `delta`,
    /// `clone`).
    Cloned,
    /// The streamed copy of the folder's files (`copy`).
    Copied,
    /// Listed now, each file read from this Mac on first use (`projected`).
    Projected,
}

/// Why a group of paths stayed on this Mac, in the order the toast lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Group {
    /// `.env*`, keys, credential folders and files (`secret`).
    Secret,
    /// Ignored paths and dependency or build folders, rebuilt on the machine (`ignored`, `heavy`).
    Rebuilt,
    /// Files over the copy's or the seed's size limits (`big`, `left_on_mac`).
    Big,
    /// A git repository inside the folder that is not a submodule (`repository`).
    Repository,
    /// Anything else the copy cannot carry: symlinks, sockets, names Linux can't hold.
    Other,
}

impl Group {
    /// The group of a skipped path's `kind`.
    fn of(kind: &str) -> Self {
        match kind {
            "secret" => Self::Secret,
            "ignored" | "heavy" => Self::Rebuilt,
            "big" | "left_on_mac" => Self::Big,
            "repository" => Self::Repository,
            _ => Self::Other,
        }
    }

    /// The group's heading.
    fn label(self) -> &'static str {
        match self {
            Self::Secret => "Secrets, kept on this Mac",
            Self::Rebuilt => "Ignored and build output, rebuilt on the machine",
            Self::Big => "Big files, kept on this Mac",
            Self::Repository => "Separate repositories, kept on this Mac",
            Self::Other => "Not copied",
        }
    }

    /// The group counted: "1 secret", "3 big files".
    fn counted(self, n: u64) -> String {
        let (one, many) = match self {
            Self::Secret => ("secret", "secrets"),
            Self::Rebuilt => ("ignored path", "ignored paths"),
            Self::Big => ("big file", "big files"),
            Self::Repository => ("separate repository", "separate repositories"),
            Self::Other => ("other path", "other paths"),
        };
        format!("{n} {}", if n == 1 { one } else { many })
    }
}

/// One group of paths left on this Mac.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    pub group: Group,
    /// The group's heading: "Secrets, kept on this Mac".
    pub label: String,
    /// Every path the answer named, in its order (a folder ends in `/`).
    pub paths: Vec<String>,
    /// How many more the copy counted but did not name (it names at most 200).
    pub more: u64,
    /// The group on one line: its heading, the first [`NAMED`] paths and how many more.
    pub text: String,
}

/// What the done toast says.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Landed {
    pub how: How,
    /// "Copied, not cloned" for a copy; none otherwise.
    pub headline: Option<String>,
    /// Why it copied, in the push's words when it gave them.
    pub reason: Option<String>,
    /// What stayed on this Mac, by group, in [`Group`]'s order. Empty when nothing did.
    pub skipped: Vec<Skipped>,
    /// Every group counted on one line: "Left on this Mac: 2 secrets, 1 big file". None when
    /// nothing stayed.
    pub summary: Option<String>,
}

/// Paths named on a group's one line before "and N more".
pub const NAMED: usize = 3;

/// The done toast's words for a seed push's answer line; none when it is not one, or when it
/// cloned (or projected) and left nothing behind.
pub fn read(object: &Map<String, Value>) -> Option<Landed> {
    let how = match object.get("mode").and_then(Value::as_str)? {
        "copy" => How::Copied,
        "seed" | "delta" | "clone" => How::Cloned,
        "projected" => How::Projected,
        _ => return None,
    };
    let copy = object.get("copy").and_then(Value::as_object);
    let listed = object
        .get("skipped_files")
        .and_then(Value::as_array)
        .filter(|items| !items.is_empty())
        .or_else(|| copy.and_then(|copy| copy.get("skipped_files")).and_then(Value::as_array));
    let mut groups: std::collections::BTreeMap<Group, (Vec<String>, u64)> = Default::default();
    for item in listed.into_iter().flatten() {
        let Some(path) = item.get("path").and_then(Value::as_str) else { continue };
        let kind = item.get("kind").and_then(Value::as_str).unwrap_or_default();
        groups.entry(Group::of(kind)).or_default().0.push(path.to_owned());
    }
    // The copy counts every path it left and names the first 200: the rest are "more".
    let counts = object
        .get("skipped_counts")
        .or_else(|| copy.and_then(|copy| copy.get("skipped_counts")))
        .and_then(Value::as_object);
    let mut counted: std::collections::BTreeMap<Group, u64> = Default::default();
    for (kind, n) in counts.into_iter().flatten() {
        let n = n.as_u64().unwrap_or(0);
        if n > 0 {
            *counted.entry(Group::of(kind)).or_default() += n;
        }
    }
    for (group, n) in &counted {
        let entry = groups.entry(*group).or_default();
        entry.1 = n.saturating_sub(entry.0.len() as u64);
    }
    let skipped: Vec<Skipped> = groups
        .into_iter()
        .filter(|(_, (paths, more))| !paths.is_empty() || *more > 0)
        .map(|(group, (paths, more))| Skipped {
            group,
            label: group.label().to_owned(),
            text: line(group, &paths, more),
            paths,
            more,
        })
        .collect();
    if how != How::Copied && skipped.is_empty() {
        return None;
    }
    let summary = (!skipped.is_empty()).then(|| {
        let parts: Vec<String> = skipped
            .iter()
            .map(|group| group.group.counted(group.paths.len() as u64 + group.more))
            .collect();
        format!("Left on this Mac: {}", parts.join(", "))
    });
    let (headline, reason) = match how {
        How::Copied => (
            Some("Copied, not cloned".to_owned()),
            Some(
                object
                    .get("fallback_why")
                    .and_then(Value::as_str)
                    .filter(|why| !why.trim().is_empty())
                    .map_or_else(
                        || "The machine had no GitHub remote to clone, so the folder's files were copied.".to_owned(),
                        str::to_owned,
                    ),
            ),
        ),
        How::Cloned | How::Projected => (None, None),
    };
    Some(Landed { how, headline, reason, skipped, summary })
}

/// Paths shown per group in the toast's grouped look before a `+N` (the gallery's look C,
/// webviews `MoveLanded.tsx` `SHOWN`).
pub const SHOWN: usize = 4;

/// The app's native done toast (`CmuxToast`) for a move that landed as `landed`, in the grouped
/// look (look C): the one line it shows, and its Details, revealed in place.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Toast {
    /// "Copied, not cloned. This chat now runs on dev. Left on this Mac: 2 secrets."
    pub message: String,
    /// Why it copied, then each group: its heading over its first [`SHOWN`] paths and a `+N`.
    /// None when there is nothing more to say.
    pub detail: Option<String>,
}

/// The done toast for `moved` (the app's "This chat now runs on dev.") with what `landed` says;
/// none when there is nothing to add, so the toast stays the one it always was.
pub fn toast(moved: &str, landed: Option<&Landed>) -> Option<Toast> {
    let landed = landed.filter(|landed| landed.how == How::Copied || !landed.skipped.is_empty())?;
    let headline = landed.headline.as_deref().map(|headline| format!("{headline}."));
    let summary = landed.summary.as_deref().map(|summary| format!("{summary}."));
    let message = [headline.as_deref(), Some(moved.trim()), summary.as_deref()]
        .into_iter()
        .flatten()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let groups = landed.skipped.iter().map(|group| {
        let shown: Vec<&str> = group.paths.iter().take(SHOWN).map(String::as_str).collect();
        let rest = (group.paths.len() - shown.len()) as u64 + group.more;
        let mut paths = shown.join("   ");
        if rest > 0 {
            if !paths.is_empty() {
                paths.push_str("   ");
            }
            paths.push_str(&format!("+{rest}"));
        }
        format!("{}\n{paths}", group.label)
    });
    let parts: Vec<String> = landed.reason.iter().cloned().chain(groups).collect();
    let detail = (!parts.is_empty()).then(|| parts.join("\n\n"));
    Some(Toast { message, detail })
}

/// A group on one line: "Secrets, kept on this Mac: .env, id_rsa and 2 more".
fn line(group: Group, paths: &[String], more: u64) -> String {
    let named: Vec<&str> = paths.iter().take(NAMED).map(String::as_str).collect();
    let rest = (paths.len().saturating_sub(named.len()) as u64).saturating_add(more);
    let names = match (named.is_empty(), rest) {
        (true, rest) => group.counted(rest),
        (false, 0) => named.join(", "),
        (false, rest) => format!("{} and {rest} more", named.join(", ")),
    };
    format!("{}: {names}", group.label())
}

#[cfg(test)]
#[path = "landed_tests.rs"]
mod tests;
