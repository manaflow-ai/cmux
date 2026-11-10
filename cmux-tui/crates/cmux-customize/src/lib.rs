//! Customize cmux by asking: the one core behind the GUI, `cmux customize`
//! and the `customize_*` MCP tools (cmuxterm-hq
//! `plans/cmux-next/customize-by-asking/DESIGN.md`).
//!
//! The model, in four sentences. The **live tree** is the set of files cmux
//! already hot reloads on save (settings, shortcuts, themes, your views app,
//! stylesheets, automations), so writing one is the preview. A **draft** is
//! the live tree differing from the current generation; a person and an
//! agent edit the same files, so neither can overwrite what the other
//! cannot see. **Apply** validates the tree and records it as the next
//! numbered **generation**; **discard** and **roll back** restore an earlier
//! one, and each first records what was live, so nothing is ever lost. A
//! **profile** is one portable file made from a generation.
//!
//! Nothing here watches, polls or runs a timer, and nothing talks to the
//! daemon: every operation is a handful of file reads and atomic writes
//! under one lock, so it works the same from the app, from a terminal with
//! cmux quit, and in safe mode.

mod brief;
mod diff;
mod engine;
mod paths;
pub mod profile;
pub mod redact;
mod store;
mod tree;
mod validate;

use serde::Serialize;

pub use brief::brief;
pub use engine::Customize;
pub use paths::{Roots, STATE_OVERRIDE};
pub use redact::Reader;
pub use store::{Ask, Draft, Generation, Kind};
pub use tree::{Part, Skipped};
pub use validate::Problem;

/// How a live file differs from the current generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ChangeKind {
    Added,
    Modified,
    Removed,
}

impl ChangeKind {
    pub fn sign(self) -> char {
        match self {
            ChangeKind::Added => '+',
            ChangeKind::Modified => '~',
            ChangeKind::Removed => '-',
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Change {
    pub path: String,
    pub part: Part,
    pub kind: ChangeKind,
    /// Edited by hand since the agent's last turn (or with no agent at
    /// all): the agent re-reads it before it writes there again.
    pub by_hand: bool,
}

/// A change with its text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FileDiff {
    pub path: String,
    pub kind: ChangeKind,
    /// A unified diff; `None` for a file that is not text.
    pub diff: Option<String>,
}

/// Everything the three surfaces show about now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    /// The generation that is applied.
    pub current: Option<Generation>,
    pub draft: Option<DraftInfo>,
    /// Live files that differ from `current`: the preview.
    pub changes: Vec<Change>,
    /// What stops an apply, by file and line. Empty means it would apply.
    pub problems: Vec<Problem>,
    /// Files left out of generations (too large, too many).
    pub skipped: Vec<Skipped>,
    /// Milliseconds from the latest ask to the first file it changed: the
    /// time to a live preview, less the reload itself.
    pub ask_to_first_change_ms: Option<u64>,
}

impl Status {
    pub fn dirty(&self) -> bool {
        !self.changes.is_empty()
    }
}

/// The open draft, as the surfaces show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DraftInfo {
    /// The generation it started from.
    pub base: Option<u32>,
    pub started_ms: u64,
    /// What was asked for, oldest first.
    pub asks: Vec<Ask>,
    /// The agent chat doing the work; the next ask continues it.
    pub session: Option<String>,
}

impl From<&Draft> for DraftInfo {
    fn from(draft: &Draft) -> DraftInfo {
        DraftInfo {
            base: draft.base,
            started_ms: draft.started_ms,
            asks: draft.asks.clone(),
            session: draft.session.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Begun {
    pub draft: DraftInfo,
    /// Generation 1 was recorded now: the setup before any customization.
    pub baseline: Option<u32>,
    /// Hand edits found outside a draft were recorded as this generation,
    /// so discarding the draft returns to them, not past them.
    pub by_hand: Option<u32>,
    /// The ask joined a draft that was already open.
    pub refined: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Applied {
    /// The generation now current.
    pub generation: Generation,
    /// False when the live tree already was the current generation.
    pub recorded: bool,
    pub changes: Vec<Change>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Restored {
    /// The generation now current and live.
    pub generation: Generation,
    /// Where what was live went, when it differed: roll back to it to get
    /// it back.
    pub kept_as: Option<u32>,
    /// What changed on disk, as seen from before the restore.
    pub changes: Vec<Change>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct History {
    pub current: Option<u32>,
    /// Newest first.
    pub generations: Vec<Generation>,
}

#[derive(Debug)]
pub enum Error {
    /// No home folder, so no customization to find.
    NoHome,
    Io(std::io::Error),
    /// The live tree does not validate; nothing was recorded.
    Invalid(Vec<Problem>),
    NoSuchGeneration(u32),
    /// There is no earlier generation.
    NothingEarlier,
    Profile(String),
    /// Files cmux keeps no copy of (too large, too many, behind a linked
    /// folder) stand where a restore or an import would write; nothing was
    /// changed.
    Untracked(Vec<Skipped>),
}

impl Error {
    /// The stable code the CLI and MCP print.
    pub fn code(&self) -> &'static str {
        match self {
            Error::NoHome => "customize.no_home",
            Error::Io(_) => "customize.io",
            Error::Invalid(_) => "customize.invalid",
            Error::NoSuchGeneration(_) => "customize.no_such_generation",
            Error::NothingEarlier => "customize.nothing_earlier",
            Error::Profile(_) => "customize.profile",
            Error::Untracked(_) => "customize.untracked",
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NoHome => f.write_str("no home folder: set HOME"),
            Error::Io(error) => write!(f, "{error}"),
            Error::Invalid(problems) => {
                write!(
                    f,
                    "{} to fix before this applies (the preview stays live):",
                    count(problems.len(), "problem")
                )?;
                for problem in problems {
                    write!(f, "\n  {}", problem.line())?;
                }
                Ok(())
            }
            Error::NoSuchGeneration(n) => {
                write!(f, "there is no generation {n}; `cmux customize generations` lists them")
            }
            Error::NothingEarlier => f.write_str("there is no earlier generation to roll back to"),
            Error::Profile(why) => f.write_str(why),
            Error::Untracked(files) => {
                write!(
                    f,
                    "nothing was changed: this would write over {} cmux keeps no copy of, so it could not be brought back. Move or shrink it (or make a linked folder a real one) first:",
                    count(files.len(), "file")
                )?;
                for file in files {
                    write!(f, "\n  {} ({})", file.path, file.reason)?;
                }
                Ok(())
            }
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Error {
        Error::Io(error)
    }
}

/// `1 problem`, `3 problems`.
pub fn count(n: usize, noun: &str) -> String {
    if n == 1 { format!("1 {noun}") } else { format!("{n} {noun}s") }
}
