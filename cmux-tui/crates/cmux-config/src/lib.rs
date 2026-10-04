//! `cmux-config`: the owner of `~/.config/cmux/cmux.json` inside the cmux
//! daemon (plans/cmux-next/settings-react.md sections 1-3 and 6).
//!
//! - [`keybindings`]: keybindings.json (R59): entries with per-entry
//!   diagnostics and comment-preserving edits.
//! - [`schema`]: the settings schema exported from Swift, embedded, with
//!   write validation per kind.
//! - [`jsonc`]: a comment-preserving JSONC parser and in-place editor.
//! - [`managed`], [`effective`]: MDM and team policy layers and the merge.
//! - [`store`]: the pure reducer `apply(&State, Op)`; [`owner`]: the single
//!   writer with IO (atomic publish, cold-start cache); [`watch`]: kernel
//!   file events.

pub mod cache;
pub mod diagnostics;
pub mod domains;
pub mod effective;
pub mod fsio;
pub mod guard;
pub mod jsonc;
pub mod keybindings;
pub mod keypath;
pub mod location;
pub mod managed;
pub mod owner;
pub mod refusal;
pub mod render;
pub mod schema;
pub mod store;
pub mod text;
pub mod value;
pub mod watch;

pub use diagnostics::{Diagnostic, DiagnosticKind};
pub use domains::Domains;
pub use effective::EffectiveSettings;
pub use location::{CONFIG_OVERRIDE, config_path};
pub use managed::{ManagedPreferences, ManagedReader, ManagedSource, Policy, TeamPolicyLayer};
pub use owner::{ApplyResult, ConfigStore};
pub use refusal::Refusal;
pub use schema::{Row, Schema};
pub use store::{Change, FileRead, Op, Origin, Outcome, State, Target, WriteMeta, apply};
pub use watch::{Watcher, watch_store};
