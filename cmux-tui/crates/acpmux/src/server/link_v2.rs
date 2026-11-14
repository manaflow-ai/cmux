//! The bounded v2 notification adapter used on authenticated peer links.
//!
//! Peer links still carry the v1 JSON-RPC stream.  v2 frames are therefore
//! wrapped as `_acpmux/v2` notifications, with the frame payload kept as raw
//! JSON rather than first materialising a generic value tree.  Each direction
//! has one pending v2 slot; v1 output is always selected first.

use acpmux_core::conn::Request;
use acpmux_core::wire::{Frame, FrameError, FrameKind};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};

pub const METHOD: &str = "_acpmux/v2";

#[derive(Debug, thiserror::Error)]
pub enum AdapterError {
    #[error("invalid peer v2 notification")]
    InvalidNotification,
    #[error("v2 frame error: {0}")]
    Frame(#[from] FrameError),
    #[error("a peer sent a second hello")]
    DuplicateHello,
    #[error("v2 payload is not valid JSON")]
    Payload(#[from] serde_json::Error),
}

#[derive(Serialize)]
struct Params<'a> {
    kind: u8,
    payload: &'a RawValue,
}

#[derive(Serialize)]
struct Notification<'a> {
    jsonrpc: &'static str,
    method: &'static str,
    params: Params<'a>,
}

#[derive(Deserialize)]
struct Incoming<'a> {
    method: String,
    #[serde(borrow)]
    params: IncomingParams<'a>,
}

#[derive(Deserialize)]
struct IncomingParams<'a> {
    kind: u8,
    #[serde(borrow)]
    payload: &'a RawValue,
}

/// A peer link's one-slot v2 adapter. The surrounding v1 serve loop owns the
/// transport; this type only provides bounded conversion and ordering.
#[derive(Default)]
pub struct Adapter {
    hello_seen: bool,
    ended: bool,
    toward_peer: Option<String>,
    from_peer: VecDeque<Frame>,
    dropped: AtomicU64,
    unknown: AtomicU64,
    before_hello: AtomicU64,
}

impl Adapter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn hello_seen(&self) -> bool {
        self.hello_seen
    }

    pub fn ended(&self) -> bool {
        self.ended
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    pub fn unknown(&self) -> u64 {
        self.unknown.load(Ordering::Relaxed)
    }

    pub fn before_hello(&self) -> u64 {
        self.before_hello.load(Ordering::Relaxed)
    }

    /// Converts one binary v2 frame to its peer notification form. The raw
    /// payload is borrowed for serialization and is never decoded into a
    /// generic `Value`.
    pub fn encode(frame: &Frame) -> Result<String, AdapterError> {
        let payload = RawValue::from_string(
            std::str::from_utf8(frame.payload())
                .map_err(|_| AdapterError::InvalidNotification)?
                .to_owned(),
        )
        .map_err(|_| AdapterError::InvalidNotification)?;
        Ok(serde_json::to_string(&Notification {
            jsonrpc: "2.0",
            method: METHOD,
            params: Params { kind: kind_number(frame.kind), payload: &payload },
        })?)
    }

    /// Accepts one peer notification. A pre-hello frame is dropped and
    /// counted; a second hello ends the first v2 connection.
    pub fn receive(&mut self, line: &str) -> Result<(), AdapterError> {
        let incoming: Incoming<'_> =
            serde_json::from_str(line).map_err(|_| AdapterError::InvalidNotification)?;
        if incoming.method != METHOD {
            self.unknown.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        let frame = Frame::new(
            FrameKind::try_from(incoming.params.kind)?,
            incoming.params.payload.get().as_bytes(),
        )?;
        let request = (frame.kind == FrameKind::Request)
            .then(|| frame.decode_json::<Request>().ok())
            .flatten();
        if matches!(request, Some(Request::Hello(_))) {
            if self.hello_seen {
                self.ended = true;
                return Err(AdapterError::DuplicateHello);
            }
            self.hello_seen = true;
        } else if !self.hello_seen {
            self.before_hello.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        if self.from_peer.len() >= 1 {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }
        self.from_peer.push_back(frame);
        Ok(())
    }

    pub fn take_from_peer(&mut self) -> Option<Frame> {
        self.from_peer.pop_front()
    }

    /// Queues one v2 frame toward the peer. A pending v1 line is given
    /// priority by [`take_outbound`].
    pub fn queue_v2(&mut self, frame: &Frame) -> Result<bool, AdapterError> {
        if self.toward_peer.is_some() {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return Ok(false);
        }
        self.toward_peer = Some(Self::encode(frame)?);
        Ok(true)
    }

    pub fn take_outbound(&mut self) -> Option<String> {
        self.toward_peer.take()
    }
}

fn kind_number(kind: FrameKind) -> u8 {
    match kind {
        FrameKind::Hello => 1,
        FrameKind::Window => 2,
        FrameKind::Delta => 3,
        FrameKind::Page => 4,
        FrameKind::Blob => 5,
        FrameKind::Ack => 6,
        FrameKind::Dropped => 7,
        FrameKind::Error => 8,
        FrameKind::Request => 9,
        FrameKind::Unknown(value) => value,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hello() -> Frame {
        Frame::json(
            FrameKind::Request,
            &json!({"method":"hello","params":{"clientKind":"peer","protocol":2}}),
        )
        .unwrap()
    }

    #[test]
    fn notification_keeps_payload_as_an_object() {
        let line = Adapter::encode(&hello()).unwrap();
        assert!(line.contains(r#""method":"_acpmux/v2""#));
        assert!(line.contains(r#""payload":{"method":"hello""#));
        assert!(!line.contains(r#"payload":"{"#));
    }

    #[test]
    fn pre_hello_is_dropped_and_duplicate_hello_ends() {
        let frame = Frame::json(FrameKind::Window, &json!({"sid":"s"})).unwrap();
        let line = Adapter::encode(&frame).unwrap();
        let mut adapter = Adapter::new();
        adapter.receive(&line).unwrap();
        assert_eq!(adapter.before_hello(), 1);
        let hello = Adapter::encode(&hello()).unwrap();
        adapter.receive(&hello).unwrap();
        assert!(matches!(adapter.receive(&hello), Err(AdapterError::DuplicateHello)));
        assert!(adapter.ended());
    }

    #[test]
    fn v1_priority_and_one_slot_are_bounded() {
        let mut adapter = Adapter::new();
        let frame = Frame::json(FrameKind::Delta, &json!({"ops":[]})).unwrap();
        assert!(adapter.queue_v2(&frame).unwrap());
        assert!(!adapter.queue_v2(&frame).unwrap());
        assert!(adapter.take_outbound().is_some());
        assert!(adapter.take_outbound().is_none());
    }
}
