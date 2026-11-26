//! The viewer's side of the `cmux.rd/1` control codec (was
//! `RemoteRdControl.swift`, `RemoteRdControlFields.swift`, `RemoteRdJSON.swift`
//! and the caps in `RemoteRdCursorShape.swift`). The messages themselves are
//! cmux-rd-proto's typed [`Control`]; this module adds only what the viewer
//! reads differently: a message type it does not know is [`Incoming::Unknown`]
//! (a newer host's message never ends the session), and a welcome from a host
//! older than rd change C1 has no `service` or `caps`.

use cmux_rd_core::service::caps;
use cmux_rd_proto::SERVICE_DESKTOP;
use cmux_rd_proto::control::{Control, SecretHex};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `RemoteRdHello.cursorCap`.
pub const CURSOR_CAP: &str = caps::CURSOR;
/// `RemoteRdHello.fecBlocksCap`.
pub const FEC_BLOCKS_CAP: &str = caps::FEC_BLOCKS;
/// `RemoteRdHello.videoScaledCap`.
pub const VIDEO_SCALED_CAP: &str = caps::VIDEO_SCALED;
/// `RemoteRdHello.clockCap`.
pub const CLOCK_CAP: &str = caps::CLOCK;
/// `RemoteRdHello.ledgerCap`.
pub const LEDGER_CAP: &str = caps::LEDGER;
/// `RemoteRdHello.clipboardTextCap`.
pub const CLIPBOARD_TEXT_CAP: &str = caps::CLIPBOARD_TEXT;
/// `RemoteRdStreamTransport.inputServiceCap`.
pub const INPUT_SERVICE_CAP: &str = caps::INPUT_SERVICE;
/// `RemoteRdStreamTransport.remoteBrowserService`.
pub const REMOTE_BROWSER_SERVICE: &str = cmux_rd_proto::SERVICE_REMOTE_BROWSER;
/// A hello's `max_datagram` unless named (`RemoteRdHello.init`), and the
/// upstream sender's when the welcome is missing.
pub const DEFAULT_MAX_DATAGRAM: usize = cmux_rd_proto::MAX_DATAGRAM_VPC;

/// Every `t` cmux-rd-proto's [`Control`] knows. A message whose tag is not
/// here parses as [`Incoming::Unknown`]; one whose tag is here but whose
/// fields do not parse is an error (the transport skips it).
pub const CONTROL_TAGS: &[&str] = &[
    "hello",
    "start",
    "stop",
    "welcome",
    "started",
    "refused",
    "ended",
    "service",
    "bulk_credit",
    "stream_open",
    "stream_opened",
    "stream_refused",
    "stream_close",
    "link_offer",
    "link_answer",
    "link_candidate",
    "link_state",
    "cursor_shape",
    "clipboard",
    "stats",
];

fn default_class() -> String {
    "user".to_owned()
}

fn default_true() -> bool {
    true
}

fn default_max_datagram() -> usize {
    DEFAULT_MAX_DATAGRAM
}

fn default_service() -> String {
    SERVICE_DESKTOP.to_owned()
}

/// The viewer's first message as the viewer builds it (`RemoteRdHello`), with
/// the Swift initializer's defaults. [`Hello::control`] is what goes out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    pub user: String,
    pub install: String,
    #[serde(default = "default_class")]
    pub class: String,
    #[serde(default = "default_true")]
    pub interactive: bool,
    /// The viewer's UDP port for media, or none for the stream carrier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub udp_port: Option<u16>,
    #[serde(default = "default_max_datagram")]
    pub max_datagram: usize,
    /// The per-launch session token, 64 hex characters; Debug never prints it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<Secret>,
    #[serde(default = "default_service")]
    pub service: String,
    #[serde(default)]
    pub caps: Vec<String>,
}

/// A token in a [`Hello`]: compared as text, never printed.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Secret(pub String);

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

impl Hello {
    pub fn new(
        user: &str,
        install: &str,
        token: Option<&str>,
        service: &str,
        caps: &[&str],
    ) -> Self {
        Self {
            user: user.to_owned(),
            install: install.to_owned(),
            class: default_class(),
            interactive: true,
            udp_port: None,
            max_datagram: DEFAULT_MAX_DATAGRAM,
            token: token.map(|t| Secret(t.to_owned())),
            service: service.to_owned(),
            caps: caps.iter().map(|&c| c.to_owned()).collect(),
        }
    }

    /// `RemoteRdHello.cloudDesktop(install:)`: a Cloud machine's desktop over
    /// the owner's Native link, with no token (the link admitted the owner).
    pub fn cloud_desktop(install: Option<&str>) -> Self {
        let install = install
            .map(str::to_owned)
            .unwrap_or_else(|| format!("cmux-next-{}", std::process::id()));
        Self::new("cmux", &install, None, SERVICE_DESKTOP, &[CURSOR_CAP, FEC_BLOCKS_CAP])
    }

    /// `RemoteRdStreamTransport.remoteBrowser`: service `rb/1` with the
    /// `input.service` cap (the transport then starts key `tab` in control).
    pub fn remote_browser(user: &str, install: &str, token: Option<&str>) -> Self {
        Self::new(user, install, token, REMOTE_BROWSER_SERVICE, &[INPUT_SERVICE_CAP])
    }

    /// The hello the stream transport sends (`RemoteRdStreamTransport.init`):
    /// no UDP port, and `clipboard.text` added once when the caller offers it.
    pub fn for_stream(mut self, clipboard: bool) -> Self {
        self.udp_port = None;
        if clipboard && !self.caps.iter().any(|c| c == CLIPBOARD_TEXT_CAP) {
            self.caps.push(CLIPBOARD_TEXT_CAP.to_owned());
        }
        self
    }

    /// The typed message.
    pub fn control(&self) -> Control {
        Control::Hello {
            user: self.user.clone(),
            install: self.install.clone(),
            class: self.class.clone(),
            interactive: self.interactive,
            udp_port: self.udp_port,
            max_datagram: self.max_datagram,
            token: self.token.as_ref().map(|t| SecretHex(t.0.clone())),
            service: self.service.clone(),
            caps: self.caps.clone(),
        }
    }

    /// `RemoteRdHello.redactedDescription`: what a log may print.
    pub fn redacted_description(&self) -> String {
        let token = if self.token.is_none() { "none" } else { "<redacted>" };
        format!(
            "RemoteRdHello(user: {}, install: {}, service: {}, token: {token})",
            self.user, self.install, self.service
        )
    }
}

/// The host's welcome as the viewer reads it (`RemoteRdWelcome`): a host older
/// than C1 leaves out `service` and `caps`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    pub encoder: String,
    pub width: u32,
    pub height: u32,
    pub max_datagram: usize,
    pub carrier: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caps: Option<Vec<String>>,
}

impl Welcome {
    pub fn has_cap(&self, cap: &str) -> bool {
        self.caps.as_ref().is_some_and(|caps| caps.iter().any(|c| c == cap))
    }
}

/// One control message from the host.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Incoming {
    Welcome {
        welcome: Welcome,
    },
    Control {
        control: Control,
    },
    /// A message type this viewer does not know (a newer host); ignored.
    Unknown {
        tag: String,
    },
}

/// Why a control message did not parse.
#[derive(Debug)]
pub enum ParseError {
    Json(serde_json::Error),
    /// Not an object with a string `t`.
    NoTag,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Json(e) => write!(f, "{e}"),
            Self::NoTag => f.write_str("control message has no tag"),
        }
    }
}

impl std::error::Error for ParseError {}

/// `RemoteRdControl.parse`: one type-1 stream frame payload.
pub fn parse(json: &[u8]) -> Result<Incoming, ParseError> {
    let value: Value = serde_json::from_slice(json).map_err(ParseError::Json)?;
    parse_value(value)
}

/// [`parse`] of an already parsed value.
pub fn parse_value(value: Value) -> Result<Incoming, ParseError> {
    let tag = value.get("t").and_then(Value::as_str).ok_or(ParseError::NoTag)?.to_owned();
    if tag == "welcome" {
        return serde_json::from_value(value)
            .map(|welcome| Incoming::Welcome { welcome })
            .map_err(ParseError::Json);
    }
    if !CONTROL_TAGS.contains(&tag.as_str()) {
        return Ok(Incoming::Unknown { tag });
    }
    serde_json::from_value(value)
        .map(|control| Incoming::Control { control })
        .map_err(ParseError::Json)
}

/// The JSON object of one message the viewer sends: absent optionals are left
/// out (the Swift encoder's `encodeIfPresent`), so a tokenless hello has no
/// `token` key at all. A service `body` is passed through as it is, null too.
pub fn encode(control: &Control) -> Value {
    let mut value = serde_json::to_value(control).unwrap_or(Value::Null);
    if let Value::Object(map) = &mut value {
        map.retain(|k, v| k == "body" || !v.is_null());
    }
    value
}

/// The `start` message: key `startKey`, mode `control` or `view`.
pub fn start(key: &str, control: bool) -> Control {
    Control::Start {
        key: key.to_owned(),
        mode: if control { "control" } else { "view" }.to_owned(),
    }
}
