use super::*;
use crate::ledger::{Ledger, Stage};

/// A project key, its stage, and (move start, first chat) in ms.
type Row<'a> = (&'a str, Stage, Option<(i64, i64)>);

fn ledger(rows: &[Row]) -> Ledger {
    let mut ledger = Ledger::new();
    for (key, stage, times) in rows {
        let entry = ledger.entry_mut("laptop:abc", key);
        entry.stage = *stage;
        entry.machine_id = Some(format!("machine-{key}"));
        entry.error = (*stage == Stage::Failed).then(|| format!("/Users/me/{key}: no room"));
        if let Some((start, chat)) = times {
            entry.started_ms = Some(*start);
            entry.first_chat_ms = Some(*chat);
        }
    }
    ledger
}

#[test]
fn a_report_counts_and_times_and_keeps_nothing_else() {
    let mut l = ledger(&[
        ("/Users/me/web", Stage::Done, Some((1_000, 65_000))),
        ("/Users/me/api", Stage::Done, Some((2_000, 152_000))),
        ("/Users/me/old", Stage::Failed, None),
        ("/Users/me/gone", Stage::Undone, Some((0, 10_000))),
        ("/Users/me/half", Stage::Pending, None),
    ]);
    l.entry_mut("laptop:abc", crate::apply::MACHINE_WIDE).stage = Stage::Done;
    let report = Report::of(&l);
    assert_eq!(
        (report.people, report.attempted, report.done, report.failed, report.pending),
        (1, 4, 2, 1, 1)
    );
    assert_eq!(report.first_chat_ms, vec![64_000, 150_000]);
    let text = serde_json::to_string(&report).unwrap();
    for private in ["/Users", "web", "machine-", "no room", "laptop:abc"] {
        assert!(!text.contains(private), "{private} leaked into {text}");
    }
}

#[test]
fn a_team_roll_up_adds_people_and_ranks_every_time() {
    let mut team =
        Report::of(&ledger(&[("a", Stage::Done, Some((0, 60_000))), ("b", Stage::Failed, None)]));
    team.add(&Report::of(&ledger(&[
        ("c", Stage::Done, Some((0, 120_000))),
        ("d", Stage::Done, Some((0, 700_000))),
        ("e", Stage::Done, Some((5_000, 1_000))),
    ])));
    let s = team.summary();
    assert_eq!((s.people, s.attempted, s.done, s.failed), (2, 5, 4, 1));
    assert_eq!(s.success_pct, Some(80.0));
    // A clock that went back (e) is not a time.
    assert_eq!(s.measured, 3);
    assert_eq!(s.median_first_chat_ms, Some(120_000));
    assert_eq!(s.p90_first_chat_ms, Some(700_000));
    assert_eq!(s.max_first_chat_ms, Some(700_000));
    assert_eq!(s.under_ten_minutes, 2);
    assert_eq!(
        team.line(),
        "4 of 5 projects moved (80%) across 2 people; time to first chat median 120.0 s, \
         p90 700.0 s, 2 of 3 under ten minutes"
    );
}

#[test]
fn nothing_moved_yet_says_so_without_a_rate() {
    let s = Report::of(&Ledger::new()).summary();
    assert_eq!((s.attempted, s.success_pct, s.median_first_chat_ms), (0, None, None));
    assert_eq!(Report::of(&Ledger::new()).line(), "0 of 0 projects moved");
}

#[test]
fn a_report_reads_back_what_it_wrote() {
    let report = Report::of(&ledger(&[("a", Stage::Done, Some((0, 64_200)))]));
    let text = serde_json::to_string(&report).unwrap();
    assert_eq!(serde_json::from_str::<Report>(&text).unwrap(), report);
}
