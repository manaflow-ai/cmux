//! The three-way hub (RFD 0142 R6): the Mac and the AutoCloud VM both send a
//! session's events to one relay room; the relay forwards each viewer (the
//! phone) the newer `(epoch, seq)` of the two once and drops the older copy,
//! so the phone downloads one stream while the other source stays a warm
//! standby. When the Mac sleeps mid-turn the VM's frames are already the
//! newest and keep flowing, with no redial.
//!
//! A hub event rides a relay frame of kind [`crate::FrameKind::Hub`]. Its
//! payload is
//!
//! `[u8 hub header version = 1][16-byte session id][u64 BE epoch][u64 BE seq]
//! [u8 source role: 1 mac, 2 vm][u8 to: 0 viewers, 1 mac, 2 vm][sealed body]`
//!
//! The first 35 bytes are the clear [`HubHeader`]: the only thing the relay
//! reads. `to` is 0 for the viewer stream (the relay keeps the newest) and
//! names the other source for Mac-to-VM sync when the two have no direct path
//! (forwarded as is). The body is sealed end to end by the source with the
//! session's [`HubKey`] (XChaCha20-Poly1305), which the relay never holds
//! (RFD 0142 section 1: "the relay holds no key that decrypts or
//! authenticates session content"). The whole clear header is the seal's
//! associated data and fixes its nonce, and the plaintext repeats the
//! `(session, epoch, seq, source)` triple, so a relay that edits, swaps or
//! replays a header is caught by [`open`] and the viewer's
//! [`crate::hub_truth::TruthTracker`]. A lying relay can still delay or drop,
//! which it always could.
//!
//! Lockstep: hub rooms are joined with the [`HUB_SUBPROTOCOL`] offered; a
//! relay without hub support has no hub route, or (a two-party `LinkRelay`)
//! answers a kind 5 frame with `bad_frame:kind`. [`hub_join_outcome`] and
//! [`relay_error_means_no_hub`] turn either into [`HubJoin::Fallback`], and
//! the client keeps today's per-source path.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

use crate::relay_frame::{RELAY_FRAME_MAX_PAYLOAD, RelayFrameError};
use crate::{FrameKind, PeerId, RelayFrame};

pub const HUB_HEADER_VERSION: u8 = 1;
/// `version + session + epoch + seq + source + to`.
pub const HUB_HEADER_LEN: usize = 1 + 16 + 8 + 8 + 1 + 1;
/// The sealed body repeats `session + epoch + seq + source`.
pub const HUB_INNER_LEN: usize = 16 + 8 + 8 + 1;
/// Poly1305 tag.
pub const HUB_TAG_LEN: usize = 16;
/// The largest event one hub frame carries.
pub const HUB_MAX_EVENT: usize =
    RELAY_FRAME_MAX_PAYLOAD - HUB_HEADER_LEN - HUB_INNER_LEN - HUB_TAG_LEN;
/// Bytes a hub frame adds to an event on the wire (relay frame header included).
pub const HUB_FRAME_OVERHEAD: usize =
    crate::relay_frame::RELAY_FRAME_HEADER_LEN + HUB_HEADER_LEN + HUB_INNER_LEN + HUB_TAG_LEN;

/// Offered on a hub join; a relay that echoes it speaks the hub at [`HUB_HEADER_VERSION`].
pub const HUB_SUBPROTOCOL: &str = "cmux-hub.v1";

/// A source of a session's events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum HubRole {
    Mac = 1,
    Vm = 2,
}

impl HubRole {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Mac),
            2 => Some(Self::Vm),
            _ => None,
        }
    }

    /// The other source.
    pub fn other(self) -> Self {
        match self {
            Self::Mac => Self::Vm,
            Self::Vm => Self::Mac,
        }
    }
}

/// Where a hub frame goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HubTo {
    /// The viewer stream: the relay forwards the newest `(epoch, seq)` once.
    Viewers,
    /// Mac-to-VM sync with no direct path: forwarded as is to that source.
    Source(HubRole),
}

impl HubTo {
    fn byte(self) -> u8 {
        match self {
            Self::Viewers => 0,
            Self::Source(role) => role as u8,
        }
    }
}

/// A position in a session's event log: epochs order first (a new owner of
/// the log), then the sequence within the epoch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct HubPos {
    pub epoch: u64,
    pub seq: u64,
}

impl HubPos {
    pub const fn new(epoch: u64, seq: u64) -> Self {
        Self { epoch, seq }
    }
}

/// The clear header of a hub frame: what the relay schedules on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HubHeader {
    pub session: [u8; 16],
    pub pos: HubPos,
    pub source: HubRole,
    pub to: HubTo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubHeaderError {
    Short,
    Version(u8),
    Role(u8),
    /// An unknown target, or a source sending to itself.
    To(u8),
}

impl HubHeader {
    pub fn encode(&self) -> [u8; HUB_HEADER_LEN] {
        let mut out = [0u8; HUB_HEADER_LEN];
        out[0] = HUB_HEADER_VERSION;
        out[1..17].copy_from_slice(&self.session);
        out[17..25].copy_from_slice(&self.pos.epoch.to_be_bytes());
        out[25..33].copy_from_slice(&self.pos.seq.to_be_bytes());
        out[33] = self.source as u8;
        out[34] = self.to.byte();
        out
    }

    /// Decodes the header at the start of a hub payload. Checks in this
    /// order: short, version, role, to.
    pub fn decode(payload: &[u8]) -> Result<Self, HubHeaderError> {
        let Some((head, _)) = payload.split_first_chunk::<HUB_HEADER_LEN>() else {
            return Err(HubHeaderError::Short);
        };
        if head[0] != HUB_HEADER_VERSION {
            return Err(HubHeaderError::Version(head[0]));
        }
        let source = HubRole::from_byte(head[33]).ok_or(HubHeaderError::Role(head[33]))?;
        let to = match head[34] {
            0 => HubTo::Viewers,
            byte => match HubRole::from_byte(byte) {
                Some(role) if role != source => HubTo::Source(role),
                _ => return Err(HubHeaderError::To(byte)),
            },
        };
        let short = HubHeaderError::Short;
        Ok(Self {
            session: take::<16>(head, 1).ok_or(short)?,
            pos: HubPos::new(be_u64(head, 17).ok_or(short)?, be_u64(head, 25).ok_or(short)?),
            source,
            to,
        })
    }
}

/// `N` bytes of `bytes` at `at`, or `None` past its end.
fn take<const N: usize>(bytes: &[u8], at: usize) -> Option<[u8; N]> {
    bytes.get(at..at.checked_add(N)?)?.try_into().ok()
}

/// A big-endian u64 at `at`, or `None` past the end.
fn be_u64(bytes: &[u8], at: usize) -> Option<u64> {
    take::<8>(bytes, at).map(u64::from_be_bytes)
}

/// The session's hub key, held by its sources and viewers and never by a
/// relay. Derive it from the pairing secret the devices already share.
#[derive(Clone)]
pub struct HubKey([u8; 32]);

impl std::fmt::Debug for HubKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HubKey(..)")
    }
}

impl HubKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// One key per session from a 32-byte secret the devices share.
    pub fn derive(secret: &[u8; 32], session: &[u8; 16]) -> Self {
        let mut material = [0u8; 48];
        material[..32].copy_from_slice(secret);
        material[32..].copy_from_slice(session);
        Self(blake3::derive_key("cmux relay hub v1 session key", &material))
    }
}

fn nonce(header: &HubHeader) -> XNonce {
    // Unique per (source, to, epoch, seq): a source never seals two different
    // events at one position, and the two sources never share a nonce.
    let mut n = [0u8; 24];
    n[0] = header.source as u8;
    n[1] = header.to.byte();
    n[2..10].copy_from_slice(&header.pos.epoch.to_be_bytes());
    n[10..18].copy_from_slice(&header.pos.seq.to_be_bytes());
    XNonce::from(n)
}

fn inner(header: &HubHeader) -> [u8; HUB_INNER_LEN] {
    let mut out = [0u8; HUB_INNER_LEN];
    out[..16].copy_from_slice(&header.session);
    out[16..24].copy_from_slice(&header.pos.epoch.to_be_bytes());
    out[24..32].copy_from_slice(&header.pos.seq.to_be_bytes());
    out[32] = header.source as u8;
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubSealError {
    TooLarge(usize),
    /// The AEAD refused (it does not for any length that fits a frame).
    Seal,
}

/// The hub payload of one event: the clear header, then the body sealed to
/// the session's viewers with the header as associated data.
pub fn seal(key: &HubKey, header: &HubHeader, event: &[u8]) -> Result<Vec<u8>, HubSealError> {
    if event.len() > HUB_MAX_EVENT {
        return Err(HubSealError::TooLarge(event.len()));
    }
    let clear = header.encode();
    let mut plaintext = Vec::with_capacity(HUB_INNER_LEN + event.len());
    plaintext.extend_from_slice(&inner(header));
    plaintext.extend_from_slice(event);
    let cipher = XChaCha20Poly1305::new((&key.0).into());
    let body = cipher
        .encrypt(&nonce(header), Payload { msg: &plaintext, aad: &clear })
        .map_err(|_| HubSealError::Seal)?;
    let mut out = Vec::with_capacity(HUB_HEADER_LEN + body.len());
    out.extend_from_slice(&clear);
    out.extend_from_slice(&body);
    Ok(out)
}

/// A hub relay frame for one event (the relay rewrites `peer`).
pub fn seal_frame(
    key: &HubKey,
    header: &HubHeader,
    event: &[u8],
) -> Result<RelayFrame, HubSealError> {
    Ok(RelayFrame {
        kind: FrameKind::Hub,
        peer: PeerId([0; 16]),
        payload: seal(key, header, event)?,
    })
}

/// An event the viewer may act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub header: HubHeader,
    /// The `(session, pos, source)` the source sealed inside the body.
    pub inner_session: [u8; 16],
    pub inner_pos: HubPos,
    pub inner_source: HubRole,
    pub event: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubOpenError {
    Header(HubHeaderError),
    /// The seal did not verify: a wrong key, or a header or body someone edited.
    Seal,
    /// The body is too short to hold the inner triple.
    Inner,
}

/// Opens a hub payload. It does not compare the clear header with the inner
/// triple: [`crate::hub_truth::TruthTracker`] does, and counts it.
pub fn open(key: &HubKey, payload: &[u8]) -> Result<Opened, HubOpenError> {
    let header = HubHeader::decode(payload).map_err(HubOpenError::Header)?;
    let (clear, body) = payload.split_at(HUB_HEADER_LEN);
    let cipher = XChaCha20Poly1305::new((&key.0).into());
    let plaintext = cipher
        .decrypt(&nonce(&header), Payload { msg: body, aad: clear })
        .map_err(|_| HubOpenError::Seal)?;
    let Some((inner, event)) = plaintext.split_first_chunk::<HUB_INNER_LEN>() else {
        return Err(HubOpenError::Inner);
    };
    let inner_err = HubOpenError::Inner;
    let inner_source = HubRole::from_byte(inner[32]).ok_or(inner_err)?;
    Ok(Opened {
        header,
        inner_session: take::<16>(inner, 0).ok_or(inner_err)?,
        inner_pos: HubPos::new(
            be_u64(inner, 16).ok_or(inner_err)?,
            be_u64(inner, 24).ok_or(inner_err)?,
        ),
        inner_source,
        event: event.to_vec(),
    })
}

/// Where the relay sends one hub frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubRoute {
    /// To every viewer of the room, once.
    Viewers,
    /// To that source's socket.
    Source(HubRole),
    /// Older than or equal to what the viewers already got: dropped and counted.
    Drop,
}

/// The relay's rule for one room (one session), byte for byte what
/// `HubRelay` in cmux-next-ios/backend/src/hub-relay.ts does: keep the
/// highest `(epoch, seq)` forwarded to viewers; forward a newer viewer frame
/// from either source once, drop an older or equal one. Constant memory, no
/// storage.
#[derive(Debug, Clone, Default)]
pub struct HubRelayRule {
    high: Option<HubPos>,
    pub forwarded: u64,
    pub dropped: u64,
}

impl HubRelayRule {
    pub fn route(&mut self, header: &HubHeader) -> HubRoute {
        match header.to {
            HubTo::Source(role) => HubRoute::Source(role),
            HubTo::Viewers => {
                if self.high.is_some_and(|high| header.pos <= high) {
                    self.dropped += 1;
                    HubRoute::Drop
                } else {
                    self.high = Some(header.pos);
                    self.forwarded += 1;
                    HubRoute::Viewers
                }
            }
        }
    }

    pub fn high(&self) -> Option<HubPos> {
        self.high
    }
}

/// Whether a session uses the hub or today's per-source path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubJoin {
    Hub,
    Fallback(HubFallback),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubFallback {
    /// The relay has no hub route (an older Worker): 404 or 405.
    NoRoute,
    /// The hub is switched off (503 `hub_off`).
    Off,
    /// Upgraded without echoing [`HUB_SUBPROTOCOL`]: it is not a hub.
    NoSubprotocol,
    /// The relay refused kind 5 frames (`bad_frame:kind`): a two-party relay.
    KindRefused,
    /// Any other refusal (401, 403, ...): the status.
    Refused(u16),
}

/// The outcome of a hub join from its HTTP status and the subprotocol the
/// relay selected.
pub fn hub_join_outcome(status: u16, selected_subprotocol: Option<&str>) -> HubJoin {
    match status {
        101 if selected_subprotocol.is_some_and(|p| p.trim() == HUB_SUBPROTOCOL) => HubJoin::Hub,
        101 => HubJoin::Fallback(HubFallback::NoSubprotocol),
        404 | 405 => HubJoin::Fallback(HubFallback::NoRoute),
        503 => HubJoin::Fallback(HubFallback::Off),
        other => HubJoin::Fallback(HubFallback::Refused(other)),
    }
}

/// Whether a relay's `error` notice means it does not carry hub frames.
pub fn relay_error_means_no_hub(code: &str) -> bool {
    code == "bad_frame:kind"
}

impl From<HubHeaderError> for RelayFrameError {
    fn from(_: HubHeaderError) -> Self {
        RelayFrameError::BadHub
    }
}

#[cfg(test)]
#[path = "hub_tests.rs"]
mod tests;
