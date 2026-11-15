//! Computer use for agents as leased desktops (cmuxterm-hq#8741).
//!
//! Leo, 2026-11-12: "And if we, like, evict as they come, it's interesting, and we can sort of
//! almost give, like, computer use to your agents as a service on macOS due to that sort of
//! framing, right?"
//!
//! An agent leases a slot ([`pool::Pool::lease`]), acts on it ([`pool::Pool::act`]: resume,
//! act, screenshot, then suspend again while the model thinks) and releases it. A host keeps
//! N slots warm and suspended; over its RAM budget the least recently used suspended slot goes
//! down a tier. Backends ([`backend::Backend`]) are pluggable: Linux desktops in cgroups now
//! ([`linux`]), macOS slots later.

pub mod backend;
pub mod journey;
pub mod linux;
pub mod mcp;
pub mod pool;
pub mod server;

/// The JSON value at `pointer` (RFC 6901, e.g. `/lease/slot`), or `null` when it is absent.
/// Reads JSON without `value["key"]` indexing, which the panic ratchet counts.
pub fn at<'a>(value: &'a serde_json::Value, pointer: &str) -> &'a serde_json::Value {
    static NULL: serde_json::Value = serde_json::Value::Null;
    value.pointer(pointer).unwrap_or(&NULL)
}
