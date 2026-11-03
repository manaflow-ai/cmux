//! Blocking dialogs (DESIGN.md section 4.4 step 4; #31849, #32291, #32409): a
//! dialog blocks its window or one tab. A key typed while a dialog blocks the
//! key's target is the dialog's (Return presses its default button, Escape
//! cancels it, text goes to its field), unless the key runs a binding (Cmd-W
//! closes the tab and its dialog). A key typed BEFORE the dialog keeps its
//! own target: it waits while the dialog blocks that target and goes on after
//! the answer, or is dropped when the answer closes the target. A blocked
//! target never takes a key, and a dialog never takes a key typed before it.

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
    /// The dialog a key typed now in `window` and aimed at `sink` goes to, the
    /// oldest one that blocks it.
    pub(super) fn dialog_for(&self, window: &Arc<str>, sink: Option<&Sink>) -> Option<u64> {
        // Today: a dialog gets a key only through AppKit's dispatch.
        let _ = (window, sink);
        None
    }

    /// Whether a dialog blocks `sink` now: its keys typed before the dialog
    /// wait for the answer.
    pub(super) fn is_blocked(&self, sink: &Sink) -> bool {
        // Today: keys typed before a dialog do not wait for its answer.
        let _ = sink;
        false
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
        let focus = &self.windows.get(window)?.focus;
        focus.topology.pane(focus.pane.as_deref()?)?.selected.as_deref()
    }
}
