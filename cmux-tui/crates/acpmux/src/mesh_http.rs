//! The mesh hub over HTTPS (cmux-platform `/v1/mesh`, `openapi.json` 1.3.0), and its config.
//!
//! `meshRelay` in config.json turns the relay on: `{"url": "https://...", "tokenCommand":
//! [...]}`. Unset (the default), the daemon starts no relay. Read at daemon start; a change takes
//! a restart.
//!
//! The hub takes a `Bearer` cmux access token of a team install (a paired daemon or device
//! install). acpmux mints none itself: `tokenCommand` is the program that does (the install's own
//! challenge and token flow), run with no arguments of ours and stdin closed. It prints the token
//! on stdout, bare or as `{"access_token", "expires_at"}` (ms). The token lives only in this
//! process's memory: never on disk, in a log, in argv or in the environment. It is used until a
//! minute before `expires_at` or until the hub answers 401, then the command runs again.

use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub};
use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;
use zeroize::Zeroizing;

/// `meshRelay` in config.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MeshRelayConfig {
    /// The hub's origin, `https://` (`http://` only for a loopback address).
    pub url: String,
    /// The program that prints a cmux access token, and its own arguments.
    pub token_command: Vec<String>,
}

impl MeshRelayConfig {
    /// The origin without a trailing slash, when it is one the relay may use.
    pub fn origin(&self) -> Result<String, String> {
        let url = reqwest::Url::parse(self.url.trim())
            .map_err(|e| format!("meshRelay.url is no URL: {e}"))?;
        let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(url.scheme() == "https" || (url.scheme() == "http" && loopback)) {
            return Err("meshRelay.url must be https (http only on a loopback address)".into());
        }
        // Nothing secret may ride in the URL: it is logged, and the token goes in a header.
        if !url.username().is_empty() || url.password().is_some() {
            return Err("meshRelay.url must carry no user or password".into());
        }
        if url.query().is_some() || url.fragment().is_some() {
            return Err("meshRelay.url must carry no query or fragment".into());
        }
        if self.token_command.first().is_none_or(|p| p.trim().is_empty()) {
            return Err("meshRelay.tokenCommand names no program".into());
        }
        let path = url.path().trim_end_matches('/');
        Ok(format!("{}{path}", url.origin().ascii_serialization()))
    }

    /// What a log may say of the hub: its scheme, host and port, never its path.
    pub fn shown(&self) -> String {
        reqwest::Url::parse(self.url.trim())
            .map(|u| u.origin().ascii_serialization())
            .unwrap_or_default()
    }
}

/// The longest wait for the token command.
const TOKEN_COMMAND_WAIT: Duration = Duration::from_secs(30);
/// The most the token command may print; past it, it is stopped and its output dropped.
const MAX_TOKEN_OUTPUT: usize = 64 << 10;
/// The largest hub answer read.
const MAX_ANSWER_BYTES: usize = 4 << 20;

/// A token and when it expires (ms since the epoch; 0: unknown, used until a 401). One copy in
/// memory: callers share it (`Arc`), never clone the text.
type Token = (Arc<Zeroizing<String>>, u64);

/// The token on the command's stdout: bare, or `{"access_token"|"accessToken", "expires_at"|...}`.
fn parse_token(stdout: &str) -> Result<Token, String> {
    /// Read straight into its fields: the token is allocated once and moved, never copied, and
    /// any other field is skipped unread.
    #[derive(Deserialize)]
    struct Minted {
        #[serde(default, alias = "accessToken")]
        access_token: Option<String>,
        #[serde(default, alias = "expiresAt")]
        expires_at: Option<u64>,
    }
    let text = stdout.trim();
    let (token, expires) = if text.starts_with('{') {
        let minted: Minted =
            serde_json::from_str(text).map_err(|_| "the token command printed no token")?;
        (Zeroizing::new(minted.access_token.unwrap_or_default()), minted.expires_at.unwrap_or(0))
    } else {
        (Zeroizing::new(text.to_owned()), 0)
    };
    let token = Arc::new(token);
    if token.is_empty() || token.len() > 16_384 || !token.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("the token command printed no token".into());
    }
    Ok((token, expires))
}

pub struct HttpHub {
    origin: String,
    command: Vec<String>,
    http: reqwest::Client,
    token: tokio::sync::Mutex<Option<Token>>,
}

impl HttpHub {
    pub fn new(config: &MeshRelayConfig) -> Result<Self, String> {
        let origin = config.origin()?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { origin, command: config.token_command.clone(), http, token: Default::default() })
    }

    /// A token: the one held while it is good, else a new one from the command.
    async fn token(&self, fresh: bool) -> Result<Arc<Zeroizing<String>>, HubError> {
        let mut held = self.token.lock().await;
        let now = crate::store::now_ms();
        if !fresh
            && let Some((token, expires)) = held.as_ref()
            && (*expires == 0 || expires.saturating_sub(60_000) > now)
        {
            return Ok(Arc::clone(token));
        }
        let (program, args) =
            self.command.split_first().ok_or_else(|| HubError::refused("no token command"))?;
        let mut child = tokio::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| HubError::unavailable(format!("cannot run the token command: {e}")))?;
        let mut pipe = child
            .stdout
            .take()
            .ok_or_else(|| HubError::unavailable("the token command has no stdout"))?;
        // Read into one buffer that never grows (no copy left behind) and is wiped on drop; the
        // child is killed when this is dropped (a timeout, too much output).
        let run = async move {
            use tokio::io::AsyncReadExt;
            let mut out = Zeroizing::new(vec![0u8; MAX_TOKEN_OUTPUT + 1]);
            let mut len = 0;
            loop {
                let n = pipe.read(&mut out[len..]).await?;
                if n == 0 {
                    break;
                }
                len += n;
                if len > MAX_TOKEN_OUTPUT {
                    return Ok((out, len, None));
                }
            }
            let status = child.wait().await?;
            Ok::<_, std::io::Error>((out, len, Some(status)))
        };
        let (out, len, status) = tokio::time::timeout(TOKEN_COMMAND_WAIT, run)
            .await
            .map_err(|_| HubError::unavailable("the token command did not answer in 30 s"))?
            .map_err(|e| HubError::unavailable(format!("the token command: {e}")))?;
        let Some(status) = status else {
            return Err(HubError::unavailable("the token command printed too much"));
        };
        if !status.success() {
            return Err(HubError::unavailable(format!("the token command failed ({status})")));
        }
        let stdout = std::str::from_utf8(&out[..len])
            .map_err(|_| HubError::unavailable("the token command printed no text"))?;
        let token = parse_token(stdout).map_err(HubError::unavailable)?;
        *held = Some((Arc::clone(&token.0), token.1));
        Ok(token.0)
    }

    /// One call, once more with a new token after a 401.
    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
        wait: Duration,
    ) -> Result<Value, HubError> {
        for retry in [false, true] {
            let token = self.token(retry).await?;
            let mut request = self
                .http
                .request(method.clone(), format!("{}{path}", self.origin))
                .bearer_auth(token.as_str())
                .timeout(wait);
            if let Some(body) = body {
                request = request.json(body);
            }
            let mut response = request
                .send()
                .await
                .map_err(|e| HubError::unavailable(format!("the hub: {}", e.without_url())))?;
            let status = response.status().as_u16();
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|e| HubError::unavailable(format!("the hub: {}", e.without_url())))?
            {
                if bytes.len() + chunk.len() > MAX_ANSWER_BYTES {
                    return Err(HubError::unavailable("the hub's answer is too large"));
                }
                bytes.extend_from_slice(&chunk);
            }
            if status == 401 && !retry {
                continue;
            }
            return answer(status, &bytes);
        }
        Err(HubError::unavailable("the hub refused two tokens"))
    }
}

/// The hub's error codes this client acts on or names in a log (the contract leaves `code` a free
/// string): any other code is dropped, since a free string could carry anything.
const KNOWN_CODES: &[&str] = &[
    "mesh.unauthorized",
    "mesh.forbidden",
    "mesh.bad_request",
    "mesh.unknown_recipient",
    "mesh.ambiguous",
    "mesh.conflict",
    "mesh.rate_limited",
    "mesh.too_large",
    "mesh.unavailable",
    "mesh.not_found",
];

/// The hub's answer as a value, or the error it names.
fn answer(status: u16, bytes: &[u8]) -> Result<Value, HubError> {
    let body: Value = serde_json::from_slice(bytes).unwrap_or(Value::Null);
    if (200..300).contains(&status) {
        return Ok(body);
    }
    // Only the status, and a code the contract names: anything else the hub (or a proxy) says
    // could reflect the request, token included, and errors are logged.
    let code = body
        .get("code")
        .and_then(Value::as_str)
        .filter(|c| KNOWN_CODES.contains(c))
        .map(str::to_owned);
    let mut error = HubError::refused(
        format!("the hub answered {status} {}", code.as_deref().unwrap_or("")).trim().to_owned(),
    );
    error.refused = !(status == 408 || status == 429 || status >= 500);
    error.status = Some(status);
    error.retry_after =
        body.get("retryAfterSeconds").and_then(Value::as_u64).map(Duration::from_secs);
    error.code = code;
    Err(error)
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, HubError> {
    // Never serde's message: it quotes the value it refused, which could be anything the answer
    // carried.
    serde_json::from_value(value)
        .map_err(|_| HubError::unavailable("the hub's answer is not the shape its contract gives"))
}

const CALL_WAIT: Duration = Duration::from_secs(30);

impl MeshHub for HttpHub {
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async move {
            let path = format!(
                "/v1/mesh/inbox?waitSeconds={}&max={}",
                wait.as_secs().min(25),
                max.clamp(1, 50)
            );
            let inbox = self.call(reqwest::Method::GET, &path, None, wait + CALL_WAIT).await?;
            decode(inbox.get("messages").cloned().unwrap_or(json!([])))
        })
    }

    fn ack<'a>(&'a self, id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async move {
            let body = serde_json::to_value(ack).unwrap_or_default();
            self.call(
                reqwest::Method::POST,
                &format!("/v1/mesh/messages/{id}/ack"),
                Some(&body),
                CALL_WAIT,
            )
            .await
            .map(drop)
        })
    }

    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async move {
            let body = serde_json::to_value(beat).unwrap_or_default();
            decode(
                self.call(reqwest::Method::POST, "/v1/mesh/heartbeat", Some(&body), CALL_WAIT)
                    .await?,
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_token_is_read_bare_or_from_json_and_nothing_else_passes() {
        assert_eq!(parse_token("tok.abc\n").unwrap().0.as_str(), "tok.abc");
        let (token, expires) =
            parse_token(r#"{"access_token": "t1", "expires_at": 1700000000000}"#).unwrap();
        assert_eq!((token.as_str(), expires), ("t1", 1_700_000_000_000));
        assert_eq!(parse_token(r#"{"accessToken": "t2"}"#).unwrap().0.as_str(), "t2");
        for bad in ["", "  ", "two words", r#"{"token": "x"}"#] {
            assert!(parse_token(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn only_https_or_loopback_http_with_a_token_command_is_used() {
        let config = |url: &str, cmd: &[&str]| MeshRelayConfig {
            url: url.into(),
            token_command: cmd.iter().map(|s| (*s).to_owned()).collect(),
        };
        let hub = "https://cmux-platform-development.debussy.workers.dev/";
        assert_eq!(
            config(hub, &["mint"]).origin().unwrap(),
            "https://cmux-platform-development.debussy.workers.dev"
        );
        assert!(config("http://127.0.0.1:8787", &["mint"]).origin().is_ok());
        assert!(config("http://hub.example.com", &["mint"]).origin().is_err());
        assert!(config(hub, &[]).origin().is_err());
        assert!(config("not a url", &["mint"]).origin().is_err());
        assert!(config("https://user:secret@hub.example.com", &["mint"]).origin().is_err());
        assert!(config("https://hub.example.com/?access_token=abc", &["mint"]).origin().is_err());
        assert!(config("https://hub.example.com/#t", &["mint"]).origin().is_err());
        assert_eq!(
            config("https://hub.example.com/mesh/", &["mint"]).origin().unwrap(),
            "https://hub.example.com/mesh"
        );
        // A log names the hub's origin only, never its path.
        assert_eq!(
            config("https://hub.example.com/s3cret", &["mint"]).shown(),
            "https://hub.example.com"
        );
    }

    #[tokio::test]
    async fn a_token_command_that_prints_without_end_is_stopped_not_buffered() {
        let config = MeshRelayConfig {
            url: "http://127.0.0.1:9".into(),
            token_command: ["sh", "-c", "yes"].map(str::to_owned).to_vec(),
        };
        let hub = HttpHub::new(&config).unwrap();
        let e = hub.token(true).await.unwrap_err();
        assert!(e.to_string().contains("too much"), "{e}");
    }

    #[test]
    fn only_a_refused_credential_ends_the_relay() {
        assert!(answer(401, br#"{"code": "mesh.unauthorized"}"#).unwrap_err().ends_relay());
        assert!(answer(403, b"").unwrap_err().ends_relay());
        // A duplicate name or another bad heartbeat is tried again, not the end of the relay.
        assert!(!answer(400, br#"{"code": "mesh.bad_request"}"#).unwrap_err().ends_relay());
        assert!(!answer(409, b"").unwrap_err().ends_relay());
        assert!(!answer(429, b"").unwrap_err().ends_relay());
        assert!(HubError::refused("no token command").ends_relay());
    }

    #[test]
    fn a_malformed_answer_logs_none_of_its_values() {
        let reply = json!({"daemonId": "inst_1", "ttlSeconds": "Bearer abc.def"});
        let e = decode::<HeartbeatReply>(reply).unwrap_err();
        assert!(!e.to_string().contains("abc.def"), "{e}");
    }

    #[test]
    fn a_hub_error_logs_no_free_text_from_the_answer() {
        let e = answer(400, br#"{"code": "mesh.bad_request", "message": "Bearer abc.def"}"#)
            .unwrap_err();
        assert!(!e.to_string().contains("abc.def"), "{e}");
        assert_eq!(e.code.as_deref(), Some("mesh.bad_request"));
        // A code the contract does not name is dropped, however tidy: it could be a token.
        let e = answer(400, br#"{"code": "eyJhbGciOi.abc.def"}"#).unwrap_err();
        assert!(!e.to_string().contains("abc.def") && e.code.is_none(), "{e}");
        let e = answer(400, br#"{"code": "Bearer abc.def ghi"}"#).unwrap_err();
        assert!(!e.to_string().contains("abc.def") && e.code.is_none(), "{e}");
    }

    #[test]
    fn the_hubs_refusals_say_whether_to_try_again() {
        let e = answer(404, br#"{"code": "mesh.unknown_recipient", "message": "no"}"#).unwrap_err();
        assert!(e.refused && e.code.as_deref() == Some("mesh.unknown_recipient"), "{e:?}");
        let e =
            answer(429, br#"{"code": "mesh.rate_limited", "retryAfterSeconds": 7}"#).unwrap_err();
        assert!(!e.refused && e.retry_after == Some(Duration::from_secs(7)), "{e:?}");
        assert!(!answer(503, b"").unwrap_err().refused);
        assert_eq!(answer(200, br#"{"ok": 1}"#).unwrap(), json!({"ok": 1}));
    }
}
