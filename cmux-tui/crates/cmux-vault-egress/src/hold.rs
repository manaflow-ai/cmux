//! Hold and retry for model requests toward a joined machine's hub.
//!
//! Every Claude a joined machine runs in team mode reaches the hub through
//! this proxy (`joined_model_plane.rs` in acpmux), and an answer the hub could
//! not give (a 429 or 529 from the inference pool, a 5xx from its edge, a
//! reset connection) used to reach Claude Code as an api_error that ends the
//! turn's call. Joined machines saw 450 to 1054 such errors per 1000 sessions
//! (2026-11-28) while the hub's pool was busy, and nothing between Claude Code
//! and the hub waited out a busy minute for them.
//!
//! For a `POST /v1/messages` (and `/v1/messages/...`) to a host [`Hold::applies`]
//! names, the proxy reads the body whole and, until a response byte reached the
//! client, re-sends it on any of these:
//!
//! - 429 or any 5xx: after the answer's `retry-after` (else a backoff doubling
//!   from [`Timings::floor`]), capped at [`Timings::step`], jittered;
//! - a connect failure or a connection that closed before an answer: on a
//!   fresh connection after [`Timings::net_step`].
//!
//! It holds until [`budget`] from the first failure: the client's own bound
//! (`X-Stainless-Timeout`, which Claude Code sets from `API_TIMEOUT_MS`) less
//! [`Timings::client_slack`], within [`Timings::stream_cap`] for a stream and
//! [`Timings::budget`] for a non-stream; [`Timings::budget`] when the header is
//! missing. Claude Code drops a request that sees no byte for about 5 min, so a
//! stream held past [`Timings::commit`] is answered `200 text/event-stream`
//! and gets an SSE `ping` every [`Timings::ping`] while the hold goes on; the
//! hub's stream follows once one comes, and a hold that runs out ends it with an
//! SSE `error` carrying the hub's own error (Claude Code retries that within the
//! turn). Uncommitted, a hold that runs out hands the last answer up as it came,
//! or a 529 `overloaded_error` with `retry-after` after transport failures.
//!
//! Headers (the substituted credential included) and the body go out the same
//! on every try. Each wait is a `vault.egress_hold` line, each run-out a
//! `vault.egress_hold_give_up`, and an answer after holds a `vault.egress_held_ok`.

use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode, header};
use http_body_util::{BodyExt, Full};
use hyper::body::{Frame, Incoming};
use tokio::sync::{Mutex, mpsc, oneshot};

use crate::proxy::{Body, Upstream};

/// Whether requests to `host`, `port` are held.
pub type Applies = Arc<dyn Fn(&str, u16) -> bool + Send + Sync>;

/// Which requests are held, and for how long.
#[derive(Clone)]
pub struct Hold {
    /// The hosts whose model requests are held: the hub's.
    pub applies: Applies,
    pub timings: Timings,
}

/// The bounds of a hold ([`Timings::default`] is what the daemon uses).
#[derive(Clone, Copy, Debug)]
pub struct Timings {
    /// A non-stream request's hold, and any request's when the client states no bound.
    pub budget: Duration,
    /// The longest a stream is held, whatever bound the client states.
    pub stream_cap: Duration,
    /// Kept off the client's stated bound, so the hold ends before the client does.
    pub client_slack: Duration,
    /// The longest one wait.
    pub step: Duration,
    /// The first wait after a refusal with no `retry-after`, and the shortest wait.
    pub floor: Duration,
    /// The wait after a transport failure.
    pub net_step: Duration,
    /// A stream held this long is answered and pinged.
    pub commit: Duration,
    /// How often a committed stream is pinged.
    pub ping: Duration,
    /// A larger body is not held (sent as it comes, once).
    pub max_body: usize,
    /// How long a refused answer's body is read before its connection is dropped.
    pub drain: Duration,
}

impl Default for Timings {
    fn default() -> Self {
        Timings {
            budget: Duration::from_secs(240),
            stream_cap: Duration::from_secs(3540),
            client_slack: Duration::from_secs(60),
            step: Duration::from_secs(30),
            floor: Duration::from_secs(1),
            net_step: Duration::from_secs(3),
            commit: Duration::from_secs(120),
            ping: Duration::from_secs(15),
            max_body: 64 << 20,
            drain: Duration::from_secs(10),
        }
    }
}

const PING_EVENT: &[u8] = b"event: ping\ndata: {\"type\": \"ping\"}\n\n";
/// The `retry-after` of a give-up after transport failures.
const GIVE_UP_RETRY_AFTER: &str = "5";

impl Hold {
    /// Whether this request is held.
    pub(crate) fn wants(&self, method: &Method, path: &str, host: &str, port: u16) -> bool {
        method == Method::POST
            && (path == "/v1/messages" || path.starts_with("/v1/messages/"))
            && (self.applies)(host, port)
    }
}

/// How long a request may be held from its first failure ([`Timings`]).
pub(crate) fn budget(t: &Timings, stream: bool, client_timeout: Option<&str>) -> Duration {
    let Some(bound) = client_timeout
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|b| b.is_finite() && *b > 0.0)
    else {
        return t.budget;
    };
    let left = Duration::from_secs_f64((bound - t.client_slack.as_secs_f64()).max(0.0));
    left.min(if stream { t.stream_cap } else { t.budget })
}

/// Whether a request body asks for a stream (`"stream": true` at the top).
pub(crate) fn is_stream(body: &[u8]) -> bool {
    #[derive(serde::Deserialize)]
    struct Head {
        #[serde(default)]
        stream: bool,
    }
    serde_json::from_slice::<Head>(body).is_ok_and(|h| h.stream)
}

fn retryable(code: StatusCode) -> bool {
    code == StatusCode::TOO_MANY_REQUESTS || code.is_server_error()
}

/// A `retry-after` in seconds (the HTTP-date form is not used by the hub).
fn retry_after(headers: &HeaderMap) -> Option<Duration> {
    let text = headers.get(header::RETRY_AFTER)?.to_str().ok()?;
    let secs = text.trim().parse::<f64>().ok().filter(|s| s.is_finite() && *s >= 0.0)?;
    Some(Duration::from_secs_f64(secs.min(86_400.0)))
}

/// Up to a quarter more, so held requests do not all come back at once.
fn jitter(wait: Duration) -> Duration {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    wait + wait.mul_f64(f64::from(nanos % 1000) / 4000.0)
}

/// The response body of a committed stream: what the hold writes, as it writes it.
struct Channel(mpsc::Receiver<Bytes>);

impl hyper::body::Body for Channel {
    type Data = Bytes;
    type Error = hyper::Error;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, hyper::Error>>> {
        self.0.poll_recv(cx).map(|b| b.map(|b| Ok(Frame::data(b))))
    }
}

fn full(bytes: Bytes) -> Body {
    Full::new(bytes).map_err(|never| match never {}).boxed()
}

fn overloaded(message: &str) -> Bytes {
    Bytes::from(
        serde_json::json!({"type": "error", "error": {"type": "overloaded_error", "message": message}})
            .to_string(),
    )
}

/// An error answer as the SSE `error` event Claude reads on a stream already answered 200.
fn sse_error(body: &[u8]) -> Bytes {
    let data = serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("error").cloned())
        .map(|error| Bytes::from(serde_json::json!({"type": "error", "error": error}).to_string()))
        .unwrap_or_else(|| overloaded("the hub refused the request"));
    let mut out = b"event: error\ndata: ".to_vec();
    out.extend_from_slice(&data);
    out.extend_from_slice(b"\n\n");
    Bytes::from(out)
}

/// What the last try got.
enum Last {
    Refused(http::response::Parts, Bytes),
    Net,
}

/// Where the answer goes: the client's response, or once committed, its stream.
enum Sink {
    Head(oneshot::Sender<Response<Body>>),
    Stream(mpsc::Sender<Bytes>),
}

impl Sink {
    async fn closed(&mut self) {
        match self {
            Sink::Head(tx) => tx.closed().await,
            Sink::Stream(tx) => tx.closed().await,
        }
    }
}

fn request(parts: &http::request::Parts, body: &Bytes) -> Request<Body> {
    let mut req = Request::new(full(body.clone()));
    *req.method_mut() = parts.method.clone();
    *req.uri_mut() = parts.uri.clone();
    *req.version_mut() = parts.version;
    *req.headers_mut() = parts.headers.clone();
    req
}

/// Send `parts` + `body` on `upstream`, holding as [`Timings`] say; the answer goes to `head`.
pub(crate) async fn run(
    upstream: Arc<Mutex<Upstream>>,
    parts: http::request::Parts,
    body: Bytes,
    t: Timings,
    head: oneshot::Sender<Response<Body>>,
    host: Arc<String>,
) {
    let stream = is_stream(&body);
    let client_timeout = parts.headers.get("x-stainless-timeout").and_then(|v| v.to_str().ok());
    let budget = budget(&t, stream, client_timeout);
    let mut upstream = upstream.lock_owned().await;
    let mut sink = Sink::Head(head);
    let mut first_fail: Option<Instant> = None;
    let mut tries: u32 = 0;
    let mut refusals: u32 = 0;
    loop {
        tries += 1;
        let sent = tokio::select! {
            sent = upstream.send(request(&parts, &body), true) => sent,
            () = sink.closed() => return,
        };
        let (last, hint) = match sent {
            Ok(response) if !retryable(response.status()) => {
                if let Some(first) = first_fail {
                    tracing::info!(
                        host = %host, status = response.status().as_u16(),
                        tries, held_s = first.elapsed().as_secs_f64(), stream, "vault.egress_held_ok"
                    );
                }
                deliver(response, sink).await;
                return;
            }
            Ok(response) => {
                refusals += 1;
                let hint = retry_after(response.headers());
                let (rparts, rbody) = response.into_parts();
                let bytes = match tokio::time::timeout(t.drain, rbody.collect()).await {
                    Ok(Ok(collected)) => collected.to_bytes(),
                    _ => {
                        upstream.reset();
                        Bytes::new()
                    }
                };
                let backoff = t.floor.saturating_mul(1 << refusals.saturating_sub(1).min(16));
                (Last::Refused(rparts, bytes), hint.unwrap_or(backoff).clamp(t.floor, t.step))
            }
            Err(_) => (Last::Net, t.net_step),
        };
        let now = Instant::now();
        let first = *first_fail.get_or_insert(now);
        let wait = jitter(hint);
        let status = match &last {
            Last::Refused(p, _) => p.status.as_u16(),
            Last::Net => 0,
        };
        if now + wait >= first + budget {
            tracing::warn!(
                host = %host, status, tries,
                held_s = (now - first).as_secs_f64(), budget_s = budget.as_secs_f64(), stream,
                committed = matches!(sink, Sink::Stream(_)), "vault.egress_hold_give_up"
            );
            give_up(last, sink).await;
            return;
        }
        tracing::info!(
            host = %host, status, tries, wait_s = wait.as_secs_f64(),
            budget_s = budget.as_secs_f64(), stream, "vault.egress_hold"
        );
        if stream && now + wait - first >= t.commit && matches!(sink, Sink::Head(_)) {
            let (body_tx, body_rx) = mpsc::channel(16);
            let mut response = Response::new(Channel(body_rx).boxed());
            let headers = response.headers_mut();
            headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
            headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
            headers.insert("x-cmux-egress", HeaderValue::from_static("held"));
            if let Sink::Head(tx) = std::mem::replace(&mut sink, Sink::Stream(body_tx))
                && tx.send(response).is_err()
            {
                return;
            }
            tracing::info!(host = %host, tries, stream, "vault.egress_stream_commit");
        }
        if !wait_out(&mut sink, wait, t.ping).await {
            return;
        }
    }
}

/// Sleep `wait`, pinging a committed stream; false when the client went away.
async fn wait_out(sink: &mut Sink, wait: Duration, ping: Duration) -> bool {
    let until = Instant::now() + wait;
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return true;
        }
        let step = if matches!(sink, Sink::Stream(_)) { left.min(ping) } else { left };
        tokio::select! {
            () = tokio::time::sleep(step) => {}
            () = sink.closed() => return false,
        }
        if let Sink::Stream(tx) = sink
            && Instant::now() < until
            && tx.send(Bytes::from_static(PING_EVENT)).await.is_err()
        {
            return false;
        }
    }
}

async fn deliver(response: Response<Incoming>, sink: Sink) {
    match sink {
        Sink::Head(tx) => {
            let _ = tx.send(response.map(BodyExt::boxed));
        }
        Sink::Stream(tx) => {
            let ok = response.status().is_success();
            let mut body = response.into_body();
            if !ok {
                let bytes = body.collect().await.map(|c| c.to_bytes()).unwrap_or_default();
                let _ = tx.send(sse_error(&bytes)).await;
                return;
            }
            while let Some(frame) = body.frame().await {
                match frame {
                    Ok(frame) => {
                        if let Ok(data) = frame.into_data()
                            && tx.send(data).await.is_err()
                        {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = tx.send(sse_error(&overloaded("the hub's stream dropped"))).await;
                        return;
                    }
                }
            }
        }
    }
}

async fn give_up(last: Last, sink: Sink) {
    match (sink, last) {
        (Sink::Stream(tx), Last::Refused(_, bytes)) => {
            let _ = tx.send(sse_error(&bytes)).await;
        }
        (Sink::Stream(tx), Last::Net) => {
            let _ = tx.send(sse_error(&overloaded("the hub could not be reached"))).await;
        }
        (Sink::Head(tx), Last::Refused(parts, bytes)) => {
            let mut response = Response::from_parts(parts, full(bytes));
            response.headers_mut().remove(header::TRANSFER_ENCODING);
            response.headers_mut().remove(header::CONTENT_LENGTH);
            response.headers_mut().insert("x-cmux-egress", HeaderValue::from_static("give-up"));
            let _ = tx.send(response);
        }
        (Sink::Head(tx), Last::Net) => {
            let mut response = Response::new(full(overloaded("the hub could not be reached")));
            *response.status_mut() =
                StatusCode::from_u16(529).unwrap_or(StatusCode::SERVICE_UNAVAILABLE);
            let headers = response.headers_mut();
            headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
            headers.insert(header::RETRY_AFTER, HeaderValue::from_static(GIVE_UP_RETRY_AFTER));
            headers.insert("x-cmux-egress", HeaderValue::from_static("give-up"));
            let _ = tx.send(response);
        }
    }
}

#[cfg(test)]
#[path = "hold_tests.rs"]
mod tests;
