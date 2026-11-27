//! Parity tests ported from `AgentPriorityRankingTests`, `SidebarLaneStatusTests`,
//! `SidebarSessionTreeFeedTests`, `SidebarTransientItemChiefTests` and friends.

use super::*;
use serde_json::{Value, json};

const NOW: f64 = 1_760_000_000.0;

fn lane(id: &str, state: LaneState, ago_minutes: f64) -> Lane {
    Lane {
        id: id.to_owned(),
        name: id.to_owned(),
        title: id.to_owned(),
        project: Some("cmux".to_owned()),
        state,
        since: Some(NOW - ago_minutes * 60.0),
        ..Lane::default()
    }
}

fn fixture() -> Vec<Lane> {
    let mut working = lane("working", LaneState::Working, 5.0);
    working.step = Some("Running tests".to_owned());
    let mut done = lane("done", LaneState::Idle, 20.0);
    done.unread = true;
    let mut asks = lane("asks", LaneState::Input, 50.0);
    asks.peer = Some("mini".to_owned());
    let mut broke = lane("broke", LaneState::Failed, 10.0);
    broke.error = Some("Credit balance too low".to_owned());
    vec![
        lane("idle-old", LaneState::Idle, 30.0),
        working,
        done,
        asks,
        broke,
        lane("asks-new", LaneState::Input, 1.0),
        lane("idle-new", LaneState::Idle, 2.0),
    ]
}

fn ids(entries: &[PriorityEntry]) -> Vec<&str> {
    entries.iter().map(|e| e.id.as_str()).collect()
}

fn rank(lanes: &[Lane], marks: &Marks, now: f64) -> Vec<PriorityEntry> {
    entries(lanes, marks, now, &BTreeSet::new(), &BTreeMap::new(), IDLE_HORIZON)
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| (*s).to_owned()).collect()
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn ranks_by_tier_then_newest() {
    let rows = rank(&fixture(), &Marks::default(), NOW);
    assert_eq!(
        ids(&rows),
        ["asks-new", "asks", "done", "broke", "working", "idle-new", "idle-old"]
    );
    let asks = &rows[1];
    assert_eq!(asks.machine.as_deref(), Some("mini"));
    assert_eq!(rows[3].preview.as_deref(), Some("Credit balance too low"));
    assert_eq!(rows[4].preview.as_deref(), Some("Running tests"));
    assert_eq!(rows[4].since, Some(NOW - 300.0));
    assert!(rows[2].unread);
}

#[test]
fn failing_checks_rank_under_failures_and_keep_stale_lanes() {
    let mut lanes = fixture();
    lanes.push(lane("red-ci", LaneState::Idle, 3.0));
    lanes.push(lane("red-stale", LaneState::Idle, 48.0 * 60.0));
    let failing = set(&["red-ci", "red-stale"]);
    let rows = entries(&lanes, &Marks::default(), NOW, &failing, &BTreeMap::new(), IDLE_HORIZON);
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
    let stale = vec![lane("red-stale", LaneState::Idle, 48.0 * 60.0)];
    assert_eq!(
        next_change(&stale, &Marks::default(), NOW, &set(&["red-stale"]), IDLE_HORIZON),
        None
    );
}

#[test]
fn failing_checks_lose_to_higher_tiers() {
    let failing = set(&["asks", "done", "working"]);
    let lanes = fixture();
    let state_of = |marks: &Marks, id: &str| {
        let rows = entries(&lanes, marks, NOW, &failing, &BTreeMap::new(), IDLE_HORIZON);
        rows.into_iter().find(|r| r.id == id).map(|r| r.state)
    };
    let marks = Marks::default();
    assert_eq!(state_of(&marks, "asks"), Some(PriorityState::NeedsYou));
    assert_eq!(state_of(&marks, "done"), Some(PriorityState::Done));
    assert_eq!(state_of(&marks, "working"), Some(PriorityState::CiFailing));
    let mut read = Marks::default();
    let done = lanes.iter().find(|l| l.id == "done").unwrap();
    read.read.insert("done".into(), stamp(done));
    assert_eq!(state_of(&read, "done"), Some(PriorityState::CiFailing));
}

#[test]
fn stale_idle_ages_out_unless_pinned() {
    let stale = lane("stale", LaneState::Idle, 48.0 * 60.0);
    assert!(rank(std::slice::from_ref(&stale), &Marks::default(), NOW).is_empty());
    let mut lanes = fixture();
    lanes.push(stale);
    let marks = Marks { pinned: set(&["stale", "idle-old"]), ..Marks::default() };
    let rows = rank(&lanes, &marks, NOW);
    assert_eq!(ids(&rows)[rows.len() - 3..], ["idle-old", "stale", "idle-new"]);
}

#[test]
fn read_and_snooze_follow_the_stamp() {
    let lanes = fixture();
    let done = lanes.iter().find(|l| l.id == "done").unwrap();
    let mut marks = Marks::default();
    marks.read.insert("done".into(), stamp(done));
    let row = rank(&lanes, &marks, NOW).into_iter().find(|r| r.id == "done").unwrap();
    assert_eq!(row.state, PriorityState::Idle);
    assert!(!row.unread);

    let asks = lanes.iter().find(|l| l.id == "asks").unwrap();
    let mut snoozed = Marks::default();
    snoozed.snoozed.insert("asks".into(), Snooze { stamp: stamp(asks), until: NOW + 3600.0 });
    assert!(!ids(&rank(&lanes, &snoozed, NOW)).contains(&"asks"));
    let mut again = lanes.clone();
    again.iter_mut().find(|l| l.id == "asks").unwrap().since = Some(NOW);
    assert!(ids(&rank(&again, &snoozed, NOW)).contains(&"asks"));
    assert!(ids(&rank(&lanes, &snoozed, NOW + 61.0 * 60.0)).contains(&"asks"));
}

#[test]
fn next_change_is_the_earliest_snooze_end_or_age_out() {
    let lanes = fixture();
    let none = BTreeSet::new();
    let change = |marks: &Marks| next_change(&lanes, marks, NOW, &none, IDLE_HORIZON);
    assert_eq!(change(&Marks::default()), Some(NOW + IDLE_HORIZON - 30.0 * 60.0));
    let asks = lanes.iter().find(|l| l.id == "asks").unwrap();
    let mut snoozed = Marks { pinned: set(&["idle-old", "idle-new"]), ..Marks::default() };
    assert_eq!(change(&snoozed), None);
    snoozed.snoozed.insert("asks".into(), Snooze { stamp: stamp(asks), until: NOW + 3600.0 });
    assert_eq!(change(&snoozed), Some(NOW + 3600.0));
    let mut older = asks.clone();
    older.since = Some(NOW - 90.0 * 60.0);
    snoozed.snoozed.insert("asks".into(), Snooze { stamp: stamp(&older), until: NOW + 3600.0 });
    assert_eq!(change(&snoozed), None);
    let archived =
        Marks { pinned: set(&["idle-new"]), archived: set(&["idle-old"]), ..Marks::default() };
    assert_eq!(change(&archived), None);
}

#[test]
fn dragged_rows_keep_their_place() {
    let mut lanes = fixture();
    let mut marks = Marks::default();
    let mut moved: Vec<String> =
        ids(&rank(&lanes, &marks, NOW)).iter().map(|s| (*s).to_owned()).collect();
    moved.retain(|id| id != "idle-new");
    moved.insert(0, "idle-new".to_owned());
    marks.place("idle-new", &moved);
    assert_eq!(
        ids(&rank(&lanes, &marks, NOW)),
        moved.iter().map(String::as_str).collect::<Vec<_>>()
    );

    let working = lanes.iter_mut().find(|l| l.id == "working").unwrap();
    working.state = LaneState::Input;
    working.since = Some(NOW);
    let rows = rank(&lanes, &marks, NOW);
    assert_eq!(
        ids(&rows),
        ["idle-new", "working", "asks-new", "asks", "done", "broke", "idle-old"]
    );

    let mut moved: Vec<String> = ids(&rows).iter().map(|s| (*s).to_owned()).collect();
    moved.retain(|id| id != "broke");
    moved.insert(1, "broke".to_owned());
    marks.place("broke", &moved);
    assert_eq!(
        ids(&rank(&lanes, &marks, NOW)),
        moved.iter().map(String::as_str).collect::<Vec<_>>()
    );

    let later = rank(&lanes, &marks, NOW + 48.0 * 3600.0);
    assert_eq!(later[0].id, "idle-new");
    assert!(!ids(&later).contains(&"idle-old"));

    marks.prune(&set(&["broke"]));
    assert_eq!(marks.placed, BTreeMap::from([("broke".to_owned(), 1)]));
}

#[test]
fn menu_lists_and_cycling() {
    let lanes = fixture();
    let marks = Marks::default();
    let waiting = needing_input(&lanes, &marks, NOW);
    assert_eq!(waiting, ["asks-new", "asks"]);
    assert_eq!(next_after(None, &waiting).as_deref(), Some("asks-new"));
    assert_eq!(next_after(Some("asks-new"), &waiting).as_deref(), Some("asks"));
    assert_eq!(next_after(Some("asks"), &waiting).as_deref(), Some("asks-new"));
    assert_eq!(next_after(Some("done"), &waiting).as_deref(), Some("asks-new"));
    assert_eq!(next_after(None, &[]), None);
    assert_eq!(running(&lanes, &marks, NOW), ["working"]);
    assert_eq!(unread(&lanes, &marks, NOW), ["done"]);
    let pinned = Marks { pinned: set(&["asks"]), ..Marks::default() };
    assert_eq!(needing_input(&lanes, &pinned, NOW), ["asks", "asks-new"]);
}

#[test]
fn stamp_uses_mark_key_else_millis() {
    let mut l = lane("a", LaneState::Idle, 0.0);
    l.since = Some(1.2345);
    assert_eq!(stamp(&l), "idle@1234");
    l.since = None;
    assert_eq!(stamp(&l), "idle@0");
    l.mark_key = Some("n7@g-".into());
    l.state = LaneState::Input;
    assert_eq!(stamp(&l), "input@n7@g-");
}

#[test]
fn merge_lets_asks_and_higher_ranks_win() {
    let row = RowActivity { activity: Indicator::Busy, progress: true, agent_working: false };
    let merged = merge(&[lane("w", LaneState::Working, 1.0)], &row);
    assert!(merged.agent_working);
    assert!(!merged.replaced);
    assert_eq!(merged.activity, Indicator::Busy);

    let merged = merge(&[lane("a", LaneState::Input, 2.0)], &row);
    assert_eq!(merged.activity, Indicator::Waiting);
    assert!(merged.replaced && !merged.progress);
    assert_eq!(merged.activity_since, Some(NOW - 120.0));

    let waiting = RowActivity { activity: Indicator::Waiting, ..RowActivity::default() };
    assert!(!merge(&[lane("f", LaneState::Failed, 1.0)], &waiting).replaced);
    let merged = merge(&[lane("f", LaneState::Failed, 1.0)], &RowActivity::default());
    assert_eq!(merged.activity, Indicator::Error);
    assert!(!merge(&[lane("i", LaneState::Idle, 1.0)], &RowActivity::default()).replaced);
}

#[test]
fn superseded_failures_go() {
    let failed = lane("f", LaneState::Failed, 10.0);
    let alone = vec![failed.clone()];
    assert_eq!(without_superseded_failures(&alone), alone);
    let with_working = vec![failed.clone(), lane("w", LaneState::Working, 20.0)];
    assert_eq!(without_superseded_failures(&with_working).len(), 1);
    let rested_after = vec![failed.clone(), lane("i", LaneState::Idle, 5.0)];
    assert_eq!(without_superseded_failures(&rested_after)[0].id, "i");
    let rested_before = vec![failed.clone(), lane("i", LaneState::Idle, 15.0)];
    assert_eq!(without_superseded_failures(&rested_before).len(), 2);
    let both_failed = vec![failed, lane("l", LaneState::Lost, 1.0)];
    assert_eq!(without_superseded_failures(&both_failed).len(), 2);
}

#[test]
fn chip_step_and_done() {
    let mut done = lane("d", LaneState::Idle, 3.0);
    done.unread = true;
    let marks = Marks::default();
    let none = BTreeSet::new();
    assert_eq!(chip(std::slice::from_ref(&done), &marks, &none, &none), None);
    assert_eq!(
        chip(std::slice::from_ref(&done), &marks, &set(&["d"]), &none),
        Some(PriorityState::CiFailing)
    );
    let failed = lane("f", LaneState::Failed, 3.0);
    let both = vec![failed.clone(), lane("a", LaneState::Input, 3.0)];
    assert_eq!(chip(&both, &marks, &none, &none), Some(PriorityState::NeedsYou));
    assert_eq!(chip(std::slice::from_ref(&failed), &marks, &none, &set(&["f"])), None);
    assert!(agent_done(std::slice::from_ref(&done), &marks));

    let mut old = lane("o", LaneState::Working, 9.0);
    old.step = Some("old".into());
    let mut new = lane("n", LaneState::Working, 1.0);
    new.turn_activity = Some("\n  Editing files \nmore".into());
    let mut prompted = lane("p", LaneState::Working, 0.0);
    prompted.turn_prompt = Some("hi".into());
    prompted.step = Some("ignored".into());
    assert_eq!(step(&[old.clone(), new, prompted]).as_deref(), Some("Editing files"));
    assert_eq!(step(&[old]).as_deref(), Some("old"));
}

#[test]
fn row_status_request() {
    let request: Request = serde_json::from_value(json!({
        "rule": "rowStatus",
        "lanes": [
            {"id": "f", "state": "failed", "since": 10.0},
            {"id": "w", "state": "working", "since": 5.0, "step": "Building"}
        ],
        "row": {"activity": "idle"}
    }))
    .unwrap();
    let answer = serde_json::to_value(respond(&request)).unwrap();
    assert_eq!(answer["superseded"], json!(["f"]));
    assert_eq!(answer["merged"]["activity"], json!("working"));
    assert_eq!(answer["merged"]["agentWorking"], json!(true));
    assert_eq!(answer["step"], json!("Building"));
    assert_eq!(answer["chip"], Value::Null);
}

fn tab(
    session: &str,
    unread: bool,
    level: Option<NoticeLevel>,
    created: Option<u64>,
) -> MachineTab {
    MachineTab {
        session: Some(session.to_owned()),
        harness: Some("claude".to_owned()),
        display_title: format!("  {session} title "),
        has_unread: unread,
        notice: level.map(|level| Notice {
            id: "7".into(),
            level: Some(level),
            created_at_ms: created,
            ledger_ms: None,
            text: Some("Needs approval".into()),
        }),
    }
}

#[test]
fn machine_lanes_keep_the_strongest_tab() {
    let tabs = vec![
        tab("a", false, None, None),
        tab("b", true, Some(NoticeLevel::Error), Some(5_000)),
        tab("a", true, Some(NoticeLevel::Warning), Some(9_000)),
        tab("a", true, Some(NoticeLevel::Error), Some(9_500)),
        MachineTab { session: Some(String::new()), ..MachineTab::default() },
    ];
    let lanes = machine_lanes(&tabs, Some("mini"), Some("3"), &BTreeMap::new(), NOW);
    assert_eq!(lanes.len(), 2);
    assert_eq!(lanes[0].id, "a");
    assert_eq!(lanes[0].state, LaneState::Input);
    assert_eq!(lanes[0].since, Some(9.0));
    assert_eq!(lanes[0].title, "a title");
    assert_eq!(lanes[0].step.as_deref(), Some("Needs approval"));
    assert_eq!(lanes[0].mark_key.as_deref(), Some("n7@9000"));
    assert_eq!(lanes[1].state, LaneState::Failed);
    assert_eq!(lanes[1].error.as_deref(), Some("Needs approval"));
    assert_eq!(lanes[1].peer.as_deref(), Some("mini"));

    let quiet = machine_lanes(&tabs[..1], None, None, &BTreeMap::new(), NOW);
    assert_eq!(quiet[0].mark_key.as_deref(), Some("none"));
    assert_eq!(quiet[0].since, Some(NOW));

    let seen = BTreeMap::from([("c#n7@g3".to_owned(), 42.0)]);
    let info = machine_lanes(
        &[tab("c", true, Some(NoticeLevel::Info), None)],
        None,
        Some("3"),
        &seen,
        NOW,
    );
    assert_eq!(info[0].since, Some(42.0));
    assert!(info[0].unread);

    let waiting = machine_waiting_lanes(&tabs, None, None, &BTreeMap::new(), NOW);
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].id, "a");
}

fn chats(id: &str, refs: &[(&str, &str)]) -> WorkspaceChats {
    WorkspaceChats {
        id: id.to_owned(),
        refs: refs
            .iter()
            .map(|(host, session)| SessionRef {
                host: (*host).to_owned(),
                session: Some((*session).to_owned()),
                harness: None,
            })
            .collect(),
    }
}

fn pr(url: &str, state: &str, checks: Option<&str>, created: &str) -> PullRequest {
    PullRequest {
        url: url.to_owned(),
        number: url.rsplit('/').next().unwrap().parse().unwrap_or(0),
        title: "t".into(),
        state: state.into(),
        checks: checks.map(str::to_owned),
        created_at: created.into(),
        ..PullRequest::default()
    }
}

#[test]
fn tree_pass_links_spawned_remote_and_recorded() {
    let mut lanes = BTreeMap::new();
    let mut parent = lane("p", LaneState::Idle, 1.0);
    parent.cwd = Some("/repo".into());
    let mut child = lane("c", LaneState::Input, 1.0);
    child.spawned_by = Some("p".into());
    child.pull_requests = vec!["https://github.com/o/r/pull/2".into()];
    lanes.insert("p".to_owned(), parent);
    lanes.insert("c".to_owned(), child);
    let inputs = TreeInputs {
        chats: vec![
            chats("w1", &[("mac", "p")]),
            chats("w2", &[("mac", "c")]),
            chats("w3", &[("box", "r")]),
            chats("w4", &[("box2", "x")]),
        ],
        lanes,
        remote_parents_by_host: BTreeMap::from([(
            "box".to_owned(),
            BTreeMap::from([("r".to_owned(), "c".to_owned())]),
        )]),
        host_aliases: BTreeMap::from([("box".to_owned(), set(&["mac"]))]),
        recorded_parents: vec![Recorded {
            child: Identity { host: "box2".into(), session: Some("x".into()) },
            parent: Identity { host: "mac".into(), session: Some("p".into()) },
        }],
        local_host: Some("mac".into()),
        pull_requests: BTreeMap::from([(
            "https://github.com/o/r/pull/2".to_owned(),
            pr("https://github.com/o/r/pull/2", "open", Some("failing"), "2026"),
        )]),
    };
    let pass = tree_pass(&inputs);
    assert_eq!(pass.parents.get("w2").map(String::as_str), Some("w1"));
    assert_eq!(pass.parents.get("w3").map(String::as_str), Some("w2"));
    assert_eq!(pass.parents.get("w4").map(String::as_str), Some("w1"));
    assert_eq!(pass.states.get("w2"), Some(&AgentState::Blocked));
    assert_eq!(pass.states.get("w1"), Some(&AgentState::Idle));
    assert_eq!(pass.asks, ["/repo", "https://github.com/o/r/pull/2"]);
    let badge = &pass.pull_requests["w2"];
    assert_eq!((badge.count, badge.status), (1, BadgeStatus::Failing));
    assert_eq!(badge.items[0].repository, "o/r");

    let flat = shaped(pass.clone(), false, false, false);
    assert!(flat.parents.is_empty() && !flat.shows_tree && !flat.reads_pull_requests);
    assert!(shaped(pass, false, true, true).shows_tree);
}

#[test]
fn tree_pass_refuses_loops() {
    let mut lanes = BTreeMap::new();
    let mut a = lane("a", LaneState::Idle, 1.0);
    a.spawned_by = Some("b".into());
    let mut b = lane("b", LaneState::Idle, 1.0);
    b.spawned_by = Some("a".into());
    lanes.insert("a".to_owned(), a);
    lanes.insert("b".to_owned(), b);
    let inputs = TreeInputs {
        chats: vec![chats("wa", &[("mac", "a")]), chats("wb", &[("mac", "b")])],
        lanes,
        local_host: Some("mac".into()),
        ..TreeInputs::default()
    };
    let pass = tree_pass(&inputs);
    assert_eq!(pass.parents.len(), 1);
    assert_eq!(pass.parents.get("wa").map(String::as_str), Some("wb"));
}

#[test]
fn holding_prefers_saved_lineage() {
    let pairs = |items: &[(&str, &str)]| -> BTreeMap<String, String> {
        items.iter().map(|(c, p)| ((*c).to_owned(), (*p).to_owned())).collect()
    };
    let parents = pairs(&[("b", "c"), ("d", "a")]);
    assert_eq!(holding(&parents, &BTreeMap::new()), parents);
    let held = holding(&pairs(&[("a", "d"), ("b", "c")]), &pairs(&[("b", "a"), ("x", "x")]));
    assert_eq!(held, pairs(&[("a", "d"), ("b", "a")]));
    let looped = holding(&parents, &pairs(&[("a", "d")]));
    assert_eq!(looped, pairs(&[("a", "d"), ("b", "c")]));
    assert!(reaches("b", "d", &held));
    assert!(!reaches("d", "b", &held));
}

#[test]
fn badge_items_and_repository() {
    assert_eq!(repository("https://github.com/o/r/pull/9"), "o/r");
    assert_eq!(repository("https://github.com/o/r/issues/9"), "");
    assert_eq!(repository("/repo"), "");
    let mut conflict = pr("https://github.com/o/r/pull/3", "open", None, "2026-01-02");
    conflict.mergeable = Some("conflicting".into());
    assert_eq!(item(&conflict).state, ItemState::Conflict);
    assert_eq!(item(&pr("u", "draft", Some("failing"), "")).state, ItemState::Draft);
    assert_eq!(item(&pr("u", "open", Some("pending"), "")).state, ItemState::Passing);
    let answers = BTreeMap::from([
        ("/repo".to_owned(), pr("https://github.com/o/r/pull/1", "merged", None, "2026-01-01")),
        (
            "https://github.com/o/r/pull/1".to_owned(),
            pr("https://github.com/o/r/pull/1", "merged", None, "2026-01-01"),
        ),
        ("https://github.com/o/r/pull/3".to_owned(), conflict),
        (
            "https://github.com/o/r/pull/4".to_owned(),
            pr("https://github.com/o/r/pull/4", "closed", None, "2026-01-03"),
        ),
    ]);
    let asks = strings(&[
        "/repo",
        "https://github.com/o/r/pull/1",
        "https://github.com/o/r/pull/3",
        "https://github.com/o/r/pull/4",
        "missing",
    ]);
    let badge = badge(&asks, &answers).unwrap();
    assert_eq!((badge.count, badge.status), (2, BadgeStatus::Attention));
    assert_eq!(badge.items.iter().map(|i| i.number).collect::<Vec<_>>(), [4, 3, 1]);
    assert_eq!(combining(&[]), None);
    assert_eq!(super::badge(&strings(&["https://github.com/o/r/pull/4"]), &answers), None);

    let mut l = lane("l", LaneState::Idle, 1.0);
    l.pull_requests = strings(&["https://github.com/o/r/pull/5"]);
    let failing = BTreeMap::from([(
        "https://github.com/o/r/pull/5".to_owned(),
        pr("https://github.com/o/r/pull/5", "open", Some("failing"), ""),
    )]);
    assert!(checks_failing(&l, &failing, true));
    assert!(!checks_failing(&l, &failing, false));
}

#[test]
fn workspaces_showing_sessions() {
    let all = vec![chats("w1", &[("box", "a"), ("mac", "b")]), chats("w2", &[("mac", "z")])];
    assert_eq!(
        workspaces_showing(&set(&["a", "b"]), &all, "mac"),
        BTreeMap::from([("w1".to_owned(), "b".to_owned())])
    );
}

#[test]
fn store_asks_stale_keys() {
    let store = BTreeMap::from([
        (
            "https://x/merged".to_owned(),
            StoreKey { answer: Some("merged".into()), ..StoreKey::default() },
        ),
        (
            "https://x/fresh".to_owned(),
            StoreKey { answer: Some("open".into()), elapsed: Some(10.0), ..StoreKey::default() },
        ),
        (
            "https://x/old".to_owned(),
            StoreKey { answer: Some("open".into()), elapsed: Some(60.0), ..StoreKey::default() },
        ),
        (
            "/backing".to_owned(),
            StoreKey { elapsed: Some(100.0), failures: 2, ..StoreKey::default() },
        ),
        (
            "/backed".to_owned(),
            StoreKey { elapsed: Some(1000.0), failures: 9, ..StoreKey::default() },
        ),
        ("/asking".to_owned(), StoreKey { asking: true, ..StoreKey::default() }),
        ("/closed".to_owned(), StoreKey { answer: Some("closed".into()), ..StoreKey::default() }),
    ]);
    let asks = set(&[
        "https://x/merged",
        "https://x/fresh",
        "https://x/old",
        "/backing",
        "/backed",
        "/asking",
        "/closed",
        "/new",
    ]);
    let plan = stale(&asks, &store, 60.0, false);
    assert_eq!(plan.urls, ["https://x/old"]);
    assert_eq!(plan.folders, ["/backed", "/closed", "/new"]);
    let recheck = stale(&asks, &store, 60.0, true);
    assert_eq!(recheck.urls, ["https://x/old"]);
    assert!(recheck.folders.is_empty());
}

fn chief(name: &str, state: LaneState) -> Lane {
    Lane {
        id: format!("id-{name}"),
        name: name.to_owned(),
        title: name.to_owned(),
        state,
        ..Lane::default()
    }
}

#[test]
fn chief_status_reads_turns_and_subagents() {
    let status = |lanes: &[Lane]| chief_status(lanes);
    assert_eq!(
        status(&[
            chief("optchat-6b68ac4a-190", LaneState::Working),
            chief("optchat-6b68ac4a-191", LaneState::Input)
        ])
        .activity,
        Indicator::Waiting
    );
    assert_eq!(
        status(&[chief("optchat-6b68ac4a-190", LaneState::Working)]).activity,
        Indicator::Working
    );
    assert_eq!(status(&[]), ChiefStatus { activity: Indicator::Idle, badge: None });
    assert_eq!(
        status(&[
            chief("optchat-6b68ac4a-9", LaneState::Failed),
            chief("optchat-6b68ac4a-10", LaneState::Idle)
        ])
        .activity,
        Indicator::Idle
    );
    assert_eq!(
        status(&[
            chief("optchat-6b68ac4a-9", LaneState::Idle),
            chief("optchat-6b68ac4a-10", LaneState::Failed)
        ])
        .activity,
        Indicator::Error
    );
    let compact = status(&[
        chief("optchat-compact-6b68ac4a-3", LaneState::Working),
        chief("optchat-sub-6b68ac4a-a2", LaneState::Input),
    ]);
    assert_eq!(compact, ChiefStatus { activity: Indicator::Idle, badge: Some(1) });
    assert_eq!(
        status(&[chief("optchat-6b68ac4a-191-2", LaneState::Input)]).activity,
        Indicator::Waiting
    );
}

#[test]
fn chief_subagents_in_number_order() {
    let mut tenth = chief("optchat-sub-6b68ac4a-a10", LaneState::Working);
    tenth.title = "Tenth".into();
    let mut third = chief("optchat-sub-6b68ac4a-a3-2", LaneState::Working);
    third.title = "Third".into();
    let titles: Vec<String> =
        chief_subagents(&[tenth, third], false).into_iter().map(|s| s.title).collect();
    assert_eq!(titles, ["Third", "Tenth"]);

    let mut inspector = chief("optchat-sub-6b68ac4a-a10", LaneState::Working);
    inspector.title = "Inspector".into();
    let lanes = vec![
        inspector,
        chief("optchat-sub-6b68ac4a-a2", LaneState::Idle),
        chief("optchat-sub-6b68ac4a-a3", LaneState::Failed),
    ];
    let folded = chief_subagents(&lanes, false);
    assert_eq!(folded.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(), ["", "Inspector"]);
    assert_eq!(folded[0].activity, Indicator::Error);
    let open = chief_subagents(&lanes, true);
    assert_eq!(open.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(), ["", "", "Inspector"]);
    assert_eq!(open[0].session, "id-optchat-sub-6b68ac4a-a2");
    assert_eq!(open[0].id, "chief-sub:id-optchat-sub-6b68ac4a-a2");
}

#[test]
fn chief_roles_and_titles() {
    assert_eq!(chief_role("optchat-6b68ac4a-191"), ChiefRole::Turn);
    assert_eq!(chief_role("optchat-6b68ac4a-191-2"), ChiefRole::Turn);
    assert_eq!(chief_role("optchat-6b68ac4a-1-2-3"), ChiefRole::Other);
    assert_eq!(chief_role("optchat-sub-6b68ac4a-a2"), ChiefRole::Subagent);
    assert_eq!(chief_role("optchat-compact-6b68ac4a-3"), ChiefRole::Other);
    assert_eq!(chief_role("optchat-x"), ChiefRole::Other);
    assert_eq!(chief_role("claude-1-2"), ChiefRole::Other);
    assert_eq!(
        chief_task_title("a14 · Native workflows runtime").as_deref(),
        Some("Native workflows runtime")
    );
    assert_eq!(
        chief_task_title("Native workflows runtime").as_deref(),
        Some("Native workflows runtime")
    );
    assert_eq!(chief_task_title("a · x").as_deref(), Some("a · x"));
    assert_eq!(chief_task_title("ab1 · x").as_deref(), Some("ab1 · x"));
    assert_eq!(chief_task_title("Fix a1 · x").as_deref(), Some("Fix a1 · x"));
    assert_eq!(chief_task_title("a3 · "), None);
    assert_eq!(subagent_number("optchat-sub-6b68ac4a-a3-2"), Some(3));
    assert_eq!(turn_number("optchat-6b68ac4a-191-2"), Some(191));
}

#[test]
fn parsing_boundaries_preserve_safe_fallbacks() {
    for name in ["", "optchat", "optchat-sub", "optchat-x", "1", "optchat-x-", "optchat-x-1-2-3"] {
        assert_eq!(chief_role(name), ChiefRole::Other, "{name}");
    }
    assert_eq!(chief_role("optchat-sub-"), ChiefRole::Subagent);
    assert_eq!(chief_role("optchat-家-1"), ChiefRole::Turn);
    for url in
        ["", "/", "https:", "https://host/owner/repo/pull", "https://host/owner/repo/issues/1"]
    {
        assert_eq!(repository(url), "", "{url}");
    }
    assert_eq!(repository("https://host/所有者/仓库/pull/1"), "所有者/仓库");
    for (title, expected) in [
        ("", None),
        (" · ", Some("·")),
        ("a · 标题", Some("a · 标题")),
        ("é · 标题", Some("é · 标题")),
        ("a１２ · 标题", Some("标题")),
        ("a1 · ", None),
    ] {
        assert_eq!(chief_task_title(title).as_deref(), expected, "{title}");
    }
    assert_eq!(next_after(Some("gone"), &[]), None);
    let singleton = strings(&["only"]);
    assert_eq!(next_after(Some("only"), &singleton).as_deref(), Some("only"));
    let ids = strings(&["first", "last"]);
    assert_eq!(next_after(Some("gone"), &ids).as_deref(), Some("first"));
    let wrapped = next_after(Some("last"), &ids);
    assert_eq!(wrapped.as_deref(), Some("first"));
    assert_eq!(next_after(wrapped.as_deref(), &ids).as_deref(), Some("last"));
}

#[test]
fn history_specs_and_titles() {
    let earlier = earlier_spec(&set(&["b", "a"]), &strings(&["c", "a"]), 0, false);
    assert_eq!(earlier.window, EARLIER_WINDOW);
    assert_eq!(earlier.limit, 1);
    assert!(earlier.top_level);
    assert_eq!(earlier.exclude, ["a", "b", "c"]);
    assert_eq!(earlier_spec(&BTreeSet::new(), &[], 30, true).limit, 1);
    assert_eq!(earlier_spec(&BTreeSet::new(), &[], 30, false).limit, 30);
    let pinned = pinned_spec(&strings(&["c", "a"]));
    assert_eq!((pinned.window.as_str(), pinned.limit, pinned.top_level), (PINNED_WINDOW, 2, false));
    assert_eq!(pinned.keys, ["c", "a"]);
    assert_eq!(pinned_spec(&[]).limit, 1);
    assert_eq!(history_title(Some("Chat"), Some("/x"), "claude"), "Chat");
    assert_eq!(history_title(None, Some("/Users/l/repo/"), "claude"), "repo");
    assert_eq!(history_title(None, Some(""), "claude"), "claude");
    assert_eq!(history_title(None, None, "codex"), "codex");
}

#[test]
fn local_lanes_keeps_and_approvals() {
    let mut lanes = BTreeMap::new();
    lanes.insert("a".to_owned(), lane("a", LaneState::Input, 1.0));
    let mut mirrored = lane("m", LaneState::Input, 1.0);
    mirrored.peer = Some("mini".into());
    lanes.insert("m".to_owned(), mirrored);
    let r = |host: &str, session: &str| {
        Some(SessionRef { host: host.into(), session: Some(session.into()), harness: None })
    };
    let tabs = vec![r("mac", "a"), r("mac", "m"), r("box", "a"), None];
    assert_eq!(local_lanes(&tabs, &lanes, Some("mac")).len(), 1);
    assert!(local_lanes(&tabs, &lanes, None).is_empty());

    let waits = waiting_chats(&strings(&["a", "m", "gone"]), &lanes, true);
    assert_eq!(waits.keys().collect::<Vec<_>>(), ["a"]);
    assert!(waiting_chats(&strings(&["a"]), &lanes, false).is_empty());

    let local = vec![r("mac", "a")];
    let live = set(&["a"]);
    assert!(keeps_workspace(&local, Some("mac"), true, None, &live));
    assert!(!keeps_workspace(&local, Some("mac"), true, None, &BTreeSet::new()));
    assert!(keeps_workspace(&local, Some("mac"), false, None, &BTreeSet::new()));
    assert!(keeps_workspace(&local, Some("mac"), false, Some(&set(&["a"])), &BTreeSet::new()));
    assert!(!keeps_workspace(&local, Some("mac"), false, Some(&set(&["z"])), &live));
    assert!(keeps_workspace(&[r("mac", "a"), None], Some("mac"), true, None, &BTreeSet::new()));
    assert!(keeps_workspace(&[r("box", "a")], Some("mac"), true, None, &BTreeSet::new()));
    assert!(keeps_workspace(&local, None, true, None, &BTreeSet::new()));
}

#[test]
fn json_requests_round_trip() {
    let request: Request = serde_json::from_value(json!({
        "rule": "entries",
        "now": NOW,
        "lanes": [{"id": "x", "title": "X", "state": "input", "since": NOW - 60.0}],
        "marks": {"pinned": ["x"]}
    }))
    .unwrap();
    let answer = serde_json::to_value(respond(&request)).unwrap();
    assert_eq!(answer["entries"][0]["state"], json!("needsYou"));
    assert_eq!(answer["entries"][0]["pinned"], json!(true));

    let request: Request = serde_json::from_value(json!({
        "rule": "place", "id": "b", "order": ["a", "b"], "marks": {"placed": {"a": 4}}
    }))
    .unwrap();
    let answer = serde_json::to_value(respond(&request)).unwrap();
    assert_eq!(answer["marks"]["placed"], json!({"a": 0, "b": 1}));

    let request: Request =
        serde_json::from_value(json!({"rule": "chiefTaskTitle", "title": "a3 · Fix"})).unwrap();
    assert_eq!(serde_json::to_value(respond(&request)).unwrap(), json!({"title": "Fix"}));

    let request: Request = serde_json::from_value(json!({
        "rule": "treePass",
        "chats": [{"id": "w", "refs": [{"host": "mac", "session": "s"}]}],
        "lanes": {"s": {"id": "s", "state": "working"}},
        "localHost": "mac"
    }))
    .unwrap();
    let answer = serde_json::to_value(respond(&request)).unwrap();
    assert_eq!(answer["states"], json!({"w": "running"}));
    assert_eq!(answer["showsTree"], json!(true));

    assert!(serde_json::from_value::<Request>(json!({"rule": "nope"})).is_err());
}
