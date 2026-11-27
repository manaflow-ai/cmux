use super::*;

#[test]
fn control_blocks_signed_out_but_not_while_restoring() {
    let facts =
        ControlFacts { session: "s".into(), chats: vec![chat("s")], ..ControlFacts::default() };
    assert_eq!(
        serde_json::to_value(control(&facts)).unwrap(),
        serde_json::json!({ "blocked": { "why": "signed-out" } })
    );
    let restoring = ControlFacts { restoring: true, ..facts.clone() };
    assert_eq!(serde_json::to_value(control(&restoring)).unwrap(), serde_json::json!({}));
    let signed_in = ControlFacts { signed_in: true, ..facts };
    assert_eq!(control(&signed_in), Control::default());
}

#[test]
fn control_names_no_plan_only_for_a_chat_on_this_mac() {
    let facts = ControlFacts {
        session: "s".into(),
        signed_in: true,
        plan_known: true,
        plan: None,
        chats: vec![chat("s")],
        ..ControlFacts::default()
    };
    assert_eq!(
        serde_json::to_value(extra(control(&facts))).unwrap(),
        serde_json::json!({ "blocked": { "why": "no-plan" } })
    );
    let in_cloud = ControlFacts { chats: vec![Chat { at: At::Cloud, ..chat("s") }], ..facts };
    assert_eq!(extra(control(&in_cloud)), Control::default());
}

#[test]
fn control_lists_holders_when_every_slot_is_pinned_elsewhere() {
    let pinned = |session: &str, at: u64| Chat {
        pin: Pin::Cloud,
        at: At::Cloud,
        lit_at_ms: Some(at),
        ..chat(session)
    };
    let facts = ControlFacts {
        session: "s".into(),
        signed_in: true,
        plan_known: true,
        plan: Some(Plan::Trial),
        chats: vec![pinned("held", 5), chat("s")],
        ..ControlFacts::default()
    };
    assert_eq!(
        serde_json::to_value(extra(control(&facts))).unwrap(),
        serde_json::json!({ "holders": [{ "session": "held", "title": "held title" }] })
    );
    // The holder itself, and a plan with a free slot, show nothing extra.
    let holder = ControlFacts { session: "held".into(), ..facts.clone() };
    assert_eq!(extra(control(&holder)), Control::default());
    let roomy = ControlFacts { plan: Some(Plan::Pro), ..facts };
    assert_eq!(extra(control(&roomy)), Control::default());
}

#[test]
fn control_facts_read_the_apps_camel_case() {
    let facts: ControlFacts = serde_json::from_value(serde_json::json!({
        "session": "s",
        "signedIn": true,
        "planKnown": true,
        "plan": "plus",
        "chats": [{ "session": "s", "pin": "auto", "at": "local" }]
    }))
    .unwrap();
    assert_eq!(facts.plan, Some(Plan::Plus));
    assert_eq!(facts.chats[0].pin, Pin::Auto);
}

#[test]
fn control_reads_the_servers_plan_id_and_ignores_an_unknown_one() {
    let pinned = Chat { pin: Pin::Cloud, at: At::Cloud, ..chat("held") };
    let facts = ControlFacts {
        session: "s".into(),
        signed_in: true,
        plan_known: true,
        plan_id: Some("next_plus".into()),
        chats: vec![pinned, chat("s")],
        ..ControlFacts::default()
    };
    assert_eq!(extra(control(&facts)), Control::default());
    let unknown = ControlFacts { plan_id: Some("enterprise_x".into()), ..facts };
    assert_eq!(control(&unknown), Control::default());
    assert_eq!(plan_of_id("next_max"), Some(Plan::Max));
    assert_eq!(plan_of_id("pro"), Some(Plan::Pro));
}

#[test]
fn control_carries_keep_running_under_a_known_plan() {
    let high = |session: &str, at: u64| Chat {
        priority: Priority::High,
        lit_at_ms: Some(at),
        ..chat(session)
    };
    let facts = ControlFacts {
        session: "s".into(),
        signed_in: true,
        plan_known: true,
        plan: Some(Plan::Trial),
        chats: vec![high("first", 1), high("s", 2)],
        ..ControlFacts::default()
    };
    // The trial's one slot goes to the earliest Keep Running: this chat waits for it.
    assert_eq!(
        serde_json::to_value(control(&facts).keep).unwrap(),
        serde_json::json!({ "priority": "high", "pin": "auto", "at": "local", "lit": false,
                            "used": 1, "total": 1, "waiting": true })
    );
    let first = ControlFacts { session: "first".into(), ..facts.clone() };
    let keep = control(&first).keep.unwrap();
    assert!(keep.lit && !keep.waiting);
    // Unknown plan or signed out: no Keep Running state to draw.
    assert_eq!(control(&ControlFacts { plan_known: false, ..facts.clone() }).keep, None);
    assert_eq!(control(&ControlFacts { signed_in: false, ..facts }).keep, None);
}

/// The control without its Keep Running view: what blocks or names holders.
fn extra(control: Control) -> Control {
    Control { keep: None, ..control }
}

fn chat(session: &str) -> Chat {
    Chat { session: session.into(), title: format!("{session} title"), ..Chat::default() }
}

#[test]
fn plans_have_the_rfd_slot_and_pool_limits() {
    let cases = [
        (None, 0, None),
        (Some(Plan::Trial), 1, Some(10)),
        (Some(Plan::Intro), 3, Some(100)),
        (Some(Plan::Plus), 3, Some(100)),
        (Some(Plan::Pro), 5, Some(1_000)),
        (Some(Plan::Agents20), 20, Some(4_000)),
        (Some(Plan::Max), 50, Some(10_000)),
    ];
    for (plan, expected_slots, expected_hours) in cases {
        assert_eq!(slots(plan), expected_slots);
        assert_eq!(pool_hours(plan), expected_hours);
    }
}

#[test]
fn every_priority_pin_and_place_combination_has_the_right_slot_rule() {
    for priority in [Priority::Normal, Priority::High] {
        for pin in [Pin::Auto, Pin::Cloud, Pin::Local] {
            for at in [At::Local, At::Cloud] {
                let actual = holds_slot(&Chat { priority, pin, at, ..Chat::default() });
                let expected = pin != Pin::Local
                    && (pin == Pin::Cloud
                        || priority == Priority::High
                        || (priority == Priority::Normal && at == At::Cloud));
                assert_eq!(actual, expected, "{priority:?} {pin:?} {at:?}");
            }
        }
    }
}

#[test]
fn admission_uses_a_free_slot_then_returns_the_oldest_borrower() {
    let free = vec![chat("one")];
    assert_eq!(admit(2, &free, "one"), Admit::Lit);

    let chats = vec![
        Chat { session: "old".into(), at: At::Cloud, active_at_ms: 10, ..chat("old") },
        Chat { session: "new".into(), at: At::Cloud, active_at_ms: 20, ..chat("new") },
        Chat { session: "wanted".into(), ..chat("wanted") },
    ];
    assert_eq!(admit(2, &chats, "wanted"), Admit::LitAfterReturn { returns: vec!["old".into()] });
}

#[test]
fn admission_reports_lit_holders_oldest_first_and_handles_no_cloud() {
    let chats = vec![
        Chat {
            session: "new".into(),
            priority: Priority::High,
            lit_at_ms: Some(20),
            ..chat("new")
        },
        Chat {
            session: "old".into(),
            priority: Priority::High,
            lit_at_ms: Some(10),
            title: "Older".into(),
            ..chat("old")
        },
        chat("wanted"),
    ];
    assert_eq!(
        admit(2, &chats, "wanted"),
        Admit::Full {
            holders: vec![
                Holder { session: "old".into(), title: "Older".into() },
                Holder { session: "new".into(), title: "new title".into() },
            ]
        }
    );
    assert_eq!(admit(0, &chats, "wanted"), Admit::NoCloud);
    assert_eq!(admit(2, &chats, "old"), Admit::Lit);
}

#[test]
fn leave_order_caps_moves_and_keeps_the_priority_and_work_order() {
    let chats = vec![
        Chat { session: "borrowed".into(), at: At::Cloud, ..chat("borrowed") },
        Chat {
            session: "high-idle".into(),
            priority: Priority::High,
            lit_at_ms: Some(1),
            ..chat("high-idle")
        },
        Chat {
            session: "high-work".into(),
            priority: Priority::High,
            lit_at_ms: Some(20),
            has_work: true,
            ..chat("high-work")
        },
        Chat { session: "auto-new".into(), active_at_ms: 50, has_work: true, ..chat("auto-new") },
        Chat { session: "auto-old".into(), active_at_ms: 10, has_work: true, ..chat("auto-old") },
        Chat {
            session: "local-pinned".into(),
            pin: Pin::Local,
            has_work: true,
            ..chat("local-pinned")
        },
        Chat {
            session: "waiting".into(),
            priority: Priority::High,
            lit_at_ms: Some(30),
            has_work: true,
            ..chat("waiting")
        },
    ];
    let leave = leave_order(3, &chats);
    assert_eq!(leave.moves, ["high-work", "waiting"]);
    assert_eq!(leave.pauses, ["auto-new", "auto-old", "local-pinned"]);
}

#[test]
fn returns_put_auto_before_newest_high_and_expose_cloud_pins() {
    let chats = vec![
        Chat {
            session: "high-old".into(),
            priority: Priority::High,
            at: At::Cloud,
            lit_at_ms: Some(10),
            ..chat("high-old")
        },
        Chat { session: "auto-new".into(), at: At::Cloud, active_at_ms: 20, ..chat("auto-new") },
        Chat {
            session: "high-new".into(),
            priority: Priority::High,
            at: At::Cloud,
            lit_at_ms: Some(30),
            ..chat("high-new")
        },
        Chat { session: "pinned".into(), pin: Pin::Cloud, at: At::Cloud, ..chat("pinned") },
    ];
    assert_eq!(return_order(&chats), ["auto-new", "high-new", "high-old"]);
    assert_eq!(pauses_in_place(&chats), ["pinned"]);
}

#[test]
fn view_never_marks_a_waiting_chat_lit_and_caps_generated_usage() {
    let mut seed = 0x5eed_u64;
    for round in 0..200 {
        let count = (seed as usize % 9) + 1;
        let total = (seed.rotate_left(7) % 6) as u32;
        let mut chats = Vec::with_capacity(count);
        for index in 0..count {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let priority = if seed & 1 == 0 { Priority::Normal } else { Priority::High };
            let pin = match (seed >> 1) % 3 {
                0 => Pin::Auto,
                1 => Pin::Cloud,
                _ => Pin::Local,
            };
            let at = if seed & 8 == 0 { At::Local } else { At::Cloud };
            chats.push(Chat {
                session: format!("{round}-{index}"),
                priority,
                pin,
                at,
                lit_at_ms: Some(seed % 100),
                active_at_ms: seed % 100,
                has_work: seed & 16 != 0,
                ..Chat::default()
            });
        }
        for chat in &chats {
            let shown = view(total, &chats, &chat.session).expect("generated session exists");
            assert!(shown.used <= shown.total);
            assert!(!(shown.lit && shown.waiting));
        }
    }
}
