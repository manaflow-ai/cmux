//! The search-everything index (plans/cmux-next/search-everything-DESIGN.md).
//!
//! The cmux-tui daemon owns one [`SearchEngine`]. It appends content docs
//! (terminal scrollback, full-screen TUI frames, finished commands, agent
//! chats, Chief messages and memory, file text) and keeps names (workspaces,
//! tabs, panes, file paths, pages) up to date. A query returns one list,
//! names and content ranked together on shared match tiers.
//!
//! Ranking uses every signal (design 7.3): the match tier (exact, phrase,
//! word starts, anywhere, fuzzy) and where the match falls, the hit's kind,
//! words that name its place ([`TargetContext`]: workspace, group, title,
//! folder, git branch, agent), recency, opens (frecency), focus history and
//! the current workspace.
//!
//! Content is found through trigram -> block postings (zoekt / Code Search
//! shape): docs are packed into ~16 KiB blocks, a query intersects the block
//! lists of its trigrams, rarest first, then verifies candidate blocks newest
//! first with a SIMD substring scan and stops once it has enough hits. Names
//! match fzf / VS Code style (word starts, camel humps, basenames).
//!
//! ```
//! use cmux_search::{Doc, EngineConfig, Kind, Query, SearchEngine};
//!
//! let mut engine = SearchEngine::new(EngineConfig::default());
//! engine.append(Doc {
//!     kind: Kind::Scrollback,
//!     source: "term:1".into(),
//!     target: "term:1".into(),
//!     position: Some(120),
//!     title: "zsh".into(),
//!     text: "cargo build\nerror: migration 0042 failed".into(),
//!     at_ms: 1_000,
//!     key: None,
//! });
//! let result = engine.search(&Query::new("migrat", 2_000));
//! assert_eq!(result.hits[0].line, 1);
//! assert_eq!(result.hits[0].snippet, "error: migration 0042 failed");
//! ```

mod context;
mod corpus;
mod engine;
mod fold;
mod frames;
mod frecency;
mod kind;
mod names;
mod persist;
mod segment;
mod trigram;

pub use context::TargetContext;
pub use corpus::SyntheticCorpus;
pub use engine::{
    Doc, EngineConfig, Hit, Query, Retired, SealDone, SealJob, SearchEngine, SearchResult, Stats,
};
pub use fold::fold;
pub use frames::ScreenFrames;
pub use kind::{Kind, Scope};
pub use names::NameDoc;
