//! The git code cmux runs, shared by the session host's `git.*` operations
//! (cmux-tui-core) and the diff sidecar (Native/DiffSidecar).
//!
//! Every function is synchronous and runs git as a child process: `run` for
//! bounded reads, `write_run` for checkpoint writes. A [`Repository`] is a
//! repository's top level plus the config overrides every read carries.
//! `parse` reads git's machine output, `diff` turns a scope into the
//! revisions to compare, and `refs` lists branches and suggests a base.
//!
//! The crate has no terminal, store or protocol types. Errors are its own
//! enums; callers map them to their wire errors.

pub mod diff;
pub mod parse;
pub mod refs;
mod repository;
pub mod run;
pub mod write_run;

pub use repository::{OpenError, Repository, filter_overrides};

/// The output limit for a run whose result is a line or a few names.
pub const MAX_SMALL_OUTPUT_BYTES: usize = 64 * 1024;
