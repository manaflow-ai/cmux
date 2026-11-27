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
mod tests {
    //! `GroupHoverCardSummaryTests`, ported: the same members, options and
    //! expectations, read as typed lines instead of English strings.

    use super::*;

    const NOW: f64 = 1_800_000_000.;

    fn members() -> Vec<Member> {
        vec![
            Member {
                title: "api".into(),
                activity: Activity::Working,
                unread: 2,
                last_activity: Some(NOW - 600.),
                branch: Some("main".into()),
                ports: Some(":3000, :5173".into()),
            },
            Member {
                title: "web".into(),
                activity: Activity::Waiting,
                last_activity: Some(NOW - 120.),
                branch: Some("feat-ui".into()),
                ports: Some(":3000".into()),
                ..Member::default()
            },
            Member {
                title: "docs".into(),
                unread: 1,
                branch: Some("main".into()),
                ..Member::default()
            },
        ]
    }

    /// `GroupHoverCardOptions()`: status lead order, every section, 6 members.
    const DEFAULT_SECTIONS: [Section; 5] =
        [Section::Status, Section::Members, Section::Activity, Section::Git, Section::Ports];

    fn request(members: Vec<Member>, sections: &[Section], max_members: i64) -> Request {
        Request { members, sections: sections.to_vec(), max_members, now: NOW }
    }

    fn sections(r: &Response) -> Vec<Section> {
        r.blocks.iter().map(|b| b.section).collect()
    }

    fn part(kind: StatusKind, count: u64) -> StatusPart {
        StatusPart { kind, count }
    }

    #[test]
    fn group_summary_the_default_card_summarizes_status_members_activity_branches_and_ports() {
        let card = summarize(&request(members(), &DEFAULT_SECTIONS, 6));
        assert_eq!(sections(&card), DEFAULT_SECTIONS.to_vec());
        let status = &card.blocks[0];
        assert_eq!(
            status.lines,
            vec![Line::Status {
                parts: vec![
                    part(StatusKind::Working, 1),
                    part(StatusKind::Waiting, 1),
                    part(StatusKind::Unread, 3)
                ]
            }]
        );
        assert_eq!(status.tone, Tone::Attention);
        assert_eq!(
            card.blocks[1].lines,
            vec![
                Line::Count { count: 3 },
                Line::Member { title: "api".into() },
                Line::Member { title: "web".into() },
                Line::Member { title: "docs".into() },
            ]
        );
        assert_eq!(
            card.blocks[2].lines,
            vec![Line::Latest { title: "web".into(), age_seconds: 120., just_now: false }]
        );
        assert_eq!(
            card.blocks[3].lines,
            vec![Line::Branches { listed: "main, feat-ui".into(), more: 0 }]
        );
        assert_eq!(
            card.blocks[4].lines,
            vec![Line::Ports { listed: ":3000, :5173".into(), more: 0 }]
        );
    }

    #[test]
    fn group_summary_the_order_setting_picks_the_leading_part() {
        for lead in [Section::Members, Section::Activity, Section::Status] {
            let mut order = vec![lead];
            order.extend(DEFAULT_SECTIONS.iter().copied().filter(|s| *s != lead));
            let card = summarize(&request(members(), &order, 6));
            assert_eq!(card.blocks[0].section, lead);
            assert_eq!(card.blocks.len(), 5);
        }
    }

    #[test]
    fn group_summary_turned_off_parts_are_left_out() {
        let card = summarize(&request(members(), &[Section::Members, Section::Ports], 6));
        assert_eq!(sections(&card), vec![Section::Members, Section::Ports]);
    }

    #[test]
    fn group_summary_a_long_group_lists_max_members_then_the_rest_as_more() {
        let many =
            (1..=12).map(|n| Member { title: format!("ws-{n}"), ..Member::default() }).collect();
        let card = summarize(&request(many, &[Section::Members], 3));
        assert_eq!(
            card.blocks[0].lines,
            vec![
                Line::Count { count: 12 },
                Line::Member { title: "ws-1".into() },
                Line::Member { title: "ws-2".into() },
                Line::Member { title: "ws-3".into() },
                Line::More { count: 9 },
            ]
        );
        // At least one member is named, whatever the setting says.
        let one = summarize(&request(members(), &[Section::Members], 0));
        assert_eq!(one.blocks[0].lines.len(), 3, "count, one member, more");
    }

    #[test]
    fn group_summary_an_idle_group_says_all_idle_and_skips_empty_parts() {
        let idle = vec![
            Member { title: "a".into(), ..Member::default() },
            Member { title: "b".into(), ..Member::default() },
        ];
        let card = summarize(&request(idle, &DEFAULT_SECTIONS, 6));
        assert_eq!(sections(&card), vec![Section::Status, Section::Members]);
        assert_eq!(card.blocks[0].lines, vec![Line::Status { parts: vec![] }]);
        assert_eq!(card.blocks[0].tone, Tone::Secondary);
    }

    #[test]
    fn group_summary_a_failed_member_turns_the_status_red() {
        let card = summarize(&request(
            vec![
                Member { title: "a".into(), activity: Activity::Failed, ..Member::default() },
                Member { title: "b".into(), activity: Activity::Working, ..Member::default() },
            ],
            &[Section::Status],
            6,
        ));
        assert_eq!(
            card.blocks[0].lines,
            vec![Line::Status {
                parts: vec![part(StatusKind::Working, 1), part(StatusKind::Failed, 1)]
            }]
        );
        assert_eq!(card.blocks[0].tone, Tone::Danger);
    }

    #[test]
    fn group_summary_lists_cap_at_four_and_ports_split_trim_and_dedupe() {
        let ms = vec![
            Member {
                title: "a".into(),
                ports: Some(" :1,:2,, :3 ".into()),
                branch: Some("b1".into()),
                ..Member::default()
            },
            Member {
                title: "b".into(),
                ports: Some(":2,\u{00A0}:4\t, :5".into()),
                branch: Some(String::new()),
                ..Member::default()
            },
            Member { title: "c".into(), branch: Some("b2".into()), ..Member::default() },
        ];
        let card = summarize(&request(ms, &[Section::Git, Section::Ports], 6));
        assert_eq!(card.blocks[0].lines, vec![Line::Branches { listed: "b1, b2".into(), more: 0 }]);
        assert_eq!(
            card.blocks[1].lines,
            vec![Line::Ports { listed: ":1, :2, :3, :4".into(), more: 1 }]
        );
    }

    #[test]
    fn group_summary_the_latest_tie_keeps_the_first_and_a_recent_change_is_just_now() {
        let ms = vec![
            Member { title: "first".into(), last_activity: Some(NOW - 30.), ..Member::default() },
            Member { title: "second".into(), last_activity: Some(NOW - 30.), ..Member::default() },
        ];
        let card = summarize(&request(ms, &[Section::Activity], 6));
        assert_eq!(
            card.blocks[0].lines,
            vec![Line::Latest { title: "first".into(), age_seconds: 30., just_now: true }]
        );
    }

    /// Swift's `String` equality is canonical equivalence: a precomposed and a decomposed
    /// "é" are one branch (and one port), listed as the member first had it.
    #[test]
    fn group_summary_canonically_equal_values_count_once() {
        let ms = vec![
            Member {
                title: "a".into(),
                branch: Some("caf\u{e9}".into()),
                ports: Some(":\u{e9}".into()),
                ..Member::default()
            },
            Member {
                title: "b".into(),
                branch: Some("cafe\u{301}".into()),
                ports: Some(":e\u{301}".into()),
                ..Member::default()
            },
        ];
        let card = summarize(&request(ms, &[Section::Git, Section::Ports], 6));
        assert_eq!(
            card.blocks[0].lines,
            vec![Line::Branches { listed: "caf\u{e9}".into(), more: 0 }]
        );
        assert_eq!(card.blocks[1].lines, vec![Line::Ports { listed: ":\u{e9}".into(), more: 0 }]);
    }

    /// Swift splits a port list on the `Character` ",": a comma followed by a combining mark is
    /// one grapheme cluster, not a comma, so the list is not split there.
    #[test]
    fn group_summary_a_comma_with_a_combining_mark_does_not_split_ports() {
        let ms = vec![Member {
            title: "a".into(),
            ports: Some(":1,\u{301}:2, :3".into()),
            ..Member::default()
        }];
        let card = summarize(&request(ms, &[Section::Ports], 6));
        assert_eq!(
            card.blocks[0].lines,
            vec![Line::Ports { listed: ":1,\u{301}:2, :3".into(), more: 0 }]
        );
    }

    #[test]
    fn group_summary_reads_and_writes_its_json() {
        let json = serde_json::json!({
            "members": [{"title": "api", "activity": "working", "unread": -4}],
            "sections": ["status", "members"],
            "max_members": 6,
            "now": NOW,
        });
        let request: Request = serde_json::from_value(json).unwrap();
        let out = serde_json::to_value(summarize(&request)).unwrap();
        assert_eq!(
            out,
            serde_json::json!({"blocks": [
                {"section": "status", "tone": "working",
                 "lines": [{"line": "status", "parts": [{"kind": "working", "count": 1}]}]},
                {"section": "members", "tone": "secondary",
                 "lines": [{"line": "count", "count": 1}, {"line": "member", "title": "api"}]},
            ]})
        );
    }
}
