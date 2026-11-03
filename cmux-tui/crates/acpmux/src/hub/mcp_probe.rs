//! The first connect after the person approves a card: `initialize`, then `tools/list`, over MCP
//! Streamable HTTP. It learns one of three things: the tools (checked by the screen and classed,
//! `cmux_mcp_connect::wire::tool_report`), that the server wants a sign-in (a 401 and its RFC 9728
//! metadata URL, which the person's sign-in step uses), or why it failed.
//!
//! - Only an approved card's URL is fetched (T4), with redirects off, so a server cannot send the
//!   request, or a key, to another host.
//! - A key goes only in the server's own header and never into a record or a reply.
//! - Replies are read up to `wire::MAX_REPLY_BYTES`; pages stop at `wire::MAX_PAGES`.

use cmux_mcp_connect::discovery::{challenge_scopes, resource_metadata_url};
use cmux_mcp_connect::target::check_url;
use cmux_mcp_connect::wire::{
    MAX_PAGES, MAX_REPLY_BYTES, MAX_TOOLS, initialize_body, initialized_note, reply_result,
    tools_list_body, tools_page,
};
use serde_json::Value;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(20);

/// What the first connect learned.
#[derive(Debug)]
pub enum Probe {
    /// The server's tools (as listed).
    Tools { tools: Vec<Value>, server: Value },
    /// The server wants a sign-in first.
    SignIn { resource_metadata: Option<String>, scopes: Vec<String> },
    /// The connect failed; the text names why and holds no secret.
    Failed(String),
}

/// A header and value that carry the person's key (never logged).
pub struct KeyHeader<'a> {
    pub name: &'a str,
    pub value: &'a str,
}

struct Conn {
    http: reqwest::Client,
    url: String,
    session: Option<String>,
}

enum Sent {
    Reply(String, String),
    Unauthorized(String),
    /// HTTP 404 to a request with a session id: the server forgot the session.
    Expired,
}

impl Conn {
    async fn post(
        &mut self,
        body: &Value,
        expect: Option<u64>,
        key: Option<&KeyHeader<'_>>,
    ) -> Result<Sent, String> {
        let mut req = self
            .http
            .post(&self.url)
            .header("accept", "application/json, text/event-stream")
            .header("content-type", "application/json")
            .header("mcp-protocol-version", cmux_mcp_connect::wire::PROTOCOL_VERSION)
            .body(body.to_string());
        if let Some(s) = &self.session {
            req = req.header("mcp-session-id", s);
        }
        if let Some(k) = key {
            req = req.header(k.name, k.value);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("could not reach the server: {}", e.without_url()))?;
        let status = resp.status();
        if status.as_u16() == 401 {
            let challenge = resp
                .headers()
                .get("www-authenticate")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_owned();
            return Ok(Sent::Unauthorized(challenge));
        }
        if status.as_u16() == 404 && self.session.is_some() {
            return Ok(Sent::Expired);
        }
        if status.is_redirection() {
            return Err("the server redirected; cmux does not follow it".to_owned());
        }
        if let Some(id) = resp.headers().get("mcp-session-id").and_then(|v| v.to_str().ok())
            && id.len() <= 256
            && id.bytes().all(|b| (0x21..=0x7e).contains(&b))
        {
            self.session = Some(id.to_owned());
        }
        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        if !status.is_success() {
            return Err(format!("the server answered HTTP {}", status.as_u16()));
        }
        let mut body = Vec::new();
        let mut resp = resp;
        while let Some(chunk) =
            resp.chunk().await.map_err(|e| format!("the reply broke off: {}", e.without_url()))?
        {
            body.extend_from_slice(&chunk);
            if body.len() > MAX_REPLY_BYTES {
                return Err("the server's reply is too large".to_owned());
            }
            // A stream may stay open after the reply; stop once the reply to `expect` is in.
            if let Some(id) = expect
                && content_type.starts_with("text/event-stream")
                && body.ends_with(b"\n")
                && reply_result(&content_type, &String::from_utf8_lossy(&body), id).is_ok()
            {
                break;
            }
        }
        Ok(Sent::Reply(content_type, String::from_utf8_lossy(&body).into_owned()))
    }
}

fn sign_in(challenge: &str) -> Probe {
    Probe::SignIn {
        resource_metadata: resource_metadata_url(challenge),
        scopes: challenge_scopes(challenge),
    }
}

/// The HTTP client of every MCP request: a timeout, and redirects off (T4).
fn client() -> Option<reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .dns_resolver(super::mcp_resolver::CheckedResolver)
        .build()
        .ok()
}

/// What one tool call came back with.
#[derive(Debug)]
pub enum Called {
    /// The server's `tools/call` result (its `content`, `isError` and the rest).
    Result(Value),
    /// The server wants a (new) sign-in.
    SignIn { resource_metadata: Option<String>, scopes: Vec<String> },
    /// The call failed; the text names why and holds no secret.
    Failed(String),
}

/// Calls the server's tool `name` at `url` with `arguments`. `session` is the MCP session id an
/// earlier call kept: when the server forgot it (404), or there is none, the call starts a new
/// one first. Returns the result and the session id to keep.
pub async fn call_tool(
    url: &str,
    key: Option<KeyHeader<'_>>,
    session: Option<String>,
    name: &str,
    arguments: &Value,
) -> (Called, Option<String>) {
    let target = match check_url(url) {
        Ok(t) => t,
        Err(refusal) => return (Called::Failed(refusal.0), None),
    };
    let Some(http) = client() else {
        return (Called::Failed("could not start an HTTP client".to_owned()), None);
    };
    let key = key.as_ref();
    let mut conn = Conn { http, url: target.url.clone(), session };
    for attempt in 0..2 {
        if conn.session.is_none() || attempt > 0 {
            conn.session = None;
            match conn.post(&initialize_body(1), Some(1), key).await {
                Ok(Sent::Unauthorized(c)) => {
                    return (
                        Called::SignIn {
                            resource_metadata: resource_metadata_url(&c),
                            scopes: challenge_scopes(&c),
                        },
                        None,
                    );
                }
                Ok(Sent::Reply(ct, body)) => {
                    if let Err(refusal) = reply_result(&ct, &body, 1) {
                        return (Called::Failed(refusal.0), None);
                    }
                }
                Ok(Sent::Expired) => {
                    return (Called::Failed("the server ended the session".to_owned()), None);
                }
                Err(e) => return (Called::Failed(e), None),
            }
            let _ = conn.post(&initialized_note(), None, key).await;
        }
        let body = cmux_mcp_connect::wire::tools_call_body(2, name, arguments);
        match conn.post(&body, Some(2), key).await {
            Ok(Sent::Expired) if attempt == 0 => continue,
            Ok(Sent::Expired) => {
                return (Called::Failed("the server ended the session".to_owned()), None);
            }
            Ok(Sent::Unauthorized(c)) => {
                return (
                    Called::SignIn {
                        resource_metadata: resource_metadata_url(&c),
                        scopes: challenge_scopes(&c),
                    },
                    None,
                );
            }
            Ok(Sent::Reply(ct, body)) => {
                let out = match reply_result(&ct, &body, 2) {
                    Ok(result) => Called::Result(result),
                    Err(refusal) => Called::Failed(refusal.0),
                };
                return (out, conn.session);
            }
            Err(e) => return (Called::Failed(e), conn.session),
        }
    }
    (Called::Failed("the server ended the session".to_owned()), None)
}

/// Connects to `url` and lists its tools. `url` must pass the URL rules again (the card may be
/// old); a key, when given, goes in its header.
pub async fn probe(url: &str, key: Option<KeyHeader<'_>>) -> Probe {
    let target = match check_url(url) {
        Ok(t) => t,
        Err(refusal) => return Probe::Failed(refusal.0),
    };
    let Some(http) = client() else {
        return Probe::Failed("could not start an HTTP client".to_owned());
    };
    let mut conn = Conn { http, url: target.url.clone(), session: None };
    let key = key.as_ref();
    let server = match conn.post(&initialize_body(1), Some(1), key).await {
        Ok(Sent::Unauthorized(c)) => return sign_in(&c),
        Ok(Sent::Expired) => return Probe::Failed("the server ended the session".to_owned()),
        Ok(Sent::Reply(ct, body)) => match reply_result(&ct, &body, 1) {
            Ok(r) => r.get("serverInfo").cloned().unwrap_or(Value::Null),
            Err(refusal) => return Probe::Failed(refusal.0),
        },
        Err(e) => return Probe::Failed(e),
    };
    // A notification answers 202 with no body; its result does not matter.
    let _ = conn.post(&initialized_note(), None, key).await;
    let mut tools = Vec::new();
    let mut cursor: Option<String> = None;
    for page in 0..MAX_PAGES {
        let id = 2 + page as u64;
        let result = match conn.post(&tools_list_body(id, cursor.as_deref()), Some(id), key).await {
            Ok(Sent::Unauthorized(c)) => return sign_in(&c),
            Ok(Sent::Expired) => return Probe::Failed("the server ended the session".to_owned()),
            Ok(Sent::Reply(ct, body)) => match reply_result(&ct, &body, id) {
                Ok(r) => r,
                Err(refusal) => return Probe::Failed(refusal.0),
            },
            Err(e) => return Probe::Failed(e),
        };
        let (page_tools, next) = match tools_page(&result) {
            Ok(p) => p,
            Err(refusal) => return Probe::Failed(refusal.0),
        };
        tools.extend(page_tools);
        if tools.len() > MAX_TOOLS {
            return Probe::Failed(format!("the server lists more than {MAX_TOOLS} tools"));
        }
        match next {
            Some(n) if !n.is_empty() => cursor = Some(n),
            _ => return Probe::Tools { tools, server },
        }
    }
    Probe::Failed("the tool list has too many pages".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A loopback server that answers 401 unless the request carries `x-test-key: k-secret`, and
    /// otherwise answers each request by its id.
    async fn keyed_server() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://127.0.0.1:{}/mcp", listener.local_addr().unwrap().port());
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut chunk = [0u8; 4096];
                    loop {
                        let text = String::from_utf8_lossy(&buf).into_owned();
                        if let Some(end) = text.find("\r\n\r\n") {
                            let head = text[..end].to_ascii_lowercase();
                            let len = head
                                .lines()
                                .find_map(|l| {
                                    l.strip_prefix("content-length:")
                                        .map(|v| v.trim().parse().unwrap_or(0))
                                })
                                .unwrap_or(0usize);
                            if buf.len() >= end + 4 + len {
                                let body: Value =
                                    serde_json::from_slice(&buf[end + 4..end + 4 + len])
                                        .unwrap_or(Value::Null);
                                buf.drain(..end + 4 + len);
                                let out = if !head.contains("x-test-key: k-secret") {
                                    "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n"
                                        .to_owned()
                                } else if body.get("id").is_none() {
                                    "HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n".to_owned()
                                } else {
                                    let result = if body["method"] == "initialize" {
                                        serde_json::json!({"serverInfo": {"name": "keyed"}})
                                    } else {
                                        serde_json::json!({"tools": [{"name": "query_docs"}]})
                                    };
                                    let b = serde_json::json!({"jsonrpc": "2.0", "id": body["id"], "result": result}).to_string();
                                    format!(
                                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{b}",
                                        b.len()
                                    )
                                };
                                if sock.write_all(out.as_bytes()).await.is_err() {
                                    return;
                                }
                                continue;
                            }
                        }
                        match sock.read(&mut chunk).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => buf.extend_from_slice(&chunk[..n]),
                        }
                    }
                });
            }
        });
        url
    }

    #[tokio::test]
    async fn mcp_connect_key_goes_only_in_its_header_and_never_in_the_result() {
        let url = keyed_server().await;
        match probe(&url, None).await {
            Probe::SignIn { .. } => {}
            other => panic!("without the key the server refuses: {other:?}"),
        }
        let got = probe(&url, Some(KeyHeader { name: "x-test-key", value: "k-secret" })).await;
        assert!(!format!("{got:?}").contains("k-secret"), "the key leaked into the result");
        match got {
            Probe::Tools { tools, server } => {
                assert_eq!(tools[0]["name"], "query_docs");
                assert_eq!(server["name"], "keyed");
            }
            other => panic!("with the key the tools list: {other:?}"),
        }
    }

    #[tokio::test]
    async fn mcp_connect_probe_refuses_unsafe_urls_before_any_request() {
        for url in
            ["http://169.254.169.254/mcp", "https://user@example.com/mcp", "http://example.com/mcp"]
        {
            assert!(matches!(probe(url, None).await, Probe::Failed(_)), "{url}");
        }
    }
}
