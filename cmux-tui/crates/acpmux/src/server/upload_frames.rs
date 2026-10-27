//! Binary upload frames (`docs/prompt-uploads.md` section 1): the app's native side streams a
//! file's raw bytes to the daemon on the WebSocket it already holds, with no base64 and no cap on
//! the file (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
//!
//! One WebSocket binary frame is one request:
//!
//! ```text
//! "AMUP" | u32 big-endian H | H bytes of JSON-RPC header | raw bytes
//! {"jsonrpc":"2.0","id":7,"method":"_acpmux/file_put_data",
//!  "params":{"sessionId":"<chat>","uploadId":"<id>","offset":<u64>}}
//! ```
//!
//! answered with an ordinary text response of the same `id` once the bytes are on disk
//! (`hub/file_uploads.rs` `append`). A connection's frames are written one after another, in the
//! order they came, by one worker with a queue of [`WINDOW`]: a sender may keep that many in
//! flight, and a sender past it is slowed by the socket, so memory stays at a few frames whatever
//! the file's size. Each answer is small (a header is at most 16 KiB, and only a short id is
//! echoed), and the worker waits for room in the connection's bounded answer queue, so a client
//! that stops reading stops its own frames. A frame whose offset is not the upload's end is `upload.offset {offset}`.
//!
//! A text message after a frame on the same connection is read only once every frame before it is
//! written and answered ([`InFlight`]): a finish, a status or a prompt sent right after the last
//! frame, without waiting for its answer, sees all its bytes. (A frame needs its upload id, which
//! the begin's answer gives, so a begin always precedes its frames.)
//!
//! Only the local app's connection (`local_app.rs`) may send them; any other gets
//! `filePut.remote` as its answer, never silence. A chat on a peer gets the bytes there, as
//! base64 `file_put_chunk` requests of at most `CHUNK_BYTES` over the peer link.

use super::{ConnAuth, Hub, Origin};
use crate::hub::file_uploads::{self, CHUNK_BYTES};
use crate::rpc::{Message, RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::{Notify, mpsc};
use tokio_tungstenite::tungstenite::Bytes;

/// The `initialize` feature of a daemon that takes binary upload frames and
/// `_acpmux/file_put_status`.
pub const FEATURE: &str = "uploadFrames";
const MAGIC: &[u8; 4] = b"AMUP";
/// Frames a connection may have waiting to be written.
pub const WINDOW: usize = 4;
/// The largest header: a frame's header names a chat, an upload and an offset.
const MAX_HEADER: usize = 16 << 10;
/// The longest request id echoed in an answer; a longer one is answered with a null id.
const MAX_ID: usize = 128;

/// A connection's frames not yet answered: its reader holds a text message until there are none.
#[derive(Default)]
pub(super) struct InFlight {
    count: AtomicUsize,
    none: Notify,
}

impl InFlight {
    fn done(&self) {
        if self.count.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.none.notify_waiters();
        }
    }

    /// Returns once every frame sent before it was answered.
    pub(super) async fn drained(&self) {
        loop {
            let none = self.none.notified();
            tokio::pin!(none);
            none.as_mut().enable();
            if self.count.load(Ordering::SeqCst) == 0 {
                return;
            }
            none.await;
        }
    }
}

/// A connection's frame worker: frames given to [`Frames::send`] are written in order and
/// answered on the connection.
pub(super) struct Frames {
    tx: mpsc::Sender<Bytes>,
    pub(super) in_flight: Arc<InFlight>,
}

impl Frames {
    /// Queues `frame`, waiting for room in the window; false once the worker ended.
    pub(super) async fn send(&self, frame: Bytes) -> bool {
        self.in_flight.count.fetch_add(1, Ordering::SeqCst);
        let sent = self.tx.send(frame).await.is_ok();
        if !sent {
            self.in_flight.done();
        }
        sent
    }
}

/// Starts `origin`'s frame worker; frames sent to it are written in order and answered on `out`.
/// It ends when the sender is dropped (the connection's reader ended) or `out` closes.
pub(super) fn spawn(
    hub: Arc<Hub>,
    origin: Origin,
    auth: ConnAuth,
    out: mpsc::Sender<String>,
) -> Frames {
    let (tx, mut rx) = mpsc::channel::<Bytes>(WINDOW);
    let in_flight = Arc::new(InFlight::default());
    let counted = in_flight.clone();
    tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            let reply = handle(&hub, origin, auth, frame).await;
            let answered = out.send(reply.to_value().to_string()).await.is_ok();
            counted.done();
            if !answered {
                break;
            }
        }
        // Ended: nothing it holds will be answered, so no text message waits on it.
        rx.close();
        while rx.try_recv().is_ok() {
            counted.done();
        }
    });
    Frames { tx, in_flight }
}

/// The header's id, params and where the bytes start.
fn parse(frame: &[u8]) -> Result<(Value, Value, usize), (Value, RpcError)> {
    let bad = |what: &str| (Value::Null, RpcError::invalid_params(format!("upload frame: {what}")));
    if frame.get(..4) != Some(MAGIC) {
        return Err(bad("it does not begin with AMUP"));
    }
    let len = frame.get(4..8).ok_or_else(|| bad("no header length"))?;
    let len = u32::from_be_bytes([len[0], len[1], len[2], len[3]]) as usize;
    if len > MAX_HEADER {
        return Err(bad("the header is over 16 KiB"));
    }
    let start = 8usize.checked_add(len).filter(|&end| end <= frame.len());
    let start = start.ok_or_else(|| bad("the header is longer than the frame"))?;
    let header: Value =
        serde_json::from_slice(&frame[8..start]).map_err(|e| bad(&format!("header: {e}")))?;
    // Every answer is small: an id a client chose is echoed only when it is short.
    let id = match header.get("id") {
        Some(id @ Value::Number(_)) => id.clone(),
        Some(Value::String(s)) if s.len() <= MAX_ID => Value::String(s.clone()),
        _ => Value::Null,
    };
    if header.get("method").and_then(Value::as_str) != Some(method::MUX_FILE_PUT_DATA) {
        let e = RpcError::method_not_found(&format!(
            "a binary frame's method is {}",
            method::MUX_FILE_PUT_DATA
        ));
        return Err((id, e));
    }
    let params = header.get("params").cloned().unwrap_or(Value::Null);
    Ok((id, params, start))
}

async fn handle(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth, frame: Bytes) -> Message {
    let (id, params, start) = match parse(&frame) {
        Ok(parsed) => parsed,
        Err((id, e)) => return Message::err(id, e),
    };
    if origin != Origin::LocalApp {
        let e = RpcError::invalid_params(
            "filePut.remote: a file is saved for a chat only from the app or over the local unix socket",
        )
        .with_data(json!({"reason": "filePut.remote"}));
        return Message::err(id, e);
    }
    match write(hub, origin, auth, &params, frame.slice(start..)).await {
        Ok(v) => Message::ok(id, v),
        Err(mut e) => {
            crate::recovery::annotate(&mut e, None);
            Message::err(id, e)
        }
    }
}

async fn write(
    hub: &Arc<Hub>,
    origin: Origin,
    auth: ConnAuth,
    params: &Value,
    data: Bytes,
) -> Result<Value, RpcError> {
    let key = super::session_key(params)?;
    let upload = params
        .get("uploadId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("uploadId is required"))?
        .to_owned();
    let offset = params
        .get("offset")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("offset is required"))?;
    let missing = match hub.resolve(key) {
        Ok(session) => return file_uploads::handle_data(session, upload, offset, data).await,
        Err(e) => e,
    };
    let Some((peer, id, _)) = hub.resolve_remote(key) else { return Err(missing) };
    if !peer.supports_file_put_chunks() {
        return Err(file_uploads::peer_unsupported(&peer));
    }
    use base64::Engine;
    let mut at = offset;
    for piece in data.chunks(CHUNK_BYTES) {
        let mut p = json!({"sessionId": id, "uploadId": upload, "offset": at,
            "data": base64::engine::general_purpose::STANDARD.encode(piece)});
        super::remote_guard::mark_forwarded(origin, auth, params, &mut p);
        let answer = peer.request(method::MUX_FILE_PUT_CHUNK, p).await?;
        at = answer
            .get("offset")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::internal(format!("peer {} gave no offset", peer.name)))?;
    }
    Ok(json!({"offset": at}))
}

/// One frame as a sender makes it.
pub fn frame(id: i64, session: &str, upload: &str, offset: u64, bytes: &[u8]) -> Vec<u8> {
    let header = json!({"jsonrpc": "2.0", "id": id, "method": method::MUX_FILE_PUT_DATA,
        "params": {"sessionId": session, "uploadId": upload, "offset": offset}})
    .to_string();
    let len = u32::try_from(header.len()).unwrap_or(u32::MAX);
    let mut out = Vec::with_capacity(8 + header.len() + bytes.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(bytes);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_frame_parses_back_to_its_header_and_bytes() {
        let f = frame(7, "chat", "up", 9, b"hello");
        let (id, params, start) = parse(&f).unwrap();
        assert_eq!(id, json!(7));
        assert_eq!(params["offset"], 9);
        assert_eq!(&f[start..], b"hello");
        for bad in [&b"AMU"[..], b"XXXX\0\0\0\x01{", b"AMUP\0\0\0\x09{}", b"AMUP\0\x01\0\0{}"] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
        // A long id is not echoed: every answer stays small whatever a client sends.
        let long = "x".repeat(MAX_ID + 1);
        let header = json!({"id": long, "method": method::MUX_FILE_PUT_DATA}).to_string();
        let mut long_id = b"AMUP".to_vec();
        long_id.extend_from_slice(&u32::try_from(header.len()).unwrap().to_be_bytes());
        long_id.extend_from_slice(header.as_bytes());
        assert_eq!(parse(&long_id).unwrap().0, Value::Null);
        let mut other = f.clone();
        let at = other.windows(9).position(|w| w == b"file_put_").unwrap();
        other[at] = b'F';
        let (id, e) = parse(&other).unwrap_err();
        assert_eq!((id, e.code), (json!(7), RpcError::method_not_found("x").code));
    }
}
