//! Freestyle background requests, for an `exec-await` sent straight to the provider with a
//! machine's client session ([`crate::session`], [`crate::machine_io`]).
//!
//! Freestyle's edge cuts a request it holds open at about 120 s: an exec-await of a command with
//! a 290 s timeout answered 524 after 125 s (production, 2026-11-21), though exec-await runs a
//! command for up to 300 s. With [`AFTER_HEADER`], a request still running after [`AFTER_SECS`]
//! answers 202 with a request id instead; the provider finishes it on its own, and
//! `GET /v5/background-requests/{id}` answers 202 until the stored answer is ready, then that
//! answer. cmux-vm does the same for the cmux API's route (workers/cmux-vm
//! src/upstream/live-background.ts), and Freestyle's own SDK polls the same way.

use std::time::Duration;

use reqwest::StatusCode;
use serde_json::Value;
use tokio::time::Instant;

/// The header that lets a long request answer 202 instead of being held open.
pub const AFTER_HEADER: &str = "x-freestyle-background-after-secs";
/// Well before the edge's cut; a short exec (a 20 s read) stays one request, with no poll added.
pub const AFTER_SECS: u64 = 60;
const ID_HEADER: &str = "x-freestyle-background-request-id";
const POLL: Duration = if cfg!(test) { Duration::from_millis(10) } else { Duration::from_secs(2) };
const POLL_TIMEOUT: Duration = Duration::from_secs(30);
/// How long polls may fail (no answer, 429 or 5xx) since the last answered one before the answer
/// is given up as lost. It is apart from the caller's deadline, the way a CDN keeps its origin
/// timeout apart from its retry window: the provider stores the answer, so an overload (Freestyle
/// answered 503 to every poll for 9 min, rebake 45960390204, 2026-11-27) is waited out instead of
/// losing a command that ran. Five failed polls in a row (10 s) did.
const OUTAGE: Duration =
    if cfg!(test) { Duration::from_millis(400) } else { Duration::from_secs(300) };
/// The longest wait between polls while the provider fails them (it doubles from [`POLL`]).
const MAX_BACKOFF: Duration =
    if cfg!(test) { Duration::from_millis(80) } else { Duration::from_secs(15) };
/// A 202's body is a few dozen bytes.
const ACCEPTED_BYTES: usize = 4096;

/// A 202 whose stored answer did not come by the deadline: the command may have run.
#[derive(Debug, PartialEq, Eq)]
pub struct Lost;

fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

async fn request_id(accepted: reqwest::Response) -> Option<String> {
    let header = accepted.headers().get(ID_HEADER).and_then(|v| v.to_str().ok()).map(str::to_owned);
    let id = match header {
        Some(id) => id,
        None => {
            let body = crate::http::bounded_json(accepted, ACCEPTED_BYTES).await?;
            let field = body.get("requestId").or_else(|| body.get("request_id"));
            field.and_then(Value::as_str)?.to_owned()
        }
    };
    valid_id(&id).then_some(id)
}

/// The final answer of `response`: itself unless it is a 202, else the stored answer of its
/// background request, polled at `api_base_url` with `identity` (header name and value, never the
/// cmux credential) until `deadline`. Failed polls back off and keep going, past the deadline too,
/// until none has answered for [`OUTAGE`]. A stored refusal comes back as that answer (its status);
/// [`Lost`] when no answer came.
pub async fn settle(
    client: &reqwest::Client,
    api_base_url: &str,
    identity: (&str, &str),
    response: reqwest::Response,
    deadline: Instant,
) -> Result<reqwest::Response, Lost> {
    if response.status() != StatusCode::ACCEPTED {
        return Ok(response);
    }
    let id = request_id(response).await.ok_or(Lost)?;
    let url = format!("{}/v5/background-requests/{id}", api_base_url.trim_end_matches('/'));
    let mut last_answer = Instant::now();
    let mut wait = POLL;
    let mut failing = false;
    loop {
        let until = if failing { deadline.max(last_answer + OUTAGE) } else { deadline };
        if Instant::now() + wait >= until {
            return Err(Lost);
        }
        tokio::time::sleep(wait).await;
        let left = until.saturating_duration_since(Instant::now());
        let timeout = left.min(POLL_TIMEOUT).max(Duration::from_millis(1));
        match client.get(&url).header(identity.0, identity.1).timeout(timeout).send().await {
            Ok(answer) if answer.status() == StatusCode::ACCEPTED => {
                last_answer = Instant::now();
                wait = POLL;
                failing = false;
            }
            Ok(answer)
                if answer.status() != StatusCode::TOO_MANY_REQUESTS
                    && !answer.status().is_server_error() =>
            {
                return Ok(answer);
            }
            _ => {
                failing = true;
                wait = (wait * 2).min(MAX_BACKOFF);
            }
        }
    }
}

#[cfg(test)]
#[path = "background_tests.rs"]
mod tests;
