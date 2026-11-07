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
//! - [`notifications`], [`history`], [`remote`], [`browser`], [`files`],
//!   [`appearance`]: the smaller handlers' tables and refusals (which unread
//!   tab a verb reads, the trail walks, the SSH machine an action names, a
//!   page fit, Picture in Picture's page, where a file or diff opens, the
//!   appearance verbs).

pub mod appearance;
pub mod browser;
pub mod close;
pub mod files;
pub mod history;
pub mod notifications;
pub mod remote;
