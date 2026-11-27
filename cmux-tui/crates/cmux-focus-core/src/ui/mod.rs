//! The macOS app's focus UI decisions (CmuxNextFocusUI), moved out of Swift:
//! the app keeps the AppKit objects (`NSEvent`, `NSRunningApplication`,
//! views, timers) and asks these rules over the layout reducer's JSON channel
//! (`focus_ui_*` ops).
//!
//! - [`no_activate::NoActivateGuard`]: whether an activation the person did
//!   not ask for gives the keyboard back to the app they were in.
//! - [`hint_policy::ShortcutHintPolicy`]: when a held modifier shows the
//!   shortcut hints.
//! - [`pane_hints::chips`]: the pane navigation hint chip on each pane.
//! - [`guards`]: the keyboard guards over view and window facts (an unseen
//!   responder, a system move off a typing target, a key from another window).

pub mod guards;
pub mod hint_policy;
pub mod no_activate;
pub mod pane_hints;
