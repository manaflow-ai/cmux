//! Admin client for the coordinator (the `weft admin` commands).

use anyhow::{Context, bail};
use serde::{Deserialize, Serialize};

use crate::types::{AuditEntry, ErrorBody, MintAuthKeyResponse, NodeSummary, PolicyResponse};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MintAuthKey {
    /// Tags with their `tag:` prefix; a tagged key enrolls tag-owned devices.
    #[serde(default)]
    pub tags: Vec<String>,
    /// The owning user for an untagged key.
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub reusable: bool,
    /// Skip device approval for devices enrolled with this key.
    #[serde(default)]
    pub preapproved: bool,
    pub ttl_seconds: u64,
}

pub struct AdminClient {
    base: String,
    token: String,
    http: reqwest::Client,
}

pub(crate) fn http_client() -> reqwest::Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(40))
        .build()
        .unwrap_or_default()
}

pub(crate) async fn check(response: reqwest::Response) -> anyhow::Result<reqwest::Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let text = response.text().await.unwrap_or_default();
    let message = serde_json::from_str::<ErrorBody>(&text).map(|body| body.error).unwrap_or(text);
    bail!("{status}: {message}")
}

impl AdminClient {
    pub fn new(base: &str, token: &str) -> Self {
        Self {
            base: base.trim_end_matches('/').to_owned(),
            token: token.to_owned(),
            http: http_client(),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }

    fn auth(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        request.header("authorization", format!("Bearer {}", self.token))
    }

    pub async fn create_tailnet(&self, name: &str, require_approval: bool) -> anyhow::Result<()> {
        let body = serde_json::json!({"name": name, "require_approval": require_approval});
        check(self.auth(self.http.post(self.url("/v1/tailnets"))).json(&body).send().await?)
            .await?;
        Ok(())
    }

    pub async fn set_policy(
        &self,
        tailnet: &str,
        policy: &str,
        if_version: Option<u64>,
    ) -> anyhow::Result<u64> {
        let mut request = self
            .auth(self.http.put(self.url(&format!("/v1/tailnets/{tailnet}/policy"))))
            .header("content-type", "application/json")
            .body(policy.to_owned());
        if let Some(version) = if_version {
            request = request.header("if-version", version.to_string());
        }
        let response: PolicyResponse = check(request.send().await?).await?.json().await?;
        Ok(response.version)
    }

    pub async fn get_policy(&self, tailnet: &str) -> anyhow::Result<PolicyResponse> {
        let request = self.auth(self.http.get(self.url(&format!("/v1/tailnets/{tailnet}/policy"))));
        Ok(check(request.send().await?).await?.json().await?)
    }

    /// Mint an auth key; returns the secret (shown once, stored hashed).
    pub async fn mint_auth_key(&self, tailnet: &str, key: &MintAuthKey) -> anyhow::Result<String> {
        let request = self
            .auth(self.http.post(self.url(&format!("/v1/tailnets/{tailnet}/authkeys"))))
            .json(key);
        let response: MintAuthKeyResponse = check(request.send().await?).await?.json().await?;
        Ok(response.key)
    }

    pub async fn nodes(&self, tailnet: &str) -> anyhow::Result<Vec<NodeSummary>> {
        let request = self.auth(self.http.get(self.url(&format!("/v1/tailnets/{tailnet}/nodes"))));
        Ok(check(request.send().await?).await?.json().await?)
    }

    pub async fn approve_node(&self, tailnet: &str, node: &str) -> anyhow::Result<()> {
        let request = self.auth(
            self.http.post(self.url(&format!("/v1/tailnets/{tailnet}/nodes/{node}/approve"))),
        );
        check(request.send().await?).await.context("approve")?;
        Ok(())
    }

    pub async fn revoke_node(&self, tailnet: &str, node: &str) -> anyhow::Result<()> {
        let request =
            self.auth(self.http.delete(self.url(&format!("/v1/tailnets/{tailnet}/nodes/{node}"))));
        check(request.send().await?).await.context("revoke")?;
        Ok(())
    }

    pub async fn audit(&self, tailnet: &str) -> anyhow::Result<Vec<AuditEntry>> {
        let request = self.auth(self.http.get(self.url(&format!("/v1/tailnets/{tailnet}/audit"))));
        Ok(check(request.send().await?).await?.json().await?)
    }
}
