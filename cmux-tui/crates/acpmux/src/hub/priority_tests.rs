//! The Priority view's ranking (`priority.rs`), ported from the Mac app's tests of the rule it
//! ranked with until now (`AgentPriorityRankingTests.swift`, `AgentLanesTests.swift`): the same
//! lanes, marks and clock, the same expected orders.
//!
//! Leo 2026-10-20: the Priority view sifts what needs the person to the top (Codex's Priority
//! list "doesn't even do that"): a question or permission prompt first, then a finished result
//! nobody has seen, then a failed or lost turn, then the working ones, then idle; within a tier
//! pinned first, then the most recent. Read and snooze marks hold until the chat moves on.

use std::collections::HashSet;

use serde_json::{Value, json};

use super::*;

/// 1_760_000_000 seconds, the Swift tests' clock.
const NOW: i64 = 1_760_000_000_000;
const MINUTE: i64 = 60_000;
const HOUR: i64 = 60 * MINUTE;

fn lane(id: &str, state: LaneState, ago_minutes: i64) -> Lane {
    Lane {
        id: id.to_owned(),
        title: id.to_owned(),
        peer: None,
        machine: None,
        state,
        since: Some(NOW - ago_minutes * MINUTE),
        error: None,
        step: None,
        unread: false,
        project: Some("cmux".to_owned()),
        harness: None,
        requires_open: false,
        archivable: false,
        mark_key: None,
        parent: None,
        spawned_by: None,
        cwd: None,
        pull_requests: Vec::new(),
        chat: None,
    }
}

fn lanes() -> Vec<Lane> {
    vec![
        lane("idle-old", LaneState::Idle, 30),
        Lane { step: Some("Running tests".into()), ..lane("working", LaneState::Working, 5) },
        Lane { unread: true, ..lane("done", LaneState::Idle, 20) },
        Lane { peer: Some("mini".into()), ..lane("asks", LaneState::Input, 50) },
        Lane {
            error: Some("Credit balance too low".into()),
            ..lane("broke", LaneState::Failed, 10)
        },
        lane("asks-new", LaneState::Input, 1),
        lane("idle-new", LaneState::Idle, 2),
    ]
}

fn none() -> HashSet<String> {
    HashSet::new()
}

fn set(ids: &[&str]) -> HashSet<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn ids(rows: &[Row]) -> Vec<&str> {
    rows.iter().map(|row| row.id.as_str()).collect()
}

fn entries(lanes: &[Lane], marks: &Marks, now: i64) -> Vec<Row> {
    Ranking::default().entries(lanes, marks, now, &none())
}

fn waiting(marks: &Marks, lanes: &[Lane]) -> Vec<String> {
    needing_input(lanes, marks, NOW).into_iter().map(|lane| lane.id.clone()).collect()
}

/// Go to Next Agent Needing Input (HQ #5329): only a chat at a question or permission prompt is a
/// destination, never an unseen result or a failure; it cycles them in the needs-you order
/// (pinned, then newest), skips snoozed and archived ones, and starts over at the first when the
/// one it opened last no longer waits.
#[test]
fn next_needs_input_cycles_and_skips_results_and_snoozed_chats() {
    let all = lanes();
    let order = waiting(&Marks::default(), &all);
    assert_eq!(order, ["asks-new", "asks"]);
    assert_eq!(next_after(None, &order).as_deref(), Some("asks-new"));
    assert_eq!(next_after(Some("asks-new"), &order).as_deref(), Some("asks"));
    assert_eq!(next_after(Some("asks"), &order).as_deref(), Some("asks-new"));
    assert_eq!(next_after(Some("done"), &order).as_deref(), Some("asks-new"));
    assert_eq!(next_after(None, &[]), None);

    let mut marks = Marks::default();
    marks.toggle_pin("asks");
    assert_eq!(waiting(&marks, &all), ["asks", "asks-new"]);
    marks.toggle_pin("asks");
    marks.snooze(&lane("asks-new", LaneState::Input, 1), SNOOZE_MS, NOW);
    let order = waiting(&marks, &all);
    assert_eq!(order, ["asks"]);
    assert_eq!(next_after(Some("asks-new"), &order).as_deref(), Some("asks"));
    marks.archive("asks");
    assert!(waiting(&marks, &all).is_empty());
    // A fresh request breaks the old snooze stamp; a new ask is never lost.
    assert_eq!(waiting(&marks, &[lane("asks-new", LaneState::Input, 0)]), ["asks-new"]);
}

#[test]
fn needs_you_then_unseen_results_then_failures_then_working_then_idle() {
    let rows = entries(&lanes(), &Marks::default(), NOW);
    assert_eq!(
        ids(&rows),
        ["asks-new", "asks", "done", "broke", "working", "idle-new", "idle-old"]
    );
    assert_eq!(rows[0].state, RowState::NeedsYou);
    assert_eq!(rows[1].machine.as_deref(), Some("mini"));
    assert!(rows[2].state == RowState::Done && rows[2].unread);
    assert_eq!(rows[3].state, RowState::Failed);
    assert_eq!(rows[3].preview.as_deref(), Some("Credit balance too low"));
    assert_eq!(rows[4].preview.as_deref(), Some("Running tests"));
    assert_eq!(rows.iter().filter(|row| row.state.needs_attention()).count(), 4);
}

/// A chat whose pull request's checks fail ranks as Red CI: after a finished result nobody has
/// seen and a failed turn, before the working ones. A question or an unseen result outranks its
/// red checks; read, the result leaves them showing.
#[test]
fn a_chat_whose_pull_request_checks_fail_ranks_as_red_ci_before_working() {
    let (red, stale) =
        (lane("red-ci", LaneState::Idle, 3), lane("red-stale", LaneState::Idle, 60 * 48));
    let ranking = Ranking::default();
    let mut all = lanes();
    all.extend([red, stale.clone()]);
    let rows = ranking.entries(&all, &Marks::default(), NOW, &set(&["red-ci", "red-stale"]));
    assert_eq!(
        ids(&rows),
        [
            "asks-new",
            "asks",
            "done",
            "broke",
            "red-ci",
            "red-stale",
            "working",
            "idle-new",
            "idle-old"
        ]
    );
    assert!(rows[4].state == RowState::CiFailing && rows[4].state.needs_attention());
    assert_eq!(ranking.next_change(&[stale], &Marks::default(), NOW, &set(&["red-stale"])), None);

    let overlapping = set(&["asks", "done", "working"]);
    let states = |marks: &Marks| -> std::collections::HashMap<String, RowState> {
        ranking
            .entries(&lanes(), marks, NOW, &overlapping)
            .into_iter()
            .map(|row| (row.id, row.state))
            .collect()
    };
    let before = states(&Marks::default());
    assert_eq!(before["asks"], RowState::NeedsYou);
    assert_eq!(before["done"], RowState::Done);
    assert_eq!(before["working"], RowState::CiFailing);
    let mut marks = Marks::default();
    marks.mark_read(&Lane { unread: true, ..lane("done", LaneState::Idle, 20) });
    assert_eq!(states(&marks)["done"], RowState::CiFailing);
}

#[test]
fn a_pinned_chat_leads_its_tier_and_stays_while_idle_for_long() {
    let mut marks = Marks::default();
    let stale = lane("stale", LaneState::Idle, 60 * 48);
    assert!(entries(std::slice::from_ref(&stale), &marks, NOW).is_empty());
    marks.toggle_pin("stale");
    marks.toggle_pin("idle-old");
    let mut all = lanes();
    all.push(stale);
    let rows = entries(&all, &marks, NOW);
    assert_eq!(ids(&rows[rows.len() - 3..]), ["idle-old", "stale", "idle-new"]);
    assert!(rows.iter().find(|row| row.id == "stale").is_some_and(|row| row.pinned));
}

#[test]
fn read_and_snooze_hold_until_the_chat_moves_on() {
    let mut marks = Marks::default();
    marks.mark_read(&Lane { unread: true, ..lane("done", LaneState::Idle, 20) });
    marks.snooze(&lane("asks", LaneState::Input, 50), SNOOZE_MS, NOW);
    let rows = entries(&lanes(), &marks, NOW);
    let done = rows.iter().find(|row| row.id == "done").expect("done is listed");
    assert_eq!(done.state, RowState::Idle);
    assert!(!done.unread);
    assert!(!rows.iter().any(|row| row.id == "asks"));
    // A new question (a new state stamp) ends the snooze; so does the hour passing.
    assert_eq!(ids(&entries(&[lane("asks", LaneState::Input, 0)], &marks, NOW)), ["asks"]);
    assert!(entries(&lanes(), &marks, NOW + 61 * MINUTE).iter().any(|row| row.id == "asks"));
}

#[test]
fn archived_chats_leave_and_pruned_marks_keep_only_listed_chats() {
    let mut marks = Marks::default();
    marks.archive("broke");
    marks.toggle_pin("working");
    marks.collapsed = true;
    assert!(!entries(&lanes(), &marks, NOW).iter().any(|row| row.id == "broke"));
    marks.prune(&set(&["working"]));
    assert!(marks.archived.is_empty());
    assert_eq!(marks.pinned.iter().collect::<Vec<_>>(), ["working"]);
    assert!(marks.collapsed);
}

#[test]
fn the_rows_wake_at_the_next_snooze_end_or_idle_age_out() {
    let ranking = Ranking::default();
    let mut marks = Marks::default();
    // idle-old (30 min ago) leaves first: 23.5 hours from now.
    assert_eq!(
        ranking.next_change(&lanes(), &marks, NOW, &none()),
        Some(NOW + 24 * HOUR - 30 * MINUTE)
    );
    marks.snooze(&lane("asks", LaneState::Input, 50), SNOOZE_MS, NOW);
    assert_eq!(ranking.next_change(&lanes(), &marks, NOW, &none()), Some(NOW + HOUR));
    // Pinned or unseen chats never age out.
    let mut pinned = Marks::default();
    pinned.toggle_pin("idle-old");
    pinned.toggle_pin("idle-new");
    assert_eq!(ranking.next_change(&lanes(), &pinned, NOW, &none()), None);
    // A snooze on an older state of the chat, or an archived chat, changes no row.
    pinned.snooze(&lane("asks", LaneState::Input, 90), SNOOZE_MS, NOW);
    assert_eq!(ranking.next_change(&lanes(), &pinned, NOW, &none()), None);
    pinned.toggle_pin("idle-old");
    pinned.archive("idle-old");
    assert_eq!(ranking.next_change(&lanes(), &pinned, NOW, &none()), None);
    marks.archive("broke");
    marks.unarchive("broke");
    assert!(entries(&lanes(), &marks, NOW).iter().any(|row| row.id == "broke"));
}

/// Leo 2026-10-21: "the click and drag doesn't quite work for moving guys up". A chat the person
/// drags keeps the place they dropped it in until they drag it again; the others rank around it.
#[test]
fn a_dragged_chat_keeps_its_place_while_the_others_rank() {
    let ranking = Ranking::default();
    let mut marks = Marks::default();
    let owned = |rows: &[Row]| -> Vec<String> { rows.iter().map(|row| row.id.clone()).collect() };
    // Ranked: asks-new, asks, done, broke, working, idle-new, idle-old. Drag idle-new to the top.
    let mut order = owned(&entries(&lanes(), &marks, NOW));
    order.retain(|id| id != "idle-new");
    order.insert(0, "idle-new".into());
    marks.place("idle-new", &order);
    assert_eq!(owned(&entries(&lanes(), &marks, NOW)), order);

    // The working chat asks a question: it climbs over the others, never over the dragged chat.
    let asking: Vec<Lane> = lanes()
        .into_iter()
        .map(|l| if l.id == "working" { lane("working", LaneState::Input, 0) } else { l })
        .collect();
    let shown = owned(&entries(&asking, &marks, NOW));
    assert_eq!(shown, ["idle-new", "working", "asks-new", "asks", "done", "broke", "idle-old"]);

    // A second drag: broke goes under it, and idle-new keeps the place it shows at.
    let mut next: Vec<String> = shown.into_iter().filter(|id| id != "broke").collect();
    next.insert(1, "broke".into());
    marks.place("broke", &next);
    assert_eq!(owned(&entries(&asking, &marks, NOW)), next);

    // A placed idle chat stays past the idle horizon, like a pinned one; the others still age out.
    let later = owned(&entries(&asking, &marks, NOW + 48 * HOUR));
    assert!(
        later.first().is_some_and(|id| id == "idle-new")
            && !later.iter().any(|id| id == "idle-old")
    );
    let placed: Vec<Lane> = asking.iter().filter(|l| l.id == "idle-new").cloned().collect();
    assert_eq!(ranking.next_change(&placed, &marks, NOW, &none()), None);

    // The places go with the chat when acpmux stops listing it.
    marks.prune(&set(&["broke"]));
    assert_eq!(marks.placed.into_iter().collect::<Vec<_>>(), [("broke".to_owned(), 1)]);
}

/// Marks saved before the dragged places existed still load.
#[test]
fn marks_saved_before_places_load() {
    let saved =
        json!({"pinned": ["a"], "read": {}, "snoozed": {}, "archived": [], "collapsed": true});
    let marks = super::super::priority_marks::from_app(&saved).expect("old marks load");
    assert!(marks.pinned.contains("a") && marks.collapsed && marks.placed.is_empty());
}

/// A mark holds for a state stamp the Mac app wrote as `state@<ms>` from a `Date`; the stamp
/// here is the same text, so marks the app saved before the rule moved still match.
#[test]
fn a_stamp_is_the_state_and_its_time_as_the_app_wrote_it() {
    assert_eq!(stamp(&lane("a", LaneState::Input, 0)), "input@1760000000000");
    assert_eq!(stamp(&Lane { since: None, ..lane("a", LaneState::Idle, 0) }), "idle@0");
    let noticed = Lane { mark_key: Some("notice-7".into()), ..lane("a", LaneState::Idle, 0) };
    assert_eq!(stamp(&noticed), "idle@notice-7");
    // Fixed values (Swift's own arithmetic, a `Date` made from ms / 1000 and read back with
    // `Int64(timeIntervalSince1970 * 1000)`): the stamps the app saved for these times.
    for (ms, saved) in [
        (1_760_000_000_001, "working@1760000000001"),
        (1_761_234_567_891, "working@1761234567891"),
        (1_700_000_000_999, "working@1700000000999"),
    ] {
        let at = Lane { since: Some(ms), ..lane("a", LaneState::Working, 0) };
        assert_eq!(stamp(&at), saved);
    }
}

fn summary(id: &str, state: &str) -> Value {
    json!({"sessionId": id, "name": id, "status": "idle",
           "lane": {"state": state, "since": 1_760_000_000_000_i64, "error": null}})
}

/// cx-v9k2f: acpmux decides each session's lane; the view reads it from the summary, as the
/// Mac app's watch feed did (`AgentLanesTests`).
#[test]
fn a_lane_reads_the_summarys_lane_and_links() {
    let mut broke = summary("op-broke", "failed");
    broke["lane"]["error"] = json!("Credit balance too low");
    broke["tags"] = json!({"mux.parent": "chief"});
    let lane = Lane::of(&broke, None).expect("a lane");
    assert_eq!(lane.state, LaneState::Failed);
    assert_eq!(lane.error.as_deref(), Some("Credit balance too low"));
    assert_eq!(lane.parent.as_deref(), Some("chief"));
    assert_eq!(lane.since, Some(1_760_000_000_000));
    assert!(lane.state.needs_attention());
    assert!(!LaneState::Working.needs_attention() && !LaneState::Idle.needs_attention());

    let mut gone = summary("op-gone", "lost");
    gone["peer"] = json!("mini");
    assert_eq!(Lane::of(&gone, None).and_then(|l| l.peer).as_deref(), Some("mini"));
    // A closed session has no lane.
    assert_eq!(Lane::of(&json!({"sessionId": "x", "status": "closed", "lane": null}), None), None);
    // `id` names a session whose summary does not.
    assert_eq!(
        Lane::of(&json!({"lane": {"state": "idle"}}), Some("y")).map(|l| l.id).as_deref(),
        Some("y")
    );

    let mut linked = summary("op-busy", "working");
    linked["cwd"] = json!("/Users/me/cmux/");
    linked["spawnedBy"] = json!("chief");
    linked["pullRequests"] = json!(["https://github.com/o/r/pull/1", ""]);
    linked["family"] = json!("codex");
    linked["agentSessionId"] = json!("abc");
    let lane = Lane::of(&linked, None).expect("a lane");
    assert_eq!(lane.project.as_deref(), Some("cmux"));
    assert_eq!(lane.chat.as_deref(), Some("codex:abc"));
    assert_eq!(
        lane.links(),
        json!({"id": "op-busy", "state": "working", "needsAttention": false, "peer": null, "parent": null,
               "spawnedBy": "chief", "cwd": "/Users/me/cmux/", "pullRequests": ["https://github.com/o/r/pull/1"],
               "chat": "codex:abc"})
    );
}

/// hq#2509: a lane's step and title are acpmux's masked `lane.step` and `lane.title`, never the
/// summary's raw prompt or title; with no masked title the session's name shows.
#[test]
fn a_lane_shows_the_daemons_masked_step_and_title_never_the_raw_prompt() {
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let mut busy = summary("op-busy", "working");
    busy["harness"] = json!("codex");
    busy["title"] = json!(format!("push {token}"));
    busy["turn"] = json!({"prompt": format!("push with {token}")});
    busy["lane"]["step"] = json!("push with [github token]");
    busy["lane"]["title"] = json!("push [github token]");
    let lane = Lane::of(&busy, None).expect("a lane");
    assert_eq!(lane.harness.as_deref(), Some("codex"));
    assert_eq!(lane.step.as_deref(), Some("push with [github token]"));
    assert_eq!(lane.title, "push [github token]");
    busy["lane"] = json!({"state": "working", "since": 1, "error": null});
    let older = Lane::of(&busy, None).expect("a lane");
    assert_eq!(older.step, None, "an acpmux from before lane.step shows no step");
    assert_eq!(older.title, "op-busy");
}
