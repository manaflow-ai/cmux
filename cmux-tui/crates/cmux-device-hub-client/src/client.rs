//! The device hub's HTTP API (PROTOCOL.md, "HTTP API" and "Computer Use
//! approvals"): every device-scoped call carries the account session and the
//! device signature.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Mutex;
use url::Url;

use crate::approval::{ApprovalRequest, Decision, HubApproval, KnownDevice};
use crate::error::HubError;
use crate::identity::{Assurance, DeviceIdentity, Platform};
use crate::signing;

/// Gives the app's Stack Auth access token for `POST /v1/auth/stack`.
#[async_trait]
pub trait StackTokenSource: Send + Sync {
    /// The current access token; an error means signed out.
    async fn stack_access_token(&self) -> Result<String, HubError>;
}

/// A fixed token (tests, and callers that refresh the token themselves).
pub struct StaticToken(pub String);

#[async_trait]
impl StackTokenSource for StaticToken {
    async fn stack_access_token(&self) -> Result<String, HubError> {
        Ok(self.0.clone())
    }
}

/// The token a program prints (a box's own sign-in helper, named by the
/// owner in the root- or SYSTEM-owned Computer Use config): run with no
/// arguments and stdin closed, it prints the access token on stdout, bare or as
/// `{"access_token"|"accessToken": "..."}`. The token stays in memory only.
pub struct CommandToken {
    pub program: std::path::PathBuf,
    pub timeout: Duration,
}

impl CommandToken {
    pub fn new(program: impl Into<std::path::PathBuf>) -> CommandToken {
        CommandToken { program: program.into(), timeout: Duration::from_secs(30) }
    }

    /// The token in a program's output.
    pub fn parse(stdout: &str) -> Option<String> {
        let text = stdout.trim();
        if text.starts_with('{') {
            let value: serde_json::Value = serde_json::from_str(text).ok()?;
            let token = value.get("access_token").or_else(|| value.get("accessToken"))?;
            return token.as_str().filter(|token| !token.is_empty()).map(str::to_owned);
        }
        (!text.is_empty() && !text.contains(char::is_whitespace)).then(|| text.to_owned())
    }
}

#[async_trait]
impl StackTokenSource for CommandToken {
    async fn stack_access_token(&self) -> Result<String, HubError> {
        let mut command = tokio::process::Command::new(&self.program);
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let output = tokio::time::timeout(self.timeout, command.output())
            .await
            .map_err(|_| HubError::NotSignedIn(format!("{} did not answer", self.program.display())))?
            .map_err(|error| HubError::NotSignedIn(format!("{}: {error}", self.program.display())))?;
        if !output.status.success() {
            return Err(HubError::NotSignedIn(format!(
                "{} exited with {}",
                self.program.display(),
                output.status
            )));
        }
        CommandToken::parse(&String::from_utf8_lossy(&output.stdout)).ok_or_else(|| {
            HubError::NotSignedIn(format!("{} printed no token", self.program.display()))
        })
    }
}

/// The hub session from `POST /v1/auth/stack`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountSession {
    pub token: String,
    pub user_id: String,
    /// Unix milliseconds.
    pub expires_at: i64,
}

/// A device as the hub lists it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HubDevice {
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub platform: Platform,
    pub signing_key: String,
    #[serde(default)]
    pub agreement_key: String,
    /// `macos`/`ios` only: the Secure Enclave key that signs Allows (null when none).
    #[serde(default)]
    pub approval_key: Option<String>,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub last_seen_at: Option<i64>,
    #[serde(default)]
    pub mac_screen_shared: bool,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub assurance: Option<Assurance>,
}

impl HubDevice {
    pub fn known(&self) -> KnownDevice {
        KnownDevice {
            id: self.id.clone(),
            platform: self.platform,
            signing_key: self.signing_key.clone(),
            approval_key: self.approval_key.clone(),
        }
    }
}

/// `GET /v1/me`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HubMe {
    pub user_id: String,
    pub plan: String,
    #[serde(default)]
    pub device: Option<HubDevice>,
}

/// A WebSocket's URL and upgrade headers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Handshake {
    pub url: Url,
    pub headers: Vec<(String, String)>,
}

/// How to reach the hub.
#[derive(Clone)]
pub struct HubClientConfig {
    /// The hub's origin, e.g. `https://device-hub.cmux.dev`.
    pub base_url: Url,
    pub identity: DeviceIdentity,
    pub tokens: Arc<dyn StackTokenSource>,
    /// Allow `http://` (tests against a local hub only).
    pub allow_http: bool,
    pub request_timeout: Duration,
}

impl HubClientConfig {
    pub fn new(
        base_url: Url,
        identity: DeviceIdentity,
        tokens: Arc<dyn StackTokenSource>,
    ) -> HubClientConfig {
        HubClientConfig {
            base_url,
            identity,
            tokens,
            allow_http: false,
            request_timeout: Duration::from_secs(20),
        }
    }
}

/// The device hub client of one device.
pub struct HubClient {
    base_url: Url,
    identity: DeviceIdentity,
    tokens: Arc<dyn StackTokenSource>,
    http: reqwest::Client,
    account: Mutex<Option<AccountSession>>,
}

impl HubClient {
    pub fn new(config: HubClientConfig) -> Result<HubClient, HubError> {
        match config.base_url.scheme() {
            "https" => {}
            "http" if config.allow_http => {}
            other => {
                return Err(HubError::NotConfigured(format!("unsupported hub scheme {other:?}")));
            }
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .https_only(!config.allow_http)
            .connect_timeout(Duration::from_secs(10))
            .timeout(config.request_timeout)
            .user_agent(concat!("cmux-device-hub-client/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| HubError::NotConfigured(format!("HTTP client: {error}")))?;
        Ok(HubClient {
            base_url: config.base_url,
            identity: config.identity,
            tokens: config.tokens,
            http,
            account: Mutex::new(None),
        })
    }

    pub fn identity(&self) -> &DeviceIdentity {
        &self.identity
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    /// The three device headers for one request, signed now.
    pub fn device_headers(
        &self,
        method: &str,
        path_and_query: &str,
        body: Option<&[u8]>,
    ) -> Result<Vec<(String, String)>, HubError> {
        let timestamp = unix_seconds();
        let canonical = signing::canonical_request(method, path_and_query, timestamp, body);
        let signature = self
            .identity
            .sign_base64(canonical.as_bytes())
            .map_err(|error| HubError::Identity(error.to_string()))?;
        Ok(vec![
            (signing::ID_HEADER.to_owned(), self.identity.id().to_owned()),
            (signing::TIMESTAMP_HEADER.to_owned(), timestamp.to_string()),
            (signing::SIGNATURE_HEADER.to_owned(), signature),
        ])
    }

    /// The account session, exchanging the Stack token when there is none or
    /// it is about to end.
    pub async fn account_session(&self) -> Result<AccountSession, HubError> {
        let mut account = self.account.lock().await;
        if let Some(session) = account.as_ref()
            && session.expires_at.saturating_sub(60_000) > unix_millis()
        {
            return Ok(session.clone());
        }
        let session = self.exchange().await?;
        *account = Some(session.clone());
        Ok(session)
    }

    /// Forgets the account session; the next call exchanges again.
    pub async fn forget_account_session(&self) {
        *self.account.lock().await = None;
    }

    async fn exchange(&self) -> Result<AccountSession, HubError> {
        let token = self.tokens.stack_access_token().await.map_err(|error| match error {
            HubError::NotSignedIn(_) => error,
            other => HubError::NotSignedIn(other.to_string()),
        })?;
        let url = self.url(&["v1", "auth", "stack"], None);
        let body = serde_json::to_vec(&json!({ "token": token }))
            .map_err(|e| HubError::Decoding(e.to_string()))?;
        let response = self
            .http
            .post(url)
            .header("Content-Type", "application/json")
            .body(body)
            .send()
            .await
            .map_err(|error| HubError::Transport(error.to_string()))?;
        let data = read_response(response).await.map_err(|error| match error {
            HubError::Server { status: 401, .. } => HubError::NotSignedIn(error.to_string()),
            other => other,
        })?;
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Answer {
            session: String,
            user_id: String,
            #[serde(default)]
            expires_at: Option<i64>,
        }
        let answer: Answer = decode(&data)?;
        Ok(AccountSession {
            token: answer.session,
            user_id: answer.user_id,
            // The session is an hour long (PROTOCOL.md) when the answer has no expiry.
            expires_at: answer.expires_at.unwrap_or_else(|| unix_millis().saturating_add(3_600_000)),
        })
    }

    /// `baseURL` with `segments` (each percent-encoded) appended, and `query`.
    fn url(&self, segments: &[&str], query: Option<&[(&str, &str)]>) -> Url {
        let mut url = self.base_url.clone();
        if let Ok(mut path) = url.path_segments_mut() {
            path.pop_if_empty();
            path.extend(segments);
        }
        url.set_query(None);
        if let Some(query) = query {
            url.query_pairs_mut().extend_pairs(query);
        }
        url
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: reqwest::Method,
        segments: &[&str],
        body: Option<Vec<u8>>,
    ) -> Result<T, HubError> {
        match self.call_once(method.clone(), segments, body.as_deref()).await {
            Err(error) if error.is_account_refusal() => {
                // The hub session ended early (or the hub restarted): exchange again, once.
                self.forget_account_session().await;
                decode(&self.call_once(method, segments, body.as_deref()).await?)
            }
            other => decode(&other?),
        }
    }

    async fn call_once(
        &self,
        method: reqwest::Method,
        segments: &[&str],
        body: Option<&[u8]>,
    ) -> Result<Vec<u8>, HubError> {
        let url = self.url(segments, None);
        let account = self.account_session().await?;
        let headers = self.device_headers(method.as_str(), &signing::path_and_query(&url), body)?;
        let mut request = self.http.request(method, url).bearer_auth(&account.token);
        for (name, value) in headers {
            request = request.header(name, value);
        }
        if let Some(body) = body {
            request = request.header("Content-Type", "application/json").body(body.to_vec());
        }
        let response =
            request.send().await.map_err(|error| HubError::Transport(error.to_string()))?;
        read_response(response).await
    }

    // MARK: Endpoints

    /// `POST /v1/devices`: registers (or updates) this device, signed with the
    /// key it registers.
    pub async fn register_device(&self, name: &str) -> Result<HubDevice, HubError> {
        let body = json!({
            "id": self.identity.id(),
            "name": name,
            "platform": self.identity.platform().as_str(),
            "signingKey": self.identity.signing_key_base64(),
            "agreementKey": self.identity.agreement_key_base64(),
            "assurance": self.identity.assurance().as_str(),
        });
        let answer: DeviceAnswer =
            self.call(reqwest::Method::POST, &["v1", "devices"], Some(to_body(&body)?)).await?;
        Ok(answer.device)
    }

    /// `GET /v1/devices`: the account's devices that are not removed.
    pub async fn devices(&self) -> Result<Vec<HubDevice>, HubError> {
        #[derive(Deserialize)]
        struct Answer {
            devices: Vec<HubDevice>,
        }
        let answer: Answer = self.call(reqwest::Method::GET, &["v1", "devices"], None).await?;
        Ok(answer.devices)
    }

    /// `GET /v1/me`.
    pub async fn me(&self) -> Result<HubMe, HubError> {
        self.call(reqwest::Method::GET, &["v1", "me"], None).await
    }

    /// `POST /v1/approvals`: asks the account's approvers.
    pub async fn create_approval(
        &self,
        request: &ApprovalRequest,
        allow_always: bool,
    ) -> Result<HubApproval, HubError> {
        let body = json!({ "request": request, "allowAlways": allow_always });
        let answer: ApprovalAnswer =
            self.call(reqwest::Method::POST, &["v1", "approvals"], Some(to_body(&body)?)).await?;
        Ok(answer.approval)
    }

    /// `GET /v1/approvals/:id`.
    pub async fn approval(&self, id: &str) -> Result<HubApproval, HubError> {
        let answer: ApprovalAnswer =
            self.call(reqwest::Method::GET, &["v1", "approvals", id], None).await?;
        Ok(answer.approval)
    }

    /// `GET /v1/approvals`: pending approvals this device may answer.
    pub async fn approvals(&self) -> Result<Vec<HubApproval>, HubError> {
        #[derive(Deserialize)]
        struct Answer {
            approvals: Vec<HubApproval>,
        }
        let answer: Answer = self.call(reqwest::Method::GET, &["v1", "approvals"], None).await?;
        Ok(answer.approvals)
    }

    /// `DELETE /v1/approvals/:id`: the asking device cancels its question.
    pub async fn cancel_approval(&self, id: &str) -> Result<HubApproval, HubError> {
        let answer: ApprovalAnswer =
            self.call(reqwest::Method::DELETE, &["v1", "approvals", id], None).await?;
        Ok(answer.approval)
    }

    /// `POST /v1/approvals/:id/decision`. The hub refuses `windows` and `linux`
    /// devices (403 `not_approver`); here for completeness.
    pub async fn decide_approval(
        &self,
        id: &str,
        decision: Decision,
        digest: &str,
        sig: &str,
    ) -> Result<HubApproval, HubError> {
        let body = json!({ "decision": decision.as_str(), "digest": digest, "sig": sig });
        let answer: ApprovalAnswer = self
            .call(
                reqwest::Method::POST,
                &["v1", "approvals", id, "decision"],
                Some(to_body(&body)?),
            )
            .await?;
        Ok(answer.approval)
    }

    /// The User DO socket's URL and headers (`GET /v1/user/ws`): the account
    /// session and the device signature, signed now.
    pub async fn user_socket_handshake(&self) -> Result<Handshake, HubError> {
        let mut url = self.url(&["v1", "user", "ws"], None);
        let scheme = match url.scheme() {
            "https" => "wss",
            "http" => "ws",
            other => {
                return Err(HubError::NotConfigured(format!("unsupported hub scheme {other:?}")));
            }
        };
        url.set_scheme(scheme)
            .map_err(|()| HubError::NotConfigured("cannot make the socket URL".into()))?;
        let account = self.account_session().await?;
        let mut headers = self.device_headers("GET", &signing::path_and_query(&url), None)?;
        headers.push(("Authorization".to_owned(), format!("Bearer {}", account.token)));
        Ok(Handshake { url, headers })
    }
}

#[derive(Deserialize)]
struct DeviceAnswer {
    device: HubDevice,
}

#[derive(Deserialize)]
struct ApprovalAnswer {
    approval: HubApproval,
}

fn to_body(value: &impl Serialize) -> Result<Vec<u8>, HubError> {
    serde_json::to_vec(value).map_err(|error| HubError::Decoding(format!("request body: {error}")))
}

fn decode<T: DeserializeOwned>(data: &[u8]) -> Result<T, HubError> {
    let data: &[u8] = if data.is_empty() { b"{}" } else { data };
    serde_json::from_slice(data)
        .map_err(|error| HubError::Decoding(format!("{}: {error}", std::any::type_name::<T>())))
}

async fn read_response(response: reqwest::Response) -> Result<Vec<u8>, HubError> {
    let status = response.status().as_u16();
    let data = response.bytes().await.map_err(|error| HubError::Transport(error.to_string()))?;
    if !(200..300).contains(&status) {
        return Err(HubError::from_response(status, &data));
    }
    Ok(data.to_vec())
}

pub(crate) fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

pub(crate) fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod command_token_tests {
    use super::CommandToken;

    #[test]
    fn a_token_is_bare_or_json() {
        assert_eq!(CommandToken::parse("tok-1\n"), Some("tok-1".into()));
        assert_eq!(CommandToken::parse(r#"{"access_token":"tok-2","expires_at":1}"#), Some("tok-2".into()));
        assert_eq!(CommandToken::parse(r#"{"accessToken":"tok-3"}"#), Some("tok-3".into()));
        assert_eq!(CommandToken::parse(""), None);
        assert_eq!(CommandToken::parse("two words"), None);
        assert_eq!(CommandToken::parse(r#"{"access_token":""}"#), None);
    }
}
