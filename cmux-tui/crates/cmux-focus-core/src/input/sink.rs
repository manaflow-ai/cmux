//! Sinks: what takes a key. A sink's id never changes while it lives, so a
//! key aimed at it at key time reaches the same thing later.

use crate::state::Overlay;
use std::sync::Arc;

/// A terminal, by the id that names it across its tabs.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TerminalKey {
    /// Its host terminal id (client-minted for a new terminal, so its
    /// stand-in tab and the daemon's tab are one sink).
    Host(Arc<str>),
    /// A terminal tab whose host terminal id the app does not know: the tab
    /// is its own sink.
    Tab(Arc<str>),
}

/// A text input that takes keys only through AppKit's dispatch.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum FieldKind {
    /// The address bar of a browser tab.
    AddressBar { tab: Arc<str> },
    /// The find bar of a browser tab.
    FindBar { tab: Arc<str> },
    /// The sidebar list.
    Sidebar,
    /// The sidebar's search or inline rename field.
    SidebarField,
    /// Any other text field of the window.
    TextField,
}

/// What takes a key.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Sink {
    /// A terminal: always takes keys, through its view when that view has the
    /// keyboard, else by its writer.
    Terminal(TerminalKey),
    /// A tab's content that is not a terminal (a browser page, an agent chat,
    /// an internal page, a conversation), by tab id: takes keys once it
    /// reported ready.
    Content(Arc<str>),
    /// The docked developer tools of a browser tab: takes keys once ready.
    DevTools(Arc<str>),
    /// A field of a window: takes keys only while AppKit's dispatch reaches
    /// it.
    Field { window: Arc<str>, field: FieldKind },
    /// An overlay of a window (palette, sheet, rename, group editor): takes
    /// keys only while AppKit's dispatch reaches it.
    Overlay { window: Arc<str>, overlay: Overlay },
    /// A blocking dialog, by its id: its keyboard takes the keys aimed at what
    /// it blocks (through its view when that has the keyboard, else its own
    /// key handling).
    Dialog(u64),
}

impl Sink {
    /// The sink has an input path of its own, used when AppKit's dispatch
    /// does not reach it: a terminal's writer, a page's native key send.
    pub fn has_direct_path(&self) -> bool {
        matches!(self, Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_) | Sink::Dialog(_))
    }

    /// A tab's sink (its terminal, its content, its developer tools): it can
    /// end, and only a new sink of its id takes keys after that. A window's
    /// field, overlay or dialog never ends that way: the next one of its kind
    /// is the same sink.
    pub fn of_tab(&self) -> bool {
        matches!(self, Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_))
    }

    /// The sink takes keys only once it reported ready.
    pub fn needs_ready(&self) -> bool {
        matches!(self, Sink::Content(_) | Sink::DevTools(_))
    }

    /// The window a field or overlay belongs to; none for a tab's sink.
    pub fn window(&self) -> Option<&Arc<str>> {
        match self {
            Sink::Field { window, .. } | Sink::Overlay { window, .. } => Some(window),
            Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_) | Sink::Dialog(_) => None,
        }
    }
}
