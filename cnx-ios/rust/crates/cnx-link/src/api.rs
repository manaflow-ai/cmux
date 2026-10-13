//! The backend's HTTP API (PROTOCOL.md "HTTP").

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceConfig {
    pub ice_servers: Vec<IceServer>,
    #[serde(default)]
    pub ttl: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRegistration {
    pub device_id: String,
    pub kind: String,
    pub name: String,
    pub team_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wg_public_key: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("request failed: {0}")]
    Http(String),
    #[error("{status}: {body}")]
    Status { status: u16, body: String },
}

#[derive(Debug, Clone)]
pub struct ApiClient {
    base: String,
    token: String,
    http: reqwest::Client,
}

impl ApiClient {
    pub fn new(base_url: &str, token: &str) -> Self {
        crate::install_crypto_provider();
        Self {
            base: base_url.trim_end_matches('/').to_owned(),
            token: token.to_owned(),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()
                .expect("HTTP client builds"),
        }
    }

    async fn check(response: reqwest::Response) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let body = response.text().await.unwrap_or_default();
        Err(ApiError::Status { status: status.as_u16(), body: body.chars().take(512).collect() })
    }

    /// `GET /v1/ice`.
    pub async fn ice(&self) -> Result<IceConfig, ApiError> {
        let response = self
            .http
            .get(format!("{}/v1/ice", self.base))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))
    }

    /// `POST /v1/devices` (upsert). Returns the backend's `device` object.
    pub async fn register_device(
        &self,
        registration: &DeviceRegistration,
    ) -> Result<serde_json::Value, ApiError> {
        let response = self
            .http
            .post(format!("{}/v1/devices", self.base))
            .bearer_auth(&self.token)
            .json(registration)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let body: serde_json::Value =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(body.get("device").cloned().unwrap_or(body))
    }

    /// `GET /v1/teams/:teamId/macs`.
    pub async fn macs(&self, team_id: &str) -> Result<Vec<crate::signaling::MacPresence>, ApiError> {
        #[derive(Deserialize)]
        struct Macs {
            macs: Vec<crate::signaling::MacPresence>,
        }
        let response = self
            .http
            .get(format!("{}/v1/teams/{team_id}/macs", self.base))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let macs: Macs =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(macs.macs)
    }
}

/// STUN servers (`host:port`) named by `stun:` URLs.
pub fn stun_servers(servers: &[IceServer]) -> Vec<String> {
    servers
        .iter()
        .flat_map(|server| server.urls.iter())
        .filter_map(|url| url.strip_prefix("stun:"))
        .map(|rest| {
            let host = rest.split('?').next().unwrap_or(rest);
            if host.rsplit_once(':').is_some_and(|(_, port)| port.parse::<u16>().is_ok()) {
                host.to_owned()
            } else {
                format!("{host}:3478")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stun_urls() {
        let servers = vec![IceServer {
            urls: vec![
                "stun:stun.cloudflare.com:3478".into(),
                "turn:turn.x:3478?transport=udp".into(),
                "stun:a.b".into(),
            ],
            username: None,
            credential: None,
        }];
        assert_eq!(stun_servers(&servers), vec!["stun.cloudflare.com:3478", "a.b:3478"]);
    }
}
