//! Every defect class R-INPUT ends, as a scenario of the router (STATUS item
//! numbers of /Users/lawrence/fun/wt/handoff/cmux-lead-status-3.md; DESIGN.md
//! section 1).

use super::support::{
    SCENARIO_LANE_LIMIT, Session, arc, browser_tab, chord, content, conversation_tab, key, pane,
    terminal, terminal_tab, topology,
};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::{
    Binding, ConsumeReason, DropReason, FieldKind, GoneReason, InputEffect, InputEvent, KeyPhase,
    Modifiers, Sink, Tier, Via, WaitReason,
};
use cmux_focus_core::state::{ExpectationKey, Target};
use cmux_focus_core::topology::Pane;

const A: u16 = 0;
const B: u16 = 11;
const C: u16 = 8;
const D: u16 = 2;
const E: u16 = 14;
const RETURN: u16 = 36;

fn selecting(id: &str, tabs: Vec<cmux_focus_core::topology::Tab>, selected: &str) -> Pane {
    Pane { id: id.into(), tabs, selected: Some(selected.into()) }
}

fn field(window: &str, field: FieldKind) -> Sink {
    Sink::Field { window: arc(window), field }
}

/// P0 1193 (items 1193, 1207, 1245): Cmd-D, a line, Cmd-D, a line. Both lines
/// ran in the first new terminal. Each key goes to the terminal the focus
/// named when it was typed, whatever view AppKit's dispatch still reaches.
#[test]
fn p0_1193_cmd_d_twice_each_line_reaches_its_own_terminal() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    let split = s.press(chord("w1", D, "newSplit", Tier::Navigation, Some(terminal("T1"))));
    assert_eq!(
        s.last(split),
        Some(&InputEffect::Run { id: split, action: arc("newSplit"), tab: Some(arc("t1")) })
    );
    // The first split's stand-in shows in the key's turn and takes the focus.
    s.create("w1", "s1", terminal("T2"));
    let two = vec![
        pane("p1", vec![terminal_tab("t1", "T1")]),
        pane("p2", vec![terminal_tab("s1", "T2")]),
    ];
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", two.clone()) });
    let a = s.press(key("w1", A, Some(terminal("T1"))));
    let b = s.press(key("w1", B, Some(terminal("T1"))));
    // The second split splits the new terminal, and its stand-in shows a
    // frame later than its keys.
    let second = s.press(chord("w1", D, "newSplit", Tier::Navigation, Some(terminal("T1"))));
    assert_eq!(
        s.last(second),
        Some(&InputEffect::Run { id: second, action: arc("newSplit"), tab: Some(arc("s1")) })
    );
    s.create("w1", "s2", terminal("T3"));
    let c = s.press(key("w1", C, Some(terminal("T1"))));
    let d = s.press(key("w1", E, Some(terminal("T1"))));
    let mut three = two;
    three.push(pane("p3", vec![terminal_tab("s2", "T3")]));
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", three) });
    assert_eq!(s.took(&terminal("T2")), vec![a, b]);
    assert_eq!(s.took(&terminal("T3")), vec![c, d]);
    assert!(s.took(&terminal("T1")).is_empty());
    assert_eq!(s.router.aim("w1"), Some(terminal("T3")));
}

/// Items 2448, 2569: a held Ctrl-C passed the text typed before it. With an
/// input method's source on, text waits for the terminal's view and the chord
/// keeps its place behind it.
#[test]
fn p0_1193_a_control_chord_keeps_its_place_behind_waiting_text() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.send(InputEvent::InputSource { composes: true });
    let a = s.press(key("w1", A, None));
    let b = s.press(key("w1", B, None));
    let ctrl_c = s.press(cmux_focus_core::input::KeyRecord {
        modifiers: Modifiers { control: true, ..Modifiers::default() },
        ..key("w1", C, None)
    });
    let enter = s.press(key("w1", RETURN, None));
    assert!(s.took(&terminal("T1")).is_empty());
    assert!(matches!(
        s.last(ctrl_c),
        Some(InputEffect::Queued { reason: WaitReason::BehindQueued, .. })
    ));
    s.reaches(Some(terminal("T1")));
    assert_eq!(s.took(&terminal("T1")), vec![a, b, ctrl_c, enter]);
}

/// REOPEN-F4/F5 (items 4618, 4653, 4658): after a reopen AppKit chose the
/// sidebar as first key view and the first line went to it. The keys go to
/// the restored terminal the focus names.
#[test]
fn reopen_f4_first_keys_reach_the_restored_terminal_not_the_sidebar() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    let sidebar = field("w1", FieldKind::Sidebar);
    s.reaches(Some(sidebar.clone()));
    let keys: Vec<_> =
        [E, C, A, B].iter().map(|code| s.press(key("w1", *code, Some(sidebar.clone())))).collect();
    assert_eq!(s.took(&terminal("T1")), keys);
    assert!(s.took(&sidebar).is_empty());
    assert!(
        keys.iter()
            .all(|id| matches!(s.last(*id), Some(InputEffect::Deliver { via: Via::Direct, .. })))
    );
}

/// #32633 (items 7629, 8061, 8918): keys typed right after a reopen were lost
/// or waited 2 s for a restored page. They wait for the page's first paint
/// and reach it then, in order, with no timer.
#[test]
fn reopen_browser_keys_wait_for_the_first_paint_then_reach_the_page() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    let keys: Vec<_> =
        [A, B, C].iter().map(|code| s.press(key("w1", *code, Some(content("b1"))))).collect();
    assert!(s.took(&content("b1")).is_empty());
    assert!(matches!(
        s.last(keys[0]),
        Some(InputEffect::Queued { reason: WaitReason::NotReady, .. })
    ));
    s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(s.took(&content("b1")), keys);
}

/// #33198 and item 8505: keys typed before the page could take them followed
/// a click into the address bar ("abcxyz"), or were lost by a flush. Each key
/// keeps the target it was typed for.
#[test]
fn a_click_before_the_first_paint_keeps_the_page_keys_for_the_page() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    let page_keys: Vec<_> =
        [A, B, C].iter().map(|code| s.press(key("w1", *code, Some(content("b1"))))).collect();
    s.focus("w1", FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Mouse });
    let bar = field("w1", FieldKind::AddressBar { tab: arc("b1") });
    s.reaches(Some(bar.clone()));
    let bar_keys: Vec<_> =
        [D, E].iter().map(|code| s.press(key("w1", *code, Some(bar.clone())))).collect();
    s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(s.took(&bar), bar_keys);
    assert_eq!(s.took(&content("b1")), page_keys);
}

/// Close-then-type (items 1333, 1353): the first key after Cmd-W went into
/// the closing terminal. Keys typed after the close go to the successor the
/// person sees.
#[test]
fn close_then_type_keys_go_to_the_successor_never_the_closing_terminal() {
    let mut s = Session::new();
    let both = vec![
        pane("p1", vec![terminal_tab("t1", "T1")]),
        pane("p2", vec![terminal_tab("t2", "T2")]),
    ];
    s.open("w1", topology("ws", both), "p2");
    s.reaches(Some(terminal("T2")));
    s.press(chord("w1", 13, "closeTab", Tier::System, Some(terminal("T2"))));
    s.focus(
        "w1",
        FocusEvent::Topology {
            topology: topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]),
        },
    );
    let l = s.press(key("w1", A, Some(terminal("T2"))));
    let after = s.press(key("w1", B, Some(terminal("T2"))));
    s.send(InputEvent::Gone { sink: terminal("T2"), reason: GoneReason::Closed });
    assert!(s.took(&terminal("T2")).is_empty());
    assert_eq!(s.took(&terminal("T1")), vec![l, after]);
}

/// Items 2073, 5796 ("#29409 again"): a second quick Cmd-W flushed the held
/// keys into the closing terminal or its neighbor.
#[test]
fn a_second_cmd_w_never_types_into_a_closing_terminal() {
    let mut s = Session::new();
    let tabs = |n: usize| -> Vec<Pane> {
        (1..=n)
            .map(|i| pane(&format!("p{i}"), vec![terminal_tab(&format!("t{i}"), &format!("T{i}"))]))
            .collect()
    };
    s.open("w1", topology("ws", tabs(3)), "p3");
    s.press(chord("w1", 13, "closeTab", Tier::System, Some(terminal("T3"))));
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", tabs(2)) });
    let a = s.press(key("w1", A, Some(terminal("T3"))));
    s.press(chord("w1", 13, "closeTab", Tier::System, Some(terminal("T3"))));
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", tabs(1)) });
    let b = s.press(key("w1", B, Some(terminal("T3"))));
    s.send(InputEvent::Gone { sink: terminal("T3"), reason: GoneReason::Closed });
    s.send(InputEvent::Gone { sink: terminal("T2"), reason: GoneReason::Closed });
    assert!(s.took(&terminal("T3")).is_empty());
    assert_eq!(s.took(&terminal("T2")), vec![a]);
    assert_eq!(s.took(&terminal("T1")), vec![b]);
}

/// A terminal that ended before its tab left the window (its process exited):
/// a key aimed at it is dropped with the reason, never typed somewhere else.
#[test]
fn a_key_for_a_terminal_that_ended_is_dropped_not_redirected() {
    let mut s = Session::new();
    let both = vec![
        pane("p1", vec![terminal_tab("t1", "T1")]),
        pane("p2", vec![terminal_tab("t2", "T2")]),
    ];
    s.open("w1", topology("ws", both), "p2");
    s.send(InputEvent::Gone { sink: terminal("T2"), reason: GoneReason::Closed });
    let k = s.press(key("w1", A, Some(terminal("T2"))));
    assert_eq!(
        s.last(k),
        Some(&InputEffect::Dropped { id: k, reason: DropReason::SinkGone(GoneReason::Closed) })
    );
    assert!(s.took(&terminal("T1")).is_empty());
}

/// INVERSE-KEY (items 7928, 8145): after Ctrl-` from a Chromium page, the
/// page window stayed key and the typed line went to the page.
#[test]
fn inverse_key_a_new_terminal_from_a_page_takes_the_keys() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.reaches(Some(content("b1")));
    s.press(cmux_focus_core::input::KeyRecord {
        modifiers: Modifiers { control: true, ..Modifiers::default() },
        ..chord("w1", 50, "newTerminalTab", Tier::Navigation, Some(content("b1")))
    });
    s.create("w1", "s9", terminal("T9"));
    let l = s.press(key("w1", A, Some(content("b1"))));
    let ls = s.press(key("w1", B, Some(content("b1"))));
    let shown =
        vec![pane("p1", vec![browser_tab("b1")]), pane("p2", vec![terminal_tab("s9", "T9")])];
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", shown) });
    s.reaches(Some(terminal("T9")));
    let x = s.press(key("w1", C, Some(terminal("T9"))));
    assert!(s.took(&content("b1")).is_empty());
    assert_eq!(s.took(&terminal("T9")), vec![l, ls, x]);
    assert!(matches!(s.last(x), Some(InputEffect::Deliver { via: Via::Responder, .. })));
}

/// A creation that fails takes the keys typed for it with it (each with the
/// reason); a key typed after the failure goes to what the focus shows.
#[test]
fn a_failed_creation_drops_its_keys_and_later_keys_go_to_the_focused_terminal() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    s.press(chord("w1", 17, "newTab", Tier::Navigation, Some(terminal("T1"))));
    s.create("w1", "n1", content("n1"));
    let g = s.press(key("w1", A, Some(terminal("T1"))));
    let h = s.press(key("w1", B, Some(terminal("T1"))));
    s.send(InputEvent::CreationFailed { key: ExpectationKey::Tab { id: "n1".into() } });
    let i = s.press(key("w1", C, Some(terminal("T1"))));
    let failed = DropReason::SinkGone(GoneReason::CreationFailed);
    assert_eq!(s.last(g), Some(&InputEffect::Dropped { id: g, reason: failed }));
    assert_eq!(s.last(h), Some(&InputEffect::Dropped { id: h, reason: failed }));
    assert_eq!(s.took(&terminal("T1")), vec![i]);
}

/// Lawrence 2026-10-23 ("i type in one window of cmux, but the text appears in
/// another window"), item 5119: the key window changed between the press and
/// its dispatch. The key goes to the window it was typed into.
#[test]
fn a_key_typed_in_one_window_never_reaches_another() {
    let mut s = Session::new();
    s.open("w1", topology("ws1", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.open("w2", topology("ws2", vec![pane("q1", vec![terminal_tab("t2", "T2")])]), "q1");
    s.reaches(Some(terminal("T2")));
    let k = s.press(key("w1", A, Some(terminal("T2"))));
    assert_eq!(s.took(&terminal("T1")), vec![k]);
    assert!(s.took(&terminal("T2")).is_empty());
}

/// Dogfood v2.2.3 (items 59, 68, 5133): a line typed for a new terminal asked
/// for over Home went into the Chief's message box, and Return sent it.
#[test]
fn a_new_workspace_terminal_takes_its_keys_never_home() {
    let mut s = Session::new();
    s.open("w1", topology("home", vec![pane("h1", vec![conversation_tab("c1")])]), "h1");
    s.send(InputEvent::Ready { sink: content("c1") });
    s.reaches(Some(content("c1")));
    s.press(chord("w1", 45, "newWorkspace", Tier::Navigation, Some(content("c1"))));
    s.create("w1", "s5", terminal("T5"));
    let keys: Vec<_> =
        [A, B, RETURN].iter().map(|code| s.press(key("w1", *code, Some(content("c1"))))).collect();
    s.focus(
        "w1",
        FocusEvent::Topology {
            topology: topology("ws5", vec![pane("x1", vec![terminal_tab("s5", "T5")])]),
        },
    );
    assert!(s.took(&content("c1")).is_empty());
    assert_eq!(s.took(&terminal("T5")), keys);
    assert_eq!(s.router.aim("w1"), Some(terminal("T5")));
}

/// A Paste typed after keys that wait keeps its place behind them (the New
/// Tab hold's rule "a chord never runs before keys typed ahead of it").
#[test]
fn a_paste_runs_after_the_keys_typed_before_it() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    let a = s.press(key("w1", A, Some(content("b1"))));
    let b = s.press(key("w1", B, Some(content("b1"))));
    let paste = s.press(cmux_focus_core::input::KeyRecord {
        modifiers: Modifiers { command: true, ..Modifiers::default() },
        binding: Some(Binding {
            action: arc("paste"),
            tier: Tier::Content,
            ghostty: false,
            edits_input: true,
        }),
        ..key("w1", 9, Some(content("b1")))
    });
    assert!(matches!(s.last(paste), Some(InputEffect::Queued { .. })));
    let effects = s.send(InputEvent::Ready { sink: content("b1") });
    let order: Vec<_> = effects.iter().filter_map(InputEffect::id).collect();
    assert_eq!(order, vec![a, b, paste]);
    assert!(matches!(effects.last(), Some(InputEffect::Run { .. })));
}

/// #32537 review: key-ups reached a page before their key-downs. A release
/// follows its press; the release of a press that ran its binding is consumed.
#[test]
fn a_release_follows_its_press() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    let down = s.press(key("w1", A, Some(content("b1"))));
    let up = s.press(cmux_focus_core::input::KeyRecord {
        phase: KeyPhase::Up,
        ..key("w1", A, Some(content("b1")))
    });
    assert!(matches!(
        s.last(up),
        Some(InputEffect::Queued { reason: WaitReason::BehindQueued, .. })
    ));
    s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(s.took(&content("b1")), vec![down, up]);
    let run = s.press(chord("w1", D, "newSplit", Tier::Navigation, Some(content("b1"))));
    let run_up = s.press(cmux_focus_core::input::KeyRecord {
        phase: KeyPhase::Up,
        ..chord("w1", D, "newSplit", Tier::Navigation, Some(content("b1")))
    });
    assert!(matches!(s.last(run), Some(InputEffect::Run { .. })));
    assert_eq!(
        s.last(run_up),
        Some(&InputEffect::Consumed { id: run_up, reason: ConsumeReason::FollowsConsumedPress })
    );
}

/// A repeat goes where its press went, even when the focus moved since.
#[test]
fn a_repeat_goes_where_its_press_went() {
    let mut s = Session::new();
    let both = vec![
        pane("p1", vec![terminal_tab("t1", "T1")]),
        pane("p2", vec![terminal_tab("t2", "T2")]),
    ];
    s.open("w1", topology("ws", both), "p1");
    let down = s.press(key("w1", A, None));
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p2".into(), workspace: None, source: Source::Mouse },
    );
    let repeat = s
        .press(cmux_focus_core::input::KeyRecord { phase: KeyPhase::Repeat, ..key("w1", A, None) });
    assert_eq!(s.took(&terminal("T1")), vec![down, repeat]);
}

/// I8: a lane is bounded; a key past the bound is refused at key time.
#[test]
fn a_full_lane_refuses_the_next_key_at_key_time() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    for _ in 0..SCENARIO_LANE_LIMIT {
        s.press(key("w1", A, None));
    }
    let over = s.press(key("w1", A, None));
    assert_eq!(
        s.last(over),
        Some(&InputEffect::Dropped { id: over, reason: DropReason::LaneFull })
    );
    let effects = s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(effects.len(), SCENARIO_LANE_LIMIT);
}

/// A field's keys wait for the field to take the keyboard; its window
/// closing drops them with the reason.
#[test]
fn a_window_close_drops_its_field_keys_with_the_reason() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.focus(
        "w1",
        FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Keyboard },
    );
    let u = s.press(key("w1", A, Some(content("b1"))));
    assert!(matches!(
        s.last(u),
        Some(InputEffect::Queued { reason: WaitReason::AwaitsResponder, .. })
    ));
    s.send(InputEvent::WindowClosed { window: arc("w1") });
    assert_eq!(s.last(u), Some(&InputEffect::Dropped { id: u, reason: DropReason::WindowClosed }));
}

/// A field the focus left before it took the keyboard: its keys can never
/// reach it, and are dropped with the reason (never given to the next target).
#[test]
fn keys_for_a_field_the_focus_left_are_dropped_not_redirected() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.focus(
        "w1",
        FocusEvent::FocusTarget { target: Target::SidebarField {}, source: Source::Mouse },
    );
    let q = s.press(key("w1", A, None));
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    assert_eq!(s.last(q), Some(&InputEffect::Dropped { id: q, reason: DropReason::TargetLeft }));
    assert!(s.took(&terminal("T1")).is_empty());
}

/// Browser focus mode keeps only its exit and Quit from the page.
#[test]
fn browser_focus_mode_gives_the_page_every_system_key_but_its_exit_and_quit() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.focus("w1", FocusEvent::ToggleBrowserFocusMode { tab: None });
    s.reaches(Some(content("b1")));
    let close = s.press(chord("w1", 13, "closeTab", Tier::System, Some(content("b1"))));
    let quit = s.press(chord("w1", 12, "quit", Tier::System, Some(content("b1"))));
    assert_eq!(s.took(&content("b1")), vec![close]);
    assert!(matches!(s.last(quit), Some(InputEffect::Run { .. })));
}

/// A focused terminal runs its own Ghostty keybinds; in copy mode the routed
/// action runs.
#[test]
fn a_ghostty_keybind_goes_to_the_focused_terminal_unless_it_is_in_copy_mode() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    let ghostty = |copy_mode| cmux_focus_core::input::KeyRecord {
        modifiers: Modifiers { command: true, control: true, ..Modifiers::default() },
        terminal_copy_mode: copy_mode,
        binding: Some(Binding {
            action: arc("goToSplit"),
            tier: Tier::Navigation,
            ghostty: true,
            edits_input: false,
        }),
        ..key("w1", 4, Some(terminal("T1")))
    };
    let own = s.press(ghostty(false));
    let routed = s.press(ghostty(true));
    assert_eq!(s.took(&terminal("T1")), vec![own]);
    assert!(matches!(s.last(routed), Some(InputEffect::Run { .. })));
}

/// An input method composing gets its keys where it composes.
#[test]
fn an_input_method_gets_the_keys_it_composes() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    let composing =
        |reaches| cmux_focus_core::input::KeyRecord { composing: true, ..key("w1", A, reaches) };
    let k = s.press(composing(Some(terminal("T1"))));
    assert!(matches!(s.last(k), Some(InputEffect::Deliver { via: Via::Responder, .. })));
    let other = s.press(composing(None));
    assert_eq!(s.last(other), Some(&InputEffect::Platform { id: other }));
}

/// The daemon's tab that replaces a creation's stand-in is the same terminal:
/// keys before and after the swap reach one sink.
#[test]
fn the_daemon_tab_that_replaces_a_stand_in_is_the_same_terminal() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.create("w1", "s1", terminal("T2"));
    let stand_in = selecting("p1", vec![terminal_tab("t1", "T1"), terminal_tab("s1", "T2")], "s1");
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", vec![stand_in]) });
    let a = s.press(key("w1", A, None));
    let daemon = selecting("p1", vec![terminal_tab("t1", "T1"), terminal_tab("d1", "T2")], "d1");
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", vec![daemon]) });
    let b = s.press(key("w1", B, None));
    assert_eq!(s.took(&terminal("T2")), vec![a, b]);
}

/// The palette panel's keys are its own; a key typed into another app window
/// is AppKit's.
#[test]
fn overlay_and_other_windows_keep_their_own_keys() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    for role in
        [cmux_focus_core::input::WindowRole::Overlay, cmux_focus_core::input::WindowRole::Other]
    {
        let k = s.press(cmux_focus_core::input::KeyRecord { role, ..key("w1", A, None) });
        assert_eq!(s.last(k), Some(&InputEffect::Platform { id: k }));
    }
}
