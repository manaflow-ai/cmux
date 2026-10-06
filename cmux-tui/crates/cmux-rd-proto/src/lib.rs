//! Wire formats of the cmux remote desktop protocol, `cmux.rd/1`.
//!
//! Media, input, cursor position and feedback travel as datagrams inside the
//! viewer's WireGuard overlay session, on overlay port [`OVERLAY_PORT`]
//! (service [`SERVICE_NAME`]). Every datagram starts with a 16-byte
//! [`DatagramHeader`]. A video frame is one [`FrameBody`] split over the data
//! packets of that frame, plus optional parity packets. All integers are
//! little-endian. This crate does no I/O.

#[cfg(feature = "serde")]
pub mod control;
mod datagram;
mod error;
mod feedback;
mod frame;
mod input;
mod stream;

pub use datagram::{
    DatagramHeader, DatagramKind, HEADER_LEN, MAX_FEC_BLOCK, MAX_FRAME_SHARDS, VERSION, flags,
};
pub use error::DecodeError;
pub use feedback::{Arrival, Feedback, MAX_ARRIVALS, MAX_NACK_FRAMES, MAX_NACK_INDEXES, Nack};
pub use frame::{FRAME_PREFIX_LEN, FrameBody, REF_NONE};
pub use input::{
    INPUT_PACKET_PREFIX_LEN, InputEvent, InputPacket, MAX_SERVICE_BYTES, MAX_TEXT_BYTES,
    service_flags,
};
pub use stream::{
    MAX_STREAM_FRAME, STREAM_CONTROL, STREAM_DATAGRAM, STREAM_PREFIX_LEN, StreamDeframer,
    encode_stream_frame,
};

/// The remote desktop service: the hello default (rd change C1).
pub const SERVICE_DESKTOP: &str = "desktop";
/// The remote browser tab service (`cmux.rb/1`).
pub const SERVICE_REMOTE_BROWSER: &str = "rb/1";

/// Overlay UDP port of the remote desktop service (transport.md section 12b).
pub const OVERLAY_PORT: u16 = 4103;

/// Service name the network policy uses for [`OVERLAY_PORT`].
pub const SERVICE_NAME: &str = "remote-desktop";

/// Largest datagram on a session that may use the Freestyle (VPC) path.
pub const MAX_DATAGRAM_VPC: usize = 1152;

/// Largest datagram on every other session.
pub const MAX_DATAGRAM_DEFAULT: usize = 1332;
