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
    assert_eq!(card.blocks[4].lines, vec![Line::Ports { listed: ":3000, :5173".into(), more: 0 }]);
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
    let many = (1..=12).map(|n| Member { title: format!("ws-{n}"), ..Member::default() }).collect();
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
    assert_eq!(card.blocks[0].lines, vec![Line::Branches { listed: "caf\u{e9}".into(), more: 0 }]);
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
