//! `cmux cloud pair-invite-watch`: the watch socket of one "Pair Another
//! Machine…" invite (`GET /v1/pair/invite/wait?invite=CODE`, subprotocols
//! `cmux.pair-invite.v1, watch.<secret>`), for the app's invite card. The app
//! runs this with the invite on stdin (the watch secret never goes in argv):
//!
//! ```json
//! {"api": "https://api.cmux.dev", "invite": "7KQ4MX2D9P", "secret": "…"}
//! ```
//!
//! Each frame the Worker pushes comes out as one JSON line, as it was sent;
//! the last line says why the socket closed: `{"closed": 4408}` (the close
//! code), or `{"closed": null}` when it closed with none, failed or never
//! opened (`"error"` says why). The socket pushes every change; nothing polls.
//! The build space header is `cmux-build-space`'s, as on every Rust cloud call:
//! a misconfigured dev build opens no socket.

use std::io::{Read as _, Write as _};
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use super::cloud_client_session::secure_origin;

// timeout: a WebSocket upgrade that never completes fails the watch (the card says lost).
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
/// An invite frame is a few hundred bytes.
const MAX_MESSAGE: usize = 64 << 10;
/// The invite socket's protocol.
pub(crate) const SUBPROTOCOL: &str = "cmux.pair-invite.v1";

/// `Some(exit code)` when `args` is `cloud pair-invite-watch`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "pair-invite-watch" {
        return None;
    }
    let mut stdout = std::io::stdout().lock();
    let mut emit = |line: &Value| {
        let _ = writeln!(stdout, "{line}").and_then(|()| stdout.flush());
    };
    if !rest.is_empty() {
        emit(&closed(None, Some("cmux cloud pair-invite-watch takes the invite as JSON on stdin")));
        return Some(1);
    }
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        emit(&closed(None, Some("the invite could not be read")));
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

/// The last line: why the socket closed.
pub(crate) fn closed(code: Option<u16>, error: Option<&str>) -> Value {
    match error {
        Some(error) => json!({"closed": code, "error": error}),
        None => json!({"closed": code}),
    }
}

/// One watch request from stdin.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Watch {
    /// `wss://…/v1/pair/invite/wait?invite=CODE` (`ws://` for a local http API).
    pub url: String,
    pub secret: String,
}

/// Reads `{api, invite, secret}`: a https (or loopback http) bare origin, a
/// letters-and-digits invite code and a non-empty secret that fits a header.
pub(crate) fn parse(input: &[u8]) -> Result<Watch, String> {
    let request: Value =
        serde_json::from_slice(input).map_err(|_| "the invite is not a JSON object".to_owned())?;
    let field = |name: &str| request.get(name).and_then(Value::as_str).map(str::trim).unwrap_or("");
    let origin = secure_origin(field("api"))?;
    let invite = field("invite");
    if invite.is_empty() || !invite.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("the invite code is not letters and digits".into());
    }
    let secret = field("secret");
    if secret.is_empty() || !secret.bytes().all(|b| b.is_ascii_graphic() && b != b',') {
        return Err("the watch secret is empty or not a protocol token".into());
    }
    let socket = match origin.split_once("://") {
        Some(("http", host)) => format!("ws://{host}"),
        Some((_, host)) => format!("wss://{host}"),
        None => return Err("the cmux API is not a URL".into()),
    };
    Ok(Watch {
        url: format!("{socket}/v1/pair/invite/wait?invite={invite}"),
        secret: secret.to_owned(),
    })
}

/// Runs the watch until the socket closes: each frame to `emit`, then the
/// closing line (returned).
pub(crate) async fn watch(input: &[u8], emit: &mut impl FnMut(&Value)) -> Value {
    let watch = match parse(input) {
        Ok(watch) => watch,
        Err(error) => return closed(None, Some(&error)),
    };
    let mut request = match watch.url.as_str().into_client_request() {
        Ok(request) => request,
        Err(error) => return closed(None, Some(&error.to_string())),
    };
    let headers = request.headers_mut();
    let Ok(mut protocols) =
        HeaderValue::from_str(&format!("{SUBPROTOCOL}, watch.{}", watch.secret))
    else {
        return closed(None, Some("the watch secret is not a header value"));
    };
    protocols.set_sensitive(true);
    headers.insert("sec-websocket-protocol", protocols);
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
        "cmux_tui::cli::cloud_pair_invite_watch",
    );
    let mut stream = match tokio::time::timeout(HANDSHAKE_TIMEOUT, connect).await {
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
        if let Ok(frame @ Value::Object(_)) = serde_json::from_slice::<Value>(&bytes) {
            emit(&frame);
        }
    }
    closed(None, None)
}

#[cfg(test)]
#[path = "cloud_pair_invite_watch_tests.rs"]
mod tests;
