use std::io::{self, Write};
use std::time::{Duration, Instant};

use base64::Engine;
use rand::Rng;
use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tiny_http::{Header, Response, Server};

use crate::cli::Error;

const OPENAI_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_ISSUER: &str = "https://auth.openai.com";
// OpenAI validates this value against the first-party Codex OAuth client.
// Keep it synchronized with codex-rs/login/src/auth/default_client.rs.
const OPENAI_ORIGINATOR: &str = "codex_cli_rs";
const OPENAI_CALLBACK_PORTS: [u16; 2] = [1455, 1457];
const OPENCODE_CONSOLE: &str = "https://console.opencode.ai";
const OPENCODE_CLIENT_ID: &str = "opencode-cli";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Provider {
    Codex,
    OpenCodeGo,
}

impl Provider {
    pub fn label(self) -> &'static str {
        match self {
            Self::Codex => "Codex / ChatGPT Plus or Pro",
            Self::OpenCodeGo => "OpenCode Go",
        }
    }
}

pub fn authenticate(provider: Provider) -> Result<Value, Error> {
    match provider {
        Provider::Codex => codex_browser_oauth(),
        Provider::OpenCodeGo => opencode_device_oauth(),
    }
}

pub fn authenticate_with_fallback(provider: Provider) -> Result<Value, Error> {
    match authenticate(provider) {
        Ok(value) => Ok(value),
        Err(direct_error) if provider == Provider::Codex => {
            eprintln!("Direct OpenAI authentication failed: {direct_error}");
            eprint!("Retry through the official Codex CLI in a portable PTY? [y/N] ");
            io::stderr().flush()?;
            let mut answer = String::new();
            io::stdin().read_line(&mut answer)?;
            if !matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
                return Err(direct_error);
            }
            codex_portable_pty()
        }
        Err(error) => Err(error),
    }
}

fn codex_portable_pty() -> Result<Value, Error> {
    use portable_pty::{CommandBuilder, PtySize, native_pty_system};

    let codex_home = tempfile::tempdir()?;
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 30,
            cols: 100,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| Error::Backend(format!("open portable PTY: {error}")))?;
    let mut command = CommandBuilder::new("codex");
    command.arg("login");
    command.env("CODEX_HOME", codex_home.path());
    let mut child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| Error::Backend(format!("start Codex login: {error}")))?;
    drop(pair.slave);
    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| Error::Backend(format!("read portable PTY: {error}")))?;
    let relay = std::thread::spawn(move || {
        let _ = io::copy(&mut reader, &mut io::stdout());
    });
    let status = child
        .wait()
        .map_err(|error| Error::Backend(format!("wait for Codex login: {error}")))?;
    drop(pair.master);
    let _ = relay.join();
    if !status.success() {
        return Err(Error::Backend(format!(
            "Codex login exited with {status:?}"
        )));
    }
    let body = std::fs::read(codex_home.path().join("auth.json"))
        .map_err(|error| Error::Backend(format!("read Codex OAuth result: {error}")))?;
    let auth: Value = serde_json::from_slice(&body)
        .map_err(|error| Error::Backend(format!("parse Codex OAuth result: {error}")))?;
    let tokens = auth
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or_else(|| Error::Backend("Codex login returned incomplete OAuth tokens".into()))?;
    let access = json_string(tokens.get("access_token"), "access token")?;
    let refresh = json_string(tokens.get("refresh_token"), "refresh token")?;
    let id = json_string(tokens.get("id_token"), "ID token")?;
    let claims = jwt_claims(id)?;
    let account_id = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .or_else(|| claims.get("chatgpt_account_id").and_then(Value::as_str))
        .ok_or_else(|| Error::Backend("Codex login returned no account ID".into()))?;
    let email = claims
        .get("email")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Backend("Codex login returned no email".into()))?;
    Ok(json!({
        "provider": "codex",
        "accessToken": access,
        "refreshToken": refresh,
        "idToken": id,
        "accountId": account_id,
        "email": email,
        "expiresAt": jwt_expiry_millis(access).unwrap_or_else(|| now_millis() + 3_600_000),
    }))
}

fn codex_browser_oauth() -> Result<Value, Error> {
    let server = bind_codex_callback()?;
    let port = server
        .server_addr()
        .to_ip()
        .ok_or_else(|| Error::Backend("OAuth callback did not bind TCP".into()))?
        .port();
    let redirect_uri = format!("http://localhost:{port}/auth/callback");
    let verifier = random_base64url(32);
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(Sha256::digest(verifier.as_bytes()));
    let state = random_base64url(32);
    let authorize = codex_authorize_url(&redirect_uri, &challenge, &state)?;
    println!("Opening OpenAI authorization in your browser…");
    println!("  {authorize}");
    let _ = webbrowser::open(authorize.as_str());

    let waiting = crate::loading::DelayedSpinner::new("Waiting for OpenAI authorization");
    let deadline = Instant::now() + Duration::from_secs(5 * 60);
    let code = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Backend("OpenAI authorization timed out".into()));
        }
        let Some(request) = server
            .recv_timeout(remaining.min(Duration::from_secs(1)))
            .map_err(|error| Error::Backend(format!("receive OAuth callback: {error}")))?
        else {
            continue;
        };
        let callback = reqwest::Url::parse(&format!("http://localhost{}", request.url()))
            .map_err(|error| Error::Backend(format!("invalid OAuth callback: {error}")))?;
        if callback.path() != "/auth/callback" {
            let _ = request.respond(Response::empty(404));
            continue;
        }
        let params: std::collections::HashMap<_, _> = callback.query_pairs().into_owned().collect();
        if !codex_callback_matches_state(&params, &state) {
            let _ = request.respond(html_response(400, "Invalid OAuth state"));
            continue;
        }
        if let Some(error) = params.get("error") {
            let _ = request.respond(html_response(400, "Authorization failed"));
            return Err(Error::Backend(format!(
                "OpenAI authorization failed: {error}"
            )));
        }
        let code = params
            .get("code")
            .cloned()
            .ok_or_else(|| Error::Backend("OpenAI returned no authorization code".into()))?;
        let _ = request.respond(html_response(
            200,
            "coderouter is authorized. You can close this tab.",
        ));
        break code;
    };
    waiting.finish();

    let exchanging = crate::loading::DelayedSpinner::new("Completing OpenAI authorization");
    let token: TokenResponse = response_json(
        client()?
            .post(format!("{OPENAI_ISSUER}/oauth/token"))
            .form(&[
                ("grant_type", "authorization_code"),
                ("code", code.as_str()),
                ("redirect_uri", redirect_uri.as_str()),
                ("client_id", OPENAI_CLIENT_ID),
                ("code_verifier", verifier.as_str()),
            ])
            .send()
            .map_err(network_error("exchange OpenAI authorization"))?,
        "exchange OpenAI authorization",
    )?;
    exchanging.finish();
    let claims = jwt_claims(&token.id_token)?;
    let account_id = claims
        .get("chatgpt_account_id")
        .or_else(|| {
            claims
                .get("https://api.openai.com/auth")
                .and_then(|value| value.get("chatgpt_account_id"))
        })
        .and_then(Value::as_str)
        .or_else(|| {
            claims
                .get("organizations")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(|value| value.get("id"))
                .and_then(Value::as_str)
        })
        .ok_or_else(|| Error::Backend("OpenAI token contains no account ID".into()))?;
    let email = claims
        .get("email")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Backend("OpenAI token contains no email".into()))?;
    Ok(json!({
        "provider": "codex",
        "accessToken": token.access_token,
        "refreshToken": token.refresh_token,
        "idToken": token.id_token,
        "accountId": account_id,
        "email": email,
        "expiresAt": now_millis() + token.expires_in.unwrap_or(3_600) * 1_000,
    }))
}

fn codex_callback_matches_state(
    params: &std::collections::HashMap<String, String>,
    expected_state: &str,
) -> bool {
    params
        .get("state")
        .is_some_and(|state| state == expected_state)
}

fn codex_callback_ports() -> [u16; 2] {
    OPENAI_CALLBACK_PORTS
}

fn bind_codex_callback() -> Result<Server, Error> {
    let mut last_error = None;
    for port in codex_callback_ports() {
        match Server::http(format!("127.0.0.1:{port}")) {
            Ok(server) => return Ok(server),
            Err(error) => last_error = Some(error),
        }
    }
    Err(Error::Backend(format!(
        "start OAuth callback on the official Codex ports 1455 or 1457: {}",
        last_error
            .map(|error| error.to_string())
            .unwrap_or_else(|| "no callback port available".to_owned())
    )))
}

fn codex_authorize_url(
    redirect_uri: &str,
    challenge: &str,
    state: &str,
) -> Result<reqwest::Url, Error> {
    let mut authorize = reqwest::Url::parse(&format!("{OPENAI_ISSUER}/oauth/authorize"))
        .map_err(|error| Error::Backend(error.to_string()))?;
    authorize.query_pairs_mut().extend_pairs([
        ("response_type", "code"),
        ("client_id", OPENAI_CLIENT_ID),
        ("redirect_uri", redirect_uri),
        (
            "scope",
            "openid profile email offline_access api.connectors.read api.connectors.invoke",
        ),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("id_token_add_organizations", "true"),
        ("codex_cli_simplified_flow", "true"),
        ("state", state),
        ("originator", OPENAI_ORIGINATOR),
    ]);
    // Codex builds this query with RFC 3986 percent-encoding rather than
    // application/x-www-form-urlencoded encoding. Match it exactly: OpenAI's
    // Hydra authorization endpoint validates this first-party request shape.
    reqwest::Url::parse(&authorize.as_str().replace('+', "%20"))
        .map_err(|error| Error::Backend(error.to_string()))
}

fn opencode_device_oauth() -> Result<Value, Error> {
    let starting = crate::loading::DelayedSpinner::new("Starting OpenCode authorization");
    let client = client()?;
    let device: DeviceCode = response_json(
        client
            .post(format!("{OPENCODE_CONSOLE}/auth/device/code"))
            .json(&json!({ "client_id": OPENCODE_CLIENT_ID }))
            .send()
            .map_err(network_error("start OpenCode Go authorization"))?,
        "start OpenCode Go authorization",
    )?;
    starting.finish();
    let url = if device.verification_uri_complete.starts_with("http") {
        device.verification_uri_complete.clone()
    } else {
        format!("{OPENCODE_CONSOLE}{}", device.verification_uri_complete)
    };
    println!("Authorize OpenCode Go:\n  {url}");
    println!("Code: {}", device.user_code);
    let _ = webbrowser::open(&url);

    let waiting = crate::loading::DelayedSpinner::new("Waiting for OpenCode authorization");
    let deadline = Instant::now() + Duration::from_secs(device.expires_in.max(1));
    let mut wait = Duration::from_secs(device.interval.max(1));
    let token = loop {
        if Instant::now() >= deadline {
            return Err(Error::Backend("OpenCode Go authorization timed out".into()));
        }
        std::thread::sleep(wait);
        let response = client
            .post(format!("{OPENCODE_CONSOLE}/auth/device/token"))
            .json(&json!({
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device.device_code,
                "client_id": OPENCODE_CLIENT_ID,
            }))
            .send()
            .map_err(network_error("poll OpenCode Go authorization"))?;
        let status = response.status();
        let value: Value = response
            .json()
            .map_err(|error| Error::Backend(format!("invalid OpenCode response: {error}")))?;
        if status.is_success() {
            break serde_json::from_value::<OpenCodeToken>(value)
                .map_err(|error| Error::Backend(format!("invalid OpenCode token: {error}")))?;
        }
        match value.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => {}
            Some("slow_down") => wait += Duration::from_secs(5),
            Some(error) => {
                return Err(Error::Backend(format!(
                    "OpenCode Go authorization failed: {error}"
                )));
            }
            None => {
                return Err(Error::Backend(format!(
                    "OpenCode Go authorization failed: HTTP {status}"
                )));
            }
        }
    };
    waiting.finish();
    let loading = crate::loading::DelayedSpinner::new("Loading OpenCode account");
    let user: OpenCodeUser = bearer_json(
        &client,
        &format!("{OPENCODE_CONSOLE}/api/user"),
        &token.access_token,
        "load OpenCode user",
    )?;
    let orgs: Vec<OpenCodeOrg> = bearer_json(
        &client,
        &format!("{OPENCODE_CONSOLE}/api/orgs"),
        &token.access_token,
        "load OpenCode organizations",
    )?;
    let org = orgs
        .into_iter()
        .min_by(|left, right| left.name.cmp(&right.name).then(left.id.cmp(&right.id)));
    loading.finish();
    Ok(json!({
        "provider": "opencode-go",
        "accessToken": token.access_token,
        "refreshToken": token.refresh_token,
        "accountId": user.id,
        "email": user.email,
        "orgId": org.as_ref().map(|value| value.id.as_str()),
        "orgName": org.as_ref().map(|value| value.name.as_str()),
        "expiresAt": now_millis() + token.expires_in * 1_000,
    }))
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    id_token: String,
    expires_in: Option<u64>,
}

#[derive(Deserialize)]
struct DeviceCode {
    device_code: String,
    user_code: String,
    verification_uri_complete: String,
    expires_in: u64,
    interval: u64,
}

#[derive(Deserialize)]
struct OpenCodeToken {
    access_token: String,
    refresh_token: String,
    expires_in: u64,
}

#[derive(Deserialize)]
struct OpenCodeUser {
    id: String,
    email: String,
}

#[derive(Deserialize)]
struct OpenCodeOrg {
    id: String,
    name: String,
}

fn bearer_json<T: serde::de::DeserializeOwned>(
    client: &Client,
    url: &str,
    token: &str,
    action: &str,
) -> Result<T, Error> {
    response_json(
        client
            .get(url)
            .bearer_auth(token)
            .send()
            .map_err(|error| Error::Backend(format!("{action}: {error}")))?,
        action,
    )
}

fn jwt_claims(token: &str) -> Result<Value, Error> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or_else(|| Error::Backend("invalid OpenAI ID token".into()))?;
    let body = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| Error::Backend("invalid OpenAI ID token".into()))?;
    serde_json::from_slice(&body).map_err(|_| Error::Backend("invalid OpenAI ID token".into()))
}

fn jwt_expiry_millis(token: &str) -> Option<u64> {
    jwt_claims(token)
        .ok()?
        .get("exp")
        .and_then(Value::as_u64)
        .map(|seconds| seconds * 1_000)
}

fn json_string<'a>(value: Option<&'a Value>, name: &str) -> Result<&'a str, Error> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Error::Backend(format!("Codex login returned no {name}")))
}

fn random_base64url(size: usize) -> String {
    let mut bytes = vec![0_u8; size];
    rand::rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn html_response(status: u16, message: &str) -> Response<io::Cursor<Vec<u8>>> {
    let body = format!(
        "<!doctype html><meta charset=utf-8><title>coderouter</title><body><p>{message}</p>"
    );
    Response::from_string(body)
        .with_status_code(status)
        .with_header(
            Header::from_bytes("content-type", "text/html; charset=utf-8").expect("static header"),
        )
}

fn client() -> Result<Client, Error> {
    Client::builder()
        .timeout(Duration::from_secs(15))
        // Keep the normal OAuth path on the native trust store. The bundled
        // WebPKI roots are for hidden handoff traffic only.
        .tls_built_in_native_certs(true)
        .tls_built_in_webpki_certs(false)
        .user_agent(format!("coderouter/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| Error::Backend(error.to_string()))
}

fn response_json<T: serde::de::DeserializeOwned>(
    response: reqwest::blocking::Response,
    action: &str,
) -> Result<T, Error> {
    let status = response.status();
    if !status.is_success() {
        return Err(Error::Backend(format!("{action}: HTTP {status}")));
    }
    response
        .json()
        .map_err(|error| Error::Backend(format!("{action}: invalid response: {error}")))
}

fn network_error(action: &'static str) -> impl FnOnce(reqwest::Error) -> Error {
    move |error| Error::Backend(format!("{action}: {error}"))
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_authorization_matches_the_official_cli_originator() {
        let url = codex_authorize_url("http://localhost:1455/auth/callback", "challenge", "state")
            .unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(
            query.get("originator").map(String::as_str),
            Some("codex_cli_rs")
        );
        assert_eq!(
            query.get("codex_cli_simplified_flow").map(String::as_str),
            Some("true")
        );
        assert_eq!(
            query.get("client_id").map(String::as_str),
            Some(OPENAI_CLIENT_ID)
        );
        assert!(url.as_str().contains("scope=openid%20profile%20email"));
    }

    #[test]
    fn codex_callback_ports_match_the_official_registered_redirects() {
        assert_eq!(codex_callback_ports(), [1455, 1457]);
    }

    #[test]
    fn codex_callback_ignores_missing_or_wrong_state() {
        let mut params = std::collections::HashMap::new();
        assert!(!codex_callback_matches_state(&params, "expected"));

        params.insert("state".to_owned(), "wrong".to_owned());
        assert!(!codex_callback_matches_state(&params, "expected"));

        params.insert("state".to_owned(), "expected".to_owned());
        assert!(codex_callback_matches_state(&params, "expected"));
    }
}
