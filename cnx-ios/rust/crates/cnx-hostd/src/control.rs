//! Supervised mode (`CNX_CONTROL=stdio`): an app (cmux-next) runs cnx-hostd
//! as its child and owns sign-in and the acpmux endpoint.
//!
//! stdin carries JSON lines from the app:
//! - `{"type":"token","token":"<Stack access token>"}`: the access token to use
//!   from now on. The app sends one at start and answers every `need_token`
//!   (hostd asks whenever it needs one and its token is under a minute from
//!   expiry, or was refused).
//! - `{"type":"acpmux","url":"ws://127.0.0.1:<port>/","token":"<bearer>"}`:
//!   the app's acpmux WebSocket, sent at start and on `need_acpmux` (it moves
//!   when acpmux restarts).
//!
//! End of stdin means the app is gone: the process exits.
//!
//! stdout carries one JSON event per line for the app (logs go to stderr);
//! [`Event`] lists them. Tokens never appear in either stream.

use std::io::Write;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::watch;

/// The acpmux WebSocket the app reported: URL and bearer token.
pub type AcpmuxEndpoint = Option<(String, Option<String>)>;

static ENABLED: OnceLock<bool> = OnceLock::new();

/// Whether this process runs supervised (`CNX_CONTROL=stdio`).
pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| std::env::var("CNX_CONTROL").is_ok_and(|v| v.trim() == "stdio"))
}

/// One line from the app.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Inbound {
    Token {
        token: String,
    },
    Acpmux {
        url: String,
        token: Option<String>,
    },
    /// The browser host the app started for `need_browser` `request`: its
    /// loopback rd stream carrier address and per-launch secret.
    Browser {
        request: u64,
        addr: String,
        secret: String,
    },
    /// The app could not start a browser host for `request`.
    BrowserFailed {
        request: u64,
        reason: String,
    },
    /// The browser host of `tab` exited.
    BrowserGone {
        tab: String,
    },
}

impl Inbound {
    /// Parses one stdin line; `None` for anything else (ignored, never echoed).
    pub fn parse(line: &str) -> Option<Self> {
        serde_json::from_str(line.trim()).ok()
    }
}

/// One line to the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// Registering and opening the signaling socket.
    Connecting,
    /// Registered and holding the signaling socket: phones can dial.
    Online { device_id: String, team_id: String },
    /// The last attempt failed or the socket closed; retrying after the delay.
    Waiting { reason: String, retry_in_seconds: u64 },
    /// The current access token is missing, about to expire, or was refused.
    NeedToken,
    /// The acpmux endpoint is missing or refused a connection (acpmux restarted).
    NeedAcpmux,
    /// A phone's link is up.
    PhoneUp { session_id: String, phone_device_id: String, transport: String, path: String },
    /// A phone's link moved to another path.
    PhonePath { session_id: String, path: String },
    /// A phone's link ended.
    PhoneDown { session_id: String, reason: String },
    /// A phone opened browser tab `tab`: start the app's browser host on
    /// `url` and answer with `browser` (or `browser_failed`) for `request`.
    NeedBrowser { request: u64, tab: String, url: String },
    /// hostd no longer needs the browser host of `tab`: stop it.
    BrowserStop { tab: String },
}

/// Writes `event` as one stdout line when supervised; otherwise nothing.
pub fn emit(event: &Event) {
    if !enabled() {
        return;
    }
    let Ok(line) = serde_json::to_string(event) else { return };
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

/// What the app supplies over stdin, as it changes.
#[derive(Clone)]
pub struct Supplied {
    pub token: watch::Receiver<Option<String>>,
    pub acpmux: watch::Receiver<AcpmuxEndpoint>,
    /// Browser hosts the app starts for the `browser` service.
    pub browser: std::sync::Arc<crate::browser::BrowserBroker>,
}

/// Reads stdin until it ends, then exits the process (the app is gone).
pub fn spawn_stdin_reader() -> Supplied {
    let (token_tx, token) = watch::channel(None);
    let (acpmux_tx, acpmux) = watch::channel(None);
    let browser = std::sync::Arc::new(crate::browser::BrowserBroker::new(std::sync::Arc::new(emit)));
    let broker = std::sync::Arc::clone(&browser);
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            match Inbound::parse(&line) {
                Some(Inbound::Token { token }) => {
                    token_tx.send_replace(Some(token));
                }
                Some(Inbound::Acpmux { url, token }) => {
                    acpmux_tx.send_replace(Some((url, token)));
                }
                Some(Inbound::Browser { request, addr, secret }) => {
                    broker.answer(request, Ok((addr, secret)));
                }
                Some(Inbound::BrowserFailed { request, reason }) => broker.answer(request, Err(reason)),
                Some(Inbound::BrowserGone { tab }) => broker.gone(&tab),
                None => tracing::warn!("ignoring an unknown control line"),
            }
        }
        tracing::info!("control input ended; exiting");
        std::process::exit(0);
    });
    Supplied { token, acpmux, browser }
}

/// The wire name of a transport.
pub fn transport_name(kind: cnx_link::TransportKind) -> &'static str {
    match kind {
        cnx_link::TransportKind::WebRtc => "webrtc",
        cnx_link::TransportKind::WireGuard => "wireguard",
    }
}

/// The wire name of a path.
pub fn path_name(path: cnx_link::dial::LinkPath) -> &'static str {
    match path {
        cnx_link::dial::LinkPath::Direct => "direct",
        cnx_link::dial::LinkPath::Relay => "relay",
        cnx_link::dial::LinkPath::Turn => "turn",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_control_lines() {
        assert_eq!(
            Inbound::parse(r#"{"type":"token","token":"a.b.c"}"#),
            Some(Inbound::Token { token: "a.b.c".into() })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"acpmux","url":"ws://127.0.0.1:1/","token":"t"}"#),
            Some(Inbound::Acpmux { url: "ws://127.0.0.1:1/".into(), token: Some("t".into()) })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"browser","request":3,"addr":"127.0.0.1:5","secret":"s"}"#),
            Some(Inbound::Browser { request: 3, addr: "127.0.0.1:5".into(), secret: "s".into() })
        );
        assert_eq!(
            Inbound::parse(r#"{"type":"browser_gone","tab":"s4"}"#),
            Some(Inbound::BrowserGone { tab: "s4".into() })
        );
        assert_eq!(Inbound::parse(r#"{"type":"nope"}"#), None);
        assert_eq!(Inbound::parse("not json"), None);
    }

    #[test]
    fn events_are_tagged_json() {
        let line = serde_json::to_string(&Event::PhoneUp {
            session_id: "s".into(),
            phone_device_id: "p".into(),
            transport: "wireguard".into(),
            path: "relay".into(),
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"phone_up","session_id":"s","phone_device_id":"p","transport":"wireguard","path":"relay"}"#
        );
        assert_eq!(serde_json::to_string(&Event::NeedToken).unwrap(), r#"{"type":"need_token"}"#);
        assert_eq!(
            serde_json::to_string(&Event::NeedBrowser {
                request: 1,
                tab: "s4".into(),
                url: "about:blank".into()
            })
            .unwrap(),
            r#"{"type":"need_browser","request":1,"tab":"s4","url":"about:blank"}"#
        );
        assert_eq!(
            serde_json::to_string(&Event::Waiting { reason: "x".into(), retry_in_seconds: 2 }).unwrap(),
            r#"{"type":"waiting","reason":"x","retry_in_seconds":2}"#
        );
    }
}
