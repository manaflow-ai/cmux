//! Own the pool and executor together so a failed request leaves no live driver.
use std::time::Duration;

use serde_json::Value;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::watch;

use super::RequestDeadline;

/// How long one connect (DNS, TCP and TLS) may take before it is given up and
/// made again. A fresh Cloud machine's network attach lands about a second
/// after it boots, and a connect sent over the old addresses or routes before
/// it can hang with nothing failing it: a bind sent then waited out the whole
/// connect or request bound (10 s, 20 s) before its retry, whether or not the
/// address set changed (`network_changed` sees only that). A connect that
/// times out sent nothing, so it is made again at once while the request's
/// deadline lasts; a connect refused at once fails as before.
pub(super) const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

pub(super) struct Transport {
    client: reqwest::Client,
    runtime: Runtime,
    /// The address-change count this pool was made at.
    epoch: u64,
}

impl Transport {
    pub(super) fn new(allow_http: bool, epoch: u64) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .https_only(!allow_http)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(Duration::from_secs(20))
            .user_agent(concat!("cmux-host/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| "Cloud transport unavailable")?;
        let runtime = Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "Cloud transport unavailable")?;
        Ok(Self { client, runtime, epoch })
    }

    pub(super) fn epoch(&self) -> u64 {
        self.epoch
    }

    pub(super) fn request(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
        network: &mut watch::Receiver<u64>,
    ) -> Result<super::Response, String> {
        deadline.remaining().ok_or("Cloud request unavailable")?;
        let result = self.runtime.block_on(async {
            tokio::select! {
                biased;
                _ = crate::deadline::wait(deadline.active(), deadline.elapsed()) => {
                    Err("Cloud request unavailable".to_owned())
                }
                // The connection under this request may be dead: fail now rather than at the deadline.
                Ok(()) = network.changed() => Err("Cloud request unavailable".to_owned()),
                response = self.send_reconnecting(method, url, body, bearer, deadline) => response,
            }
        })?;
        deadline.remaining().ok_or("Cloud response unavailable")?;
        Ok(result)
    }

    /// [`Transport::send`], made again at once each time its connect timed out
    /// ([`CONNECT_TIMEOUT`]) while `deadline` has time left: a connect that
    /// hangs costs one connect timeout, not the request's whole bound.
    async fn send_reconnecting(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<super::Response, String> {
        loop {
            let remaining = deadline.remaining().ok_or("Cloud request unavailable")?;
            match self.send(method.clone(), url, body, bearer, remaining).await {
                Err(Failure::ConnectTimedOut) => continue,
                Err(failure) => return Err(failure.message()),
                Ok(response) => return Ok(response),
            }
        }
    }

    async fn send(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        remaining: Duration,
    ) -> Result<super::Response, Failure> {
        let mut request = self.client.request(method, url).timeout(remaining);
        if let Some(body) = body {
            request = request.json(body);
        }
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        let mut response = request.send().await.map_err(|error| {
            if error.is_connect() && error.is_timeout() {
                Failure::ConnectTimedOut
            } else {
                Failure::Other("Cloud request failed")
            }
        })?;
        let status = response.status().as_u16();
        // The one header a caller reads (a 429's wait), bounded like the body.
        let retry_after = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .filter(|value| value.len() <= 64)
            .map(str::to_owned);
        const LIMIT: usize = 1024 * 1024;
        if response.content_length().is_some_and(|n| n > LIMIT as u64) {
            return Err(Failure::Other("Cloud response too large"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) =
            response.chunk().await.map_err(|_| Failure::Other("Cloud response failed"))?
        {
            if chunk.len() > LIMIT - bytes.len() {
                return Err(Failure::Other("Cloud response too large"));
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(super::Response { status, retry_after, bytes })
    }

    pub(super) fn stop(self) {
        let Self { client, runtime, .. } = self;
        drop(client);
        // Async drivers and their credential-bearing sockets are aborted.
        // A system DNS lookup may finish separately; it owns only the hostname.
        // Never wait indefinitely for Tokio's blocking resolver pool.
        runtime.shutdown_timeout(Duration::ZERO);
    }
}

/// Why one [`Transport::send`] failed.
enum Failure {
    /// Its connect timed out ([`CONNECT_TIMEOUT`]): nothing was sent.
    ConnectTimedOut,
    Other(&'static str),
}

impl Failure {
    fn message(self) -> String {
        match self {
            Failure::ConnectTimedOut => "Cloud request failed".to_owned(),
            Failure::Other(message) => message.to_owned(),
        }
    }
}
