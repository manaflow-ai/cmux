//! Claude Code and Codex customization, read and edited where each CLI keeps
//! it, for cmux NEXT's "Claude Code & Codex" settings and
//! `cmux agent-config`. One module per surface; every edit keeps the file's
//! other keys, order and comments, writes atomically and backs up the prior
//! file (see [`paths::write_with_backup`]).

pub mod cli;
pub mod hooks;
pub mod hooks_cli;
mod ojson;
pub mod paths;

pub use ojson::OJson;
