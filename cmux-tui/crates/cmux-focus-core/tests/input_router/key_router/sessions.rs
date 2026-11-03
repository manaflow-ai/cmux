//! Stage S1b's scenarios: key sessions (link hints started by the person,
//! window hints, the shortcut recorder), blocking dialogs, page-first chords
//! and the Escape return rule (STATUS item numbers of
//! /Users/lawrence/fun/wt/handoff/cmux-lead-status-3.md).

use super::support::{
    Session, arc, browser_tab, chord, content, key, pane, terminal, terminal_tab, topology,
};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::{
    ConsumeReason, DialogScope, DropReason, FieldKind, GoneReason, InputEffect, InputEvent,
    InputId, KeyRecord, Modifiers, SessionEnd, SessionKey, SessionKind, Sink, Tier, Via,
    WaitReason,
};
use cmux_focus_core::state::{Resolved, Target};
use cmux_focus_core::topology::Pane;

const A: u16 = 0;
const B: u16 = 11;
const D: u16 = 2;
const F: u16 = 3;
const RETURN: u16 = 36;
const ESCAPE: u16 = 53;

/// A window w1 with a terminal pane p1 (T1) and a browser pane p2 (b1, ready),
/// the keyboard on the page.
fn page_window() -> Session {
    let mut s = Session::new();
    let panes =
        vec![pane("p1", vec![terminal_tab("t1", "T1")]), pane("p2", vec![browser_tab("b1")])];
    s.open("w1", topology("ws", panes), "p2");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.reaches(Some(content("b1")));
    s
}

fn hints(tab: &str) -> InputEvent {
    InputEvent::SessionStarted { kind: SessionKind::LinkHints { tab: arc(tab) }, window: arc("w1") }
}

fn ends(s: &Session) -> Vec<SessionEnd> {
    s.effects
        .iter()
        .filter_map(|effect| match effect {
            InputEffect::SessionEnded { reason, .. } => Some(*reason),
            _ => None,
        })
        .collect()
}

fn escape(reaches: Option<Sink>) -> KeyRecord {
    key("w1", ESCAPE, reaches)
}

/// #32537 (items 7543, 8170): the page never sees the hint letters. With a
/// session the person started, every letter is a hint letter; Escape ends it,
/// and the next letter is the page's again.
#[test]
fn link_hints_take_their_letters_and_no_letter_reaches_the_page() {
    let mut s = page_window();
    s.send(hints("b1"));
    let f = s.press(key("w1", F, Some(content("b1"))));
    let d = s.press(key("w1", D, Some(content("b1"))));
    let shifted = s.press(KeyRecord {
        modifiers: Modifiers { shift: true, ..Modifiers::default() },
        ..key("w1", A, Some(content("b1")))
    });
    assert_eq!(
        s.last(f),
        Some(&InputEffect::SessionKey {
            id: f,
            key: SessionKey::Letter { letter: 'f', shift: false }
        })
    );
    assert_eq!(
        s.last(d),
        Some(&InputEffect::SessionKey {
            id: d,
            key: SessionKey::Letter { letter: 'd', shift: false }
        })
    );
    assert_eq!(
        s.last(shifted),
        Some(&InputEffect::SessionKey {
            id: shifted,
            key: SessionKey::Letter { letter: 'a', shift: true }
        })
    );
    let esc = s.press(escape(Some(content("b1"))));
    assert_eq!(s.last(esc), Some(&InputEffect::SessionKey { id: esc, key: SessionKey::Escape }));
    assert_eq!(ends(&s), vec![SessionEnd::Escape]);
    let after = s.press(key("w1", B, Some(content("b1"))));
    assert_eq!(s.took(&content("b1")), vec![after]);
}

/// #32537 review rounds 1 and 3 (items 7898, 8478): a click while hints show
/// ended the session but the letters typed meanwhile went to the page, or
/// were lost. A session's keys are the session's at key time: the click ends
/// it, and the keys after the click go where the person clicked.
#[test]
fn a_click_ends_link_hints_and_the_keys_after_it_reach_the_clicked_pane() {
    let mut s = page_window();
    s.send(hints("b1"));
    let hint = s.press(key("w1", A, Some(content("b1"))));
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    assert_eq!(ends(&s), vec![SessionEnd::FocusLeft]);
    let typed = s.press(key("w1", B, Some(content("b1"))));
    assert!(matches!(s.last(hint), Some(InputEffect::SessionKey { .. })));
    assert_eq!(s.took(&terminal("T1")), vec![typed]);
    assert!(s.took(&content("b1")).is_empty());
}

/// A key that is no hint key (Return) ends the session and reaches the page,
/// in the same call: none is held, none is lost.
#[test]
fn a_key_that_is_no_hint_key_ends_link_hints_and_routes_as_usual() {
    let mut s = page_window();
    s.send(hints("b1"));
    let enter = s.press(key("w1", RETURN, Some(content("b1"))));
    assert_eq!(ends(&s), vec![SessionEnd::OtherKey]);
    assert_eq!(s.took(&content("b1")), vec![enter]);
}

/// #32537 round 5 (item 8692): a chord bound to link hints, typed while hints
/// showed, started a session that the old session's end then cancelled. The
/// chord ends the running session once, runs its action, and the action's
/// new session is the only one (I5, checked by the ledger after every call).
#[test]
fn a_hint_chord_inside_a_session_ends_it_once_and_its_new_session_runs() {
    let mut s = page_window();
    s.send(hints("b1"));
    let again = s.press(KeyRecord {
        modifiers: Modifiers { command: true, shift: true, ..Modifiers::default() },
        ..chord("w1", F, "linkHints.show", Tier::Navigation, Some(content("b1")))
    });
    assert!(matches!(s.last(again), Some(InputEffect::Run { .. })));
    s.send(hints("b1"));
    assert_eq!(ends(&s), vec![SessionEnd::OtherKey]);
    let letter = s.press(key("w1", D, Some(content("b1"))));
    assert!(matches!(s.last(letter), Some(InputEffect::SessionKey { .. })));
}

/// A newer session replaces a running one: the old one ends first.
#[test]
fn a_newer_session_replaces_the_running_one() {
    let mut s = page_window();
    s.send(hints("b1"));
    s.send(InputEvent::SessionStarted { kind: SessionKind::WindowHints, window: arc("w1") });
    assert_eq!(ends(&s), vec![SessionEnd::Replaced]);
}

/// A key of another window ends the session; that key goes on to its window.
#[test]
fn a_key_of_another_window_ends_the_session() {
    let mut s = page_window();
    s.open("w2", topology("ws2", vec![pane("q1", vec![terminal_tab("t2", "T2")])]), "q1");
    s.send(hints("b1"));
    let other = s.press(key("w2", A, Some(terminal("T2"))));
    assert_eq!(ends(&s), vec![SessionEnd::OtherWindow]);
    assert_eq!(s.took(&terminal("T2")), vec![other]);
}

/// Link hints start only on the page the window's keys go to: asked for a page
/// that is not focused, the session ends at once and keys go on as usual.
#[test]
fn link_hints_for_a_page_without_the_keys_never_start() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    s.send(hints("b1"));
    assert_eq!(ends(&s), vec![SessionEnd::FocusLeft]);
    let typed = s.press(key("w1", A, Some(terminal("T1"))));
    assert_eq!(s.took(&terminal("T1")), vec![typed]);
}

/// The Keyboard Shortcuts recorder takes every key of its window, a bound
/// close chord too, until the platform ends it.
#[test]
fn the_recorder_takes_every_key_until_it_ends() {
    let mut s = page_window();
    s.send(InputEvent::SessionStarted { kind: SessionKind::Recorder, window: arc("w1") });
    let close = s.press(chord("w1", 13, "closeTab", Tier::System, Some(content("b1"))));
    assert_eq!(s.last(close), Some(&InputEffect::SessionKey { id: close, key: SessionKey::Any }));
    s.send(InputEvent::SessionEnded);
    assert_eq!(ends(&s), vec![SessionEnd::Finished]);
    let close = s.press(chord("w1", 13, "closeTab", Tier::System, Some(content("b1"))));
    assert!(matches!(s.last(close), Some(InputEffect::Run { .. })));
}

/// #31849 (items 5123, 5200): a Return and typed text under a cmux dialog
/// reached the terminal the dialog blocks. Every key that runs no binding is
/// the dialog's; a bound chord still runs (Cmd-W closes the tab and its dialog).
#[test]
fn keys_typed_under_a_dialog_go_to_the_dialog_never_the_terminal() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    s.reaches(Some(terminal("T1")));
    let scope = DialogScope::Tab { window: arc("w1"), tab: arc("t1") };
    s.send(InputEvent::DialogShown { id: 7, scope });
    let enter = s.press(key("w1", RETURN, Some(terminal("T1"))));
    let text = s.press(key("w1", A, Some(terminal("T1"))));
    let esc = s.press(escape(Some(terminal("T1"))));
    assert_eq!(s.took(&Sink::Dialog(7)), vec![enter, text, esc]);
    assert!(matches!(s.last(enter), Some(InputEffect::Deliver { via: Via::Direct, .. })));
    let close = s.press(chord("w1", 13, "closeTab", Tier::System, Some(terminal("T1"))));
    assert!(matches!(s.last(close), Some(InputEffect::Run { .. })));
    s.send(InputEvent::DialogDismissed { id: 7 });
    let after = s.press(key("w1", B, Some(terminal("T1"))));
    assert_eq!(s.took(&terminal("T1")), vec![after]);
}

/// #32291 and #32409 (items 6627, 6673, 6919): keys held before a close
/// question went to the question (a Return would press Close), or came out of
/// order. Keys typed before a dialog keep their target: they wait while the
/// dialog blocks it and go on, in order, after the answer.
#[test]
fn keys_typed_before_a_dialog_wait_for_its_answer_and_keep_their_order() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p2", vec![browser_tab("b1")])]), "p2");
    s.reaches(Some(content("b1")));
    let a = s.press(key("w1", A, Some(content("b1"))));
    let b = s.press(key("w1", B, Some(content("b1"))));
    s.send(InputEvent::DialogShown {
        id: 3,
        scope: DialogScope::Tab { window: arc("w1"), tab: arc("b1") },
    });
    s.send(InputEvent::Ready { sink: content("b1") });
    assert!(s.took(&content("b1")).is_empty());
    let at_question = s.press(key("w1", RETURN, Some(content("b1"))));
    assert_eq!(s.took(&Sink::Dialog(3)), vec![at_question]);
    let blocked = s.router.waiting().any(|(sink, n)| *sink == content("b1") && n == 2);
    assert!(blocked, "the page's two keys wait while the dialog blocks it");
    s.send(InputEvent::DialogDismissed { id: 3 });
    assert_eq!(s.took(&content("b1")), vec![a, b]);
}

/// The answer closed the tab: the keys it kept are dropped with the reason,
/// never given to another tab or to the dialog.
#[test]
fn a_dialog_answer_that_closes_the_tab_drops_the_keys_it_kept() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p2", vec![browser_tab("b1")])]), "p2");
    let kept = s.press(key("w1", A, None));
    s.send(InputEvent::DialogShown { id: 4, scope: DialogScope::Window(arc("w1")) });
    s.send(InputEvent::Gone { sink: content("b1"), reason: GoneReason::Closed });
    s.send(InputEvent::DialogDismissed { id: 4 });
    let closed = DropReason::SinkGone(GoneReason::Closed);
    assert_eq!(s.last(kept), Some(&InputEffect::Dropped { id: kept, reason: closed }));
}

/// #31849's review (item 5274): a parked tab's dialog blocked the shown tab's
/// keys. A tab's dialog blocks only that tab.
#[test]
fn a_dialog_of_a_tab_that_does_not_show_blocks_nothing_else() {
    let mut s = Session::new();
    let tabs = vec![terminal_tab("t1", "T1"), terminal_tab("t9", "T9")];
    s.open(
        "w1",
        topology("ws", vec![Pane { id: "p1".into(), tabs, selected: Some("t1".into()) }]),
        "p1",
    );
    s.send(InputEvent::DialogShown {
        id: 5,
        scope: DialogScope::Tab { window: arc("w1"), tab: arc("t9") },
    });
    let typed = s.press(key("w1", A, Some(terminal("T1"))));
    assert_eq!(s.took(&terminal("T1")), vec![typed]);
}

/// With the keyboard in the window's chrome (the sidebar list), a dialog of
/// the focused pane's tab takes the window's keys.
#[test]
fn a_tab_dialog_takes_the_keys_typed_in_the_sidebar_list() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusTarget {
            target: Target::Sidebar { keyboard: false },
            source: Source::Mouse,
        },
    );
    let sidebar = Sink::Field { window: arc("w1"), field: FieldKind::Sidebar };
    s.reaches(Some(sidebar));
    s.send(InputEvent::DialogShown {
        id: 6,
        scope: DialogScope::Tab { window: arc("w1"), tab: arc("b1") },
    });
    let typed = s.press(key("w1", A, None));
    assert_eq!(s.took(&Sink::Dialog(6)), vec![typed]);
}

/// Item 8309: a page that handles Cmd-F keeps it; an unhandled Cmd-F runs cmux
/// Find, once, with the key's own id (item 8324: it was logged "unattributed").
#[test]
fn a_page_first_chord_runs_its_action_only_when_the_page_leaves_it_unhandled() {
    let mut s = page_window();
    let find = s.press(chord("w1", F, "find", Tier::Navigation, Some(content("b1"))));
    assert_eq!(
        s.last(find),
        Some(&InputEffect::Offer {
            id: find,
            sink: content("b1"),
            via: Via::Responder,
            action: arc("find")
        })
    );
    assert_eq!(s.took(&content("b1")), vec![find]);
    let ran = s.send(InputEvent::PageUnhandled { id: find });
    assert_eq!(ran, vec![InputEffect::Run { id: find, action: arc("find"), tab: Some(arc("b1")) }]);
    assert!(s.send(InputEvent::PageUnhandled { id: find }).is_empty(), "it runs once");
}

/// A page reports its unhandled keys in key order, so a report of a newer key
/// means the older offered keys were handled: their actions never run.
#[test]
fn a_report_of_a_newer_key_means_the_older_offers_were_handled() {
    let mut s = page_window();
    let bold = s.press(KeyRecord {
        page_editing_chord: true,
        ..chord("w1", B, "toggleSidebar", Tier::Navigation, Some(content("b1")))
    });
    let find = s.press(chord("w1", F, "find", Tier::Navigation, Some(content("b1"))));
    assert!(matches!(s.last(bold), Some(InputEffect::Offer { .. })));
    let ran = s.send(InputEvent::PageUnhandled { id: find });
    assert_eq!(ran, vec![InputEffect::Run { id: find, action: arc("find"), tab: Some(arc("b1")) }]);
    assert!(s.send(InputEvent::PageUnhandled { id: bold }).is_empty());
}

/// #32849: an action that opens a browser is never offered to a page, and a
/// page whose window does not have the keys gets no offer: the action runs now.
#[test]
fn page_first_offers_only_when_the_page_has_the_keys_and_may_own_the_action() {
    let mut s = page_window();
    let opens = s.press(KeyRecord {
        page_editing_chord: true,
        ..chord("w1", 37, "openBrowser", Tier::Navigation, Some(content("b1")))
    });
    assert!(matches!(s.last(opens), Some(InputEffect::Run { .. })));
    let shell = s.press(chord("w1", F, "find", Tier::Navigation, None));
    assert!(matches!(s.last(shell), Some(InputEffect::Run { .. })));
    let no_report = s.send(InputEvent::PageUnhandled { id: InputId(shell.0) });
    assert!(no_report.is_empty());
}

/// #33049 (items 8273, 8329): Escape in the right sidebar's field did not give
/// the keyboard back to the page. Escape in a field the person moved into from
/// content gives the keyboard back to that content.
#[test]
fn escape_in_a_field_gives_the_keyboard_back_to_the_page_it_came_from() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusTarget { target: Target::TextField {}, source: Source::Keyboard },
    );
    let field = Sink::Field { window: arc("w1"), field: FieldKind::TextField };
    s.reaches(Some(field));
    let esc = s.press(escape(None));
    assert_eq!(
        s.last(esc),
        Some(&InputEffect::Consumed { id: esc, reason: ConsumeReason::ReturnedFocus })
    );
    let focus = s.router.focus("w1").map(|f| f.derived.resolved.clone());
    assert!(matches!(focus, Some(Resolved::BrowserPage { .. })), "{focus:?}");
    let typed = s.press(key("w1", A, Some(content("b1"))));
    assert_eq!(s.took(&content("b1")), vec![typed]);
}

/// The field uses Escape itself (it clears its text, closes its list): the
/// field takes it, and the keyboard stays.
#[test]
fn escape_the_field_uses_stays_in_the_field() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusTarget { target: Target::SidebarField {}, source: Source::Keyboard },
    );
    let field = Sink::Field { window: arc("w1"), field: FieldKind::SidebarField };
    s.reaches(Some(field.clone()));
    let esc = s.press(KeyRecord { field_uses_escape: true, ..escape(Some(field.clone())) });
    assert_eq!(s.took(&field), vec![esc]);
}

/// Escape returns the keyboard only after the person's own move into the
/// field, never after the app put it there.
#[test]
fn escape_after_the_app_moved_the_keyboard_stays_in_the_field() {
    let mut s = page_window();
    s.focus(
        "w1",
        FocusEvent::FocusTarget { target: Target::TextField {}, source: Source::Programmatic },
    );
    let field = Sink::Field { window: arc("w1"), field: FieldKind::TextField };
    s.reaches(Some(field.clone()));
    let esc = s.press(escape(Some(field.clone())));
    assert_eq!(s.took(&field), vec![esc]);
}

/// A dialog's own keys wait for its view when an input method composes, and
/// go with it when it closes.
#[test]
fn keys_waiting_for_a_dialog_go_with_it() {
    let mut s = page_window();
    s.send(InputEvent::InputSource { composes: true });
    s.send(InputEvent::DialogShown { id: 9, scope: DialogScope::Window(arc("w1")) });
    let typed = s.press(key("w1", A, Some(content("b1"))));
    assert!(matches!(
        s.last(typed),
        Some(InputEffect::Queued { reason: WaitReason::AwaitsResponder, .. })
    ));
    s.send(InputEvent::DialogDismissed { id: 9 });
    let closed = DropReason::SinkGone(GoneReason::Closed);
    assert_eq!(s.last(typed), Some(&InputEffect::Dropped { id: typed, reason: closed }));
}
