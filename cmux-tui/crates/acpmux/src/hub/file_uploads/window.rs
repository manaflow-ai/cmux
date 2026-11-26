//! A window of an upload's chunks in flight (`_acpmux/file_put_chunk`), instead of one chunk per
//! round trip.
//!
//! Stop-and-wait paid a full round trip per 512 KiB chunk: a 2 MiB upload over a lossy LTE link
//! spent 5.9 s of its 7.3 s waiting on four chunk answers in turn (the round-trip audit,
//! `round_trip_audit.rs`, 2026-11-24). Leo, 2026-11-24: "question why there may even need to be
//! round trips at all."
//!
//! A sender ([`send`]) keeps up to [`CHUNKS`] chunks unanswered and sends the finish right behind
//! the last chunk, marked [`IN_FLIGHT`], without waiting for any chunk's answer: one upload is about
//! one round trip plus the bytes' time on the link.
//!
//! A daemon that lists [`FEATURE`] takes that. Its requests run concurrently (each its own task,
//! `server/mod.rs`), so chunk k+1 may reach the disk before chunk k: a chunk ahead of the upload's
//! end by at most [`AHEAD_BYTES`] waits its turn ([`in_turn`]) for at most [`TURN_WAIT`], and a
//! finish marked [`IN_FLIGHT`] waits the same way for the bytes before it. Every write still lands
//! at the upload's end, in order, so the `.part` never has a hole and `_acpmux/file_put_status`
//! still answers the resumable offset. A chunk or a finish past either bound gets the answer it
//! always did (`upload.offset`, `upload.incomplete`).
//!
//! A peer that does not list [`FEATURE`] is sent one chunk at a time, then the finish, as before.

use super::CHUNK_BYTES;
use crate::rpc::{RpcError, method};
use cmux_json::JsonSet as _;
use futures_util::StreamExt as _;
use serde_json::{Value, json};
use std::future::Future;
use std::sync::LazyLock;
use std::time::Duration;
use tokio::sync::watch;

/// The `initialize` feature of a daemon that takes a window of chunks and a finish behind them.
pub const FEATURE: &str = "filePutWindow";
/// Chunks a sender keeps unanswered: 4 MiB, a few round trips of an LTE link's bytes.
pub const CHUNKS: usize = 8;
/// How far ahead of an upload's end a chunk's offset (or a finish's size) may be and still wait
/// for the bytes before it: twice a sender's window.
pub const AHEAD_BYTES: u64 = (2 * CHUNKS * CHUNK_BYTES) as u64;
/// The longest a chunk or a finish waits for the bytes before it. A chunk lost in front of it
/// (a sender that died) fails it then, as it would have failed at once before.
pub const TURN_WAIT: Duration = Duration::from_secs(30);
/// The finish param that says its chunks may still be in flight: it waits for them.
pub const IN_FLIGHT: &str = "chunksInFlight";

/// One upload's turn, striped as `hold` is: bumped whenever one of the stripe's uploads gains
/// bytes, finishes or goes. A waiter retries on each bump; a bump for another upload of the same
/// stripe costs it one more look.
static TURNS: LazyLock<[watch::Sender<u64>; super::STRIPES]> =
    LazyLock::new(|| std::array::from_fn(|_| watch::Sender::new(0)));

fn turn(upload: &str) -> &'static watch::Sender<u64> {
    let turns: &'static [watch::Sender<u64>; super::STRIPES] = &TURNS;
    let [first, ..] = turns;
    turns.get(super::stripe(upload)).unwrap_or(first)
}

/// Upload `upload` gained bytes, finished or went: its waiters look again.
pub(super) fn bump(upload: &str) {
    turn(upload).send_modify(|n| *n = n.wrapping_add(1));
}

/// Whether `e` is an upload that is behind `want` by no more than [`AHEAD_BYTES`]: its bytes
/// before `want` may still be on their way.
fn behind(e: &RpcError, want: u64) -> bool {
    let data = e.data.as_ref();
    let reason = data.and_then(|d| d.get("reason")).and_then(Value::as_str);
    let at = data.and_then(|d| d.get("offset")).and_then(Value::as_u64);
    matches!(reason, Some("upload.offset" | "upload.incomplete"))
        && at.is_some_and(|at| at < want && want - at <= AHEAD_BYTES)
}

/// Runs `attempt` (blocking: an append at `want`, or a finish of `want` bytes) off the runtime,
/// again each time upload `upload` changes while it answers that the bytes before `want` are not
/// all there, until [`TURN_WAIT`] has passed: then its last answer.
pub(super) async fn in_turn<F>(upload: &str, want: u64, attempt: F) -> Result<Value, RpcError>
where
    F: Fn() -> Result<Value, RpcError> + Clone + Send + 'static,
{
    let deadline = tokio::time::Instant::now() + TURN_WAIT;
    // Before the first try: a change after it is seen however soon it comes.
    let mut changed = turn(upload).subscribe();
    loop {
        let once = attempt.clone();
        let answer = tokio::task::spawn_blocking(once)
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
        match &answer {
            Err(e) if behind(e, want) => {}
            _ => return answer,
        }
        if !matches!(tokio::time::timeout_at(deadline, changed.changed()).await, Ok(Ok(()))) {
            return answer;
        }
    }
}

/// One chunk of an upload as a sender sends it: its offset, its decoded length and its base64.
pub struct Piece {
    pub offset: u64,
    pub len: usize,
    pub data: String,
}

/// One request of [`send`]: a chunk's answer is checked against the end it should give, a
/// finish's answer is returned.
async fn call<S, F>(
    send: &S,
    m: &'static str,
    params: Value,
    end: Option<u64>,
) -> Result<Option<Value>, RpcError>
where
    S: Fn(&'static str, Value) -> F,
    F: Future<Output = Result<Value, RpcError>>,
{
    let answer = send(m, params).await?;
    let Some(end) = end else { return Ok(Some(answer)) };
    match answer.get("offset").and_then(Value::as_u64) {
        Some(at) if at == end => Ok(None),
        at => Err(RpcError::internal(format!(
            "the chunk ending at {end} was answered with offset {}",
            at.map_or_else(|| "none".to_owned(), |at| at.to_string())
        ))),
    }
}

/// Sends an upload's chunks, `next` giving each in order (None after the last), with up to
/// `window` unanswered, then `finish` if given: right behind the last chunk, marked
/// [`IN_FLIGHT`], when `window` is more than one; after every chunk's answer otherwise. `base`
/// is a chunk's params without `offset` and `data`. Answers the finish's answer (None without a
/// finish). The first error ends it; the chunks still in flight are dropped unanswered (the
/// caller cancels the upload). Every request is bounded by `send`'s own deadline.
pub async fn send<S, F>(
    send: S,
    base: &Value,
    window: usize,
    mut next: impl FnMut() -> Result<Option<Piece>, RpcError>,
    finish: Option<Value>,
) -> Result<Option<Value>, RpcError>
where
    S: Fn(&'static str, Value) -> F,
    F: Future<Output = Result<Value, RpcError>>,
{
    let window = window.max(1);
    let mut flight = futures_util::stream::FuturesUnordered::new();
    let mut finish = finish;
    let mut last = false;
    loop {
        while !last && flight.len() < window {
            let Some(piece) = next()? else {
                last = true;
                // The finish goes right behind the last chunk: the daemon holds it for them.
                if window > 1
                    && let Some(mut params) = finish.take()
                {
                    params.set(IN_FLIGHT, json!(true));
                    flight.push(call(&send, method::MUX_FILE_PUT_FINISH, params, None));
                }
                break;
            };
            let mut params = base.clone();
            params.set("offset", json!(piece.offset));
            params.set("data", json!(piece.data));
            let end = piece.offset + piece.len as u64;
            flight.push(call(&send, method::MUX_FILE_PUT_CHUNK, params, Some(end)));
        }
        match flight.next().await {
            // The finish answered: every byte is on the disk.
            Some(Ok(Some(answer))) => return Ok(Some(answer)),
            Some(Ok(None)) => {}
            Some(Err(e)) => return Err(e),
            None if last => break,
            None => {}
        }
    }
    match finish {
        Some(params) => call(&send, method::MUX_FILE_PUT_FINISH, params, None).await,
        None => Ok(None),
    }
}

/// The window to use towards `peer`: [`CHUNKS`] when it takes them, one otherwise.
pub fn for_peer(peer: &crate::peer::Peer) -> usize {
    if peer.lists(FEATURE) { CHUNKS } else { 1 }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::lost_home_race_tests::isolated;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    const RTT: Duration = Duration::from_millis(80);
    const N: usize = 16;
    const PIECE: usize = 4 << 10;
    const CHAT: &str = "chat-window";

    fn file() -> Vec<u8> {
        (0..N * PIECE).map(|i| (i % 251) as u8).collect()
    }

    /// Uploads [`file`] through a link of [`RTT`] whose requests take up to 45 ms more one way,
    /// a later chunk of every four sooner than the one before it (so they reach the daemon out of
    /// order, and the finish before the last chunks): the time it took, the methods in the order
    /// sent, and whether a finish was marked [`IN_FLIGHT`].
    async fn upload(window: usize) -> (Duration, Vec<&'static str>, bool, Value) {
        use base64::Engine as _;
        let bytes = file();
        let began =
            super::super::begin(CHAT, &json!({"fileName": "w.bin", "size": bytes.len()})).unwrap();
        let id = began["uploadId"].as_str().unwrap().to_owned();
        let sent = Arc::new(Mutex::new((Vec::new(), false)));
        let log = sent.clone();
        let send = move |m: &'static str, p: Value| {
            let log = log.clone();
            async move {
                {
                    let mut log = log.lock().unwrap();
                    log.0.push(m);
                    log.1 |= p.get(IN_FLIGHT) == Some(&json!(true));
                }
                let k = p.get("offset").and_then(Value::as_u64).map_or(0, |o| o / PIECE as u64);
                let jitter = Duration::from_millis(15 * (3 - k % 4));
                tokio::time::sleep(RTT / 2 + jitter).await;
                let answer = match m {
                    method::MUX_FILE_PUT_CHUNK => super::super::chunk_in_turn(p).await,
                    _ => super::super::finish_in_turn(CHAT.to_owned(), p).await,
                };
                tokio::time::sleep(RTT / 2).await;
                answer
            }
        };
        let base = json!({"sessionId": CHAT, "uploadId": id});
        let mut pieces = bytes.chunks(PIECE).enumerate();
        let next = || {
            Ok(pieces.next().map(|(n, piece)| Piece {
                offset: (n * PIECE) as u64,
                len: piece.len(),
                data: base64::engine::general_purpose::STANDARD.encode(piece),
            }))
        };
        let finish = json!({"sessionId": CHAT, "uploadId": id, "fileName": "w.bin",
            "size": bytes.len()});
        let started = Instant::now();
        let answer = super::send(send, &base, window, next, Some(finish)).await.unwrap().unwrap();
        let took = started.elapsed();
        let (methods, marked) = sent.lock().unwrap().clone();
        (took, methods, marked, answer)
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap()
    }

    /// The round-trip audit's finding (2026-11-24): stop-and-wait paid one round trip per chunk.
    /// A window of chunks in flight, with the finish right behind them, lands N chunks in far
    /// fewer than N round trips, the file whole and in order even though its chunks and its
    /// finish reached the daemon out of order.
    #[test]
    fn a_window_of_chunks_lands_in_far_fewer_round_trips_than_chunks() {
        isolated(
            module_path!(),
            "a_window_of_chunks_lands_in_far_fewer_round_trips_than_chunks",
            |_| {
                let rt = runtime();
                let (took, methods, marked, answer) = rt.block_on(upload(CHUNKS));
                assert!(
                    took < RTT * N as u32 / 2,
                    "{N} chunks took {took:?} at {RTT:?} a round trip"
                );
                assert!(marked, "the finish went right behind the chunks: {methods:?}");
                assert_eq!(methods.iter().filter(|m| **m == method::MUX_FILE_PUT_CHUNK).count(), N);
                let path = answer["path"].as_str().unwrap();
                assert_eq!(std::fs::read(path).unwrap(), file());
                println!("WINDOWED {took:?}");
            },
            |_, out| assert!(out.contains("WINDOWED"), "{out}"),
        );
    }

    /// A peer that does not list [`FEATURE`] gets what it always did: one chunk per round trip,
    /// then a finish that waits for nothing.
    #[test]
    fn an_older_peer_is_sent_one_chunk_at_a_time_and_then_the_finish() {
        isolated(
            module_path!(),
            "an_older_peer_is_sent_one_chunk_at_a_time_and_then_the_finish",
            |_| {
                let rt = runtime();
                let (took, methods, marked, answer) = rt.block_on(upload(1));
                assert!(took >= RTT * N as u32, "{took:?}");
                assert!(!marked);
                assert_eq!(methods.last(), Some(&method::MUX_FILE_PUT_FINISH));
                assert_eq!(std::fs::read(answer["path"].as_str().unwrap()).unwrap(), file());
                println!("SERIAL {took:?}");
            },
            |_, out| assert!(out.contains("SERIAL"), "{out}"),
        );
    }

    /// A chunk further ahead than [`AHEAD_BYTES`], or one behind the upload's end, is refused at
    /// once as before, and so is a finish not marked [`IN_FLIGHT`] before its bytes are in.
    #[test]
    fn a_chunk_too_far_ahead_and_an_unmarked_early_finish_are_refused_at_once() {
        isolated(
            module_path!(),
            "a_chunk_too_far_ahead_and_an_unmarked_early_finish_are_refused_at_once",
            |_| {
                use base64::Engine as _;
                let rt = runtime();
                let size = AHEAD_BYTES * 2;
                let began =
                    super::super::begin(CHAT, &json!({"fileName": "f.bin", "size": size})).unwrap();
                let id = began["uploadId"].as_str().unwrap().to_owned();
                let data = base64::engine::general_purpose::STANDARD.encode([1u8; 16]);
                let started = Instant::now();
                let far = json!({"sessionId": CHAT, "uploadId": id, "offset": AHEAD_BYTES + 1,
                    "data": data});
                let e = rt.block_on(super::super::chunk_in_turn(far)).unwrap_err();
                assert_eq!(e.data.unwrap()["reason"], "upload.offset");
                let early = json!({"sessionId": CHAT, "uploadId": id, "fileName": "f.bin",
                    "size": size});
                let e = rt.block_on(super::super::finish_in_turn(CHAT.into(), early)).unwrap_err();
                assert_eq!(e.data.unwrap()["reason"], "upload.incomplete");
                assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
                println!("REFUSED");
            },
            |_, out| assert!(out.contains("REFUSED"), "{out}"),
        );
    }
}
