//! The JSON catalogs the daemon and the CLI both read, compiled in once for both. As plain
//! `include_str!` text in each reader they were 7.6 MB of the binary, the resource and action
//! catalogs twice. The action and Cloud catalogs are compressed (cmux-embed): each reader parses
//! its catalog once and keeps the parse, so it inflates with `inflate()` and drops the text.

use cmux_embed::{PackedStr, packed_str};

/// The v2 resource operation catalog (cmux-tui/spec/resource-operations-v2.json), 1.3 MB, kept
/// as plain text in the binary and not compressed: `cmux mcp serve` (one per agent) indexes it
/// by borrowing raw slices for its whole life (cli/mcp/v2_tools.rs). Compressed, every server
/// would inflate its own 1.3 MB heap copy; plain, they all share the binary's clean pages.
pub static RESOURCE_OPERATIONS_V2: &str = include_str!("../../../spec/resource-operations-v2.json");

/// The action catalog (plans/cmux-next/action-surfaces.json).
pub static ACTION_SURFACES: PackedStr =
    packed_str!(include_str!("../../../../plans/cmux-next/action-surfaces.json"));

/// The generated Cloud operation catalog (backend/catalog/cloud-operations.json).
pub static CLOUD_OPERATIONS: PackedStr =
    packed_str!(include_str!("../../../../backend/catalog/cloud-operations.json"));
