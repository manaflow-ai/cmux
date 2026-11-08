//! Own the pool and executor together so a failed request leaves no live driver.
use std::time::Duration;

use serde_json::Value;
use tokio::runtime::{Builder, Runtime};

use super::RequestDeadline;

pub(super) struct Transport {
    client: reqwest::Client,
    runtime: Runtime,
}

impl Transport {
    pub(super) fn new(allow_http: bool) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .https_only(!allow_http)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(20))
            .user_agent(concat!("cmux-host/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| "Cloud transport unavailable")?;
        let runtime = Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "Cloud transport unavailable")?;
        Ok(Self { client, runtime })
    }

    pub(super) fn request(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        let remaining = deadline.remaining().ok_or("Cloud request unavailable")?;
        let result = self.runtime.block_on(async {
            tokio::select! {
                biased;
                _ = crate::deadline::wait(deadline.active(), deadline.elapsed()) => {
                    Err("Cloud request unavailable".to_owned())
                }
                response = self.send(method, url, body, bearer, remaining) => response,
            }
        })?;
        deadline.remaining().ok_or("Cloud response unavailable")?;
        Ok(result)
    }

    async fn send(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        remaining: Duration,
    ) -> Result<(u16, Vec<u8>), String> {
        let mut request = self.client.request(method, url).timeout(remaining);
        if let Some(body) = body {
            request = request.json(body);
        }
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        let mut response = request.send().await.map_err(|_| "Cloud request failed")?;
        let status = response.status().as_u16();
        const LIMIT: usize = 1024 * 1024;
        if response.content_length().is_some_and(|n| n > LIMIT as u64) {
            return Err("Cloud response too large".into());
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "Cloud response failed")? {
            if chunk.len() > LIMIT - bytes.len() {
                return Err("Cloud response too large".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok((status, bytes))
    }

    pub(super) fn stop(self) {
        let Self { client, runtime } = self;
        drop(client);
        // Async drivers and their credential-bearing sockets are aborted.
        // A system DNS lookup may finish separately; it owns only the hostname.
        // Never wait indefinitely for Tokio's blocking resolver pool.
        runtime.shutdown_timeout(Duration::ZERO);
    }
}
