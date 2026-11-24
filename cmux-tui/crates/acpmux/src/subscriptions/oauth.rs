//! Device authorization for xAI, GitHub and Kimi Code. Responses may contain credentials,
//! so errors carry fixed codes only.

use std::sync::OnceLock;
use std::time::Duration;

use base64::Engine as _;
use reqwest::{Client, RequestBuilder, Url};
use serde::Deserialize;
use tokio::time::Instant;

use super::{Failure, KimiRegion, Provider, Record, now};

const GROK_CLIENT: &str = "b1a00492-073a-47ea-816f-4c329264a828";
const GROK_SCOPES: &str = "openid profile email offline_access grok-cli:access api:access";
// OpenCode's GitHub Copilot provider.
const COPILOT_CLIENT: &str = "Ov23li8tweQw6odWQebz";
// https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/auth/oauth.py
const KIMI_CLIENT: &str = "17e5f671-d194-4dfb-9706-5516cb48c098";
const DEVICE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";

pub(super) struct Endpoints {
    pub grok_issuer: String,
    pub github: String,
    pub github_api: String,
    pub kimi_global: String,
    pub kimi_china: String,
    pub openrouter: String,
}

impl Default for Endpoints {
    fn default() -> Self {
        Self {
            grok_issuer: "https://auth.x.ai".into(),
            github: "https://github.com".into(),
            github_api: "https://api.github.com".into(),
            kimi_global: "https://auth.kimi.ai".into(),
            kimi_china: "https://auth.kimi.com".into(),
            openrouter: "https://openrouter.ai".into(),
        }
    }
}

pub(super) struct Challenge {
    pub url: String,
    pub code: String,
    pub deadline: Instant,
    pub expires_at: i64,
    pub interval: Duration,
    device_code: String,
    region: Option<KimiRegion>,
    device_id: Option<String>,
}

#[derive(Deserialize)]
struct Discovery {
    issuer: String,
    device_authorization_endpoint: String,
    token_endpoint: String,
    revocation_endpoint: String,
}

#[derive(Deserialize)]
struct Device {
    device_code: String,
    user_code: String,
    #[serde(default)]
    verification_uri: String,
    verification_uri_complete: Option<String>,
    expires_in: Option<u64>,
    interval: Option<u64>,
}

#[derive(Deserialize)]
struct TokenReply {
    access_token: Option<String>,
    id_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
    error: Option<String>,
    interval: Option<u64>,
}

#[derive(Deserialize)]
struct CopilotEntitlement {
    chat_enabled: Option<bool>,
    endpoints: Option<CopilotEndpoints>,
}

#[derive(Deserialize)]
struct CopilotEndpoints {
    api: Option<String>,
}

impl TokenReply {
    fn record(self, provider: Provider, prior: Option<&Record>) -> Result<Record, Failure> {
        let access_token = self
            .access_token
            .filter(|value| crate::agent_credentials::token_shaped(value))
            .ok_or("bad_reply")?;
        if provider == Provider::Copilot {
            return Ok(Record {
                access_token,
                refresh_token: String::new(),
                expires_at: 0,
                region: None,
                device_id: None,
                sub: None,
                login: None,
                email: None,
            });
        }
        let now = now();
        let expires_at = self
            .expires_in
            .and_then(|seconds| now.checked_add(seconds))
            .filter(|expiry| *expiry > now)
            .ok_or("bad_reply")?;
        let refresh_token = self
            .refresh_token
            .or_else(|| prior.map(|record| record.refresh_token.clone()))
            .filter(|value| crate::agent_credentials::token_shaped(value))
            .ok_or("bad_reply")?;
        let claims = self.id_token.as_deref().and_then(identity_claims);
        Ok(Record {
            access_token,
            refresh_token,
            expires_at,
            region: prior.and_then(|record| record.region),
            device_id: prior.and_then(|record| record.device_id.clone()),
            sub: prior.and_then(|record| record.sub.clone()).or_else(|| identity(claims.as_ref()?.get("sub")?)),
            login: prior.and_then(|record| record.login.clone()),
            email: prior.and_then(|record| record.email.clone()).or_else(|| identity(claims.as_ref()?.get("email")?)),
        })
    }
}

pub(super) struct OAuth {
    pub(super) endpoints: Endpoints,
    kimi_device_id: OnceLock<String>,
    http: OnceLock<Client>,
}

impl OAuth {
    pub fn new(endpoints: Endpoints) -> Self {
        Self { endpoints, http: OnceLock::new(), kimi_device_id: OnceLock::new() }
    }

    pub(super) fn http(&self) -> Result<&Client, Failure> {
        if let Some(client) = self.http.get() {
            return Ok(client);
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|_| "network")?;
        Ok(self.http.get_or_init(|| client))
    }

    fn grok(&self, path: &str) -> String {
        format!("{}{path}", self.endpoints.grok_issuer)
    }

    fn kimi(&self, region: KimiRegion, path: &str) -> String {
        let host = match region {
            KimiRegion::Global => &self.endpoints.kimi_global,
            KimiRegion::China => &self.endpoints.kimi_china,
        };
        format!("{host}/api/oauth/{path}")
    }

    fn device_id(&self) -> &str {
        self.kimi_device_id.get_or_init(|| uuid::Uuid::new_v4().simple().to_string())
    }

    fn kimi_headers(&self, request: RequestBuilder, id: Option<&str>) -> RequestBuilder {
        let id = match id {
            Some(id) => id,
            None => self.device_id(),
        };
        request
            .header("User-Agent", "cmux")
            .header("X-Msh-Platform", "cmux")
            .header("X-Msh-Device-Id", id)
            .header("X-Msh-Device-Name", "cmux")
    }

    fn token_url(&self, provider: Provider, region: Option<KimiRegion>) -> String {
        match provider {
            Provider::Grok => self.grok("/oauth2/token"),
            Provider::Copilot => format!("{}/login/oauth/access_token", self.endpoints.github),
            Provider::Kimi => self.kimi(region.unwrap_or(KimiRegion::Global), "token"),
        }
    }

    pub async fn begin(
        &self,
        provider: Provider,
        region: Option<KimiRegion>,
    ) -> Result<Challenge, Failure> {
        let http = self.http()?;
        let request = match provider {
            Provider::Grok => {
                let discovery: Discovery =
                    reply(http.get(self.grok("/.well-known/openid-configuration"))).await?;
                let device = self.grok("/oauth2/device/code");
                if discovery.issuer != self.endpoints.grok_issuer
                    || discovery.device_authorization_endpoint != device
                    || discovery.token_endpoint != self.token_url(provider, region)
                    || discovery.revocation_endpoint != self.grok("/oauth2/revoke")
                {
                    return Err("bad_reply");
                }
                form(http.post(device), &[("client_id", GROK_CLIENT), ("scope", GROK_SCOPES)])
            }
            Provider::Copilot => http
                .post(format!("{}/login/device/code", self.endpoints.github))
                .json(&serde_json::json!({"client_id": COPILOT_CLIENT, "scope": "read:user"})),
            Provider::Kimi => form(
                self.kimi_headers(
                    http.post(
                        self.kimi(region.unwrap_or(KimiRegion::Global), "device_authorization"),
                    ),
                    None,
                ),
                &[("client_id", KIMI_CLIENT)],
            ),
        };
        let device: Device = reply(request).await?;
        if provider == Provider::Copilot && Url::parse(&device.verification_uri).ok()
            .and_then(|url| url.host_str().map(str::to_owned))
            .is_some_and(|host| host.ends_with(".ghe.com"))
        {
            return Err("enterprise_server");
        }
        let url = if provider == Provider::Kimi {
            device
                .verification_uri_complete
                .filter(|url| verification_url(provider, url))
                .unwrap_or(device.verification_uri)
        } else {
            device.verification_uri
        };
        let seconds = device
            .expires_in
            .filter(|ttl| *ttl > 0)
            .or_else(|| (provider == Provider::Kimi).then_some(600))
            .ok_or("bad_reply")?
            .min(1800);
        if device.device_code.is_empty()
            || device.device_code.len() > 4096
            || device.user_code.is_empty()
            || device.user_code.len() > 64
            || !device.user_code.bytes().all(|byte| byte.is_ascii_graphic())
            || !verification_url(provider, &url)
        {
            return Err("bad_reply");
        }
        Ok(Challenge {
            url,
            code: device.user_code,
            deadline: Instant::now() + Duration::from_secs(seconds),
            expires_at: now() + seconds as i64,
            interval: Duration::from_secs(device.interval.unwrap_or(5).clamp(1, 900)),
            device_code: device.device_code,
            region,
            device_id: (provider == Provider::Kimi).then(|| self.device_id().to_owned()),
        })
    }

    pub async fn poll(&self, provider: Provider, challenge: Challenge) -> Result<Record, Failure> {
        let http = self.http()?;
        let mut interval = challenge.interval;
        let token_url = self.token_url(provider, challenge.region);
        let mut retried_non_json = false;
        loop {
            let seconds_left = challenge.expires_at.saturating_sub(now()).max(0) as u64;
            let next = Instant::now() + interval.min(Duration::from_secs(seconds_left));
            if next >= challenge.deadline {
                tokio::time::sleep_until(challenge.deadline).await;
                return Err("expired_token");
            }
            tokio::time::sleep_until(next).await;
            if now() >= challenge.expires_at { return Err("expired_token"); }
            let request = match provider {
                Provider::Grok => form(
                    http.post(&token_url),
                    &[
                        ("client_id", GROK_CLIENT),
                        ("device_code", challenge.device_code.as_str()),
                        ("grant_type", DEVICE_GRANT),
                    ],
                ),
                Provider::Kimi => form(
                    self.kimi_headers(http.post(&token_url), challenge.device_id.as_deref()),
                    &[
                        ("client_id", KIMI_CLIENT),
                        ("device_code", &challenge.device_code),
                        ("grant_type", DEVICE_GRANT),
                    ],
                ),
                Provider::Copilot => http.post(&token_url).json(&serde_json::json!({
                    "client_id": COPILOT_CLIENT, "device_code": challenge.device_code,
                    "grant_type": DEVICE_GRANT,
                })),
            };
            let response = request.header("Accept", "application/json").send().await;
            let response = match response {
                Ok(response) => response,
                Err(error) if error.is_timeout() || error.is_connect() => {
                    interval = (interval * 2).min(Duration::from_secs(900));
                    continue;
                }
                Err(_) => return Err("network"),
            };
            if response.status().is_server_error() {
                interval = (interval * 2).min(Duration::from_secs(900));
                continue;
            }
            if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
                interval = (interval + Duration::from_secs(5)).min(Duration::from_secs(900));
                continue;
            }
            let ok = response.status().is_success();
            let token: TokenReply = match response.json().await {
                Ok(token) => token,
                Err(_) if !retried_non_json => {
                    retried_non_json = true;
                    continue;
                }
                Err(_) => return Err("bad_reply"),
            };
            retried_non_json = false;
            match token.error.as_deref() {
                Some("authorization_pending") => {}
                Some("slow_down") => {
                    interval = (interval + Duration::from_secs(5))
                        .max(Duration::from_secs(token.interval.unwrap_or(0).min(900)));
                }
                Some("access_denied") => return Err("access_denied"),
                Some("enterprise_server" | "github_enterprise_server") if provider == Provider::Copilot =>
                    return Err("enterprise_server"),
                Some("expired_token") => return Err("expired_token"),
                Some(_) => return Err("provider_error"),
                None if ok => {
                    let mut record = token.record(provider, None)?;
                    record.region = challenge.region;
                    record.device_id = challenge.device_id;
                    if provider == Provider::Copilot {
                        self.copilot_endpoint(&record.access_token).await?;
                        let user: serde_json::Value = reply(http.get(format!("{}/user", self.endpoints.github_api))
                            .header("User-Agent", "cmux").bearer_auth(&record.access_token)).await?;
                        record.sub = user["id"].as_u64().map(|id| id.to_string());
                        record.login = identity(&user["login"]);
                        if record.sub.is_none() || record.login.is_none() { return Err("bad_reply"); }
                    }
                    if provider == Provider::Kimi && record.sub.is_none()
                        && let Some(region) = record.region
                        && let Some(user) = self.kimi_identity(http, region, &record).await
                    {
                        record.sub = identity(&user["sub"]).or_else(|| user["id"].as_u64().map(|id| id.to_string()));
                        record.login = identity(&user["name"]);
                        record.email = identity(&user["email"]);
                    }
                    return Ok(record);
                }
                None => return Err("provider_error"),
            }
        }
    }

    async fn kimi_identity(&self, http: &Client, region: KimiRegion, record: &Record) -> Option<serde_json::Value> {
        let issuer = match region {
            KimiRegion::Global => &self.endpoints.kimi_global,
            KimiRegion::China => &self.endpoints.kimi_china,
        };
        let discovery: serde_json::Value = reply(http.get(format!("{issuer}/.well-known/openid-configuration"))
            .timeout(Duration::from_secs(3))).await.ok()?;
        let endpoint = Url::parse(discovery["userinfo_endpoint"].as_str()?).ok()?;
        if endpoint.origin() != Url::parse(issuer).ok()?.origin() || !endpoint.username().is_empty()
            || endpoint.password().is_some()
        {
            return None;
        }
        reply(self.kimi_headers(http.get(endpoint), record.device_id.as_deref())
            .timeout(Duration::from_secs(3)).bearer_auth(&record.access_token)).await.ok()
    }

    pub async fn copilot_endpoint(&self, token: &str) -> Result<Option<String>, Failure> {
        let response = self
            .http()?
            .get(format!("{}/copilot_internal/user", self.endpoints.github_api))
            .header("X-GitHub-Api-Version", "2025-04-01")
            .header("User-Agent", "cmux")
            .timeout(Duration::from_secs(5))
            .bearer_auth(token);
        let response = response.header("Accept", "application/json").send().await.map_err(|_| "network")?;
        match response.status().as_u16() {
            401 => return Err("reauth_required"),
            403 | 404 => return Err("no_copilot_access"),
            200..=299 => {}
            _ => return Err("provider_error"),
        }
        let user: CopilotEntitlement = response.json().await.map_err(|_| "bad_reply")?;
        if user.chat_enabled == Some(false) {
            return Err("no_copilot_access");
        }
        user.endpoints
            .and_then(|endpoints| endpoints.api)
            .map(|api| copilot_api_url(&api).ok_or("bad_reply"))
            .transpose()
    }

    pub async fn refresh(&self, provider: Provider, prior: &Record) -> Result<Record, Failure> {
        let request = self.http()?.post(self.token_url(provider, prior.region));
        let (request, client) = if provider == Provider::Kimi {
            (self.kimi_headers(request, prior.device_id.as_deref()), KIMI_CLIENT)
        } else {
            (request, GROK_CLIENT)
        };
        let response = form(
            request,
            &[
                ("client_id", client),
                ("grant_type", "refresh_token"),
                ("refresh_token", prior.refresh_token.as_str()),
            ],
        )
        .send()
        .await
        .map_err(|_| "network")?;
        let ok = response.status().is_success();
        if provider == Provider::Kimi && response.status().as_u16() == 401 {
            return Err("reauth_required");
        }
        let tokens: TokenReply = response.json().await.map_err(|_| "bad_reply")?;
        match tokens.error.as_deref() {
            Some("invalid_grant") => Err("reauth_required"),
            Some("invalid_token") if provider != Provider::Kimi => Err("reauth_required"),
            None if ok => tokens.record(provider, Some(prior)),
            _ => Err("provider_error"),
        }
    }

    pub async fn revoke(&self, provider: Provider, record: &Record) {
        // GitHub requires the OAuth application's secret to revoke its grant.
        if provider == Provider::Grok
            && let Ok(http) = self.http()
        {
            let _ = form(
                http.post(self.grok("/oauth2/revoke")),
                &[
                    ("client_id", GROK_CLIENT),
                    ("token", record.refresh_token.as_str()),
                    ("token_type_hint", "refresh_token"),
                ],
            )
            .send()
            .await;
        }
    }
}

// Identity is display and deduplication metadata from the issuer's own HTTPS
// token response. It never grants access or participates in authorization.
fn identity_claims(id_token: &str) -> Option<serde_json::Value> {
    let payload = id_token.split('.').nth(1)?;
    if payload.len() > 16_384 { return None; }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn identity(value: &serde_json::Value) -> Option<String> {
    let value = value.as_str()?;
    (!value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

fn copilot_api_url(raw: &str) -> Option<String> {
    let url = Url::parse(raw).ok()?;
    let host = url.host_str()?;
    (url.scheme() == "https"
        && host.ends_with(".githubcopilot.com")
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none())
    .then(|| url.origin().ascii_serialization())
}

#[cfg(test)]
#[test]
fn copilot_api_url_accepts_only_github_copilot_origins() {
    assert_eq!(
        copilot_api_url("https://api.business.githubcopilot.com/").as_deref(),
        Some("https://api.business.githubcopilot.com"),
    );
    for url in [
        "https://notgithubcopilot.com",
        "https://api.githubcopilot.com.example.com",
        "https://api.githubcopilot.com@localhost",
        "http://api.githubcopilot.com",
        "https://api.githubcopilot.com/?query",
    ] {
        assert!(copilot_api_url(url).is_none());
    }
}

fn verification_url(provider: Provider, raw: &str) -> bool {
    let Ok(url) = Url::parse(raw) else { return false };
    url.scheme() == "https"
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && match provider {
            Provider::Grok => {
                matches!(
                    url.host_str(),
                    Some("accounts.x.ai" | "auth.x.ai" | "grok.com" | "www.grok.com" | "x.ai")
                )
            }
            Provider::Copilot => {
                url.host_str() == Some("github.com") && url.path() == "/login/device"
            }
            Provider::Kimi => matches!(
                url.host_str(),
                Some(
                    "kimi.com"
                        | "www.kimi.com"
                        | "auth.kimi.com"
                        | "kimi.ai"
                        | "www.kimi.ai"
                        | "auth.kimi.ai"
                )
            ),
        }
}

async fn reply<T: serde::de::DeserializeOwned>(request: RequestBuilder) -> Result<T, Failure> {
    let response =
        request.header("Accept", "application/json").send().await.map_err(|_| "network")?;
    if !response.status().is_success() {
        return Err("provider_error");
    }
    response.json().await.map_err(|_| "bad_reply")
}

fn form(request: RequestBuilder, pairs: &[(&str, &str)]) -> RequestBuilder {
    request
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(crate::chatgpt::oauth::form_encode(pairs))
}
