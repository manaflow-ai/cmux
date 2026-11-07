//! The rules of the cmux NEXT window handlers, in Rust so the macOS app keeps
//! only the platform work (Leo, 2026-11-06: "ok we need to go all hands on
//! deck here. don't just do baby steps. we can just... do it"). Pure: no I/O.
//! The app reads the facts (its tab models, the settings, the daemon's
//! answers), asks here, and acts on the answer: the dialog, the toast, the
//! daemon command. Served to the app over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `window_*`).
//!
//! - [`close`]: what closing tabs asks first (a working agent, a foreground
//!   program) and whether the close earns an undo toast.
//! - [`tabs`]: what a new tab or pane opens and where (its kind, the browser
//!   open plan, a split's plan), tab moves, numbers, duplicates, restarts and
//!   icons; [`tabs::panes`] the pane and terminal tables.
//! - [`chat`]: where an agent chat, a tool opened from it and a column action
//!   go (the chat dock, the strip, the column target), and the agent chat
//!   handlers' rules ([`chat::agent`]).

pub mod chat;
pub mod close;
pub mod tabs;
