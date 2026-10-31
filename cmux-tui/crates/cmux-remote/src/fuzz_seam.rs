//! Fuzz seam, compiled only under `--cfg fuzzing` (cargo-fuzz sets it; no
//! shipped or test build has it). It exposes the mux line codec: the `CMXL`
//! packets that carry each JSON line (the daemon's events and replies on the
//! download side, requests on the upload side) and the assembler that joins
//! a line's parts, in any order, across interleaved messages.

use bytes::Bytes;
use cmux_remote_protocol::Lane;

use crate::mux_codec::{self, MuxLineAssembler};

pub use crate::mux_codec::MuxCodecError;

/// The download-side line limit, the largest a client assembler accepts.
pub const MAX_DOWNLOAD_LINE_BYTES: usize = mux_codec::MAX_MUX_DOWNLOAD_LINE_BYTES;

/// Split `line` into its packets, as the sending side does.
pub fn encode_line(message: u64, line: &[u8], maximum: usize) -> Result<Vec<Bytes>, MuxCodecError> {
    mux_codec::encode_line_with_limit(message, line, maximum)
}

/// A client's line assembler with `maximum` bytes per line.
pub struct Assembler(MuxLineAssembler<()>);

impl Assembler {
    pub fn new(maximum: usize) -> Self {
        Self(MuxLineAssembler::with_maximum(maximum))
    }

    /// One packet on `lane`: a completed line's lane and bytes, or `None`
    /// while parts are missing.
    pub fn push(
        &mut self,
        lane: Lane,
        packet: Bytes,
    ) -> Result<Option<(Lane, Bytes)>, MuxCodecError> {
        Ok(self
            .0
            .push_retaining(lane, packet, ())?
            .map(|line| (line.lane(), line.payload().clone())))
    }

    /// Lines with parts still missing, and the bytes they hold.
    pub fn in_flight(&self) -> (usize, usize) {
        self.0.in_flight()
    }
}
