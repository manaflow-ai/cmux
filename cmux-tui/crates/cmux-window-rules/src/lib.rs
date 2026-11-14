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
//! - [`targets`]: how an action finds what it acts on (the 9-is-last
//!   ordinal, the wrapping step, id-then-name lookup, the explicit target)
//!   and the refusal a handler's failure becomes.
//! - [`workspaces`]: the workspace, screen, space and group verbs' rules
//!   (bulk closes and their question, the question each destructive action
//!   asks, space defaults, description and status, screen moves).
//! - [`closed`]: the daemon's closed history (page rows, Cmd-Shift-T's
//!   owner) and the undo toast's expected closes, a reducer.
//! - [`notifications`], [`history`], [`remote`], [`browser`], [`files`],
//!   [`appearance`]: the smaller handlers' tables and refusals (which unread
//!   tab a verb reads, the trail walks, the SSH machine an action names, a
//!   page fit, Picture in Picture's page, where a file or diff opens, the
//!   appearance verbs).

pub mod appearance;
pub mod browser;
pub mod chat;
pub mod close;
pub mod closed;
pub mod files;
pub mod history;
pub mod notifications;
pub mod remote;
pub mod tabs;
pub mod targets;
pub mod workspaces;
