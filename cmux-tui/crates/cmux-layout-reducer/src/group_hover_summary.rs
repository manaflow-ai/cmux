//! What a group's hover card says (a sidebar workspace group's header, a tab
//! group's chip): one block of lines per shown section, in the order the
//! host's `sidebar.hoverCards.groups.*` options pick. Ported from cmux-next
//! macOS `GroupHoverCardSummary.swift` (Lawrence 2026-10-20: "hovering on
//! workspace group or tab group for a while should still show the card, like
//! summary stuff, and should be fully customizable too").
//!
//! The rule lives here; the words do not. Each line is a typed value (a
//! count, a member's title, a list and how many more), and the app formats it
//! with its localized strings (`GroupHoverCardStrings`) and its age formatter.
//! The app reaches it once per card show through `cmux_layout_reducer_json`
//! (`group_hover_summary`).

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// What a member is doing, as the card counts it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Activity {
    #[default]
    Idle,
    /// An agent works or a command runs.
    Working,
    /// Waiting for the person.
    Waiting,
    Failed,
}

/// One member, in group order.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Member {
    pub title: String,
    pub activity: Activity,
    /// Unread items (a dot counts as one); below zero counts as zero.
    pub unread: i64,
    /// When the member last changed, in seconds since the epoch `now` uses (the app
    /// sends Foundation's reference date); none when unknown.
    pub last_activity: Option<f64>,
    pub branch: Option<String>,
    /// Listening ports as the member reports them (":3000, :5173").
    pub ports: Option<String>,
}

/// One part of the card.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Section {
    Status,
    Members,
    Activity,
    Git,
    Ports,
}

/// The status block's color.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tone {
    Secondary,
    Working,
    Attention,
    Danger,
}

/// One count of the status line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatusKind {
    Working,
    Waiting,
    Failed,
    Unread,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusPart {
    pub kind: StatusKind,
    pub count: u64,
}

/// One line, for the host to put in words.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "line", rename_all = "snake_case")]
pub enum Line {
    /// The status counts that are not zero, in this order, joined with " · "
    /// ("Working: 2 · Unread: 3"); none: "All idle".
    Status { parts: Vec<StatusPart> },
    /// "Workspaces: N" or "Tabs: N" (the host knows the kind).
    Count { count: u64 },
    /// "• title".
    Member { title: String },
    /// "+N more".
    More { count: u64 },
    /// "Latest: title · age": "Just now" when `just_now`, else the host's
    /// abbreviated age of `age_seconds` (one unit: weeks, days, hours, minutes).
    Latest { title: String, age_seconds: f64, just_now: bool },
    /// "Branches: listed", then " +N more" when `more` is not zero.
    Branches { listed: String, more: u64 },
    /// "Ports: listed", then " +N more" when `more` is not zero.
    Ports { listed: String, more: u64 },
}

/// One shown section and its lines (never empty).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Block {
    pub section: Section,
    pub tone: Tone,
    pub lines: Vec<Line>,
}

/// The request: the members in group order, the sections to show in order
/// (`GroupHoverCardOptions.sections`), the most members to name, and now.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub members: Vec<Member>,
    pub sections: Vec<Section>,
    pub max_members: i64,
    /// Now, in seconds since the same epoch as `Member::last_activity`.
    pub now: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub blocks: Vec<Block>,
}

/// The most values one list line names before "+N more".
pub const MAX_LISTED: usize = 4;

/// An age under this many seconds reads "Just now".
pub const JUST_NOW_SECONDS: f64 = 60.;

fn count(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

/// The card's blocks for `request`.
#[must_use]
pub fn summarize(request: &Request) -> Response {
    let members = &request.members;
    let mut blocks = Vec::new();
    for section in &request.sections {
        match section {
            Section::Status => blocks.push(status(members)),
            Section::Members => {
                let limit = usize::try_from(request.max_members.max(1)).unwrap_or(usize::MAX);
                let mut lines = vec![Line::Count { count: count(members.len()) }];
                lines.extend(
                    members.iter().take(limit).map(|m| Line::Member { title: m.title.clone() }),
                );
                let shown = members.len().min(limit);
                if members.len() > shown {
                    lines.push(Line::More { count: count(members.len().saturating_sub(shown)) });
                }
                blocks.push(Block { section: Section::Members, tone: Tone::Secondary, lines });
            }
            Section::Activity => {
                // The first member with the latest time (Swift's `max(by:)` keeps the first).
                let mut latest: Option<(&Member, f64)> = None;
                for member in members {
                    if let Some(date) = member.last_activity
                        && latest.is_none_or(|(_, best)| best < date)
                    {
                        latest = Some((member, date));
                    }
                }
                if let Some((member, date)) = latest {
                    let age_seconds = request.now - date;
                    // Swift's `guard seconds >= 60`: NaN reads "Just now" too.
                    let just_now = age_seconds < JUST_NOW_SECONDS || age_seconds.is_nan();
                    blocks.push(Block {
                        section: Section::Activity,
                        tone: Tone::Secondary,
                        lines: vec![Line::Latest {
                            title: member.title.clone(),
                            age_seconds,
                            just_now,
                        }],
                    });
                }
            }
            Section::Git => {
                let branches = unique(members.iter().filter_map(|m| m.branch.clone()));
                if !branches.is_empty() {
                    let (listed, more) = joined(&branches);
                    blocks.push(Block {
                        section: Section::Git,
                        tone: Tone::Secondary,
                        lines: vec![Line::Branches { listed, more }],
                    });
                }
            }
            Section::Ports => {
                let ports =
                    unique(members.iter().filter_map(|m| m.ports.as_deref()).flat_map(|ports| {
                        split_on_comma(ports)
                            .into_iter()
                            .map(|p| trim_whitespaces(p).to_owned())
                            .collect::<Vec<_>>()
                    }));
                if !ports.is_empty() {
                    let (listed, more) = joined(&ports);
                    blocks.push(Block {
                        section: Section::Ports,
                        tone: Tone::Secondary,
                        lines: vec![Line::Ports { listed, more }],
                    });
                }
            }
        }
    }
    Response { blocks }
}

/// "Working: 2 · Waiting: 1 · Unread: 3", or "All idle" (no parts).
fn status(members: &[Member]) -> Block {
    let tally =
        |activity: Activity| count(members.iter().filter(|m| m.activity == activity).count());
    let working = tally(Activity::Working);
    let waiting = tally(Activity::Waiting);
    let failed = tally(Activity::Failed);
    let unread = members
        .iter()
        .fold(0u64, |sum, m| sum.saturating_add(u64::try_from(m.unread.max(0)).unwrap_or(0)));
    let parts: Vec<StatusPart> = [
        (StatusKind::Working, working),
        (StatusKind::Waiting, waiting),
        (StatusKind::Failed, failed),
        (StatusKind::Unread, unread),
    ]
    .into_iter()
    .filter(|(_, n)| *n > 0)
    .map(|(kind, count)| StatusPart { kind, count })
    .collect();
    let tone = if failed > 0 {
        Tone::Danger
    } else if waiting > 0 {
        Tone::Attention
    } else if working > 0 {
        Tone::Working
    } else {
        Tone::Secondary
    };
    Block { section: Section::Status, tone, lines: vec![Line::Status { parts }] }
}

/// The first `MAX_LISTED` values joined with ", ", and how many more there are.
fn joined(values: &[String]) -> (String, u64) {
    let listed = values.iter().take(MAX_LISTED).map(String::as_str).collect::<Vec<_>>().join(", ");
    (listed, count(values.len().saturating_sub(MAX_LISTED)))
}

/// The non-empty values, each once, in first-seen order. Two values are the same when they
/// are canonically equivalent (equal after NFC), as Swift's `String` equality says, and the
/// first one seen is the one listed.
fn unique(values: impl Iterator<Item = String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for value in values {
        if !value.is_empty() && seen.insert(value.nfc().collect::<String>()) {
            out.push(value);
        }
    }
    out
}

/// `text` split at each grapheme cluster that is exactly ",", as Swift's
/// `split(separator: ",")` on `Character`s does: a comma followed by a combining mark is one
/// cluster and does not split. Empty parts are kept (the caller drops them after trimming).
fn split_on_comma(text: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0usize;
    for (at, cluster) in text.grapheme_indices(true) {
        if cluster == "," {
            parts.push(text.get(start..at).unwrap_or_default());
            start = at.saturating_add(cluster.len());
        }
    }
    parts.push(text.get(start..).unwrap_or_default());
    parts
}

/// Foundation's `CharacterSet.whitespaces`: Unicode general category Zs and tab.
fn is_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

fn trim_whitespaces(s: &str) -> &str {
    s.trim_matches(is_whitespace)
}

#[cfg(test)]
mod tests;
