use super::*;

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
