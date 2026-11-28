//! The binary frame the host's Durable Object relay forwards.
//!
//! `[u8 version = 1][u8 kind][16-byte peer install id][payload]`, one frame
//! per WebSocket binary message. On the host's socket `peer` names the
//! client the datagrams came from or go to; on a client's socket it names
//! the host. The relay never trusts `peer` in a client's frame: it forwards
//! the frame to the host with `peer` rewritten to the install bound to the
//! client's authenticated socket, so a client cannot speak as another.
//! The relay reads only `version`, `kind` and `peer`; datagrams
//! are WireGuard messages it cannot decrypt. The TypeScript relay checks
//! itself against `tests/vectors/relay-frames.json`.
//!
//! A `Hub` payload (kind 5, RFD 0142 R6) starts with the clear hub header
//! of [`crate::hub`]; decoders check it after `too_large` (`bad_hub`).
//!
//! A `Datagrams` payload is one or more `[u16 big-endian length][datagram]`
//! records. Batching matters: one Durable Object passes about 4,000
//! incoming messages per second (measured 2026-10-02), so a sender packs
//! every datagram that is ready into one message (up to 16 KiB), which also
//! cuts per-message billing.

pub const RELAY_FRAME_VERSION: u8 = 1;
pub const RELAY_FRAME_HEADER_LEN: usize = 18;
/// Largest payload. Anything larger is a protocol error, not a split.
pub const RELAY_FRAME_MAX_PAYLOAD: usize = 16 * 1024;

/// A 128-bit install or host id, as `TeamDO` assigns it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PeerId(pub [u8; 16]);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// One or more length-prefixed WireGuard datagrams.
    Datagrams = 1,
    /// The sender's current path candidates (CBOR list), for rendezvous.
    Candidates = 2,
    /// Ask a paused or sleeping host to come back; the relay forwards it to
    /// the host's socket or to the wake path.
    Wake = 3,
    /// hop/1 DATA records (`TaggedRecord`s): a `Datagrams` frame whose records carry a class and an optional
    /// latest-wins tag. Only the two-party link relay (`LinkRelay`) forwards it; an older one refuses it with
    /// `{"type":"error","code":"bad_frame:kind"}` and the sender falls back to `Datagrams` (`RelaySender`).
    TaggedDatagrams = 4,
    /// RFD 0142 R6, the three-way hub: one event of a session, sealed end to
    /// end by its source (the Mac or the VM) to the session's viewers, behind
    /// a clear [`crate::hub::HubHeader`] the relay schedules on. Only a hub
    /// relay forwards it; a two-party relay answers `bad_frame:kind`.
    /// Kind 4 is LinkRelay's tagged datagrams (cmux#54189); the hub is 5.
    Hub = 5,
}

impl FrameKind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Datagrams),
            2 => Some(Self::Candidates),
            3 => Some(Self::Wake),
            4 => Some(Self::TaggedDatagrams),
            5 => Some(Self::Hub),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayFrame {
    pub kind: FrameKind,
    pub peer: PeerId,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayFrameError {
    Short,
    Version(u8),
    Kind(u8),
    TooLarge(usize),
    /// A `Datagrams` payload whose records do not tile it exactly, or an
    /// empty record.
    BadBatch,
    /// A `Hub` payload whose clear hub header is short, of an unknown
    /// version, or names an unknown role or target.
    BadHub,
}

impl RelayFrame {
    pub fn encode(&self) -> Result<Vec<u8>, RelayFrameError> {
        if self.payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(self.payload.len()));
        }
        check_payload(self.kind, &self.payload)?;
        let mut bytes = Vec::with_capacity(RELAY_FRAME_HEADER_LEN + self.payload.len());
        bytes.push(RELAY_FRAME_VERSION);
        bytes.push(self.kind as u8);
        bytes.extend_from_slice(&self.peer.0);
        bytes.extend_from_slice(&self.payload);
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, RelayFrameError> {
        let Some((header, payload)) = bytes.split_first_chunk::<RELAY_FRAME_HEADER_LEN>() else {
            return Err(RelayFrameError::Short);
        };
        let [version, kind_byte, peer_bytes @ ..] = header;
        if *version != RELAY_FRAME_VERSION {
            return Err(RelayFrameError::Version(*version));
        }
        let kind = FrameKind::from_byte(*kind_byte).ok_or(RelayFrameError::Kind(*kind_byte))?;
        if payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(payload.len()));
        }
        check_payload(kind, payload)?;
        let peer: [u8; 16] = *peer_bytes;
        Ok(Self { kind, peer: PeerId(peer), payload: payload.to_vec() })
    }

    /// Packs datagrams into one `Datagrams` frame. Returns `TooLarge` when
    /// they do not fit; the caller sends the rest in the next frame.
    pub fn datagrams(peer: PeerId, datagrams: &[&[u8]]) -> Result<Self, RelayFrameError> {
        let mut payload = Vec::new();
        for datagram in datagrams {
            let len = u16::try_from(datagram.len())
                .map_err(|_| RelayFrameError::TooLarge(datagram.len()))?;
            if len == 0 {
                return Err(RelayFrameError::BadBatch);
            }
            payload.extend_from_slice(&len.to_be_bytes());
            payload.extend_from_slice(datagram);
        }
        if payload.is_empty() {
            return Err(RelayFrameError::BadBatch);
        }
        if payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(payload.len()));
        }
        Ok(Self { kind: FrameKind::Datagrams, peer, payload })
    }

    /// Packs records into one `TaggedDatagrams` frame (`TooLarge` when they do not fit).
    pub fn tagged_datagrams(
        peer: PeerId,
        records: &[TaggedRecord<'_>],
    ) -> Result<Self, RelayFrameError> {
        let mut payload = Vec::new();
        for record in records {
            record.encode_into(&mut payload)?;
        }
        if payload.is_empty() {
            return Err(RelayFrameError::BadBatch);
        }
        if payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(payload.len()));
        }
        Ok(Self { kind: FrameKind::TaggedDatagrams, peer, payload })
    }

    /// The records of a `TaggedDatagrams` frame, in order.
    pub fn split_tagged(&self) -> Result<Vec<TaggedRecord<'_>>, RelayFrameError> {
        split_tagged(&self.payload)
    }

    /// The datagrams of a `Datagrams` frame, in order.
    pub fn split_datagrams(&self) -> Result<Vec<&[u8]>, RelayFrameError> {
        split_batch(&self.payload)
    }
}

fn check_payload(kind: FrameKind, payload: &[u8]) -> Result<(), RelayFrameError> {
    match kind {
        FrameKind::Datagrams => split_batch(payload).map(|_| ()),
        FrameKind::TaggedDatagrams => split_tagged(payload).map(|_| ()),
        FrameKind::Hub => {
            crate::hub::HubHeader::decode(payload).map(|_| ()).map_err(|_| RelayFrameError::BadHub)
        }
        FrameKind::Candidates | FrameKind::Wake => Ok(()),
    }
}

fn split_batch(payload: &[u8]) -> Result<Vec<&[u8]>, RelayFrameError> {
    let mut records = Vec::new();
    let mut rest = payload;
    while !rest.is_empty() {
        let Some((len_bytes, tail)) = rest.split_first_chunk::<2>() else {
            return Err(RelayFrameError::BadBatch);
        };
        let len = usize::from(u16::from_be_bytes(*len_bytes));
        if len == 0 {
            return Err(RelayFrameError::BadBatch);
        }
        let Some((record, next)) = tail.split_at_checked(len) else {
            return Err(RelayFrameError::BadBatch);
        };
        records.push(record);
        rest = next;
    }
    if records.is_empty() {
        return Err(RelayFrameError::BadBatch);
    }
    Ok(records)
}

/// One hop/1 DATA record (docs/cmux-next/relay-pop-hop.md): `[u8 class][u8 flags][tag if flags & 1: u32 key,
/// u32 key_seq][u16 len > 0][bytes]`. Class 0 control, 1 interactive state (latest-wins when tagged), 2 input,
/// 3 bulk, 4 media. A class above 4, a flag bit other than bit 0 (tag present), or a tag on a class other than 1
/// is a bad batch (hop's `HopError::Class`, `Flags`, `TagClass`); `tests/relay_vectors.rs` checks this parser
/// against `hop::HopMsg::decode` on every vector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaggedRecord<'a> {
    pub class: u8,
    /// `(stream key id, key seq)`, the R5 latest-wins tag.
    pub tag: Option<(u32, u32)>,
    pub data: &'a [u8],
}

impl TaggedRecord<'_> {
    fn encode_into(&self, out: &mut Vec<u8>) -> Result<(), RelayFrameError> {
        let len = u16::try_from(self.data.len())
            .map_err(|_| RelayFrameError::TooLarge(self.data.len()))?;
        if len == 0 {
            return Err(RelayFrameError::BadBatch);
        }
        out.push(self.class);
        out.push(u8::from(self.tag.is_some()));
        if let Some((key, seq)) = self.tag {
            out.extend_from_slice(&key.to_be_bytes());
            out.extend_from_slice(&seq.to_be_bytes());
        }
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(self.data);
        Ok(())
    }
}

fn split_tagged(payload: &[u8]) -> Result<Vec<TaggedRecord<'_>>, RelayFrameError> {
    // hop's decoder is the one parser of the record layout; this only borrows the bytes it accepted.
    let decoded = crate::decode_records(payload).map_err(|_| RelayFrameError::BadBatch)?;
    let mut records = Vec::with_capacity(decoded.len());
    let mut rest = payload;
    for record in decoded {
        let head = if record.tag.is_some() { 2 + 8 + 2 } else { 2 + 2 };
        let (consumed, next) =
            rest.split_at_checked(head + record.bytes.len()).ok_or(RelayFrameError::BadBatch)?;
        records.push(TaggedRecord {
            class: record.class as u8,
            tag: record.tag.map(|t| (t.key, t.seq)),
            data: consumed.get(head..).ok_or(RelayFrameError::BadBatch)?,
        });
        rest = next;
    }
    Ok(records)
}

/// The notice an older `LinkRelay` answers a `TaggedDatagrams` frame with (it refuses every kind but `datagrams`).
pub const OLD_RELAY_KIND_NOTICE: &str = "bad_frame:kind";

/// Which frame kind a sender puts its datagrams in for a `LinkRelay` socket. It starts with tagged records and
/// falls back to plain `Datagrams` for the rest of the socket when the relay says it does not know the kind, so a
/// new sender works against an old relay (the tags only steer latest-wins dropping; they are never needed to
/// deliver). Whether the relay may be sent tagged frames at all is the caller's choice (`new(false)` = plain).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RelaySender {
    tagged: bool,
}

impl RelaySender {
    pub fn new(tagged: bool) -> Self {
        Self { tagged }
    }

    pub fn is_tagged(&self) -> bool {
        self.tagged
    }

    /// A relay text notice (`{"type":"error","code":...}`) arrived; true when it switched the sender to plain.
    pub fn on_notice(&mut self, text: &str) -> bool {
        let refused = self.tagged
            && text.contains("\"type\":\"error\"")
            && text.contains(&format!("\"code\":\"{OLD_RELAY_KIND_NOTICE}\""));
        if refused {
            self.tagged = false;
        }
        refused
    }

    /// The frame for `records`: tagged as they are, or (after a fallback) the same bytes as plain datagrams.
    pub fn frame(
        &self,
        peer: PeerId,
        records: &[TaggedRecord<'_>],
    ) -> Result<RelayFrame, RelayFrameError> {
        if self.tagged {
            return RelayFrame::tagged_datagrams(peer, records);
        }
        let datagrams: Vec<&[u8]> = records.iter().map(|record| record.data).collect();
        RelayFrame::datagrams(peer, &datagrams)
    }
}
