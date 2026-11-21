//! The one adapter to the Mac app's carrier (design/cloud-carrier.md): the
//! socket the app hands this server for a machine, and how its refusals
//! read. Only this file knows that seam.
//!
//! The server never dials and never holds a credential. For each new link
//! it asks the host for the machine's carrier socket with one `relay.carrier
//! {machine}` line (crate::api::relay). The daemon routes it to the Mac
//! app's `credential` provider as `credential.carrier_socket {machine}`; the
//! app makes sure its own `cmux carrier serve --machine <vm_…> --socket …`
//! child for that machine runs (the one its Cloud session uses, with the
//! person's credential in that child only) and answers `{"socket": PATH}`:
//! the absolute path of that child's 0600 socket, nothing else. Each
//! connection to the socket is one carrier dial of the machine's `mux`
//! service; its bytes are the daemon stream (`cmux.protocol/2` lines). A
//! dial that `carrier serve` refuses closes that connection having written
//! nothing (the app sees the refusal on the child's stderr).
//!
//! A refused ask is a wire error whose `code` is a `cmux carrier` step
//! (`ticket`, `relay`, `parked_timeout`, `handshake`, `service_refused`,
//! `bad_request`, `socket`), `cloud.machine.not_found` (the app has no
//! session of that machine) or `unavailable`; [`DialCode::from_carrier`]
//! reads it.

use serde_json::Value;
use std::path::{Path, PathBuf};

/// `sun_path` is 104 bytes on macOS (one for the NUL).
const MAX_SOCKET_PATH: usize = 103;

/// Why a link to the machine could not be had. The names ([`Self::as_str`])
/// are the server's own vocabulary on its event lines (super::argv); the
/// carrier's step codes map onto them ([`Self::from_carrier`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DialCode {
    /// The machine is paused: start it (`cloud.machine.start`) and dial again.
    HostPaused,
    /// No Cloud machine of the signed-in team has this id.
    UnknownHost,
    /// This person may not reach the machine or the service (no grant).
    NotAuthorized,
    /// The carrier did not get through (relay, park or handshake), or the
    /// app's carrier socket stopped answering.
    Unreachable,
    /// The ask was malformed (a version skew between this server and the app).
    BadRequest,
    /// The app gave no usable answer: the text says what came instead.
    Unavailable(String),
}

impl DialCode {
    /// The server's own name (from [`Self::as_str`]) back to its code, for
    /// the carrier's event lines.
    pub fn parse(code: &str) -> Self {
        match code {
            "host_paused" => Self::HostPaused,
            "unknown_host" => Self::UnknownHost,
            "not_authorized" => Self::NotAuthorized,
            "unreachable" => Self::Unreachable,
            "bad_request" => Self::BadRequest,
            other => Self::Unavailable(format!("the carrier answered {other:?}")),
        }
    }

    /// A refusal of the app's carrier: a `cmux carrier` step code (and its
    /// detail), mapped as the sidebar reads them. `ticket` is the platform
    /// refusing a ticket or grant: a paused machine when the detail says so,
    /// else no access. `relay`, `parked_timeout` and `handshake` did not get
    /// through. `service_refused` is the daemon refusing the grant.
    pub fn from_carrier(code: &str, detail: Option<&str>) -> Self {
        match code {
            "ticket" if detail.is_some_and(|d| d.to_ascii_lowercase().contains("paused")) => {
                Self::HostPaused
            }
            "ticket" | "service_refused" => Self::NotAuthorized,
            "relay" | "parked_timeout" | "handshake" => Self::Unreachable,
            "bad_request" => Self::BadRequest,
            "cloud.machine.not_found" => Self::UnknownHost,
            "socket" => {
                Self::Unavailable("another cmux is serving this machine's carrier socket".into())
            }
            "unavailable" => Self::Unavailable(
                detail
                    .and_then(clip_detail)
                    .unwrap_or_else(|| "the cmux app has no carrier".into()),
            ),
            other => Self::Unavailable(format!(
                "the cmux app refused the carrier: {other}{}",
                detail.and_then(clip_detail).map(|d| format!(" ({d})")).unwrap_or_default()
            )),
        }
    }

    /// The server's name of the code (the carrier's event lines).
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

/// A refused link: its typed code and, when one came, the detail that says
/// what failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: DialCode,
    pub detail: Option<String>,
}

impl From<DialCode> for Refusal {
    fn from(code: DialCode) -> Self {
        Self { code, detail: None }
    }
}

/// The longest detail kept, in bytes: one display line.
const MAX_DETAIL_BYTES: usize = 300;

/// A detail as one line of at most [`MAX_DETAIL_BYTES`] (cut on a
/// character boundary, control characters dropped); None when it is absent
/// or empty.
pub fn clip_detail(text: &str) -> Option<String> {
    let mut kept = String::new();
    for c in text.chars().filter(|c| !c.is_control()) {
        if kept.len().saturating_add(c.len_utf8()) > MAX_DETAIL_BYTES {
            break;
        }
        kept.push(c);
    }
    let line = kept.trim();
    (!line.is_empty()).then(|| line.to_owned())
}

/// The value of a `credential.carrier_socket` answer: `{"socket": PATH}`,
/// an absolute path that fits a Unix socket address, with no `..` part and
/// no control characters. Any other key is ignored (no credential is ever
/// read from it).
pub fn socket_answer(value: &Value) -> Result<PathBuf, Refusal> {
    let bad = |why: &str| Refusal::from(DialCode::Unavailable(format!("the cmux app {why}")));
    let text = value
        .get("socket")
        .and_then(Value::as_str)
        .ok_or_else(|| bad("answered no carrier socket"))?;
    let path = Path::new(text);
    if !path.is_absolute()
        || text.len() > MAX_SOCKET_PATH
        || text.chars().any(char::is_control)
        || path.components().any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(bad("answered a carrier socket that is not a usable socket path"));
    }
    Ok(path.to_path_buf())
}

/// A wire error of the ask as a refusal (its code read by
/// [`DialCode::from_carrier`], its message kept as the detail).
pub fn ask_refusal(code: &str, message: &str) -> Refusal {
    Refusal { code: DialCode::from_carrier(code, Some(message)), detail: clip_detail(message) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_carrier_step_maps_onto_a_dial_code() {
        for (code, detail, expected) in [
            ("ticket", Some("the platform answered 403"), DialCode::NotAuthorized),
            ("ticket", Some("the machine is paused"), DialCode::HostPaused),
            ("ticket", None, DialCode::NotAuthorized),
            ("relay", None, DialCode::Unreachable),
            ("parked_timeout", None, DialCode::Unreachable),
            ("handshake", Some("the daemon key differs"), DialCode::Unreachable),
            ("service_refused", None, DialCode::NotAuthorized),
            ("bad_request", None, DialCode::BadRequest),
            ("cloud.machine.not_found", None, DialCode::UnknownHost),
        ] {
            assert_eq!(DialCode::from_carrier(code, detail), expected, "{code} {detail:?}");
        }
        assert!(matches!(DialCode::from_carrier("socket", None), DialCode::Unavailable(_)));
        assert!(matches!(
            DialCode::from_carrier("unavailable", Some("no bundled cmux-tui")),
            DialCode::Unavailable(why) if why == "no bundled cmux-tui"
        ));
        assert!(matches!(
            DialCode::from_carrier("credential.app_refused", Some("only cmux/cloud")),
            DialCode::Unavailable(why) if why.contains("credential.app_refused")
        ));
    }

    #[test]
    fn the_servers_own_names_round_trip() {
        for code in [
            DialCode::HostPaused,
            DialCode::UnknownHost,
            DialCode::NotAuthorized,
            DialCode::Unreachable,
            DialCode::BadRequest,
        ] {
            assert_eq!(DialCode::parse(code.as_str()), code);
        }
    }

    #[test]
    fn a_socket_answer_is_one_absolute_socket_path() {
        assert_eq!(
            socket_answer(&json!({ "socket": "/tmp/cmux-501/cmux-link-0123456789ab.sock" })),
            Ok(PathBuf::from("/tmp/cmux-501/cmux-link-0123456789ab.sock"))
        );
        let long = format!("/tmp/{}.sock", "a".repeat(100));
        for bad in [
            json!({}),
            json!({ "socket": 3 }),
            json!({ "socket": "cmux-link.sock" }),
            json!({ "socket": "/tmp/../etc/cmux.sock" }),
            json!({ "socket": "/tmp/cmux\n.sock" }),
            json!({ "socket": long }),
        ] {
            let refused = socket_answer(&bad);
            assert!(
                matches!(&refused, Err(Refusal { code: DialCode::Unavailable(_), .. })),
                "{bad}: {refused:?}"
            );
        }
    }

    #[test]
    fn an_ask_refusal_keeps_the_message_as_its_detail() {
        let refusal = ask_refusal("parked_timeout", "the machine's daemon never registered");
        assert_eq!(refusal.code, DialCode::Unreachable);
        assert_eq!(refusal.detail.as_deref(), Some("the machine's daemon never registered"));
    }
}
