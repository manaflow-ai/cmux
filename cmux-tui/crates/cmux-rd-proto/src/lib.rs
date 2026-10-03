//! Wire formats of the cmux remote desktop protocol, `cmux.rd/1`.
//!
//! Media, input, cursor position and feedback travel as datagrams inside the
//! viewer's WireGuard overlay session, on overlay port [`OVERLAY_PORT`]
//! (service [`SERVICE_NAME`]). Every datagram starts with a 16-byte
//! [`DatagramHeader`]. A video frame is one [`FrameBody`] split over the data
//! packets of that frame, plus optional parity packets. All integers are
//! little-endian. This crate does no I/O.

mod datagram;
mod error;
mod feedback;
mod frame;
mod input;

pub use datagram::{DatagramHeader, DatagramKind, HEADER_LEN, VERSION, flags};
pub use error::DecodeError;
pub use feedback::{Arrival, Feedback, Nack};
pub use frame::{FRAME_PREFIX_LEN, FrameBody, REF_NONE};
pub use input::{InputEvent, InputPacket, MAX_TEXT_BYTES};

/// Overlay UDP port of the remote desktop service (transport.md section 12b).
pub const OVERLAY_PORT: u16 = 4103;

/// Service name the network policy uses for [`OVERLAY_PORT`].
pub const SERVICE_NAME: &str = "remote-desktop";

/// Largest datagram on a session that may use the Freestyle (VPC) path.
pub const MAX_DATAGRAM_VPC: usize = 1152;

/// Largest datagram on every other session.
pub const MAX_DATAGRAM_DEFAULT: usize = 1332;
