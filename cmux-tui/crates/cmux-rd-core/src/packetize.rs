//! Splits one encoded frame into `cmux.rd/1` datagrams: data shards sized to
//! the session's `max_datagram`, then parity shards of the same size.

use cmux_rd_proto::{DatagramHeader, DatagramKind, FrameBody, HEADER_LEN, MAX_FRAME_SHARDS};

use crate::fec::{self, FecError, MAX_SHARDS};

/// Packetizer state for one display stream.
#[derive(Debug, Clone)]
pub struct Packetizer {
    stream: u16,
    max_datagram: usize,
    next_transport_seq: u16,
}

/// The datagrams of one frame, ready to send in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketizedFrame {
    pub frame: u32,
    pub datagrams: Vec<Vec<u8>>,
    /// Transport sequence number of the first datagram (they are consecutive).
    pub first_transport_seq: u16,
    pub data_shards: u16,
    pub parity_shards: u16,
}

/// Why a frame cannot be packetized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PacketizeError {
    /// The frame needs more than `MAX_FRAME_SHARDS` shards at this datagram size.
    FrameTooLarge,
    Fec(FecError),
}

impl Packetizer {
    /// `max_datagram` comes from the link (1152 or 1332 bytes); tests may use
    /// smaller values, never below 64.
    pub fn new(stream: u16, max_datagram: usize) -> Self {
        Self { stream, max_datagram: max_datagram.max(64), next_transport_seq: 0 }
    }

    /// Payload bytes per shard.
    pub fn shard_len(&self) -> usize {
        self.max_datagram - HEADER_LEN
    }

    /// Reserves `n` transport sequence numbers for datagrams that are not
    /// frame shards (input acks, cursor, probes) and returns the first.
    pub fn reserve_transport_seq(&mut self, n: u16) -> u16 {
        let first = self.next_transport_seq;
        self.next_transport_seq = self.next_transport_seq.wrapping_add(n);
        first
    }

    /// Splits `body` into data shards plus `parity` parity shards.
    pub fn packetize(
        &mut self,
        frame: u32,
        flags: u8,
        body: &FrameBody,
        parity: usize,
    ) -> Result<PacketizedFrame, PacketizeError> {
        let bytes = body.encode();
        let shard_len = self.shard_len();
        let data_shards = bytes.len().div_ceil(shard_len).max(1);
        if data_shards > MAX_FRAME_SHARDS as usize {
            return Err(PacketizeError::FrameTooLarge);
        }
        // A frame larger than one FEC block (a big keyframe) goes without parity; NACKs
        // and recovery cover its losses.
        let parity = if data_shards + parity > MAX_SHARDS { 0 } else { parity };
        let mut shards: Vec<Vec<u8>> = bytes.chunks(shard_len).map(<[u8]>::to_vec).collect();
        if shards.is_empty() {
            shards.push(Vec::new());
        }
        if let Some(last) = shards.last_mut() {
            last.resize(shard_len, 0);
        }
        let parity_shards = if parity == 0 {
            Vec::new()
        } else {
            let refs: Vec<&[u8]> = shards.iter().map(Vec::as_slice).collect();
            fec::encode(&refs, parity).map_err(PacketizeError::Fec)?
        };
        let count = data_shards as u16;
        let fec_count = parity as u16;
        let first_transport_seq = self.reserve_transport_seq(count + fec_count);
        let datagrams = shards
            .iter()
            .chain(parity_shards.iter())
            .enumerate()
            .map(|(index, payload)| {
                let header = DatagramHeader {
                    flags,
                    kind: if index < data_shards { DatagramKind::Video } else { DatagramKind::Fec },
                    stream: self.stream,
                    frame,
                    index: index as u16,
                    count,
                    fec_count,
                    transport_seq: first_transport_seq.wrapping_add(index as u16),
                };
                let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
                header.encode_into(&mut out);
                out.extend_from_slice(payload);
                out
            })
            .collect();
        Ok(PacketizedFrame {
            frame,
            datagrams,
            first_transport_seq,
            data_shards: count,
            parity_shards: fec_count,
        })
    }
}

/// Parity shards for a frame of `data_shards` shards at a measured loss rate
/// (0.0 to 1.0): none on a clean path, then 10 % to 50 % of the data shards,
/// at least one shard for keyframes and refinement frames on a lossy path.
pub fn parity_for(data_shards: usize, loss: f64, important: bool) -> usize {
    if loss <= 0.001 {
        return 0;
    }
    let ratio = (loss * 3.0).clamp(0.10, 0.50);
    let n = (data_shards as f64 * ratio).ceil() as usize;
    let n = if important { n.max(1) } else { n };
    n.min(MAX_SHARDS.saturating_sub(data_shards))
}
