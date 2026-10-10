//! The RPC surface as a checked-in JSON document, embedded so
//! `acpmux daemon schema` always matches the running binary.

pub const SCHEMA: &str = include_str!("../docs/acpmux-schema.json");
