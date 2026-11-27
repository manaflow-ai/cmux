// Ported from the macOS app's UnreadRing*Tests, AgentTurnRingTests,
// TabAttentionTests, NotificationRingEdgeCaseTests, TypingKeepsUnreadDotTests,
// FocusUnreadPaneFlashTests and WorkspaceNotificationArrivalTests (they stay
// as the app's parity tests).

use super::*;

fn unread(id: u64) -> Tab {
    Tab { has_unread: true, notification: Some(id), clears_source: true, ..Tab::default() }
}

fn marked(generation: u64) -> Tab {
    Tab { marked_unread: true, marked_generation: generation, ..Tab::default() }
}

fn asked(generation: u64) -> Tab {
    Tab { attention: true, attention_generation: generation, ..Tab::default() }
}

const FOCUS_READS: ReadPolicy = ReadPolicy { clears_agent: true, rings_chat: false };

#[test]
fn a_read_tab_draws_no_ring() {
    assert_eq!(unread_ring(&Tab::default(), 0), None);
}

#[test]
fn the_ring_follows_the_tabs_unread_state() {
    assert_eq!(unread_ring(&unread(7), 0), Some(7));
    assert_eq!(unread_ring(&marked(3), 0), Some(MARK_RING_BASE | 3));
    let both = Tab { marked_unread: true, marked_generation: 3, ..unread(7) };
    assert_eq!(unread_ring(&both, 0), Some(7), "the notification rings first");
}

#[test]
fn a_notification_with_no_marker_rings_as_one() {
    let tab = Tab { has_unread: true, ..Tab::default() };
    assert_eq!(unread_ring(&tab, 0), Some(1));
    assert_eq!(unread_ring(&tab, 1), None);
}

#[test]
fn dismiss_hides_a_notification_until_a_newer_one() {
    assert_eq!(unread_ring(&unread(7), 7), None);
    assert_eq!(unread_ring(&unread(8), 7), Some(8));
}

#[test]
fn a_dismissed_notification_still_rings_its_mark() {
    let tab = Tab { marked_unread: true, marked_generation: 2, ..unread(7) };
    assert_eq!(unread_ring(&tab, 7), Some(MARK_RING_BASE | 2));
}

#[test]
fn dismiss_hides_a_marked_ring_until_the_tab_is_marked_again() {
    let tab = Tab { dismissed_mark: 3, ..marked(3) };
    assert_eq!(unread_ring(&tab, 0), None);
    let again = Tab { dismissed_mark: 3, ..marked(4) };
    assert_eq!(unread_ring(&again, 0), Some(MARK_RING_BASE | 4));
}

#[test]
fn an_agent_request_rings_above_marks_until_hidden() {
    let ring = unread_ring(&asked(5), 0);
    assert_eq!(ring, Some(MARK_RING_BASE | ATTENTION_RING_BASE | 5));
    let hidden = Tab { attention_hidden: true, ..asked(5) };
    assert_eq!(unread_ring(&hidden, 0), None);
}

#[test]
fn a_request_generation_never_spills_into_the_base_bits() {
    let tab = asked(u64::MAX);
    let bases = MARK_RING_BASE | ATTENTION_RING_BASE;
    assert_eq!(unread_ring(&tab, 0), Some(bases | (u64::MAX & !bases)));
}

#[test]
fn going_into_the_tab_reads_it_with_the_default_settings() {
    for trigger in [Trigger::Focus, Trigger::Click, Trigger::Keystroke, Trigger::Open] {
        assert!(reads(trigger, &unread(1), false, FOCUS_READS), "{trigger:?}");
    }
}

#[test]
fn focus_alone_keeps_the_ring_under_the_click_mode() {
    let tab = Tab { clears_source: false, ..unread(1) };
    assert!(!reads(Trigger::Focus, &tab, false, FOCUS_READS));
}

#[test]
fn only_a_click_reads_a_mark() {
    assert!(reads(Trigger::Click, &marked(1), false, FOCUS_READS));
    for trigger in [Trigger::Focus, Trigger::Keystroke, Trigger::Open] {
        assert!(!reads(trigger, &marked(1), false, FOCUS_READS), "{trigger:?}");
    }
}

#[test]
fn a_request_reads_by_the_agent_policy() {
    assert!(reads(Trigger::Focus, &asked(1), false, FOCUS_READS));
    let keeps = ReadPolicy { clears_agent: false, rings_chat: false };
    assert!(!reads(Trigger::Focus, &asked(1), false, keeps));
}

#[test]
fn a_finished_turn_reads_only_when_asked_for_and_ringing() {
    let tab = Tab { agent_chat: true, finished: Some(2), ..Tab::default() };
    let rings = ReadPolicy { clears_agent: true, rings_chat: true };
    assert!(reads(Trigger::Focus, &tab, true, rings));
    assert!(!reads(Trigger::Focus, &tab, false, rings), "no turn: nothing to read");
    assert!(!reads(Trigger::Focus, &tab, true, FOCUS_READS), "the chat ring is off");
    let keeps = ReadPolicy { clears_agent: false, rings_chat: true };
    assert!(!reads(Trigger::Focus, &tab, true, keeps));
}

#[test]
fn a_held_or_unviewed_tab_is_not_read_on_sight() {
    let viewed = Tab { viewed: true, ..unread(1) };
    assert!(reads_on_sight(&viewed, FOCUS_READS));
    assert!(!reads_on_sight(&Tab { held: true, ..viewed.clone() }, FOCUS_READS));
    assert!(!reads_on_sight(&unread(1), FOCUS_READS));
}

fn pane(name: &str, tab: Tab) -> ShownPane {
    ShownPane { pane: name.into(), tab }
}

fn facts(panes: Vec<ShownPane>) -> MarkFacts {
    MarkFacts {
        local: true,
        policy: FOCUS_READS,
        rings_terminal: true,
        panes,
        ..MarkFacts::default()
    }
}

#[test]
fn every_unread_pane_rings_with_its_source_color() {
    let marks =
        marks(&facts(vec![pane("a", unread(4)), pane("b", Tab::default()), pane("c", marked(2))]));
    assert_eq!(
        marks,
        vec![
            PaneMark {
                pane: "a".into(),
                generation: 4,
                agent_chat: false,
                quiet: false,
                color: MarkColor::Source
            },
            PaneMark {
                pane: "c".into(),
                generation: MARK_RING_BASE | 2,
                agent_chat: false,
                quiet: false,
                color: MarkColor::Ring,
            },
        ]
    );
}

#[test]
fn a_muted_workspace_or_the_none_style_rings_nothing() {
    let muted = MarkFacts { muted: true, ..facts(vec![pane("a", unread(1))]) };
    assert!(marks(&muted).is_empty());
    let none = MarkFacts { style_none: true, ..facts(vec![pane("a", unread(1))]) };
    assert!(marks(&none).is_empty());
}

#[test]
fn a_viewed_pane_is_read_on_sight_and_draws_none() {
    let viewed = Tab { viewed: true, ..unread(1) };
    assert!(marks(&facts(vec![pane("a", viewed)])).is_empty());
}

#[test]
fn a_thinking_chat_draws_no_ring() {
    let tab = Tab { agent_chat: true, working: true, ..unread(1) };
    assert!(marks(&facts(vec![pane("a", tab)])).is_empty());
}

#[test]
fn a_finished_chat_rings_its_pane_with_the_chat_ring_on() {
    let tab = Tab { agent_chat: true, finished: Some(9), quiet: true, ..Tab::default() };
    let on = MarkFacts {
        policy: ReadPolicy { clears_agent: true, rings_chat: true },
        ..facts(vec![pane("a", tab.clone())])
    };
    assert_eq!(
        marks(&on),
        vec![PaneMark {
            pane: "a".into(),
            generation: 9,
            agent_chat: true,
            quiet: true,
            color: MarkColor::Agent
        }]
    );
    assert!(
        marks(&facts(vec![pane("a", tab.clone())])).is_empty(),
        "a finished turn rings nothing by default"
    );
    let remote = MarkFacts { local: false, ..on };
    assert!(marks(&remote).is_empty(), "finished turns are this Mac's");
}

#[test]
fn an_unread_agent_chat_rings_like_its_dot_with_the_default_settings() {
    let tab = Tab { agent_chat: true, ..unread(3) };
    let marks = marks(&facts(vec![pane("a", tab)]));
    assert_eq!(
        marks,
        vec![PaneMark {
            pane: "a".into(),
            generation: 3,
            agent_chat: false,
            quiet: false,
            color: MarkColor::Source
        }]
    );
}

#[test]
fn the_terminal_look_off_rings_no_terminal() {
    let off = MarkFacts { rings_terminal: false, ..facts(vec![pane("a", unread(1))]) };
    assert!(marks(&off).is_empty());
}

#[test]
fn a_dismissed_workspace_rings_only_newer_notifications() {
    let dismissed =
        MarkFacts { dismissed: 5, ..facts(vec![pane("a", unread(5)), pane("b", unread(6))]) };
    let rung: Vec<_> = marks(&dismissed).into_iter().map(|mark| mark.pane).collect();
    assert_eq!(rung, vec!["b".to_string()]);
}

fn look(trigger: Trigger, tab: Tab) -> InteractionFacts {
    InteractionFacts {
        trigger,
        local: true,
        flashes: true,
        policy: FOCUS_READS,
        tab,
        ..InteractionFacts::default()
    }
}

#[test]
fn a_look_reads_the_notification_and_blinks() {
    let plan = interaction(&look(Trigger::Click, unread(1)));
    assert_eq!(plan.ack, Ack::Read);
    assert!(plan.entry_read && plan.ends_hold && plan.sees_workspace);
}

#[test]
fn a_remote_daemon_without_ack_keeps_its_mark() {
    let facts = InteractionFacts { owner_cannot_ack: true, ..look(Trigger::Click, unread(1)) };
    let plan = interaction(&facts);
    assert_eq!(plan.ack, Ack::Refused);
    assert!(!plan.entry_read);
}

#[test]
fn a_key_reads_only_past_its_backoff() {
    let held = interaction(&look(Trigger::Keystroke, unread(1)));
    assert_eq!(held.ack, Ack::None);
    let back = interaction(&look(Trigger::Keystroke, Tab { key_may_read: true, ..unread(1) }));
    assert_eq!(back.ack, Ack::Read);
    assert!(!back.sees_workspace, "a key sees no status symbols");
}

#[test]
fn the_policy_keeping_it_reads_nothing() {
    let tab = Tab { clears_source: false, ..unread(1) };
    let plan = interaction(&look(Trigger::Focus, tab));
    assert_eq!(plan.ack, Ack::None);
    assert!(!plan.entry_read && !plan.ends_hold);
}

#[test]
fn a_click_or_a_ready_key_reads_a_mark_and_focus_keeps_it() {
    assert!(interaction(&look(Trigger::Click, marked(1))).reads_mark);
    assert!(!interaction(&look(Trigger::Focus, marked(1))).reads_mark);
    assert!(!interaction(&look(Trigger::Keystroke, marked(1))).reads_mark);
    let ready = Tab { key_may_read: true, ..marked(1) };
    assert!(interaction(&look(Trigger::Keystroke, ready)).reads_mark);
}

#[test]
fn going_into_a_marked_tab_hides_its_request_ring() {
    for trigger in [Trigger::Click, Trigger::Keystroke, Trigger::Open, Trigger::Focus] {
        assert!(interaction(&look(trigger, asked(1))).hides_attention, "{trigger:?}");
    }
    let click_mode =
        InteractionFacts { policy: ReadPolicy::default(), ..look(Trigger::Focus, asked(1)) };
    assert!(!interaction(&click_mode).hides_attention);
    assert!(!interaction(&look(Trigger::Timeout, asked(1))).hides_attention);
}

#[test]
fn a_finished_turn_reads_on_this_mac_only() {
    let tab = Tab { finished: Some(1), ..Tab::default() };
    assert!(interaction(&look(Trigger::Focus, tab.clone())).reads_turn);
    let remote = InteractionFacts { local: false, ..look(Trigger::Focus, tab) };
    assert!(!interaction(&remote).reads_turn);
}

#[test]
fn no_blink_without_the_flash_setting() {
    let facts = InteractionFacts { flashes: false, ..look(Trigger::Click, unread(1)) };
    assert!(!interaction(&facts).entry_read);
}

#[test]
fn dismiss_highlight_reads_every_unread_tab_and_records_the_newest() {
    let tabs = vec![
        unread(4),
        Tab::default(),
        Tab { finished: Some(2), ..marked(3) },
        asked(1),
        Tab { finished: Some(5), ..Tab::default() },
    ];
    let plan = dismiss_highlight(&HighlightFacts {
        local: true,
        flashes_on_read: true,
        dismissed: 2,
        tabs,
    });
    assert_eq!(plan.through, Some(4));
    let indexes: Vec<_> = plan.steps.iter().map(|step| step.index).collect();
    assert_eq!(indexes, vec![0, 2, 3, 4]);
    let marked_step = plan.steps.get(1).copied();
    assert_eq!(
        marked_step,
        Some(HighlightStep {
            index: 2,
            clears_turn: true,
            hides_mark: Some(3),
            hides_attention: false,
            entry_read: true
        })
    );
    assert!(plan.steps.get(2).is_some_and(|step| step.hides_attention));
}

#[test]
fn dismiss_highlight_keeps_an_older_dismissal_and_remote_turns() {
    let plan = dismiss_highlight(&HighlightFacts {
        local: false,
        flashes_on_read: false,
        dismissed: 9,
        tabs: vec![unread(4)],
    });
    assert_eq!(plan.through, None);
    assert_eq!(
        plan.steps.first().map(|step| (step.clears_turn, step.entry_read)),
        Some((false, false))
    );
}

#[test]
fn a_finished_turn_rings_nothing_with_the_chat_ring_off() {
    let end = turn_ended(&TurnEndFacts {
        rings: false,
        generation: 3,
        viewed: vec![false],
        ..TurnEndFacts::default()
    });
    assert!(end.rings.is_empty() && !end.pulsed);
    assert_eq!(end.generation, 3);
}

#[test]
fn a_turn_end_rings_unviewed_tabs_and_a_burst_pulses_once() {
    let end = turn_ended(&TurnEndFacts {
        rings: true,
        since_pulse_ms: None,
        generation: 1,
        viewed: vec![false, true, false],
    });
    assert_eq!(
        end.rings,
        vec![
            TurnRing { index: 0, generation: 2, quiet: false },
            TurnRing { index: 2, generation: 3, quiet: true },
        ]
    );
    assert_eq!(end.generation, 3);
    assert!(end.pulsed);
}

#[test]
fn a_finish_within_the_burst_window_rings_at_rest() {
    let quiet = turn_ended(&TurnEndFacts {
        rings: true,
        since_pulse_ms: Some(899.0),
        generation: 0,
        viewed: vec![false],
    });
    assert_eq!(quiet.rings, vec![TurnRing { index: 0, generation: 1, quiet: true }]);
    assert!(!quiet.pulsed);
    let late = turn_ended(&TurnEndFacts {
        rings: true,
        since_pulse_ms: Some(900.0),
        generation: 0,
        viewed: vec![false],
    });
    assert!(late.pulsed && late.rings.iter().all(|ring| !ring.quiet));
}

#[test]
fn the_finish_generation_wraps() {
    let end = turn_ended(&TurnEndFacts {
        rings: true,
        generation: u64::MAX,
        viewed: vec![false],
        ..TurnEndFacts::default()
    });
    assert_eq!(end.generation, 0);
}

fn reply(banner: &str, marker: u64) -> ReplyFacts {
    ReplyFacts {
        banner: banner.into(),
        text_empty: false,
        located: true,
        pty: true,
        marker: Some(marker),
        marker_unread: true,
    }
}

#[test]
fn a_reply_types_only_into_its_own_unread_notification() {
    assert!(reply_allowed(&reply("cmux-notification-12", 12)));
    assert!(!reply_allowed(&reply("cmux-notification-12", 13)), "a newer notification replaced it");
    assert!(!reply_allowed(&reply("cmux-notification-1", 12)));
    assert!(!reply_allowed(&reply("other-12", 12)));
    assert!(!reply_allowed(&ReplyFacts {
        marker_unread: false,
        ..reply("cmux-notification-12", 12)
    }));
    assert!(!reply_allowed(&ReplyFacts { pty: false, ..reply("cmux-notification-12", 12) }));
    assert!(!reply_allowed(&ReplyFacts { text_empty: true, ..reply("cmux-notification-12", 12) }));
    assert!(!reply_allowed(&ReplyFacts { located: false, ..reply("cmux-notification-12", 12) }));
    assert!(!reply_allowed(&ReplyFacts { marker: None, ..reply("cmux-notification-12", 12) }));
}

fn arriving() -> ArrivalFacts {
    ArrivalFacts { located: true, ..ArrivalFacts::default() }
}

#[test]
fn an_arrival_goes_by_its_facts_in_order() {
    assert_eq!(
        arrival(&ArrivalFacts { terminal_off: true, ..ArrivalFacts::default() }),
        ArrivalRoute::TerminalOff
    );
    assert_eq!(arrival(&ArrivalFacts::default()), ArrivalRoute::Untracked);
    assert_eq!(
        arrival(&ArrivalFacts { acknowledge: true, ..arriving() }),
        ArrivalRoute::ReadOnSight
    );
    assert_eq!(arrival(&arriving()), ArrivalRoute::Deliver);
}

#[test]
fn a_visible_finished_turn_is_seen() {
    let seen =
        ArrivalFacts { finished_turn: true, visible: true, clears_focus: true, ..arriving() };
    assert_eq!(arrival(&seen), ArrivalRoute::ReadSeen);
    assert_eq!(arrival(&ArrivalFacts { clears_focus: false, ..seen }), ArrivalRoute::KeepSeen);
    assert_eq!(arrival(&ArrivalFacts { holds_other_ask: true, ..seen }), ArrivalRoute::Deliver);
    assert_eq!(arrival(&ArrivalFacts { visible: false, ..seen }), ArrivalRoute::Deliver);
}

#[test]
fn a_terminal_alert_waits_for_its_record() {
    let alert = ArrivalFacts { terminal_source: true, looks_like_alert: true, ..arriving() };
    assert_eq!(arrival(&alert), ArrivalRoute::HoldForRecord);
    assert_eq!(arrival(&ArrivalFacts { program: true, ..alert }), ArrivalRoute::Deliver);
    assert_eq!(arrival(&ArrivalFacts { terminal_source: false, ..alert }), ArrivalRoute::Deliver);
}

#[test]
fn a_seen_program_status_reads_by_the_focus_policy() {
    assert_eq!(seen(true), ArrivalRoute::ReadSeen);
    assert_eq!(seen(false), ArrivalRoute::KeepSeen);
}

#[test]
fn a_workspace_mark_goes_out_when_the_tree_or_last_send_differs() {
    assert!(mark_needs_send(&MarkSend { marked: true, current: false, ..MarkSend::default() }));
    assert!(!mark_needs_send(&MarkSend { marked: true, current: true, ..MarkSend::default() }));
    let cleared_before_echo = MarkSend {
        marked: false,
        current: false,
        last: Some(LastSend { marked: true, ago_ms: 10.0 }),
        throttled: false,
    };
    assert!(mark_needs_send(&cleared_before_echo));
}

#[test]
fn a_throttled_repeat_within_the_echo_window_is_in_flight() {
    let repeat = MarkSend {
        marked: false,
        current: true,
        last: Some(LastSend { marked: false, ago_ms: 1999.0 }),
        throttled: true,
    };
    assert!(!mark_needs_send(&repeat));
    assert!(mark_needs_send(&MarkSend {
        last: Some(LastSend { marked: false, ago_ms: 2000.0 }),
        ..repeat
    }));
    assert!(mark_needs_send(&MarkSend { throttled: false, ..repeat }));
}

#[test]
fn entry_reads_blink_only_removed_panes_the_person_went_into() {
    let viewed = Tab { viewed: true, ..unread(1) };
    let facts = EntryFacts {
        removed: vec!["a".into(), "b".into(), "c".into()],
        flashes_on_focus: true,
        any_entry_reads: true,
        policy: FOCUS_READS,
        panes: vec![
            EntryPane { pane: "a".into(), tabs: vec![Tab { entry_read: true, ..Tab::default() }] },
            EntryPane { pane: "b".into(), tabs: vec![viewed.clone()] },
            EntryPane { pane: "c".into(), tabs: vec![unread(1)] },
            EntryPane { pane: "d".into(), tabs: vec![Tab { entry_read: true, ..Tab::default() }] },
        ],
    };
    assert_eq!(entered(&facts), vec!["a".to_string(), "b".to_string()]);
    let no_focus_flash = EntryFacts { flashes_on_focus: false, ..facts.clone() };
    assert_eq!(entered(&no_focus_flash), vec!["a".to_string()]);
    let nothing = EntryFacts { any_entry_reads: false, flashes_on_focus: false, ..facts };
    assert!(entered(&nothing).is_empty());
}
