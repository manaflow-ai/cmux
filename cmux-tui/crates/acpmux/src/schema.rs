//! The RPC surface as a checked-in JSON document, embedded so
//! `acpmux daemon schema` always matches the running binary.

pub static SCHEMA: cmux_embed::PackedStr =
    cmux_embed::packed_str!(include_str!("../docs/acpmux-schema.json"));
