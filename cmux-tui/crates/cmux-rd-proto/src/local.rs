//! The viewer's local hop (design D7, screen-share-under-100ms.md): `cmux-rd connect`
//! reassembles a display stream itself and hands the app complete frames, newest only,
//! instead of datagrams. Both frame types ride the same `u8 type, u32 len` stream as
//! control and datagram frames, only between `connect` and the app on one Mac, and only
//! after the app asked for them (its answer line's `assemble`): a host never sends or
//! reads them.

use crate::error::{DecodeError, Reader};
use crate::frame::FrameBody;

/// Stream frame type of one complete frame the connect process reassembled ([`LocalFrame`]).
pub const STREAM_LOCAL_FRAME: u8 = 4;
/// Stream frame type of one report from the app back to the connect process ([`LocalReport`]).
pub const STREAM_LOCAL_REPORT: u8 = 5;
/// Largest [`STREAM_LOCAL_FRAME`] payload: a whole keyframe, not one datagram.
pub const MAX_LOCAL_FRAME: usize = 16 << 20;
/// Size of a [`LocalFrame`]'s prefix in front of its [`FrameBody`].
pub const LOCAL_FRAME_PREFIX_LEN: usize = 44;

/// The connect process's receive counters for a stream, carried on every frame so the
/// app's stats read what the reassembler saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LocalCounters {
    /// The last frame the reassembler released (the feedback's acked frame).
    pub acked_frame: u32,
    pub need_recovery: bool,
    /// Frames released by the reassembler.
    pub frames_released: u64,
    /// Frames that never reached the app: lost on the path, or replaced in the connect
    /// process by a newer frame the app could decode instead.
    pub frames_lost: u64,
}

/// One complete frame of `stream`, released by the connect process at `release_us`
/// (`CLOCK_UPTIME_RAW` microseconds: on a Mac the same clock as the app's
/// `DispatchTime.uptimeNanoseconds` and Core Animation's media time).
///
/// Layout: `u16 stream`, `u32 frame`, `u8 flags`, `u8 need_recovery`, `u64 release_us`,
/// `u32 acked_frame`, `u64 frames_released`, `u64 frames_lost`, `u64 reserved`, then the
/// [`FrameBody`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalFrame {
    pub stream: u16,
    pub frame: u32,
    pub flags: u8,
    pub release_us: u64,
    pub counters: LocalCounters,
    pub body: FrameBody,
}

impl LocalFrame {
    pub fn encode(&self) -> Vec<u8> {
        let body = self.body.encode();
        let mut out = Vec::with_capacity(LOCAL_FRAME_PREFIX_LEN + body.len());
        out.extend_from_slice(&self.stream.to_le_bytes());
        out.extend_from_slice(&self.frame.to_le_bytes());
        out.push(self.flags);
        out.push(u8::from(self.counters.need_recovery));
        out.extend_from_slice(&self.release_us.to_le_bytes());
        out.extend_from_slice(&self.counters.acked_frame.to_le_bytes());
        out.extend_from_slice(&self.counters.frames_released.to_le_bytes());
        out.extend_from_slice(&self.counters.frames_lost.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());
        out.extend_from_slice(&body);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let stream = r.u16()?;
        let frame = r.u32()?;
        let flags = r.u8()?;
        let need_recovery = r.u8()? != 0;
        let release_us = r.u64()?;
        let acked_frame = r.u32()?;
        let frames_released = r.u64()?;
        let frames_lost = r.u64()?;
        let _reserved = r.u64()?;
        let body = FrameBody::decode(r.rest())?;
        Ok(Self {
            stream,
            frame,
            flags,
            release_us,
            counters: LocalCounters { acked_frame, need_recovery, frames_released, frames_lost },
            body,
        })
    }
}

/// What the app tells the connect process about one frame of a stream it reassembles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalReport {
    /// The app took `frame` off the hop and its decoder finished with it (decoded, or
    /// skipped while it waits for a keyframe: `decode_us` 0). The connect process then
    /// sends the next frame: at most one frame is between the two processes.
    Consumed { stream: u16, frame: u32, decode_us: u32 },
    /// `frame` reached the glass at `presented_us` (the drawable's presented time, same
    /// clock as [`LocalFrame::release_us`]).
    Presented { stream: u16, frame: u32, presented_us: u64 },
    /// The decoder needs a keyframe or recovery frame on `stream` (a decode error).
    KeyframeWanted { stream: u16 },
}

const REPORT_CONSUMED: u8 = 1;
const REPORT_PRESENTED: u8 = 2;
const REPORT_KEYFRAME: u8 = 3;
/// Every report is this long: `u8 kind`, `u8 0`, `u16 stream`, `u32 frame`, `u64 value`.
pub const LOCAL_REPORT_LEN: usize = 16;

impl LocalReport {
    pub fn stream(&self) -> u16 {
        match *self {
            Self::Consumed { stream, .. }
            | Self::Presented { stream, .. }
            | Self::KeyframeWanted { stream } => stream,
        }
    }

    pub fn encode(&self) -> [u8; LOCAL_REPORT_LEN] {
        let (kind, stream, frame, value) = match *self {
            Self::Consumed { stream, frame, decode_us } => {
                (REPORT_CONSUMED, stream, frame, u64::from(decode_us))
            }
            Self::Presented { stream, frame, presented_us } => {
                (REPORT_PRESENTED, stream, frame, presented_us)
            }
            Self::KeyframeWanted { stream } => (REPORT_KEYFRAME, stream, 0, 0),
        };
        let mut out = [0u8; LOCAL_REPORT_LEN];
        out[0] = kind;
        out[2..4].copy_from_slice(&stream.to_le_bytes());
        out[4..8].copy_from_slice(&frame.to_le_bytes());
        out[8..16].copy_from_slice(&value.to_le_bytes());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let kind = r.u8()?;
        let _pad = r.u8()?;
        let stream = r.u16()?;
        let frame = r.u32()?;
        let value = r.u64()?;
        Ok(match kind {
            REPORT_CONSUMED => Self::Consumed {
                stream,
                frame,
                decode_us: u32::try_from(value).unwrap_or(u32::MAX),
            },
            REPORT_PRESENTED => Self::Presented { stream, frame, presented_us: value },
            REPORT_KEYFRAME => Self::KeyframeWanted { stream },
            _ => return Err(DecodeError::Invalid("local report kind")),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_frame_round_trips() {
        let f = LocalFrame {
            stream: 3,
            frame: 77,
            flags: crate::flags::KEYFRAME,
            release_us: 123_456_789,
            counters: LocalCounters {
                acked_frame: 76,
                need_recovery: true,
                frames_released: 70,
                frames_lost: 6,
            },
            body: FrameBody {
                t_capture_us: 42,
                ref_frame: crate::REF_NONE,
                access_unit: vec![1, 2, 3],
            },
        };
        let bytes = f.encode();
        assert_eq!(bytes.len(), LOCAL_FRAME_PREFIX_LEN + crate::FRAME_PREFIX_LEN + 3);
        assert_eq!(LocalFrame::decode(&bytes).unwrap(), f);
        assert!(LocalFrame::decode(&bytes[..LOCAL_FRAME_PREFIX_LEN - 1]).is_err());
    }

    #[test]
    fn local_reports_round_trip() {
        for r in [
            LocalReport::Consumed { stream: 0, frame: 9, decode_us: 3_100 },
            LocalReport::Presented { stream: 1, frame: 9, presented_us: u64::MAX - 1 },
            LocalReport::KeyframeWanted { stream: 2 },
        ] {
            assert_eq!(LocalReport::decode(&r.encode()).unwrap(), r);
        }
        let mut bad = LocalReport::KeyframeWanted { stream: 0 }.encode();
        bad[0] = 9;
        assert!(LocalReport::decode(&bad).is_err());
    }
}
