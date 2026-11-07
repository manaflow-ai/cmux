//! One window's focus (R-INPUT stage S2, DESIGN.md section 5): the focus
//! machine's state, the address bar memory (Chrome's per-tab omnibox focus,
//! [`OmnibarFocusMemory`]) and the Close Tab aim ([`PaneCloseAim`]), with the
//! one set of operations the app's focus handle and the input router both
//! use. The app FFI's per-window handle wraps it with its reply buffers; the
//! input router holds one per window, so a focus event reduces the same way
//! wherever it comes from.

use crate::close_aim::{PaneCloseAim, Press};
use crate::event::{FocusEffect, FocusEvent};
use crate::omnibar_memory::OmnibarFocusMemory;
use crate::reducer;
use crate::state::{CloseFocusPolicy, FocusState};
use crate::topology::Topology;

/// What one reduction did besides its effects.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Reduction {
    /// The reducer ran: false when the event changed nothing at all (an equal
    /// topology report, a responder report that names the current focus).
    pub ran: bool,
    /// Queue the address bar return ([`crate::omnibar_memory::return_event`])
    /// after this event's effects.
    pub omnibar_return: bool,
    /// This event is that queued return: the address bar restores its edit
    /// instead of selecting all.
    pub returns_to_omnibar: bool,
}

/// One window's focus: the state, the address bar memory and the Close Tab aim.
#[derive(Clone, Debug)]
pub struct WindowFocus {
    state: FocusState,
    omnibar: OmnibarFocusMemory,
    close_aim: PaneCloseAim,
}

impl Default for WindowFocus {
    fn default() -> WindowFocus {
        WindowFocus::new()
    }
}

impl WindowFocus {
    /// An empty window's focus (its state derived).
    pub fn new() -> WindowFocus {
        let mut state = FocusState::default();
        state.derive();
        WindowFocus { state, omnibar: OmnibarFocusMemory::new(), close_aim: PaneCloseAim::new() }
    }

    /// The focus machine's state.
    pub fn state(&self) -> &FocusState {
        &self.state
    }

    /// Reduces `event`; `effects` gets its effects (cleared first). A topology
    /// event takes [`WindowFocus::set_topology`]'s path, as the app's handle
    /// does: an equal topology changes nothing.
    pub fn send(&mut self, event: &FocusEvent, effects: &mut Vec<FocusEffect>) -> Reduction {
        if let FocusEvent::Topology { topology } = event {
            return self.set_topology(topology.clone(), effects);
        }
        let returns = self.omnibar.take_return(event);
        let before = self.state.derived.resolved.clone();
        let ran = reducer::reduce(&mut self.state, event, effects);
        let queue = self.omnibar.note(event, &before, &self.state.derived.resolved);
        Reduction { ran, omnibar_return: queue, returns_to_omnibar: returns }
    }

    /// A topology report; an equal topology returns at once (`ran` false). A
    /// topology change is a way back to a tab (a workspace switch).
    pub fn set_topology(
        &mut self,
        topology: Topology,
        effects: &mut Vec<FocusEffect>,
    ) -> Reduction {
        let before = self.state.derived.resolved.clone();
        let ran = reducer::set_topology(&mut self.state, topology, effects);
        let queue = self.omnibar.note_reduction(true, &before, &self.state.derived.resolved);
        Reduction { ran, omnibar_return: queue, returns_to_omnibar: false }
    }

    /// The focused pane moved from `from` to the pane the state focuses now;
    /// returns the move's serial, for [`WindowFocus::frame_presented`].
    pub fn pane_moved(&mut self, from: Option<&str>) -> u64 {
        let to = self.state.pane.clone();
        self.close_aim.pane_moved(from, to.as_deref())
    }

    /// The frame that shows move `serial` was presented at `time` (seconds of
    /// system uptime).
    pub fn frame_presented(&mut self, serial: u64, time: f64) {
        self.close_aim.presented(serial, time);
    }

    /// `press` closed the last tab of `pane`.
    pub fn pane_emptied(&mut self, pane: &str, press: Press) {
        self.close_aim.pane_emptied(pane, press);
    }

    /// Whether `press` is aimed at a pane a close emptied, not at the focused
    /// pane: it closes nothing, and the app shows why.
    pub fn aims_at_emptied_pane(&mut self, press: Press) -> bool {
        let focused = self.state.pane.clone();
        self.close_aim.aims_at_emptied_pane(press, focused.as_deref())
    }

    /// The focus a close leaves to (the app's setting).
    pub fn set_close_focus(&mut self, policy: CloseFocusPolicy) {
        self.state.close_focus = policy;
    }

    /// Replaces the state with a journal checkpoint; false (nothing changed)
    /// when it does not parse. The address bar memory and the Close Tab aim
    /// stay: a checkpoint holds the machine's state only.
    pub fn import(&mut self, json: &[u8]) -> bool {
        match FocusState::import(json) {
            Ok(state) => {
                self.state = state;
                true
            }
            Err(_) => false,
        }
    }

    /// Derives the state again: after a reduction that stopped part way, the
    /// fast paths read `derived`.
    pub fn rederive(&mut self) {
        self.state.derive();
    }
}
