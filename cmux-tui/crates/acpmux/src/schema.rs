//! The RPC surface as a checked-in JSON document, embedded so
//! `acpmux daemon schema` always matches the running binary. A test fails
//! when a method constant is missing from it.

pub const SCHEMA: &str = include_str!("../docs/acpmux-schema.json");
