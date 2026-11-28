//! Import from Conductor. Conductor Cloud goes read-only on 2026-11-13 and
//! shuts down on 2026-11-20, and its local app winds down after that; this
//! crate reads what a person made there and says what cmux would make of it.
//!
//! - [`detect`]: whether Conductor was used on this machine (its database,
//!   its workspaces folder, the app). None of these raise a privacy prompt.
//! - [`catalog`]: `repos` and `workspaces` from `conductor.db`, read-only
//!   (the database is never written, created or locked for Conductor).
//! - [`settings`]: each repository's `.conductor/settings.toml` (and the
//!   legacy `conductor.json`, the `.json` and `.local` variants) merged over
//!   the database's scripts: setup, run and archive scripts, "files to copy",
//!   and the names (never the values) of its environment variables.
//! - [`plan`]: the dry run. Each repository becomes a project; each live
//!   workspace is adopted in place, after `git worktree list` confirms it;
//!   an archived one whose commit still exists is listed as recoverable and
//!   left unchecked. Pure: the git and file facts are gathered by [`inspect`].
//! - [`ledger`]: what earlier runs made, so a rerun makes nothing twice.
//! - [`chats`]: Claude Code transcripts of each workspace, linked by path
//!   (`~/.claude/projects/<slug>`), never copied.
//!
//! ```no_run
//! let home = std::path::Path::new("/Users/me");
//! let found = cmux_conductor_import::detect::detect(home);
//! if let Some(db) = found.database.as_deref() {
//!     let catalog = cmux_conductor_import::catalog::read(db).unwrap();
//!     let facts = cmux_conductor_import::inspect::inspect(&catalog, home);
//!     let ledger = cmux_conductor_import::ledger::Ledger::default();
//!     let open_now = std::collections::BTreeSet::new();
//!     let plan = cmux_conductor_import::plan::plan(&catalog, &facts, &ledger, &open_now);
//!     println!("{}", serde_json::to_string_pretty(&plan).unwrap());
//! }
//! ```

pub mod catalog;
pub mod chats;
pub mod detect;
mod git;
pub mod inspect;
pub mod ledger;
pub mod plan;
pub mod settings;
pub mod tools;

/// Conductor Cloud stops taking changes (UTC date).
pub const CLOUD_READ_ONLY: &str = "2026-11-13";
/// Conductor Cloud shuts down (UTC date).
pub const CLOUD_SHUTDOWN: &str = "2026-11-20";

/// The variables Conductor sets for its scripts and the cmux variable each
/// one aliases. A mapped script runs with both names set, so its command is
/// saved as written.
pub const VARIABLE_ALIASES: [(&str, &str); 4] = [
    ("CONDUCTOR_WORKSPACE_PATH", "CMUX_WORKSPACE_PATH"),
    ("CONDUCTOR_ROOT_PATH", "CMUX_ROOT_PATH"),
    ("CONDUCTOR_WORKSPACE_NAME", "CMUX_WORKSPACE_NAME"),
    ("CONDUCTOR_PORT", "CMUX_PORT"),
];
