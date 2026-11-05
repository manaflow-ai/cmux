//! The cmux window focus state machine and key rules, shared by every
//! platform shell (plans/cmux-next/focus.md, plans/cmux-next/layer-ownership.md).
//!
//! - [`reducer::reduce`] and [`reducer::set_topology`]: one window's focus
//!   transition, applied in place to the state the window's handle owns
//!   (the app FFI's `cmux_focus_*`). The macOS app sends small typed events
//!   and applies the effects (first responder, selection, layout reveal,
//!   registry context) synchronously, in the same turn; it never sends or
//!   receives the whole state.
//! - [`close_focus`]: the focus successor of every close kind (pane, tab,
//!   workspace).
//! - [`close_aim::PaneCloseAim`]: which pane a Close Tab press is aimed at
//!   after a close emptied a pane.
//! - [`omnibar_memory::OmnibarFocusMemory`]: Chrome's per-tab address bar
//!   focus, restored on return to the tab.
//! - [`invariants`]: the input invariants (model, transition, world).
//! - [`type_ahead::TypeAheadQueue`]: keys typed before a page can take them.
//! - [`child_window`]: what a window does when a child window becomes key.
//! - [`agent_cursor_visibility::resolve`]: where an agent cursor for a
//!   target tab draws (its page, an anchor in its window, or nowhere).
//! - [`input::InputRouter`]: the one input router: every window's focus and
//!   every key's route, decided in the key's own call and fixed for the
//!   key's life (handoff/rewrites/R-INPUT/DESIGN.md).
//!
//! Pure: no I/O, no clock (time comes in as monotonic nanoseconds), no
//! daemon. The serde shapes are the macOS app's synthesized `Codable`
//! shapes: the journal checkpoints and replay use them, and [`wire`] holds
//! the per-key JSON rules.

pub mod agent_cursor_visibility;
pub mod child_window;
pub mod close_aim;
pub mod close_focus;
pub mod event;
pub mod input;
pub mod invariants;
pub mod omnibar_memory;
pub mod reducer;
pub mod state;
pub mod topology;
pub mod type_ahead;
pub mod window;
pub mod wire;
