//! Connect-phase retry for Cloud HTTPS: a new socket when one's SYN goes nowhere.
//!
//! Some network paths black-hole one connection's 5-tuple: its SYN and every retransmit of it are
//! dropped, while a new socket (a new source port) connects in milliseconds. Measured on
//! 2026-11-17: 1 in 8 to 1 in 2 new connections to the Cloud API host. With no connect timeout a
//! request waits its whole deadline (20 s for a carrier ticket) on that one socket.
//!
//! A client built with [`CONNECT_TIMEOUT`] gives each resolved address its share of it (hyper
//! divides the timeout by the address count: 1 s each for the API host's two), and [`send`] sends a
//! request again, on a new connection, only when it failed to connect: nothing of it was written,
//! so even a mutation without an idempotency key is safe to send again. At most [`CONNECT_TRIES`]
//! tries; an answer, or any error after the connect, is the caller's as before.

use std::future::Future;
use std::time::Duration;

/// The connect budget of a Cloud HTTPS client, TLS included, for hosts that connect in 10 to 50 ms.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

/// Tries of one request when it does not connect.
pub const CONNECT_TRIES: u32 = 3;

/// Sends `request` through `send`, and again (a copy `copy` made before the send) while it fails
/// with an error `is_connect` calls a connect failure, at most `tries` times. A request `copy`
/// cannot copy is sent once. Any other answer, or the last try's, is the caller's.
pub async fn retry_connect<R, T, E, Fut>(
    tries: u32,
    request: R,
    copy: impl Fn(&R) -> Option<R>,
    send: impl Fn(R) -> Fut,
    is_connect: impl Fn(&E) -> bool,
) -> Result<T, E>
where
    Fut: Future<Output = Result<T, E>>,
{
    let mut current = request;
    let mut tried = 1;
    loop {
        let spare = if tried < tries { copy(&current) } else { None };
        match send(current).await {
            Err(error) if is_connect(&error) => match spare {
                Some(next) => {
                    current = next;
                    tried += 1;
                }
                None => return Err(error),
            },
            other => return other,
        }
    }
}

/// Sends `request`, again on a new connection when it did not connect (up to [`CONNECT_TRIES`]).
/// A request whose body cannot be cloned (a stream) is sent once.
pub async fn send(request: reqwest::RequestBuilder) -> Result<reqwest::Response, reqwest::Error> {
    retry_connect(
        CONNECT_TRIES,
        request,
        reqwest::RequestBuilder::try_clone,
        reqwest::RequestBuilder::send,
        reqwest::Error::is_connect,
    )
    .await
}

#[cfg(test)]
#[path = "connect_retry_tests.rs"]
mod tests;
