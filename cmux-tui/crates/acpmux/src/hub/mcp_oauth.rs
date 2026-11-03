//! The person signs in to an approved MCP server (plans/cmux-next/mcp-connect-DESIGN.md
//! section 5, threat model T12, T13): OAuth 2.1 with PKCE S256, run by the daemon so no token or
//! code reaches an agent.
//!
//! `_acpmux/mcp_sign_in {id}` (the person only):
//! 1. reads the server's RFC 9728 metadata (from its 401, or the well-known URL) and checks that
//!    it names this server; reads its authorization server's RFC 8414 metadata and checks the
//!    issuer, the endpoints and S256;
//! 2. opens a one-shot listener on `http://127.0.0.1:<port>/callback` and registers a public
//!    client for it (RFC 7591);
//! 3. answers the authorize URL (with `state`, the S256 challenge and the RFC 8707 resource),
//!    which the app opens in a cmux browser tab;
//! 4. on the redirect, checks `state` in constant time and `iss` (RFC 9207), exchanges the code
//!    with the verifier, keeps the tokens in the secret store, lists the tools and marks the
//!    connection `connected`. The chat that asked gets an `mcp_connect_result` record.
//!
//! Refresh: [`Hub::mcp_secret_for_call`] refreshes a token that expires within a minute; a
//! refused refresh marks the connection `needsSignIn`.

use super::Hub;
use super::mcp_probe::{KeyHeader, Probe};
use super::mcp_store::{Connection, OauthClient};
use crate::rpc::RpcError;
use cmux_mcp_connect::discovery::{
    AuthServer, AuthorizeRequest, ProtectedResource, Token, auth_server_url, choose_scopes,
    encode_form, protected_resource_url, refresh_form, registration, token_form,
};
use cmux_mcp_connect::pkce;
use cmux_mcp_connect::target::check_url;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zeroize::Zeroizing;

/// How long a sign-in's listener waits for the browser.
const SIGN_IN_TTL: Duration = Duration::from_secs(10 * 60);
const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_METADATA_BYTES: usize = 256 * 1024;
const MAX_REQUEST_BYTES: usize = 16 * 1024;
/// A token this close to its expiry is refreshed before a call.
const REFRESH_EARLY_MS: u64 = 60_000;

fn http() -> Result<reqwest::Client, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "could not start an HTTP client".to_owned())
}

/// The body of a response, at most `cap` bytes.
async fn read_capped(resp: reqwest::Response, cap: usize) -> Result<String, String> {
    let mut resp = resp;
    let mut body = Vec::new();
    while let Some(chunk) =
        resp.chunk().await.map_err(|e| format!("the answer broke off: {}", e.without_url()))?
    {
        body.extend_from_slice(&chunk);
        if body.len() > cap {
            return Err("the answer is too large".to_owned());
        }
    }
    String::from_utf8(body).map_err(|_| "the answer is not text".to_owned())
}

/// GETs JSON metadata from `url`, which must pass the URL rules (T4); no redirects.
async fn get_metadata(client: &reqwest::Client, url: &str) -> Result<String, String> {
    let target = check_url(url).map_err(|r| r.0)?;
    let resp = client
        .get(&target.url)
        .header("accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("could not read {}: {}", target.url, e.without_url()))?;
    if !resp.status().is_success() {
        return Err(format!("{} answered HTTP {}", target.url, resp.status().as_u16()));
    }
    read_capped(resp, MAX_METADATA_BYTES).await
}

/// POSTs a form to a token endpoint and reads the token.
async fn post_token(
    client: &reqwest::Client,
    endpoint: &str,
    form: &[(&'static str, String)],
) -> Result<Token, String> {
    let target = check_url(endpoint).map_err(|r| r.0)?;
    let body = Zeroizing::new(encode_form(form));
    let resp = client
        .post(&target.url)
        .header("content-type", "application/x-www-form-urlencoded")
        .header("accept", "application/json")
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| format!("could not reach the token endpoint: {}", e.without_url()))?;
    let text = Zeroizing::new(read_capped(resp, MAX_METADATA_BYTES).await?);
    Token::parse(&text).map_err(|r| r.0)
}

/// The secret JSON kept for a token.
fn token_secret(token: &Token, client_id: &str) -> Zeroizing<String> {
    let expires_at = token.expires_in.map(|s| crate::store::now_ms() + s.saturating_mul(1000));
    Zeroizing::new(
        json!({
            "accessToken": token.access_token,
            "refreshToken": token.refresh_token,
            "expiresAt": expires_at,
            "clientId": client_id,
        })
        .to_string(),
    )
}

/// What the sign-in learned before the browser step.
struct Plan {
    auth: AuthServer,
    resource: String,
    scopes: Vec<String>,
}

async fn discover(client: &reqwest::Client, conn: &Connection) -> Result<Plan, String> {
    let pr_url = match &conn.resource_metadata {
        Some(u) => u.clone(),
        None => protected_resource_url(&conn.url).map_err(|r| r.0)?,
    };
    let pr = ProtectedResource::parse(&get_metadata(client, &pr_url).await?).map_err(|r| r.0)?;
    pr.check(&conn.url).map_err(|r| r.0)?;
    let issuer = pr.authorization_servers[0].clone();
    let auth = AuthServer::parse(
        &get_metadata(client, &auth_server_url(&issuer).map_err(|r| r.0)?).await?,
    )
    .map_err(|r| r.0)?;
    auth.check(&issuer).map_err(|r| r.0)?;
    let registry = cmux_mcp_connect::registry::Registry::builtin();
    let listed: Vec<String> =
        registry.by_url(&conn.url).map(|e| e.scopes.clone()).unwrap_or_default();
    let supported =
        if pr.scopes_supported.is_empty() { &auth.scopes_supported } else { &pr.scopes_supported };
    let scopes = choose_scopes(&listed, &conn.challenge_scopes, supported);
    Ok(Plan { auth, resource: pr.resource, scopes })
}

/// The HTML a browser shows after the redirect (no secret, no server text).
fn page(ok: bool, title: &str) -> String {
    let (head, line) = if ok {
        ("Signed in", format!("cmux is connected to {title}. You can close this tab."))
    } else {
        (
            "Sign-in did not finish",
            format!("cmux could not finish the sign-in to {title}. Try again from cmux."),
        )
    };
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let body = format!(
        "<!doctype html><meta charset=utf-8><title>{h}</title><body style=\"font:15px -apple-system,sans-serif;margin:40px\"><h2>{h}</h2><p>{l}</p>",
        h = esc(head),
        l = esc(&line)
    );
    format!(
        "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncache-control: no-store\r\nconnection: close\r\ncontent-length: {}\r\n\r\n{body}",
        body.len()
    )
}

/// Reads one HTTP request from `sock` and returns the query of a `GET /callback?...`.
async fn read_callback(sock: &mut tokio::net::TcpStream) -> Option<String> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 2048];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = tokio::time::timeout(Duration::from_secs(10), sock.read(&mut chunk))
            .await
            .ok()?
            .ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() > MAX_REQUEST_BYTES {
            return None;
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let line = text.lines().next()?;
    let target = line.strip_prefix("GET ")?.split(' ').next()?;
    target.strip_prefix("/callback?").map(str::to_owned)
}

impl Hub {
    /// `_acpmux/mcp_sign_in`: starts the sign-in and answers `{authorizeUrl}` for the app to open.
    pub async fn mcp_sign_in(self: &Arc<Self>, id: &str) -> Result<Value, RpcError> {
        let conn = self
            .mcp_store
            .get(id)
            .ok_or_else(|| RpcError::invalid_params("no MCP connection with that id"))?;
        if !matches!(conn.auth.as_str(), "oauth" | "discover") {
            return Err(RpcError::invalid_params("this server signs in with a key, not OAuth"));
        }
        let client = http().map_err(RpcError::invalid_params)?;
        let plan = discover(&client, &conn).await.map_err(|why| {
            self.mcp_store.audit(
                json!({"event": "signIn", "id": id, "outcome": "failed", "step": "discovery"}),
            );
            RpcError::invalid_params(format!("sign-in: {why}"))
        })?;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|_| RpcError::invalid_params("could not open the sign-in listener"))?;
        let port = listener
            .local_addr()
            .map_err(|_| RpcError::invalid_params("could not open the sign-in listener"))?
            .port();
        let redirect_uri = format!("http://127.0.0.1:{port}/callback");
        let Some(registration_endpoint) = plan.auth.registration_endpoint.clone() else {
            return Err(RpcError::invalid_params(
                "sign-in: the server has no client registration (RFC 7591); cmux cannot sign in to it yet",
            ));
        };
        let registered = async {
            let target = check_url(&registration_endpoint).map_err(|r| r.0)?;
            let resp = client
                .post(&target.url)
                .header("content-type", "application/json")
                .header("accept", "application/json")
                .body(registration(&redirect_uri).to_string())
                .send()
                .await
                .map_err(|e| format!("could not register: {}", e.without_url()))?;
            let text = read_capped(resp, MAX_METADATA_BYTES).await?;
            let value: Value = serde_json::from_str(&text)
                .map_err(|_| "the registration answer is not JSON".to_owned())?;
            value["client_id"]
                .as_str()
                .filter(|c| !c.is_empty() && c.len() <= 512)
                .map(str::to_owned)
                .ok_or_else(|| "the registration gave no client id".to_owned())
        }
        .await
        .map_err(|why| RpcError::invalid_params(format!("sign-in: {why}")))?;
        let mut random = [0u8; 32];
        getrandom::fill(&mut random).map_err(|_| RpcError::invalid_params("no randomness"))?;
        let verifier = Zeroizing::new(pkce::verifier(&random));
        getrandom::fill(&mut random).map_err(|_| RpcError::invalid_params("no randomness"))?;
        let state = pkce::state(&random);
        let authorize_url = plan
            .auth
            .authorize_url(&AuthorizeRequest {
                client_id: &registered,
                redirect_uri: &redirect_uri,
                state: &state,
                code_challenge: &pkce::challenge_s256(&verifier),
                resource: &plan.resource,
                scopes: &plan.scopes,
            })
            .map_err(|r| RpcError::invalid_params(r.0))?;
        let oauth = OauthClient {
            issuer: plan.auth.issuer.clone(),
            token_endpoint: plan.auth.token_endpoint.clone(),
            client_id: registered.clone(),
            resource: plan.resource.clone(),
            scopes: plan.scopes.clone(),
        };
        self.mcp_store.audit(json!({
            "event": "signIn", "id": id, "outcome": "started", "issuer": oauth.issuer,
            "scopes": oauth.scopes,
        }));
        let hub = self.clone();
        let id_owned = id.to_owned();
        tokio::spawn(async move {
            let done = tokio::time::timeout(
                SIGN_IN_TTL,
                hub.finish_sign_in(
                    listener,
                    &id_owned,
                    plan.auth,
                    oauth,
                    redirect_uri,
                    state,
                    verifier,
                    client,
                ),
            )
            .await;
            if done.is_err() {
                hub.mcp_store
                    .audit(json!({"event": "signIn", "id": id_owned, "outcome": "expired"}));
            }
        });
        Ok(
            json!({"id": id, "authorizeUrl": authorize_url, "redirectUri": format!("http://127.0.0.1:{port}/callback")}),
        )
    }

    #[allow(clippy::too_many_arguments)]
    async fn finish_sign_in(
        self: &Arc<Self>,
        listener: tokio::net::TcpListener,
        id: &str,
        auth: AuthServer,
        oauth: OauthClient,
        redirect_uri: String,
        state: String,
        verifier: Zeroizing<String>,
        client: reqwest::Client,
    ) {
        let title = self.mcp_store.get(id).map(|c| c.title).unwrap_or_default();
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let Some(query) = read_callback(&mut sock).await else {
                let _ = sock
                    .write_all(
                        b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                    )
                    .await;
                continue;
            };
            // A wrong state is someone else's request: ignored, the listener keeps waiting (T12).
            let code = match auth.callback_code(&query, &state) {
                Ok(code) => Zeroizing::new(code),
                Err(r) if r.0.contains("state") => {
                    let _ = sock.write_all(b"HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").await;
                    continue;
                }
                Err(_) => {
                    let _ = sock.write_all(page(false, &title).as_bytes()).await;
                    self.mcp_store
                        .audit(json!({"event": "signIn", "id": id, "outcome": "refused"}));
                    return;
                }
            };
            let token = post_token(
                &client,
                &auth.token_endpoint,
                &token_form(&code, &verifier, &redirect_uri, &oauth.client_id, &oauth.resource),
            )
            .await;
            let ok = match token {
                Ok(token) => self.keep_token(id, &token, oauth.clone()).await,
                Err(_) => false,
            };
            let _ = sock.write_all(page(ok, &title).as_bytes()).await;
            self.mcp_store.audit(json!({
                "event": "signIn", "id": id, "outcome": if ok { "connected" } else { "failed" },
            }));
            return;
        }
    }

    /// Keeps a fresh token, lists the tools with it and marks the connection connected; tells
    /// the chat that asked. False when the server does not list tools with it.
    async fn keep_token(&self, id: &str, token: &Token, oauth: OauthClient) -> bool {
        let secret = token_secret(token, &oauth.client_id);
        let Some(conn) = self.mcp_store.get(id) else { return false };
        let bearer = Zeroizing::new(format!("Bearer {}", token.access_token));
        let Probe::Tools { tools, server } = super::mcp_probe::probe(
            &conn.url,
            Some(KeyHeader { name: "authorization", value: &bearer }),
        )
        .await
        else {
            return false;
        };
        if self.mcp_store.secrets.put(id, &secret).is_err() {
            return false;
        }
        self.mcp_store.update(id, |c| c.oauth = Some(oauth));
        self.relist(id, tools.clone());
        if let Ok(session) = self.resolve(&conn.asked_by) {
            let report = cmux_mcp_connect::wire::tool_report(&tools);
            self.append(
                &session,
                "mux",
                "mcp_connect_result",
                json!({
                    "connect": "connected", "connectionId": id, "name": conn.name,
                    "server": server.get("name").cloned().unwrap_or(Value::Null),
                    "tools": report, "pinned": tools.len(), "signedIn": true,
                }),
            );
        }
        true
    }

    /// The secret a call carries for `conn`: the stored key, or an access token refreshed first
    /// when it expires within a minute. `Err` is a code; a refused refresh marks the connection
    /// `needsSignIn`.
    pub(super) async fn mcp_secret_for_call(
        &self,
        conn: &Connection,
    ) -> Result<Option<Zeroizing<String>>, &'static str> {
        let Some(secret) = self.mcp_store.secrets.get(&conn.id)? else { return Ok(None) };
        let value: Zeroizing<Value> =
            Zeroizing::new(serde_json::from_str(&secret).unwrap_or(Value::Null));
        let expires_at = value.get("expiresAt").and_then(Value::as_u64);
        let due = expires_at.is_some_and(|at| at <= crate::store::now_ms() + REFRESH_EARLY_MS);
        if !due {
            return Ok(Some(secret));
        }
        let (Some(refresh), Some(oauth)) =
            (value.get("refreshToken").and_then(Value::as_str), &conn.oauth)
        else {
            self.mcp_store.update(&conn.id, |c| c.state = "needsSignIn".to_owned());
            return Err("mcp.sign_in_expired");
        };
        let client = http().map_err(|_| "mcp.http_client")?;
        match post_token(
            &client,
            &oauth.token_endpoint,
            &refresh_form(refresh, &oauth.client_id, &oauth.resource),
        )
        .await
        {
            Ok(mut token) => {
                // A server may keep the refresh token and not send it again.
                if token.refresh_token.is_none() {
                    token.refresh_token = Some(refresh.to_owned());
                }
                let fresh = token_secret(&token, &oauth.client_id);
                self.mcp_store.secrets.put(&conn.id, &fresh)?;
                self.mcp_store.audit(json!({"event": "refresh", "id": conn.id, "outcome": "ok"}));
                Ok(Some(fresh))
            }
            Err(_) => {
                self.mcp_store.update(&conn.id, |c| c.state = "needsSignIn".to_owned());
                self.mcp_store
                    .audit(json!({"event": "refresh", "id": conn.id, "outcome": "refused"}));
                Err("mcp.sign_in_expired")
            }
        }
    }
}
