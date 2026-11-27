//! `cmux cloud wire-watch`: one connection of the Mac app's Cloud machine
//! event socket (`/v1/wire/cloud`), for its spare-ready, machine-pausing and
//! port-change callbacks. The app runs this with the person's session on stdin
//! (the access token never goes in argv):
//!
//! ```json
//! {"api": "https://api.cmux.dev", "access": "…", "team": "team_…"|null, "version": "1.2.3"|null}
//! ```
//!
//! It mints a one-use ticket (`POST /v1/wire/ticket`, scope `cloud`, as the
//! person), opens the socket with the ticket and the team in the subprotocol
//! (`cmux.wire.v1, ticket.<t>, team.<team>`; the access token never goes in
//! it), answers the Worker's `welcome` with `{"t":"subscribe"}` and prints
//! each frame as one JSON line, as it was sent. The last line says why the
//! socket closed: `{"closed": CODE}` or `{"closed": null, "error": "…"}`. The
//! app reconnects (with its backoff) by running this again. The build space
//! header is `cmux-build-space`'s, on the ticket and the upgrade alike: a
//! misconfigured dev build mints no ticket and opens no socket.

use std::io::{Read as _, Write as _};
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use super::cloud_client_session::secure_origin;
use super::cloud_pair_invite_watch::closed;

// timeout: a ticket request or an upgrade that never answers fails this connection (the app backs off and retries).
const TIMEOUT: Duration = Duration::from_secs(20);
/// A wire frame (a snapshot of the team's machines) stays well under this.
const MAX_MESSAGE: usize = 8 << 20;
/// The wire socket's protocol.
pub(crate) const SUBPROTOCOL: &str = "cmux.wire.v1";

/// `Some(exit code)` when `args` is `cloud wire-watch`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "wire-watch" {
        return None;
    }
    let mut stdout = std::io::stdout().lock();
    let mut emit = |line: &Value| {
        let _ = writeln!(stdout, "{line}").and_then(|()| stdout.flush());
    };
    if !rest.is_empty() {
        emit(&closed(None, Some("cmux cloud wire-watch takes its request as JSON on stdin")));
        return Some(1);
    }
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        emit(&closed(None, Some("the request could not be read")));
        return Some(1);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            emit(&closed(None, Some(&error.to_string())));
            return Some(1);
        }
    };
    let last = runtime.block_on(watch(&input, &mut emit));
    emit(&last);
    Some(0)
}

/// One wire request from stdin.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Wire {
    /// The API's bare origin (`https://…`, or loopback `http://…`).
    pub origin: String,
    /// `wss://…/v1/wire/cloud` (`ws://` for a local http API).
    pub socket: String,
    pub access: String,
    pub team: Option<String>,
    pub version: Option<String>,
}

/// Reads `{api, access, team?, version?}`: a https (or loopback http) bare
/// origin, a non-empty access token, and a team that fits a protocol token.
pub(crate) fn parse(input: &[u8]) -> Result<Wire, String> {
    let request: Value =
        serde_json::from_slice(input).map_err(|_| "the request is not a JSON object".to_owned())?;
    let field = |name: &str| {
        request.get(name).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
    };
    let origin = secure_origin(field("api").unwrap_or(""))?;
    let access = field("access").ok_or("no access token")?.to_owned();
    let team = field("team").map(str::to_owned);
    if team.as_deref().is_some_and(|t| !t.bytes().all(|b| b.is_ascii_graphic() && b != b',')) {
        return Err("the team is not a protocol token".into());
    }
    let socket = match origin.split_once("://") {
        Some(("http", host)) => format!("ws://{host}/v1/wire/cloud"),
        Some((_, host)) => format!("wss://{host}/v1/wire/cloud"),
        None => return Err("the cmux API is not a URL".into()),
    };
    Ok(Wire { origin, socket, access, team, version: field("version").map(str::to_owned) })
}

/// The upgrade's `Sec-WebSocket-Protocol`: the ticket and the team, never the access token.
pub(crate) fn protocols(ticket: &str, team: Option<&str>) -> String {
    match team {
        Some(team) => format!("{SUBPROTOCOL}, ticket.{ticket}, team.{team}"),
        None => format!("{SUBPROTOCOL}, ticket.{ticket}"),
    }
}

/// `POST /v1/wire/ticket` for the cloud scope as the person: the one-use ticket.
async fn mint_ticket(wire: &Wire) -> Result<String, String> {
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (_base, http) =
        cmux_cloud_client::http(&wire.origin, Some(&wire.access), None, user_agent, TIMEOUT)
            .map_err(|error| error.to_string())?;
    let response = http
        .post(format!("{}/v1/wire/ticket", wire.origin))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(r#"{"scope":"cloud"}"#)
        .send()
        .await
        .map_err(|error| error.without_url().to_string())?;
    if !response.status().is_success() {
        return Err(format!("Cloud wire ticket refused ({})", response.status().as_u16()));
    }
    let body: Value = response.json().await.map_err(|_| "Cloud wire ticket response".to_owned())?;
    body.get("ticket")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_graphic() && b != b','))
        .map(str::to_owned)
        .ok_or_else(|| "Cloud wire ticket response".to_owned())
}

/// Runs one connection until the socket closes: each frame to `emit`, then
/// the closing line (returned).
pub(crate) async fn watch(input: &[u8], emit: &mut impl FnMut(&Value)) -> Value {
    let wire = match parse(input) {
        Ok(wire) => wire,
        Err(error) => return closed(None, Some(&error)),
    };
    let ticket = match mint_ticket(&wire).await {
        Ok(ticket) => ticket,
        Err(error) => return closed(None, Some(&error)),
    };
    let mut request = match wire.socket.as_str().into_client_request() {
        Ok(request) => request,
        Err(error) => return closed(None, Some(&error.to_string())),
    };
    let headers = request.headers_mut();
    let Ok(mut protocols) = HeaderValue::from_str(&protocols(&ticket, wire.team.as_deref())) else {
        return closed(None, Some("the ticket is not a header value"));
    };
    protocols.set_sensitive(true);
    headers.insert("sec-websocket-protocol", protocols);
    if let Some(version) = wire.version.as_deref().and_then(|v| HeaderValue::from_str(v).ok()) {
        headers.insert("x-cmux-client-version", version);
    }
    if let Err(error) = cmux_build_space::insert(headers) {
        return closed(None, Some(&error.to_string()));
    }
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let connect = cmux_egress::ws::connect_async_with_config(
        request,
        Some(config),
        false,
        "cmux_tui::cli::cloud_wire_watch",
    );
    let mut stream = match tokio::time::timeout(TIMEOUT, connect).await {
        Err(_) => return closed(None, Some("handshake timed out")),
        Ok(Err(error)) => return closed(None, Some(&error.to_string())),
        Ok(Ok((stream, _))) => stream,
    };
    while let Some(message) = stream.next().await {
        let bytes = match message {
            Ok(Message::Text(text)) => text.as_str().as_bytes().to_vec(),
            Ok(Message::Binary(bytes)) => bytes.to_vec(),
            Ok(Message::Ping(_)) => {
                // tungstenite queues the pong for a ping; flush sends it.
                let _ = stream.flush().await;
                continue;
            }
            Ok(Message::Close(frame)) => return closed(frame.map(|f| u16::from(f.code)), None),
            Ok(_) => continue,
            Err(error) => return closed(None, Some(&error.to_string())),
        };
        // One JSON object per line, as the Worker sent it; anything else is skipped.
        let Ok(frame @ Value::Object(_)) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        if frame.get("t").and_then(Value::as_str) == Some("welcome") {
            let subscribe = json!({"t": "subscribe"}).to_string();
            if let Err(error) = stream.send(Message::Text(subscribe.into())).await {
                return closed(None, Some(&error.to_string()));
            }
        }
        emit(&frame);
    }
    closed(None, None)
}

#[cfg(test)]
#[path = "cloud_wire_watch_tests.rs"]
mod tests;
