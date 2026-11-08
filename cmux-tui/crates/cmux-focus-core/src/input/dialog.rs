//! Blocking dialogs (DESIGN.md section 4.4 step 3; #31849, #32291, #32409): a
//! dialog blocks its window or one tab. A key with no Command or Control typed
//! while a dialog blocks the key's target is the dialog's, before any key
//! session and any binding (Return presses its default button, Escape cancels
//! it, text goes to its field): a modal dialog is above every session, as in
//! Chrome, where a page's alert blocks its hint script. A Command or Control
//! chord still runs its binding (Cmd-W closes the tab and its dialog). A key
//! typed BEFORE the dialog keeps its own target: it waits while the dialog
//! blocks that target and goes on after the answer, or is dropped when the
//! answer closes the target. A blocked target never takes a key, and a dialog
//! never takes a key typed before it.

use super::key::{KeyRecord, WindowRole};
use super::router::InputRouter;
use super::sink::{FieldKind, Sink};
use std::sync::Arc;

/// What a dialog blocks.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum DialogScope {
    /// Every target of the window but its overlays (the palette, a sheet).
    Window(Arc<str>),
    /// One tab of the window: its content and its developer tools. While the
    /// window's keyboard is in its chrome (the sidebar list, or nothing) and
    /// its focused pane shows the tab, the window's keys are the dialog's too.
    Tab { window: Arc<str>, tab: Arc<str> },
}

impl InputRouter {
    /// The blocking dialog key `key` goes to before any session or binding: a
    /// key with no Command or Control, typed in a cmux window (no input method
    /// composing), whose target a dialog blocks.
    pub(super) fn dialog_first(&self, key: &KeyRecord) -> Option<u64> {
        if self.dialogs.is_empty()
            || key.role != WindowRole::Main
            || key.composing
            || key.modifiers.is_chord()
        {
            return None;
        }
        let (window_id, window) = self.windows.get_key_value(&key.window)?;
        let aim = self.aim_in(window_id, window);
        self.dialog_for(window_id, aim.sink.as_ref())
    }

    /// The dialog a key typed now in `window` and aimed at `sink` goes to, the
    /// oldest one that blocks it.
    pub(super) fn dialog_for(&self, window: &Arc<str>, sink: Option<&Sink>) -> Option<u64> {
        if self.dialogs.is_empty() {
            return None;
        }
        let chrome = match sink {
            None | Some(Sink::Field { field: FieldKind::Sidebar, .. }) => true,
            Some(_) => false,
        };
        self.dialogs.iter().find_map(|(id, scope)| {
            let blocks = match scope {
                DialogScope::Window(blocked) => {
                    blocked == window && !matches!(sink, Some(Sink::Overlay { .. }))
                }
                DialogScope::Tab { window: blocked, tab } => {
                    blocked == window
                        && (sink.is_some_and(|sink| self.tab_owns(blocked, tab, sink))
                            || (chrome && self.focused_tab(blocked) == Some(tab.as_ref())))
                }
            };
            blocks.then_some(*id)
        })
    }

    /// Whether a dialog blocks `sink` now: its keys typed before the dialog
    /// wait for the answer.
    pub(super) fn is_blocked(&self, sink: &Sink) -> bool {
        if self.dialogs.is_empty() || matches!(sink, Sink::Dialog(_) | Sink::Overlay { .. }) {
            return false;
        }
        self.dialogs.iter().any(|(_, scope)| match scope {
            DialogScope::Window(window) => match sink.window() {
                Some(own) => own == window,
                None => self.windows.get(window).is_some_and(|input| {
                    input.tabs.iter().any(|(tab, _)| self.tab_owns(window, tab, sink))
                }),
            },
            DialogScope::Tab { window, tab } => self.tab_owns(window, tab, sink),
        })
    }

    /// Whether `sink` is tab `tab`'s content or developer tools in `window`.
    fn tab_owns(&self, window: &Arc<str>, tab: &Arc<str>, sink: &Sink) -> bool {
        if *sink == Sink::DevTools(tab.clone()) {
            return true;
        }
        let Some(input) = self.windows.get(window) else { return false };
        match input.tabs.get_key_value(tab.as_ref()) {
            Some((id, info)) => super::router::content_sink(id, info).as_ref() == Some(sink),
            None => false,
        }
    }

    /// The tab `window`'s focused pane shows.
    fn focused_tab(&self, window: &Arc<str>) -> Option<&str> {
        let focus = self.windows.get(window)?.focus();
        focus.topology.pane(focus.pane.as_deref()?)?.selected.as_deref()
    }
}
