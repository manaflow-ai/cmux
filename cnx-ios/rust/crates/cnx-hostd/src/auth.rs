//! Stack Auth tokens for the Mac: a fixed access token, or a refresh token
//! exchanged for fresh access tokens at
//! `POST <stack api>/api/v1/auth/sessions/current/refresh`.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use base64::Engine;
use tokio::sync::Mutex;

pub const DEFAULT_STACK_API: &str = "https://api.stack-auth.com";
/// The dev Stack project (PROTOCOL.md).
pub const DEFAULT_STACK_PROJECT: &str = "454ecd03-1db2-4050-845e-4ce5b0cd9895";

#[derive(Debug, Clone)]
pub enum TokenSource {
    /// A fixed access token (expires; fine for tests and short runs).
    Access(String),
    Refresh {
        refresh_token: String,
        project_id: String,
        publishable_key: Option<String>,
        api: String,
    },
}

pub struct Tokens {
    source: TokenSource,
    cached: Mutex<Option<(String, Option<u64>)>>,
    http: reqwest::Client,
}

/// The claims cnx-hostd reads from a Stack access token (no verification:
/// the token is the Mac's own; the backend verifies it).
#[derive(Debug, Clone, Default)]
pub struct Claims {
    pub sub: Option<String>,
    pub exp: Option<u64>,
}

pub fn claims(token: &str) -> Claims {
    let Some(payload) = token.split('.').nth(1) else { return Claims::default() };
    let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload.trim_end_matches('='))
    else {
        return Claims::default();
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return Claims::default() };
    Claims {
        sub: value.get("sub").and_then(|v| v.as_str()).map(str::to_owned),
        exp: value.get("exp").and_then(serde_json::Value::as_u64),
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_secs()
}

impl Tokens {
    pub fn new(source: TokenSource) -> Self {
        cnx_link::install_crypto_provider();
        Self { source, cached: Mutex::new(None), http: reqwest::Client::new() }
    }

    /// A current access token, refreshed 60 s before it expires.
    pub async fn access_token(&self) -> Result<String> {
        let mut cached = self.cached.lock().await;
        if let Some((token, exp)) = cached.as_ref()
            && exp.is_none_or(|exp| exp > now() + 60)
        {
            return Ok(token.clone());
        }
        let token = match &self.source {
            TokenSource::Access(token) => token.clone(),
            TokenSource::Refresh { refresh_token, project_id, publishable_key, api } => {
                let mut request = self
                    .http
                    .post(format!("{}/api/v1/auth/sessions/current/refresh", api.trim_end_matches('/')))
                    .header("content-type", "application/json")
                    .header("x-stack-project-id", project_id)
                    .header("x-stack-access-type", "client")
                    .header("x-stack-refresh-token", refresh_token)
                    .body("{}");
                if let Some(key) = publishable_key {
                    request = request.header("x-stack-publishable-client-key", key);
                }
                let response = request.send().await.context("Stack refresh request")?;
                let status = response.status();
                let body: serde_json::Value = response.json().await.unwrap_or_default();
                match body.get("access_token").and_then(|v| v.as_str()) {
                    Some(token) if status.is_success() => token.to_owned(),
                    _ => bail!("Stack refresh failed with {status}"),
                }
            }
        };
        let exp = claims(&token).exp;
        *cached = Some((token.clone(), exp));
        Ok(token)
    }

    /// Forget the cached token (after the backend refused it).
    pub async fn invalidate(&self) {
        *self.cached.lock().await = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_sub_and_exp() {
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"sub":"user-1","exp":99}"#);
        let claims = claims(&format!("h.{payload}.s"));
        assert_eq!(claims.sub.as_deref(), Some("user-1"));
        assert_eq!(claims.exp, Some(99));
        assert!(super::claims("not-a-jwt").sub.is_none());
    }
}
