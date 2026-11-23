//! `_acpmux/voice/stream.*`: streaming dictation, words while speaking (crate `cmux-voice`,
//! `stream.rs` the wire, `session.rs` the reducer).
//!
//! - `stream.start {language?}` answers `{stream}` once a session is set up, `{streaming: false}`
//!   when the chosen provider does not stream (the app records and transcribes in one call), or
//!   `{error}` (not configured, no key). It does not wait for the provider: a failed connection
//!   ends the stream like any other failure.
//! - `stream.audio {stream, seq, pcm}`: 16 kHz mono PCM16, little-endian, base64, numbered from 0.
//!   Requests on one connection may run at once, so the chunks are put back in `seq` order here.
//! - `stream.stop {stream, seq}` (`seq` = the number after the last chunk) answers after the last
//!   words: `{text}` or `{error}`.
//! - `stream.cancel {stream}` ends it at once.
//! - The daemon sends `stream.event {stream, partial}` (the words so far, replacing the last
//!   partial), `{stream, final}` (a finished stretch, appended), and `{stream, end: {text} |
//!   {error}}` once, when the session ends.
//!
//! A stream belongs to the connection that started it, at most one at a time (a new start cancels
//! the last), and ends with the connection. Who may call: the unix socket only, as `voice.rs`.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use base64::Engine;
use cmux_voice::{Command, Shown, VoiceError};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::{Conn, Origin};
use crate::rpc::{Message, RpcError, method};

pub(super) const METHODS: &[&str] = &[
    method::MUX_VOICE_STREAM_START,
    method::MUX_VOICE_STREAM_AUDIO,
    method::MUX_VOICE_STREAM_STOP,
    method::MUX_VOICE_STREAM_CANCEL,
];

/// Chunks waiting for the session to take them (about 100 ms each: half a minute).
const QUEUE: usize = 300;
/// Chunks that came ahead of a missing one.
const EARLY_MAX: usize = 64;
/// The most bytes of one chunk (2 s of audio).
const CHUNK_MAX_BYTES: usize = 64 * 1024;
/// How long a stop waits for the last words: the session's own finalizing deadline, plus room
/// for the chunks still queued ahead of the stop.
const STOP_WAIT: Duration = Duration::from_secs(20);

enum Item {
    Audio(Vec<i16>),
    Stop,
}

struct Stream {
    id: String,
    commands: mpsc::Sender<Command>,
    /// The `seq` the session takes next.
    next: u64,
    early: BTreeMap<u64, Item>,
    /// How the session ended, for the stop that waits on it.
    outcome: Option<oneshot::Receiver<Result<String, VoiceError>>>,
}

/// One connection's dictation stream; `None` inside once the connection ended.
pub(crate) struct Streams {
    live: Mutex<Option<Option<Stream>>>,
    next_id: AtomicU64,
}

impl Default for Streams {
    fn default() -> Self {
        Streams { live: Mutex::new(Some(None)), next_id: AtomicU64::new(1) }
    }
}

fn refused(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

fn no_stream() -> RpcError {
    refused("voice.stream", "no such dictation stream on this connection")
}

impl Streams {
    /// The connection ended: its stream is cancelled (the session sees its sender go).
    pub(crate) fn close_all(&self) {
        self.live.lock().unwrap_or_else(PoisonError::into_inner).take();
    }

    fn with<T>(&self, f: impl FnOnce(&mut Option<Stream>) -> T) -> Option<T> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner).as_mut().map(f)
    }

    /// Puts `item` at `seq` and hands the session every chunk now in order.
    fn put(&self, id: &str, seq: u64, item: Item) -> Result<(), RpcError> {
        self.with(|live| {
            let stream = live.as_mut().filter(|s| s.id == id).ok_or_else(no_stream)?;
            if seq < stream.next || stream.early.contains_key(&seq) {
                return Err(refused("voice.seq", "that chunk number was already sent"));
            }
            if stream.early.len() >= EARLY_MAX {
                return Err(refused("voice.seq", "too many chunks came ahead of a missing one"));
            }
            stream.early.insert(seq, item);
            while let Some(item) = stream.early.remove(&stream.next) {
                let command = match item {
                    Item::Audio(samples) => Command::Audio(samples),
                    Item::Stop => Command::Stop,
                };
                // A full queue is a session that stopped taking audio: the chunk is dropped, and
                // the session's own end says why.
                let _ = stream.commands.try_send(command);
                stream.next += 1;
            }
            Ok(())
        })
        .unwrap_or_else(|| Err(refused("voice.closed", "the connection has ended")))
    }
}

/// The samples of a base64 PCM16 little-endian chunk.
fn samples(params: &Value) -> Result<Vec<i16>, RpcError> {
    let pcm = params.get("pcm").and_then(Value::as_str).unwrap_or_default();
    if pcm.len() > CHUNK_MAX_BYTES / 3 * 4 + 4 {
        return Err(RpcError::invalid_params("an audio chunk is at most 64 KiB"));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(pcm)
        .map_err(|_| RpcError::invalid_params("pcm is not base64"))?;
    if bytes.len() % 2 != 0 {
        return Err(RpcError::invalid_params("pcm is 16-bit samples: an even byte count"));
    }
    Ok(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

fn text<'a>(params: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

fn seq(params: &Value) -> Result<u64, RpcError> {
    params
        .get("seq")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("seq is required"))
}

fn event(id: &str, what: Value) -> Message {
    let mut params = json!({"stream": id});
    if let (Some(params), Value::Object(what)) = (params.as_object_mut(), what) {
        params.extend(what);
    }
    Message::notification(method::MUX_VOICE_STREAM_EVENT, params)
}

fn end_reply(result: &Result<String, VoiceError>) -> Value {
    match result {
        Ok(text) => json!({"text": text}),
        Err(e) => json!({"error": e}),
    }
}

async fn start(conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let resolved = cmux_voice::resolve(&super::voice::settings_now().await?);
    let endpoint = match resolved.endpoint {
        Ok(e) => e,
        Err(e) => return Ok(json!({"error": e})),
    };
    if cmux_voice::stream_url(&endpoint).is_none() {
        return Ok(json!({"streaming": false}));
    }
    let key = super::voice::saved_key(&endpoint, super::voice::USE_KEY_WAIT).await;
    let key = match cmux_voice::usable_key(&endpoint, key) {
        Ok(key) => key,
        Err(e) => return Ok(json!({"error": e})),
    };
    let language = params.get("language").and_then(Value::as_str).map(str::to_owned);
    let id = format!("voice-{}", conn.voice_streams.next_id.fetch_add(1, Ordering::Relaxed));
    let (commands, rx) = mpsc::channel(QUEUE);
    let (shown_tx, mut shown_rx) = mpsc::channel::<Shown>(64);
    let (done, outcome) = oneshot::channel();
    let stream = Stream {
        id: id.clone(),
        commands,
        next: 0,
        early: BTreeMap::new(),
        outcome: Some(outcome),
    };
    // A new start replaces (and so cancels) the last.
    if conn.voice_streams.with(|live| *live = Some(stream)).is_none() {
        return Err(refused("voice.closed", "the connection has ended"));
    }
    let session =
        cmux_voice::stream::run(endpoint, key, cmux_voice::Http::default(), language, rx, shown_tx);
    let (conn, sid) = (conn.clone(), id.clone());
    // The session ends with its commands: a stop, a cancel, or the connection's end
    // (`Streams::close_all` drops the sender); the hub's shutdown drops it too.
    let _session = conn.scope.spawn_until_cancelled("voice-stream", async move {
        let forward = async {
            while let Some(shown) = shown_rx.recv().await {
                let what = match shown {
                    Shown::Partial(text) => json!({"partial": text}),
                    Shown::Final(text) => json!({"final": text}),
                };
                conn.send(&event(&sid, what));
            }
        };
        let (result, ()) = tokio::join!(session, forward);
        conn.send(&event(&sid, json!({"end": end_reply(&result)})));
        let _ = done.send(result);
    });
    Ok(json!({"stream": id}))
}

async fn stop(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let id = text(params, "stream")?;
    conn.voice_streams.put(id, seq(params)?, Item::Stop)?;
    let outcome = conn
        .voice_streams
        .with(|live| live.as_mut().filter(|s| s.id == id).and_then(|s| s.outcome.take()))
        .flatten()
        .ok_or_else(|| refused("voice.stream", "this stream is already stopping"))?;
    let result = match tokio::time::timeout(STOP_WAIT, outcome).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(VoiceError::bare(cmux_voice::ErrorCode::Offline)),
        Err(_) => Err(VoiceError::new(
            cmux_voice::ErrorCode::Timeout,
            "the last words did not come in time",
            None,
        )),
    };
    conn.voice_streams.with(|live| {
        if live.as_ref().is_some_and(|s| s.id == id) {
            *live = None;
        }
    });
    Ok(end_reply(&result))
}

fn cancel(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let id = text(params, "stream")?;
    conn.voice_streams.with(|live| {
        if live.as_ref().is_some_and(|s| s.id == id) {
            *live = None;
        }
    });
    Ok(json!({}))
}

pub(super) async fn handle(conn: &Arc<Conn>, m: &str, params: &Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(RpcError::invalid_params("dictation: only the unix socket may ask"));
    }
    match m {
        method::MUX_VOICE_STREAM_START => start(conn, params).await,
        method::MUX_VOICE_STREAM_AUDIO => {
            let id = text(params, "stream")?;
            conn.voice_streams.put(id, seq(params)?, Item::Audio(samples(params)?))?;
            Ok(json!({}))
        }
        method::MUX_VOICE_STREAM_STOP => stop(conn, params).await,
        method::MUX_VOICE_STREAM_CANCEL => cancel(conn, params),
        _ => Err(RpcError::method_not_found(m)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(streams: &Streams) -> mpsc::Receiver<Command> {
        let (commands, rx) = mpsc::channel(QUEUE);
        streams.with(|live| {
            *live = Some(Stream {
                id: "s".into(),
                commands,
                next: 0,
                early: BTreeMap::new(),
                outcome: None,
            });
        });
        rx
    }

    #[test]
    fn chunks_go_to_the_session_in_seq_order() {
        let streams = Streams::default();
        let mut rx = stream(&streams);
        streams.put("s", 1, Item::Audio(vec![2])).unwrap();
        assert!(rx.try_recv().is_err(), "chunk 1 waits for chunk 0");
        streams.put("s", 2, Item::Stop).unwrap();
        streams.put("s", 0, Item::Audio(vec![1])).unwrap();
        assert_eq!(rx.try_recv().unwrap(), Command::Audio(vec![1]));
        assert_eq!(rx.try_recv().unwrap(), Command::Audio(vec![2]));
        assert_eq!(rx.try_recv().unwrap(), Command::Stop);
        assert!(streams.put("s", 1, Item::Audio(vec![3])).is_err(), "a number twice");
        assert!(streams.put("other", 3, Item::Audio(vec![3])).is_err());
    }

    #[test]
    fn a_closed_connection_cancels_its_stream() {
        let streams = Streams::default();
        let mut rx = stream(&streams);
        streams.close_all();
        assert!(matches!(rx.try_recv(), Err(mpsc::error::TryRecvError::Disconnected)));
        assert!(streams.put("s", 0, Item::Stop).is_err());
    }

    #[test]
    fn pcm_is_little_endian_16_bit() {
        let pcm = base64::engine::general_purpose::STANDARD.encode([1u8, 0, 0xff, 0xff]);
        assert_eq!(samples(&json!({"pcm": pcm})).unwrap(), vec![1, -1]);
        assert!(samples(&json!({"pcm": "AQ=="})).is_err(), "an odd byte count");
        assert!(samples(&json!({"pcm": "%%"})).is_err());
    }

    #[test]
    fn events_carry_the_stream() {
        let line = event("voice-1", json!({"partial": "hi"})).to_line();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["method"], method::MUX_VOICE_STREAM_EVENT);
        assert_eq!(v["params"], json!({"stream": "voice-1", "partial": "hi"}));
    }
}
