//! Sink lifetimes and the details of a key's route that the first review of
//! the router found wrong (PR #34052 review, findings 1-3, 8, 10, 11), and the
//! fuzz failure of the S1b green step (fleet step 1803a1b30c2e, seed 39): a
//! sink that ended takes keys again only as a new sink, a creation's reply
//! comes after its stand-in showed, an input action waits for its sink like a
//! key, the binding rules read the key's own target, and a key that reached
//! nothing has no repeat or release anywhere.

use super::support::{
    Session, arc, browser_tab, chord, content, key, pane, terminal, terminal_tab, topology,
};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::{
    Binding, ConsumeReason, DialogScope, DropReason, FieldKind, GoneReason, InputEffect,
    InputEvent, KeyPhase, KeyRecord, Modifiers, Sink, Tier, Via, WaitReason,
};
use cmux_focus_core::state::{ExpectationKey, Overlay, Target};
use cmux_focus_core::topology::{Kind, Tab};

const A: u16 = 0;
const B: u16 = 11;
const C: u16 = 8;
const D: u16 = 2;
const V: u16 = 9;
const W: u16 = 13;
const BACKSPACE: u16 = 51;
const LEFT: u16 = 123;

/// Cmd-V bound to the Paste action, which edits the input it is aimed at.
fn paste(window: &str, reaches: Option<Sink>) -> KeyRecord {
    KeyRecord {
        binding: Some(Binding {
            action: arc("paste"),
            tier: Tier::Content,
            ghostty: false,
            edits_input: true,
        }),
        ..chord(window, V, "paste", Tier::Content, reaches)
    }
}

fn closed() -> DropReason {
    DropReason::SinkGone(GoneReason::Closed)
}

fn failed() -> DropReason {
    DropReason::SinkGone(GoneReason::CreationFailed)
}

/// Fuzz seed 39 of the S1b green step (InputId 47 went to Host("T2") after T2
/// ended): a terminal that ended takes no key while its tab still shows, and
/// takes keys again when a window shows it after none did (a closed window
/// opened again). The ledger checks that no key reaches the terminal while it
/// is ended, and accepts it again once the router says it came back.
#[test]
fn a_terminal_that_ended_takes_keys_again_only_when_a_window_shows_it_again() {
    let mut s = Session::new();
    let shows = || topology("ws2", vec![pane("q1", vec![terminal_tab("t2", "T2")])]);
    s.open("w2", shows(), "q1");
    s.reaches(Some(terminal("T2")));
    s.send(InputEvent::Gone { sink: terminal("T2"), reason: GoneReason::Closed });
    let while_shown = s.press(key("w2", A, Some(terminal("T2"))));
    assert_eq!(
        s.last(while_shown),
        Some(&InputEffect::Dropped { id: while_shown, reason: closed() })
    );
    s.send(InputEvent::WindowClosed { window: arc("w2") });
    s.open("w2", shows(), "q1");
    let again = s.press(key("w2", B, Some(terminal("T2"))));
    assert_eq!(s.took(&terminal("T2")), vec![again]);
}

/// Review finding 1: Reopen Closed brings a tab back under its old id. Its new
/// page takes keys after its own first paint; none of the old page's state
/// (its end, its readiness) holds for it.
#[test]
fn a_tab_reopened_with_its_old_id_takes_keys_after_its_new_first_paint() {
    let mut s = Session::new();
    let both = || {
        topology(
            "ws",
            vec![pane("p1", vec![terminal_tab("t1", "T1")]), pane("p2", vec![browser_tab("b1")])],
        )
    };
    s.open("w1", both(), "p2");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.reaches(Some(content("b1")));
    s.press(chord("w1", W, "closeTab", Tier::System, Some(content("b1"))));
    let without = topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]);
    s.focus("w1", FocusEvent::Topology { topology: without });
    s.send(InputEvent::Gone { sink: content("b1"), reason: GoneReason::Closed });
    s.focus("w1", FocusEvent::Topology { topology: both() });
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p2".into(), workspace: None, source: Source::Keyboard },
    );
    let early = s.press(key("w1", A, Some(content("b1"))));
    assert_eq!(
        s.last(early),
        Some(&InputEffect::Queued { id: early, sink: content("b1"), reason: WaitReason::NotReady })
    );
    s.send(InputEvent::Ready { sink: content("b1") });
    let late = s.press(key("w1", B, Some(content("b1"))));
    assert_eq!(s.took(&content("b1")), vec![early, late]);
}

/// Review finding 1, a close and a reopen in one turn: no topology showed the
/// tab gone. The reopen's creation names the tab again: it is a new sink.
#[test]
fn a_creation_that_names_an_ended_tab_again_makes_it_a_new_sink() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.send(InputEvent::Ready { sink: content("b1") });
    s.reaches(Some(content("b1")));
    s.send(InputEvent::Gone { sink: content("b1"), reason: GoneReason::Closed });
    let ended = s.press(key("w1", A, Some(content("b1"))));
    assert_eq!(s.last(ended), Some(&InputEffect::Dropped { id: ended, reason: closed() }));
    s.send(InputEvent::Creation {
        key: ExpectationKey::Tab { id: "b1".into() },
        sink: content("b1"),
    });
    let early = s.press(key("w1", B, Some(content("b1"))));
    s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(s.took(&content("b1")), vec![early]);
}

/// Review finding 2: a creation's reply comes after its stand-in showed (the
/// stand-in shows in the key's own turn). A failure then still ends the new
/// terminal: a key that waits for it and every key typed for it later are
/// dropped with the reason, never sent to a terminal that does not exist.
#[test]
fn a_creation_that_fails_after_its_stand_in_showed_ends_its_terminal() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    s.press(chord("w1", D, "newSplit", Tier::Navigation, Some(terminal("T1"))));
    s.create("w1", "s1", terminal("T2"));
    let two = vec![
        pane("p1", vec![terminal_tab("t1", "T1")]),
        pane("p2", vec![terminal_tab("s1", "T2")]),
    ];
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", two) });
    let before = s.press(key("w1", A, Some(terminal("T1"))));
    s.send(InputEvent::InputSource { composes: true });
    let waiting = s.press(key("w1", B, Some(terminal("T1"))));
    s.send(InputEvent::CreationFailed { key: ExpectationKey::Tab { id: "s1".into() } });
    let after = s.press(key("w1", C, Some(terminal("T1"))));
    assert_eq!(s.took(&terminal("T2")), vec![before]);
    assert_eq!(s.last(waiting), Some(&InputEffect::Dropped { id: waiting, reason: failed() }));
    assert_eq!(s.last(after), Some(&InputEffect::Dropped { id: after, reason: failed() }));
}

/// Review finding 3: a Paste typed before a page's first paint was run at once,
/// and Chromium dropped it (item 8061). An action that edits its sink's input
/// waits in that sink's lane like a key, and keeps its place.
#[test]
fn a_paste_before_the_first_paint_waits_for_it_and_keeps_its_place() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    let pasted = s.press(paste("w1", Some(content("b1"))));
    assert_eq!(
        s.last(pasted),
        Some(&InputEffect::Queued {
            id: pasted,
            sink: content("b1"),
            reason: WaitReason::NotReady
        })
    );
    let typed = s.press(key("w1", A, Some(content("b1"))));
    let painted = s.send(InputEvent::Ready { sink: content("b1") });
    assert_eq!(
        painted,
        vec![
            InputEffect::Run { id: pasted, action: arc("paste"), tab: Some(arc("b1")) },
            InputEffect::Deliver { id: typed, sink: content("b1"), via: Via::Responder },
        ]
    );
}

/// A Paste typed while a dialog blocks its target pastes into the dialog now:
/// it never waits behind the keys the target kept from before the dialog.
#[test]
fn a_paste_typed_under_a_dialog_runs_at_once() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![browser_tab("b1")])]), "p1");
    s.reaches(Some(content("b1")));
    s.press(key("w1", A, Some(content("b1"))));
    s.send(InputEvent::DialogShown {
        id: 2,
        scope: DialogScope::Tab { window: arc("w1"), tab: arc("b1") },
    });
    let pasted = s.press(paste("w1", Some(content("b1"))));
    assert_eq!(
        s.last(pasted),
        Some(&InputEffect::Run { id: pasted, action: arc("paste"), tab: Some(arc("b1")) })
    );
}

/// Review finding 8: the binding rules read the focus now while the key's
/// sink was the tab the focus is on its way to. A Ghostty keybind typed for a
/// new browser tab went to the old terminal's rule (to the view), so its
/// action never ran and the chord waited for the new page as a raw key.
#[test]
fn a_ghostty_keybind_typed_for_a_new_tab_runs_its_action() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    s.press(chord("w1", 17, "newTab", Tier::Navigation, Some(terminal("T1"))));
    s.create("w1", "n1", content("n1"));
    let keybind = s.press(KeyRecord {
        modifiers: Modifiers { command: true, option: true, ..Modifiers::default() },
        binding: Some(Binding {
            action: arc("goToSplit"),
            tier: Tier::Navigation,
            ghostty: true,
            edits_input: false,
        }),
        letter: None,
        ..key("w1", LEFT, Some(terminal("T1")))
    });
    assert_eq!(
        s.last(keybind),
        Some(&InputEffect::Run { id: keybind, action: arc("goToSplit"), tab: Some(arc("n1")) })
    );
}

/// Review finding 10 and its nit: a key-down that reached nothing (no target,
/// or dropped before its sink took it) has no repeat or release anywhere: a
/// sink never gets a repeat or a key-up with no key-down.
#[test]
fn the_repeats_and_release_of_a_key_that_reached_nothing_reach_nothing() {
    let mut s = Session::new();
    let panes = vec![pane("p0", Vec::new()), pane("p1", vec![terminal_tab("t1", "T1")])];
    s.open("w1", topology("ws", panes), "p0");
    let down = s.press(key("w1", A, Some(terminal("T1"))));
    assert_eq!(
        s.last(down),
        Some(&InputEffect::Consumed { id: down, reason: ConsumeReason::NoTarget })
    );
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    let repeat =
        s.press(KeyRecord { phase: KeyPhase::Repeat, ..key("w1", A, Some(terminal("T1"))) });
    let up = s.press(KeyRecord { phase: KeyPhase::Up, ..key("w1", A, Some(terminal("T1"))) });
    assert!(s.took(&terminal("T1")).is_empty());
    let follows = ConsumeReason::FollowsConsumedPress;
    assert_eq!(s.last(repeat), Some(&InputEffect::Consumed { id: repeat, reason: follows }));
    assert_eq!(s.last(up), Some(&InputEffect::Consumed { id: up, reason: follows }));

    // A field's key-down dropped because the person clicked away before the
    // field took the keyboard: its release does not reach the field.
    s.focus("w1", FocusEvent::FocusTarget { target: Target::TextField {}, source: Source::Mouse });
    let field = Sink::Field { window: arc("w1"), field: FieldKind::TextField };
    let field_down = s.press(key("w1", B, Some(terminal("T1"))));
    assert!(matches!(
        s.last(field_down),
        Some(InputEffect::Queued { reason: WaitReason::AwaitsResponder, .. })
    ));
    s.focus(
        "w1",
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Mouse },
    );
    assert_eq!(
        s.last(field_down),
        Some(&InputEffect::Dropped { id: field_down, reason: DropReason::TargetLeft })
    );
    let field_up = s.press(KeyRecord { phase: KeyPhase::Up, ..key("w1", B, Some(field.clone())) });
    assert!(s.took(&field).is_empty());
    assert_eq!(s.last(field_up), Some(&InputEffect::Consumed { id: field_up, reason: follows }));
}

/// Review finding 11: a creation known by its surface (the app expects the
/// address bar of a tab the store does not have yet) lost its tab, so the
/// keys typed for the address bar went to the page.
#[test]
fn an_address_bar_expected_by_surface_takes_the_keys_typed_for_it() {
    let mut s = Session::new();
    s.open("w1", topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]), "p1");
    s.reaches(Some(terminal("T1")));
    let surface = ExpectationKey::Surface { id: "sf5".into() };
    s.send(InputEvent::Creation { key: surface.clone(), sink: content("b5") });
    s.focus("w1", FocusEvent::BeginIntent {});
    let generation = s.router.focus("w1").map_or(0, |focus| focus.generation);
    s.focus(
        "w1",
        FocusEvent::Expect {
            key: surface,
            target: Target::AddressBar {},
            away_from: None,
            generation,
        },
    );
    let typed = s.press(key("w1", A, Some(terminal("T1"))));
    let bar = Sink::Field { window: arc("w1"), field: FieldKind::AddressBar { tab: arc("b5") } };
    assert_eq!(
        s.last(typed),
        Some(&InputEffect::Queued {
            id: typed,
            sink: bar.clone(),
            reason: WaitReason::AwaitsResponder
        })
    );
    let shown =
        Tab { id: "b5".into(), surface: Some("sf5".into()), kind: Kind::Browser, terminal: None };
    let panes = vec![pane("p1", vec![terminal_tab("t1", "T1")]), pane("p2", vec![shown])];
    s.focus("w1", FocusEvent::Topology { topology: topology("ws", panes) });
    s.reaches(Some(bar.clone()));
    assert_eq!(s.took(&bar), vec![typed]);
}

/// The shrunk case of fuzz seed 39 (3 events: a window, its palette, one key):
/// the palette is open but AppKit's dispatch does not reach it yet. The key
/// waits for the palette and never goes to what AppKit reaches; it ends when
/// AppKit reaches the palette, or is dropped with the reason when the palette
/// closes. No key waits once the palette is gone.
#[test]
fn a_key_for_the_open_palette_waits_for_it_and_ends_when_it_closes() {
    let mut s = Session::new();
    s.send(InputEvent::WindowOpened { window: arc("w1") });
    s.focus("w1", FocusEvent::OverlayOpened { overlay: Overlay::Palette });
    let palette = Sink::Overlay { window: arc("w1"), overlay: Overlay::Palette };
    let first = s.press(key("w1", BACKSPACE, Some(terminal("T8"))));
    assert_eq!(
        s.last(first),
        Some(&InputEffect::Queued {
            id: first,
            sink: palette.clone(),
            reason: WaitReason::AwaitsResponder
        })
    );
    s.reaches(Some(palette.clone()));
    assert_eq!(s.took(&palette), vec![first]);
    s.reaches(Some(terminal("T8")));
    let second = s.press(key("w1", A, Some(terminal("T8"))));
    s.focus("w1", FocusEvent::OverlayClosed { overlay: Overlay::Palette });
    assert_eq!(
        s.last(second),
        Some(&InputEffect::Dropped { id: second, reason: DropReason::TargetLeft })
    );
    assert!(s.took(&terminal("T8")).is_empty());
    assert!(s.ledger.waiting().is_empty(), "{:?}", s.ledger.waiting());
}
