//! Claude Code and Codex customization from cmux NEXT (`cmux agent-config`, Settings > Claude
//! Code & Codex, behind Labs `labs.agentCustomization`).
//!
//! Leo, 2026-11-19: "the customization with, like, getting, like, Claude Code, getting Codex ...
//! when I say Claude Code, when I say Codex ... I need you guys to be, like, doing the thing."
//!
//! Each part reads and writes the agent's own files, as the agent's own CLI does, so a change made
//! here is the change the agent sees and a change made in the agent shows here. One module per
//! part: [`settings`] (each agent's effective settings and the curated keys cmux edits). Writes keep
//! what cmux does not know (key order, comments, unknown keys), are atomic, and back up the prior
//! file ([`write`]).

pub mod paths;
pub mod settings;
pub mod write;

pub use paths::Homes;
