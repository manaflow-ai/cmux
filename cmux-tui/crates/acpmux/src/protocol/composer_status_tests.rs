use std::collections::HashSet;

use serde_json::json;

use super::*;

fn link(link: MachineLink) -> Option<StatusItem> {
    machine_link_item("mini-3", link, Some(1_000), None, false)
}

/// Every kind has one wire word and one words-key prefix of its own, `status.<kind>`.
#[test]
fn every_kind_has_one_wire_word_and_one_words_prefix() {
    let mut prefixes = HashSet::new();
    for kind in StatusKind::ALL {
        let word = serde_json::to_value(kind).unwrap();
        assert_eq!(word, json!(kind.as_str()));
        assert_eq!(serde_json::from_value::<StatusKind>(word).unwrap(), kind);
        assert_eq!(kind.words_prefix(), format!("status.{}", kind.as_str()));
        assert!(prefixes.insert(kind.words_prefix()), "{kind:?} shares its prefix");
    }
    // No prefix is another's start: a key names exactly one kind.
    for a in StatusKind::ALL {
        for b in StatusKind::ALL {
            if a != b {
                assert!(!b.words_prefix().starts_with(&format!("{}.", a.words_prefix())));
            }
        }
    }
    for action in StatusAction::ALL {
        let word = serde_json::to_value(action).unwrap();
        assert_eq!(serde_json::from_value::<StatusAction>(word).unwrap(), action);
    }
    assert_eq!(serde_json::to_value(StatusAction::ResumeQueue).unwrap(), json!("resumeQueue"));
    assert_eq!(serde_json::to_value(FactKind::Subagents).unwrap(), json!("subagents"));
}

/// The key of an item names its own kind and only it.
fn words_of_kind(item: &StatusItem) {
    let prefix = item.kind.words_prefix();
    let rest = item.words.strip_prefix(prefix).unwrap_or_else(|| panic!("{item:?}"));
    assert!(rest.is_empty() || rest.starts_with('.'), "{item:?}");
    let owners = StatusKind::ALL
        .iter()
        .filter(|k| {
            item.words
                .strip_prefix(k.words_prefix())
                .is_some_and(|r| r.is_empty() || r.starts_with('.'))
        })
        .count();
    assert_eq!(owners, 1, "{item:?}");
    assert!(item.kind.emitted_by_daemon(), "{item:?}");
}

#[test]
fn levels_are_ordered_problem_worst() {
    assert!(StatusLevel::Problem > StatusLevel::Attention);
    assert!(StatusLevel::Attention > StatusLevel::Info);
    let mut sorted = StatusLevel::ALL;
    sorted.sort();
    assert_eq!(sorted, StatusLevel::ALL);
}

/// Connected and paused say nothing; a transient state is info and waits the quiet bound.
#[test]
fn transient_link_states_are_info_and_wait_ten_seconds() {
    assert_eq!(link(MachineLink::Connected), None);
    assert_eq!(link(MachineLink::Paused), None);
    for (state, word) in [
        (MachineLink::Connecting, "connecting"),
        (MachineLink::Reconnecting, "reconnecting"),
        (MachineLink::Degraded, "degraded"),
        (MachineLink::Restarting, "restarting"),
    ] {
        let item = link(state).unwrap();
        words_of_kind(&item);
        assert_eq!(item.kind, StatusKind::MachineLink);
        assert_eq!(item.level, StatusLevel::Info, "{state:?}");
        assert_eq!(item.words, format!("status.machineLink.{word}"));
        assert_eq!(item.subject.as_deref(), Some("mini-3"));
        assert_eq!(item.since, Some(1_000));
        assert_eq!(item.show_at, Some(1_000 + LINK_QUIET_MS));
        assert_eq!(LINK_QUIET_MS, 10_000);
        assert_eq!(item.action, None);
    }
}

/// Offline is attention at once with Reconnect unless its reason names another remedy;
/// authFailed and updateRequired are problems at once with their own action.
#[test]
fn terminal_link_states_show_at_once_with_their_action() {
    let offline = link(MachineLink::Offline).unwrap();
    assert_eq!(offline.level, StatusLevel::Attention);
    assert_eq!(offline.words, "status.machineLink.offline");
    assert_eq!(offline.show_at, None);
    assert_eq!(offline.action, Some(StatusAction::Reconnect));

    let expected = [
        (
            OfflineReason::CredentialUnavailable,
            "credentialUnavailable",
            Some(StatusAction::Reconnect),
        ),
        (OfflineReason::MachineStopped, "machineStopped", None),
        (OfflineReason::LoginNeeded, "loginNeeded", Some(StatusAction::SignIn)),
        (OfflineReason::RestartBudgetExceeded, "restartBudgetExceeded", None),
        (OfflineReason::DiskFull, "diskFull", None),
    ];
    assert_eq!(expected.len(), OfflineReason::ALL.len());
    for (reason, word, action) in expected {
        let item =
            machine_link_item("m", MachineLink::Offline, Some(5), Some(reason), false).unwrap();
        words_of_kind(&item);
        assert_eq!(item.level, StatusLevel::Attention);
        assert_eq!(item.words, format!("status.machineLink.offline.{word}"));
        assert_eq!(item.show_at, None);
        assert_eq!(item.action, action, "{reason:?}");
    }

    let auth = link(MachineLink::AuthFailed).unwrap();
    assert_eq!(
        (auth.level, auth.show_at, auth.action),
        (StatusLevel::Problem, None, Some(StatusAction::SignIn))
    );
    assert_eq!(auth.words, "status.machineLink.authFailed");
    let update = link(MachineLink::UpdateRequired).unwrap();
    assert_eq!(
        (update.level, update.show_at, update.action),
        (StatusLevel::Problem, None, Some(StatusAction::Update))
    );
    assert_eq!(update.words, "status.machineLink.updateRequired");

    let removed = machine_link_item("m", MachineLink::Offline, Some(5), None, true).unwrap();
    assert_eq!(removed.words, "status.machineLink.removed");
    assert_eq!(
        (removed.level, removed.action, removed.show_at),
        (StatusLevel::Attention, None, None)
    );
    words_of_kind(&removed);
}

/// Every link state either says nothing or makes an item of its own kind.
#[test]
fn every_link_state_maps() {
    for state in MachineLink::ALL {
        if let Some(item) = link(state) {
            words_of_kind(&item);
        }
    }
}

fn quiet<'a>() -> SessionFacts<'a> {
    SessionFacts { harness: Some("claude"), ..SessionFacts::default() }
}

#[test]
fn a_healthy_session_has_no_items() {
    assert!(composer_status(&quiet()).items.is_empty());
}

#[test]
fn each_session_kind_maps_to_its_level_words_and_action() {
    for (reason, word, action) in [
        (StuckReason::HarnessUnavailable, "harnessUnavailable", None),
        (StuckReason::Capacity, "capacity", None),
        (StuckReason::Auth, "auth", Some(StatusAction::SignIn)),
        (StuckReason::SpawnFailed, "spawnFailed", None),
    ] {
        let facts = SessionFacts { stuck_reason: Some(reason), stuck_since: Some(7), ..quiet() };
        let items = composer_status(&facts).items;
        assert_eq!(items.len(), 1);
        let item = &items[0];
        words_of_kind(item);
        assert_eq!((item.kind, item.level), (StatusKind::Stuck, StatusLevel::Problem));
        assert_eq!(item.words, format!("status.stuck.{word}"));
        assert_eq!((item.since, item.action, item.show_at), (Some(7), action, None));
        assert_eq!(item.subject.as_deref(), Some("claude"));
    }

    let sandbox =
        SessionFacts { harness_sandbox_failing: true, harness_sandbox_failed: Some(9), ..quiet() };
    let item = composer_status(&sandbox).items.remove(0);
    words_of_kind(&item);
    assert_eq!((item.kind, item.level), (StatusKind::HarnessSandbox, StatusLevel::Problem));
    assert_eq!((item.words.as_str(), item.since), ("status.harnessSandbox.failing", Some(9)));
    // A sandbox that failed once and recovered says nothing.
    let recovered = SessionFacts { harness_sandbox_failed: Some(9), ..quiet() };
    assert!(composer_status(&recovered).items.is_empty());

    let limited = SessionFacts { rate_limited_until: Some(50_000), ..quiet() };
    let item = composer_status(&limited).items.remove(0);
    words_of_kind(&item);
    assert_eq!((item.kind, item.level), (StatusKind::RateLimited, StatusLevel::Attention));
    assert_eq!(
        (item.words.as_str(), item.until, item.since),
        ("status.rateLimited.until", Some(50_000), None)
    );
    assert_eq!(item.action, None);

    let parked =
        SessionFacts { rate_limited_until: Some(50_000), rate_limit_parked: Some(40), ..quiet() };
    let items = composer_status(&parked).items;
    assert_eq!(items.len(), 1, "parked replaces until: {items:?}");
    assert_eq!(
        (items[0].words.as_str(), items[0].since, items[0].until),
        ("status.rateLimited.parked", Some(40), Some(50_000))
    );

    let paused = SessionFacts { queue_paused: true, ..quiet() };
    let item = composer_status(&paused).items.remove(0);
    words_of_kind(&item);
    assert_eq!((item.kind, item.level), (StatusKind::QueuePaused, StatusLevel::Attention));
    assert_eq!(
        (item.words.as_str(), item.action),
        ("status.queuePaused.paused", Some(StatusAction::ResumeQueue))
    );
    assert_eq!(item.subject, None);
}

/// Worst level first, then the oldest `since`, an unknown one last.
#[test]
fn items_sort_worst_first_then_oldest() {
    let facts = SessionFacts {
        queue_paused: true,
        rate_limited_until: Some(90),
        stuck_reason: Some(StuckReason::Capacity),
        stuck_since: Some(30),
        harness_sandbox_failing: true,
        harness_sandbox_failed: Some(20),
        ..quiet()
    };
    let kinds: Vec<StatusKind> = composer_status(&facts).items.iter().map(|i| i.kind).collect();
    assert_eq!(
        kinds,
        [
            StatusKind::HarnessSandbox,
            StatusKind::Stuck,
            StatusKind::RateLimited,
            StatusKind::QueuePaused
        ]
    );
    let parked = SessionFacts { rate_limit_parked: Some(5), ..facts };
    let kinds: Vec<StatusKind> = composer_status(&parked).items.iter().map(|i| i.kind).collect();
    assert_eq!(
        kinds,
        [
            StatusKind::HarnessSandbox,
            StatusKind::Stuck,
            StatusKind::RateLimited,
            StatusKind::QueuePaused
        ],
        "parked since 5 goes before the unknown-since queue pause"
    );
}

fn full<'a>() -> SessionFacts<'a> {
    SessionFacts {
        peer: Some("mini-3"),
        cwd: Some("/Users/leo/cmux"),
        branch: Some("main"),
        harness: Some("claude"),
        model: Some("opus"),
        context_tokens: Some(50_000),
        context_window: Some(200_000),
        subagents_live: Some(2),
        queued: 3,
        turn_started_at: Some(1_234),
        ..SessionFacts::default()
    }
}

#[test]
fn facts_come_in_footer_order_and_only_counters_are_live() {
    let facts = composer_status(&full()).facts;
    let kinds: Vec<FactKind> = facts.iter().map(|f| f.kind).collect();
    assert_eq!(kinds, FactKind::ALL);
    for fact in &facts {
        let live = matches!(fact.kind, FactKind::Subagents | FactKind::Queued);
        assert_eq!(fact.live, live, "{fact:?}");
    }
    let by = |kind| facts.iter().find(|f| f.kind == kind).unwrap();
    assert_eq!(by(FactKind::Machine).text.as_deref(), Some("mini-3"));
    assert_eq!(by(FactKind::Folder).text.as_deref(), Some("/Users/leo/cmux"));
    assert_eq!(by(FactKind::Branch).text.as_deref(), Some("main"));
    assert_eq!(by(FactKind::Harness).text.as_deref(), Some("claude"));
    assert_eq!(by(FactKind::Model).text.as_deref(), Some("opus"));
    assert_eq!(by(FactKind::Context).fraction, Some(0.25));
    assert_eq!(by(FactKind::Turn).since, Some(1_234));
    assert_eq!(by(FactKind::Subagents).count, Some(2));
    assert_eq!(by(FactKind::Queued).count, Some(3));
}

#[test]
fn empty_facts_are_left_out() {
    let none = composer_status(&SessionFacts::default());
    assert_eq!(none, ComposerStatus::default());
    let blank = SessionFacts {
        cwd: Some("  "),
        branch: None,
        context_tokens: Some(10),
        context_window: Some(0),
        subagents_live: Some(0),
        queued: 0,
        ..SessionFacts::default()
    };
    assert!(composer_status(&blank).facts.is_empty());
    // A context fuller than its window reads as full, not past it.
    let over = SessionFacts {
        context_tokens: Some(300),
        context_window: Some(200),
        ..SessionFacts::default()
    };
    assert_eq!(composer_status(&over).facts[0].fraction, Some(1.0));
}

/// The summary's own wire fields feed the same facts, and the JSON shape is camelCase with
/// empty optionals left off.
#[test]
fn from_summary_reads_the_wire_row() {
    let row = json!({
        "peer": "mini-3",
        "cwd": "/Users/leo/cmux",
        "gitBranch": "main",
        "harness": "claude",
        "model": "opus",
        "usageStats": {"contextTokens": 50_000, "contextWindow": 200_000, "subagentsLive": 9},
        "subagentsRunning": 2,
        "queued": 3,
        "queuePaused": true,
        "rateLimitedUntil": 77,
        "stuckReason": "spawn_failed",
        "stuckSince": 30,
        "harnessSandboxFailing": false,
        "harnessSandboxFailed": 5,
        "turn": {"startedAt": 1_234},
    });
    let facts = SessionFacts::from_summary(&row);
    assert_eq!(facts.subagents_live, Some(2), "running work wins over the harness records");
    assert_eq!(facts.stuck_reason, Some(StuckReason::SpawnFailed));
    let status = composer_status(&facts);
    assert_eq!(status.facts, composer_status(&full()).facts);
    let wire = serde_json::to_value(&status).unwrap();
    assert_eq!(
        wire["items"][0],
        json!({
            "kind": "stuck", "level": "problem", "words": "status.stuck.spawnFailed",
            "subject": "claude", "since": 30,
        })
    );
    assert_eq!(
        wire["facts"][0],
        json!({"kind": "machine", "text": "mini-3", "live": false, "atRest": true}),
        "a peer's machine earns its name at rest"
    );
    assert!(wire["facts"][1].get("atRest").is_none(), "no other fact is marked at rest");
    assert_eq!(wire["facts"][8], json!({"kind": "queued", "count": 3, "live": true}));
    let back: ComposerStatus = serde_json::from_value(wire).unwrap();
    assert_eq!(back, status);

    // An older row: no usage, no stuck fields, null stuck reason.
    let old = json!({"cwd": "/x", "harness": "codex", "queued": 0, "stuckReason": null});
    let status = composer_status(&SessionFacts::from_summary(&old));
    assert!(status.items.is_empty());
    assert_eq!(status.facts.len(), 2);
    // Fields that are not the right type are read as absent.
    let odd = json!({"cwd": 3, "queued": "many", "turn": null});
    assert_eq!(composer_status(&SessionFacts::from_summary(&odd)), ComposerStatus::default());
}
