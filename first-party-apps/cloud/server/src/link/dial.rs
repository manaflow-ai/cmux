//! The one adapter to `cmux link dial` (lane 12, link slice 2): the argv
//! of one dial, and the reply line the dial writes on its stderr. Only
//! this file knows that seam. Contract (lane 12, `cmux link dial`,
//! cmux-tui/spec/cli.md, landed 227dd67c2fe): argv
//! `link dial --host <host_…> --socket <hub_socket>` (service defaults to
//! daemon; `--socket` from 70da4b7ef87: a missing socket = exit 6
//! link_unavailable, a non-socket = 64 bad_request), exactly one
//! JSON reply line on stderr first (any key order; `link_unavailable` when
//! no link runs), then the stream on stdin/stdout. A missing or non-JSON
//! line (an older link) is read as unavailable. Exit codes (0 ok, 2..6,
//! 64) are not read: the reply line already carries the same answer.
//!
//! `cmux link dial --host <host_…>` is a stdio bridge to the host's daemon
//! service: after one JSON reply line on stderr (`{"ok":true,
//! "path_state":...}` or `{"ok":false,"error_code":...}`), stdin and stdout
//! carry the daemon stream. The link resolves the host through
//! `cloud.machine.connect_info` and mints one `cloud.machine.link_token`
//! per dial itself: no token, key or route ever reaches this server.

use serde_json::Value;

/// The longest reply line the dial writes (`cmux_link::dial::MAX_LINE_BYTES`).
pub const MAX_REPLY_BYTES: usize = 1024;

/// The argv (after the binary) of one dial to the daemon service of
/// `host` through the link listening on `socket` (the host's `hub_socket`).
/// The dial child has a private HOME, so it must be told the link's socket
/// (`--socket`, lane 12 70da4b7ef87): a registration lookup would find
/// nothing there, and a tagged or dev link is not at the default path.
pub fn dial_args(host: &str, socket: &std::path::Path) -> Vec<String> {
    vec![
        "link".into(),
        "dial".into(),
        "--host".into(),
        host.to_owned(),
        "--socket".into(),
        socket.to_string_lossy().into_owned(),
    ]
}

/// Why `link.dial` refused (`DialError` of cmux-link, snake case).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DialCode {
    /// The machine is paused: start it (`cloud.machine.start`) and dial again.
    HostPaused,
    /// No Cloud machine names this host.
    UnknownHost,
    /// This install may not reach the host or service (policy or token).
    NotAuthorized,
    /// No path answered.
    Unreachable,
    /// The dial line was malformed (a version skew between this server and the link).
    BadRequest,
    /// The link did not answer a reply line (not running, crashed, an
    /// unknown code): the text says what came instead.
    Unavailable(String),
}

impl DialCode {
    pub fn parse(code: &str) -> Self {
        match code {
            "host_paused" => Self::HostPaused,
            "unknown_host" => Self::UnknownHost,
            "not_authorized" => Self::NotAuthorized,
            "unreachable" => Self::Unreachable,
            "bad_request" => Self::BadRequest,
            // Coming in lane 12's next slice: the link always writes a line.
            "link_unavailable" => Self::Unavailable("cmux link is not running".into()),
            other => Self::Unavailable(format!("cmux link answered {other:?}")),
        }
    }

    /// The code as the dial wrote it (for the carrier's event line).
    pub fn as_str(&self) -> &str {
        match self {
            Self::HostPaused => "host_paused",
            Self::UnknownHost => "unknown_host",
            Self::NotAuthorized => "not_authorized",
            Self::Unreachable => "unreachable",
            Self::BadRequest => "bad_request",
            Self::Unavailable(_) => "unavailable",
        }
    }

    /// A refusal that ends access to the machine (the link stays revoked).
    pub fn revokes(&self) -> bool {
        matches!(self, Self::UnknownHost | Self::NotAuthorized)
    }
}

/// The dial's reply line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DialReply {
    /// The stream is up; `path_state` is `direct`, `relay` or `tunnel`.
    Connected {
        path_state: String,
    },
    Refused(DialCode),
}

/// Reads the dial's first stderr line. Anything that is not a reply (an
/// error text of a link that does not run, an empty line) is
/// [`DialCode::Unavailable`] with that text, cut to a short display.
pub fn parse_reply(line: &str) -> DialReply {
    let text = line.trim();
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        let shown: String = text.chars().take(200).collect();
        return DialReply::Refused(DialCode::Unavailable(if shown.is_empty() {
            "cmux link gave no reply".into()
        } else {
            format!("cmux link: {shown}")
        }));
    };
    match value["ok"].as_bool() {
        Some(true) => DialReply::Connected {
            path_state: value["path_state"].as_str().unwrap_or("direct").to_owned(),
        },
        Some(false) => DialReply::Refused(
            value["error_code"]
                .as_str()
                .map_or_else(|| DialCode::Unavailable("cmux link refused".into()), DialCode::parse),
        ),
        None => DialReply::Refused(DialCode::Unavailable("cmux link sent no ok field".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replies_parse() {
        assert_eq!(
            parse_reply(r#"{"ok":true,"path_state":"tunnel","relay_available":false}"#),
            DialReply::Connected { path_state: "tunnel".into() }
        );
        assert_eq!(
            parse_reply(r#"{"ok":false,"error_code":"host_paused","path_state":"unreachable"}"#),
            DialReply::Refused(DialCode::HostPaused)
        );
        assert!(matches!(
            parse_reply("cmux link is not running: no such file"),
            DialReply::Refused(DialCode::Unavailable(_))
        ));
        assert_eq!(
            dial_args("host_x", std::path::Path::new("/tmp/l.sock")),
            ["link", "dial", "--host", "host_x", "--socket", "/tmp/l.sock"]
        );
    }
}
