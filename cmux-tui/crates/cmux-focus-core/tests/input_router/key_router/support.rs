//! Builders and a session that runs the router with its ledger.

use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::ledger::Ledger;
use cmux_focus_core::input::{
    Binding, InputEffect, InputEvent, InputId, InputRouter, KeyPhase, KeyRecord, Modifiers, Sink,
    TerminalKey, Tier, WindowRole,
};
use cmux_focus_core::state::{ExpectationKey, Target};
use cmux_focus_core::topology::{Kind, Pane, Tab, Topology};
use std::sync::Arc;

pub fn arc(text: &str) -> Arc<str> {
    Arc::from(text)
}

pub fn terminal_tab(id: &str, host: &str) -> Tab {
    Tab { id: id.into(), surface: None, kind: Kind::Terminal, terminal: Some(host.into()) }
}

pub fn browser_tab(id: &str) -> Tab {
    Tab { id: id.into(), surface: None, kind: Kind::Browser, terminal: None }
}

pub fn conversation_tab(id: &str) -> Tab {
    Tab { id: id.into(), surface: None, kind: Kind::Conversation, terminal: None }
}

/// A pane showing its first tab.
pub fn pane(id: &str, tabs: Vec<Tab>) -> Pane {
    let selected = tabs.first().map(|tab| tab.id.clone());
    Pane { id: id.into(), tabs, selected }
}

pub fn topology(workspace: &str, panes: Vec<Pane>) -> Topology {
    Topology::new(Some(workspace.into()), panes, Vec::new())
}

pub fn terminal(host: &str) -> Sink {
    Sink::Terminal(TerminalKey::Host(arc(host)))
}

pub fn content(tab: &str) -> Sink {
    Sink::Content(arc(tab))
}

/// A plain key-down typed into the main window `window`, reaching `reaches`.
pub fn key(window: &str, code: u16, reaches: Option<Sink>) -> KeyRecord {
    KeyRecord {
        window: arc(window),
        role: WindowRole::Main,
        phase: KeyPhase::Down,
        code,
        modifiers: Modifiers::default(),
        timestamp_ns: 0,
        composing: false,
        terminal_copy_mode: false,
        reaches,
        binding: None,
    }
}

/// A Command chord bound to `action`.
pub fn chord(
    window: &str,
    code: u16,
    action: &str,
    tier: Tier,
    reaches: Option<Sink>,
) -> KeyRecord {
    KeyRecord {
        modifiers: Modifiers { command: true, ..Modifiers::default() },
        binding: Some(Binding { action: arc(action), tier, ghostty: false, edits_input: false }),
        ..key(window, code, reaches)
    }
}

/// Runs the router, checks its ledger after every call, and keeps every effect.
pub struct Session {
    pub router: InputRouter,
    pub ledger: Ledger,
    pub effects: Vec<InputEffect>,
}

impl Default for Session {
    fn default() -> Session {
        Session::new()
    }
}

impl Session {
    pub fn new() -> Session {
        Session { router: InputRouter::new(), ledger: Ledger::new(), effects: Vec::new() }
    }

    pub fn send(&mut self, event: InputEvent) -> Vec<InputEffect> {
        let effects = self.router.handle(&event).to_vec();
        self.ledger.call(&event, &effects);
        assert!(
            self.ledger.violations().is_empty(),
            "{:?} after {event:?}",
            self.ledger.violations()
        );
        self.effects.extend(effects.iter().cloned());
        effects
    }

    /// Sends key `record` and returns its id.
    pub fn press(&mut self, record: KeyRecord) -> InputId {
        let effects = self.send(InputEvent::Key(record));
        let newest = effects.iter().filter_map(InputEffect::id).max();
        newest.unwrap_or(InputId(0))
    }

    pub fn open(&mut self, window: &str, shows: Topology, focused: &str) {
        self.send(InputEvent::WindowOpened { window: arc(window) });
        self.focus(window, FocusEvent::Topology { topology: shows });
        self.focus(
            window,
            FocusEvent::FocusPane {
                pane: focused.into(),
                workspace: None,
                source: Source::Keyboard,
            },
        );
    }

    pub fn focus(&mut self, window: &str, event: FocusEvent) {
        self.send(InputEvent::Focus { window: arc(window), event });
    }

    pub fn reaches(&mut self, sink: Option<Sink>) {
        self.send(InputEvent::Dispatch { reaches: sink });
    }

    /// A creation of `sink` under tab `tab` that the person asked for: the
    /// focus waits for its tab.
    pub fn create(&mut self, window: &str, tab: &str, sink: Sink) {
        let key = ExpectationKey::Tab { id: tab.into() };
        self.send(InputEvent::Creation { key: key.clone(), sink });
        self.focus(window, FocusEvent::BeginIntent {});
        let generation = self.router.focus(window).map_or(0, |focus| focus.generation);
        self.focus(
            window,
            FocusEvent::Expect { key, target: Target::Content {}, away_from: None, generation },
        );
    }

    /// The keys `sink` took, in the order it took them.
    pub fn took(&self, sink: &Sink) -> Vec<InputId> {
        self.effects
            .iter()
            .filter_map(|effect| match effect {
                InputEffect::Deliver { id, sink: to, .. } if to == sink => Some(*id),
                _ => None,
            })
            .collect()
    }

    /// The last effect about key `id`.
    pub fn last(&self, id: InputId) -> Option<&InputEffect> {
        self.effects.iter().rev().find(|effect| effect.id() == Some(id))
    }
}
