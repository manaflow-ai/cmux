//! `OmnibarFocusMemory`, ported from the Swift `OmnibarFocusMemoryTests`:
//! Chrome's per-tab omnibox focus (u2573). A browser tab left while its
//! address bar had the keyboard gets the address bar back on return; a click
//! into its page does not.

use cmux_focus_core::event::{FocusEvent, Responder, Source};
use cmux_focus_core::omnibar_memory::{LIMIT, OmnibarFocusMemory, return_event};
use cmux_focus_core::state::{Resolved, Target};

fn bar(tab: &str) -> Resolved {
    Resolved::AddressBar { pane: "p1".into(), tab: tab.into() }
}

fn page(tab: &str) -> Resolved {
    Resolved::BrowserPage { pane: "p1".into(), tab: tab.into() }
}

fn terminal() -> Resolved {
    Resolved::Terminal { pane: "p2".into(), tab: "t".into() }
}

fn select(tab: &str, source: Source) -> FocusEvent {
    FocusEvent::SelectTab { pane: "p1".into(), tab: tab.into(), workspace: None, source }
}

fn focus_pane(pane: &str, source: Source) -> FocusEvent {
    FocusEvent::FocusPane { pane: pane.into(), workspace: None, source }
}

#[test]
fn returning_to_the_tab_restores_its_address_bar() {
    let mut memory = OmnibarFocusMemory::new();
    assert!(!memory.note(&select("b", Source::Keyboard), &bar("a"), &page("b")));
    assert_eq!(memory.tabs(), ["a".to_owned()]);
    assert!(memory.note(&select("a", Source::Mouse), &page("b"), &page("a")));
    assert!(memory.tabs().is_empty(), "once");
    // Its address-bar request is the return, once: a later identical request
    // (Cmd-L) is not.
    assert!(memory.take_return(&return_event()));
    assert!(!memory.take_return(&return_event()));
}

#[test]
fn a_pane_switch_back_restores_it_too() {
    let mut memory = OmnibarFocusMemory::new();
    memory.note(&focus_pane("p2", Source::Mouse), &bar("a"), &terminal());
    assert!(memory.note(&focus_pane("p1", Source::Keyboard), &terminal(), &page("a")));
}

/// A click in the page (a responder report) is the user's choice: the
/// memory is dropped, nothing is restored.
#[test]
fn a_click_in_the_page_forgets_it() {
    let mut memory = OmnibarFocusMemory::new();
    memory.note(&focus_pane("p2", Source::Mouse), &bar("a"), &terminal());
    let click = FocusEvent::Responder {
        responder: Responder::Content { pane: "p1".into() },
        source: Source::Mouse,
    };
    assert!(!memory.note(&click, &terminal(), &page("a")));
    assert!(memory.tabs().is_empty());
}

/// Leaving the bar for the same tab's page (Enter, Escape) is not leaving
/// the tab.
#[test]
fn enter_on_the_same_tab_remembers_nothing() {
    let mut memory = OmnibarFocusMemory::new();
    assert!(!memory.note(&focus_pane("p1", Source::Programmatic), &bar("a"), &page("a")));
    assert!(memory.tabs().is_empty());
}

/// Only the return event this memory queued is taken, and only once.
#[test]
fn only_the_queued_return_is_taken() {
    let mut memory = OmnibarFocusMemory::new();
    assert!(!memory.take_return(&return_event()), "nothing queued");
    memory.note(&select("b", Source::Keyboard), &bar("a"), &page("b"));
    memory.note(&select("a", Source::Keyboard), &page("b"), &page("a"));
    let user_cmd_l =
        FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Keyboard };
    assert!(!memory.take_return(&user_cmd_l));
    assert!(memory.take_return(&return_event()));
}

/// Past the bound the oldest remembered tab goes (the Swift set dropped an
/// arbitrary one).
#[test]
fn the_memory_is_bounded_oldest_first() {
    let mut memory = OmnibarFocusMemory::new();
    for i in 0..=LIMIT {
        memory.note(&select("x", Source::Keyboard), &bar(&format!("t{i}")), &page("x"));
    }
    assert_eq!(memory.tabs().len(), LIMIT);
    assert_eq!(memory.tabs().first().map(String::as_str), Some("t1"));
    assert_eq!(memory.tabs().last().map(String::as_str), Some(format!("t{LIMIT}").as_str()));
}
