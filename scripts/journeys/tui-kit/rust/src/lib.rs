//! The TUI load kit's compiled programs (scripts/journeys/tui-kit): the same seeded output as the
//! Python programs, at a held rate. Python keeps the seed and the layout (tuikit.py computes the
//! seeded style and passes it on the command line); this crate draws and paces.

pub mod args;
pub mod beacon;
pub mod gradient;
pub mod jsonl;
pub mod pace;
pub mod storm;
pub mod sys;
