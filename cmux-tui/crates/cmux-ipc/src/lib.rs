//! Binary frames for the one app-daemon connection
//! (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.2; spec/transports.md,
//! "Binary frames").
//!
//! A connection carries UTF-8 JSON lines, as it does today, and after
//! negotiation also frames: a 16-byte header (`frame::FrameHeader`) and a
//! payload. Routing reads only the header. This crate is pure: no I/O beyond
//! `std::io::Read`, no threads, no panics on peer input; every refusal is a
//! typed `BadMessage` that closes the connection.
//!
//! The Swift reader (CmuxNextIPC) and this crate share the golden vectors in
//! spec/fixtures/ipc-frames.
//!
//! Bindings come from the schema at build time (section 3.3): `build.rs`
//! reads spec/sdk-schema.json and spec/resource-operations-v2.json and writes
//! Rust into OUT_DIR, never into git. `schema::SCHEMA_IDENTITY` names the
//! schema bytes a build compiled.
//!
//! `methods` holds the schema's method tables (design 3.3), one more
//! build.rs emitter over the same parsed schemas. `server_families` exports
//! the macros that generate the daemon's request params and `Command`
//! variants for the families in `server-families.json` (task 026).
//!
//! `client` (feature `client`) holds the generated request types of the
//! `cli` client: one struct per command, with its wire name and method id.
//!
//! [`fds`] passes file descriptors with `SCM_RIGHTS` and queues the ones that
//! arrive in order: the holder link uses it, and so do the daemon's frame lanes.
//! It is the only module with `unsafe` (libc `sendmsg`/`recvmsg`).
//!
//! [`lane_writer`] is the outbound priority policy (design 3.4): input
//! streams, then the one control FIFO, then bulk, then background, with
//! per-stream turns, a starvation bound, chunking and a byte bound.

#![deny(unsafe_code)]
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::unreachable,
    clippy::todo,
    clippy::unimplemented,
    clippy::indexing_slicing,
    clippy::string_slice,
    clippy::panic_in_result_fn
)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        reason = "tests assert by panicking"
    )
)]

#[cfg(feature = "client")]
pub mod client;
#[cfg(unix)]
#[allow(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "SCM_RIGHTS needs libc sendmsg/recvmsg and CMSG macros; its two slices are bounded by the lengths they are cut from"
)]
pub mod fds;
pub mod frame;
pub mod lane_writer;
pub mod methods;
pub mod reader;
pub mod schema;
mod schema_digest;
mod server_families;

pub use frame::{
    Aux, AuxClass, BadMessage, CallAux, CallFlags, Frame, FrameHeader, FrameKind, HEADER_LEN,
    MAGIC, MAX_FRAME_PAYLOAD, PriorityHint,
};
pub use lane_writer::{
    CoalesceKey, EndReason, EndedStream, Lane, LaneError, LaneWriter, LaneWriterConfig, Pushed,
    StreamLane,
};
pub use methods::{
    Coalesce, Durability, EventAttrs, EventId, FamilyTable, MethodAttrs, MethodId, MethodTables,
    Ordering, Payload,
};
pub use reader::{FrameReader, MAX_JSON_LINE, Message, ReaderLimits};
pub use schema::{SCHEMA_IDENTITY, SchemaIdentity};

#[cfg(test)]
mod cmux_ipc_tests;
