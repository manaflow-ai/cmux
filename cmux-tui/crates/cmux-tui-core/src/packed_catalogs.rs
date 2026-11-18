//! The JSON catalogs the daemon and the CLI both read, compiled in compressed
//! (cmux-embed) once for both. As plain `include_str!` text they were 7.6 MB of
//! the binary, the resource and action catalogs twice; packed they are about
//! 300 KB. Each reader parses its catalog once and keeps the parse, so it
//! inflates with `inflate()` and drops the text; a reader that borrows from
//! the text for the life of the process uses `get()`.

use cmux_embed::{PackedStr, packed_str};

/// The v2 resource operation catalog (cmux-tui/spec/resource-operations-v2.json).
pub static RESOURCE_OPERATIONS_V2: PackedStr =
    packed_str!(include_str!("../../../spec/resource-operations-v2.json"));

/// The action catalog (plans/cmux-next/action-surfaces.json).
pub static ACTION_SURFACES: PackedStr =
    packed_str!(include_str!("../../../../plans/cmux-next/action-surfaces.json"));

/// The generated Cloud operation catalog (backend/catalog/cloud-operations.json).
pub static CLOUD_OPERATIONS: PackedStr =
    packed_str!(include_str!("../../../../backend/catalog/cloud-operations.json"));
