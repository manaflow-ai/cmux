//! Script sessions (plans/cmux-next/scripting-runtime.md, phase 1).
//!
//! A script session is one `cmux-app-host` process started with
//! `--profile script` ([`crate::Limits::script`]). Its `main` is the script
//! prelude ([`prelude::main_source`]): the app runtime's `cmux` global, the
//! REPL cell host (acorn plus `cmux-browser-host/js/repl-host.js`) and
//! `js/script-prelude.js`. [`Session::eval`] runs one cell; the session keeps
//! top-level bindings across cells, so one session serves both a one-shot
//! `cmux script run` (one cell) and `cmux script repl` (many).
//!
//! Every op a cell calls arrives as a `call` line and goes to the
//! [`ScriptRouter`] the daemon supplies, which checks and routes it. The VM
//! never sees a credential, the network or the filesystem: the host applies
//! its OS sandbox before it reads the script.
//!
//! This module needs no engine (`default-features = false` is enough): the
//! daemon links it and spawns the host binary.

pub mod prelude;
mod session;

pub use session::{
    DEFAULT_TIMEOUT, LogSink, MAX_TIMEOUT, ScriptError, ScriptRouter, Session, codes,
};
