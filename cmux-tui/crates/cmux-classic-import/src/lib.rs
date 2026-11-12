//! The one-time move from classic cmux to cmux NEXT
//! (plans/cmux-next/classic-migration-DESIGN.md). Classic's files are only
//! ever read and copied, never written, moved or deleted.
//!
//! - [`model`]: a classic session as read: windows, their workspaces in
//!   sidebar order with splits and tabs, groups, colors and pins.
//! - [`decode`]: reads `session-<bundle>.json` into the model, inside fixed
//!   limits so a damaged or hostile file cannot take unbounded memory, with
//!   each terminal's scrollback from classic's checkpoint after a crash.
//! - [`source`]: which save to read (this build's own classic channel, else
//!   the one saved last), what identifies a save, and whether classic is
//!   running and may still save.
//! - [`ledger`]: the version-stamped record of what earlier runs made, and
//!   the folder holding it and the backups.
//! - [`plan`]: whether a launch runs, and what a run makes. Pure.
//! - [`read`]: the save a run reads, trying the session file, its
//!   `-previous` copy and the newest archive in turn.
//!
//! ```no_run
//! use cmux_classic_import::{ledger, plan, read, source};
//! let home = std::path::Path::new("/Users/me");
//! let support = home.join("Library/Application Support");
//! let finder = source::Finder::new(&support, Some("com.cmuxterm.app"));
//! if let Ok(Some(save)) = read::read(&finder, None, home) {
//!     let folder = ledger::Folder::new(support.join("cmux-next/com.cmuxterm.app/classic-migration"));
//!     let loaded = folder.load();
//!     let saved = loaded.ledger();
//!     let open = std::collections::BTreeSet::new();
//!     let made = plan::plan(&save.snapshot, saved.as_ref(), &open, &open, plan::Mode::Automatic);
//!     println!("{}", serde_json::to_string_pretty(&made).unwrap());
//! }
//! ```

pub mod decode;
pub mod ledger;
mod limits;
pub mod model;
mod names;
pub mod plan;
pub mod read;
pub mod source;

pub use decode::Error;
