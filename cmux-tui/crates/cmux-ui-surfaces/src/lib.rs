//! Agent UI surfaces (plans/cmux-next/agent-ui-surfaces-DESIGN.md): A2UI 1.0
//! messages and MCP Apps resources in, the normalized `cmux.ui-surface/1`
//! model out. Everything here is a function of its inputs: no network, no
//! disk, no clock, no randomness. The acpmux daemon does the I/O; this crate
//! decides what is drawn, what a button may send, and holds the data model so
//! a renderer never builds a payload.
//!
//! Trust rules (cmuxterm-hq docs/probes/6236-31): data only, strict
//! validation, unknown input degrades to inert `fallback` text, every
//! outbound effect goes through [`store::SurfaceStore::confirm`].

pub mod a2ui;
pub mod actions;
pub mod catalog;
pub mod coalesce;
pub mod functions;
pub mod mcp_apps;
pub mod model;
pub mod pointer;
pub mod store;
mod text;

pub use model::{Node, NodeKind, Pending, SCHEMA, Surface};
pub use store::SurfaceStore;

/// The caps from the design ("Trust and permission mediation").
pub mod caps {
    /// Component definitions held per surface.
    pub const COMPONENTS: usize = 512;
    /// Nesting depth of the drawn tree.
    pub const DEPTH: usize = 32;
    pub const TABLE_ROWS: usize = 200;
    /// Chart points across every series of one chart.
    pub const CHART_POINTS: usize = 1_000;
    /// Bytes per string; longer strings are cut with an ellipsis.
    pub const STRING_BYTES: usize = 4 * 1024;
    /// Bytes per normalized surface (and per held data model).
    pub const SURFACE_BYTES: usize = 256 * 1024;
    /// Drawn nodes per surface once templates expand (the byte cap usually
    /// bites first).
    pub const NODES: usize = 4 * COMPONENTS;
    /// Pattern length for the `regex` function.
    pub const REGEX_PATTERN: usize = 256;
    /// MCP App frame height clamp, px.
    pub const FRAME_MIN_HEIGHT: u32 = 40;
    pub const FRAME_MAX_HEIGHT: u32 = 1_200;
    /// Surfaces one store holds (a session); the oldest is dropped past it.
    pub const SURFACES: usize = 64;
}

/// Why an input or an action was refused. The text is plain and shown to the
/// person or returned to the agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal(pub String);

impl Refusal {
    pub(crate) fn new(text: impl Into<String>) -> Self {
        Self(text.into())
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refusal {}
