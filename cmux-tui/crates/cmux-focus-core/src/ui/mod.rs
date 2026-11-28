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
//! - [`creation_hold::CreationHold`]: the keys typed while a tab, split or
//!   workspace is still being made, and where each goes once it is.
//! - [`guards`]: the keyboard guards over view and window facts (an unseen
//!   responder, a system move off a typing target, a key from another window).
//! - [`typing_park::TypingPark`]: text that waits for a page its pane no
//!   longer shows (New Tab key, a letter, New Tab key).
//! - [`given_back::GivenBackInput`]: keys a failed terminal creation gave
//!   back, held for a terminal of the window they were typed in.
//! - [`held_key`]: a held key as the daemon's `send` / `send-key` take it.
//! - [`page_first_key::PageFirstKeyOffer`]: the keys a browser page gets
//!   first, with the action cmux runs if the page reports one unhandled.
//! - [`awaited_content`]: the focused content a key typed now would miss.
//! - [`browser_chords`]: the chords a browser owns while it has the keyboard.

pub mod awaited_content;
pub mod browser_chords;
pub mod creation_hold;
pub mod given_back;
pub mod guards;
pub mod held_key;
pub mod hint_policy;
pub mod no_activate;
pub mod page_first_key;
pub mod pane_hints;
pub mod typing_park;
