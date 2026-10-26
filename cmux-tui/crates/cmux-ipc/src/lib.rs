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

#![forbid(unsafe_code)]
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

pub mod frame;
pub mod reader;

pub use frame::{
    Aux, AuxClass, BadMessage, CallAux, CallFlags, Frame, FrameHeader, FrameKind, HEADER_LEN,
    MAGIC, MAX_FRAME_PAYLOAD, PriorityHint,
};
pub use reader::{FrameReader, MAX_JSON_LINE, Message, ReaderLimits};

#[cfg(test)]
mod cmux_ipc_tests;
