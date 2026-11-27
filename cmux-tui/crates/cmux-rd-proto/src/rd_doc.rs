//! The cmux.rd/1 offer and answer documents a hub session's signaling carries (the Mac's
//! `MacScreenRdDocument`, the hub host's `rd_doc`), the fingerprint both sides sign, and a
//! session's ICE servers as `cmux-rd serve` and `cmux rd connect` take them.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const HEADER: &str = "cmux.rd/1";
pub const KEY_PREFIX: &str = "cmux-rd-key ";

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RdDocument {
    /// The sender's session key (64 lowercase hex).
    pub key: String,
    pub candidates: Vec<String>,
    pub display: Option<i64>,
    /// Offer: the display to show by CGDirectDisplayID (a run's screen link); wins over `display`.
    pub display_id: Option<u32>,
    pub max_width: Option<u32>,
    pub max_fps: Option<u32>,
    /// Offer: the highest bitrate the stream may use, in kbit/s (nil: the host's own cap).
    pub max_kbps: Option<u32>,
    /// Offer: whether the stream shows the cursor (nil: it does, as it always has).
    pub cursor: Option<bool>,
    /// The screen-share profile the viewer asks for (`standard` or `ultra`, the person's
    /// choice); the host runs standard when it is absent or unknown.
    pub encode_profile: Option<String>,
    pub displays: Vec<(u32, u32)>,
    pub current_display: Option<usize>,
    /// Answer: each display's CGDirectDisplayID, in `displays` order (macOS hosts).
    pub display_ids: Vec<u32>,
}

impl RdDocument {
    pub fn text(&self) -> String {
        let mut lines = vec![HEADER.to_owned(), format!("a=fingerprint:{KEY_PREFIX}{}", self.key)];
        lines.extend(self.candidates.iter().map(|c| format!("a=cmux-rd-candidate:{c}")));
        if let Some(d) = self.display {
            lines.push(format!("a=cmux-rd-display:{d}"));
        }
        if let Some(id) = self.display_id {
            lines.push(format!("a=cmux-rd-display-id:{id}"));
        }
        if let Some(w) = self.max_width {
            lines.push(format!("a=cmux-rd-max-width:{w}"));
        }
        if let Some(f) = self.max_fps {
            lines.push(format!("a=cmux-rd-max-fps:{f}"));
        }
        if let Some(k) = self.max_kbps {
            lines.push(format!("a=cmux-rd-max-kbps:{k}"));
        }
        if let Some(c) = self.cursor {
            lines.push(format!("a=cmux-rd-cursor:{}", u8::from(c)));
        }
        if let Some(p) = &self.encode_profile {
            lines.push(format!("a=cmux-rd-encode-profile:{p}"));
        }
        if !self.displays.is_empty() {
            let sizes: Vec<String> =
                self.displays.iter().map(|(w, h)| format!("{w}x{h}")).collect();
            lines.push(format!("a=cmux-rd-displays:{}", sizes.join(",")));
        }
        if !self.display_ids.is_empty() {
            let ids: Vec<String> = self.display_ids.iter().map(u32::to_string).collect();
            lines.push(format!("a=cmux-rd-display-ids:{}", ids.join(",")));
        }
        if let Some(c) = self.current_display {
            lines.push(format!("a=cmux-rd-current:{c}"));
        }
        lines.join("\r\n") + "\r\n"
    }

    /// A cmux.rd/1 document, or None (a WebRTC SDP, or a malformed key).
    pub fn parse(text: &str) -> Option<Self> {
        let mut lines = text.lines().map(str::trim);
        if lines.next()? != HEADER {
            return None;
        }
        let mut doc = RdDocument::default();
        let mut key = None;
        for line in lines {
            let Some(rest) = line.strip_prefix("a=") else { continue };
            let Some((name, value)) = rest.split_once(':') else { continue };
            match name {
                "fingerprint" => key = value.strip_prefix(KEY_PREFIX).map(str::to_owned),
                "cmux-rd-candidate" => doc.candidates.push(value.to_owned()),
                "cmux-rd-display" => doc.display = value.parse().ok(),
                "cmux-rd-display-id" => doc.display_id = value.parse().ok(),
                "cmux-rd-display-ids" => {
                    doc.display_ids = value.split(',').filter_map(|s| s.parse().ok()).collect();
                }
                "cmux-rd-max-width" => doc.max_width = value.parse().ok(),
                "cmux-rd-max-fps" => doc.max_fps = value.parse().ok(),
                "cmux-rd-max-kbps" => doc.max_kbps = value.parse().ok(),
                "cmux-rd-cursor" => {
                    doc.cursor = match value {
                        "0" => Some(false),
                        "1" => Some(true),
                        _ => None,
                    };
                }
                "cmux-rd-encode-profile" => doc.encode_profile = Some(value.to_owned()),
                "cmux-rd-current" => doc.current_display = value.parse().ok(),
                "cmux-rd-displays" => {
                    doc.displays = value
                        .split(',')
                        .filter_map(|s| {
                            let (w, h) = s.split_once('x')?;
                            Some((w.parse().ok()?, h.parse().ok()?))
                        })
                        .collect();
                }
                _ => {}
            }
        }
        let key = key?;
        if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        doc.key = key.to_ascii_lowercase();
        Some(doc)
    }
}

/// The values of an SDP's `a=fingerprint:` lines, in order, joined with `,`.
pub fn fingerprint_of(sdp: &str) -> Option<String> {
    let values: Vec<&str> = sdp
        .lines()
        .filter_map(|l| l.trim().strip_prefix("a=fingerprint:"))
        .map(str::trim)
        .collect();
    (!values.is_empty()).then(|| values.join(","))
}

/// The bytes an `fpSig` signs: `"<sid>|<role>|<fingerprint>"`, `role` the signer's.
pub fn fingerprint_message(session: &str, role: &str, fingerprint: &str) -> Vec<u8> {
    format!("{session}|{role}|{fingerprint}").into_bytes()
}

/// How a TURN relay is reached: `turn:` over UDP, `turn:..?transport=tcp`, or `turns:` (TLS).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum TurnTransport {
    #[default]
    Udp,
    Tcp,
    Tls,
}

impl TurnTransport {
    pub fn is_udp(&self) -> bool {
        *self == TurnTransport::Udp
    }
}

/// One TURN relay as `cmux-rd serve` takes it. `transport` is left out for UDP, so a
/// UDP relay reads as it always has.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Turn {
    pub addr: String,
    pub username: String,
    pub password: String,
    #[serde(default, skip_serializing_if = "TurnTransport::is_udp")]
    pub transport: TurnTransport,
}

/// The ticket's ICE servers (`[{urls, username?, credential?}]`) as STUN addresses and
/// TURN relays: every UDP relay first, then the TCP and TLS (`turns:`) ones, which are
/// the only way through a network that blocks UDP. The link speaks UDP TURN, so callers
/// hand it the UDP relays ([`udp_only`]) and carry the rest separately.
pub fn servers(ice: &Value) -> (Vec<String>, Vec<Turn>) {
    let (mut stun, mut turn) = (Vec::new(), Vec::new());
    let address = |s: &str| {
        if s.is_empty() {
            String::new()
        } else if s.contains(':') {
            s.to_owned()
        } else {
            format!("{s}:3478")
        }
    };
    for server in ice.as_array().into_iter().flatten() {
        let urls: Vec<&str> = match &server["urls"] {
            Value::String(s) => vec![s.as_str()],
            Value::Array(a) => a.iter().filter_map(Value::as_str).collect(),
            _ => Vec::new(),
        };
        for url in urls {
            let (base, query) = url.split_once('?').unwrap_or((url, ""));
            if let Some(host) = base.strip_prefix("stun:") {
                let a = address(host);
                if !a.is_empty() && !stun.contains(&a) {
                    stun.push(a);
                }
            } else if let Some((host, transport)) = base
                .strip_prefix("turns:")
                .map(|h| (h, TurnTransport::Tls))
                .or_else(|| base.strip_prefix("turn:").map(|h| (h, TurnTransport::Udp)))
            {
                let (Some(user), Some(pass)) =
                    (server["username"].as_str(), server["credential"].as_str())
                else {
                    continue;
                };
                let tcp = query.split('&').any(|q| q.eq_ignore_ascii_case("transport=tcp"));
                let transport = match transport {
                    TurnTransport::Udp if tcp => TurnTransport::Tcp,
                    t => t,
                };
                let addr = match transport {
                    TurnTransport::Tls if !host.contains(':') => format!("{host}:5349"),
                    _ => address(host),
                };
                let relay = Turn { addr, username: user.into(), password: pass.into(), transport };
                if !host.is_empty() && !turn.contains(&relay) {
                    turn.push(relay);
                }
            }
        }
    }
    // UDP first, then TCP, then TLS; the ticket's order within each.
    turn.sort_by_key(|t| t.transport as u8);
    (stun, turn)
}

/// The UDP relays of [`servers`], the ones the link can allocate on today.
pub fn udp_only(turn: &[Turn]) -> Vec<Turn> {
    turn.iter().filter(|t| t.transport.is_udp()).cloned().collect()
}

/// Whether a link path kind goes through a relay (the hub's `path` report).
pub fn is_relayed(kind: &str) -> bool {
    matches!(kind, "turn_relay" | "do_relay" | "via_cloud_region")
}

#[cfg(test)]
#[path = "rd_doc_tests.rs"]
mod tests;
