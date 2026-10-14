//! The cmux window focus state machine and key rules, shared by every
//! platform shell (plans/cmux-next/focus.md, plans/cmux-next/layer-ownership.md).
//!
//! - [`reducer::reduce`]: `(state, event) -> (state, effects)` for one
//!   window's focus. The macOS app sends every focus event through the app
//!   FFI and applies the effects (first responder, selection, layout
//!   reveal, registry context) synchronously, in the same turn.
//! - [`close_focus::pane`]: the focused-pane successor when a pane closes.
//! - [`type_ahead::TypeAheadQueue`]: keys typed before a page can take them.
//! - [`child_window`]: what a window does when a child window becomes key.
//!
//! Pure: no I/O, no clock (time comes in as monotonic nanoseconds), no
//! daemon. The JSON shapes ([`wire`]) are the macOS app's synthesized
//! `Codable` shapes, so the app keeps plain value types.

pub mod child_window;
pub mod close_focus;
pub mod event;
pub mod reducer;
pub mod state;
pub mod topology;
pub mod type_ahead;
pub mod wire;
