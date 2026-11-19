//! The cmux.rd/1 offer and answer documents a device hub session's signaling carries, and the
//! session's ICE servers as the secure link takes them. One definition for every Rust side:
//! the Linux host (`cmux-hub-host`), the Linux viewer (`cmux-rd view`) and the iPhone viewer
//! (`cmux-mobile-link-ffi` `screen`). The Mac app's Swift copy is `MacScreenRdDocument`.
//!
//! ```text
//! cmux.rd/1
//! a=fingerprint:cmux-rd-key <64 hex>
//! a=cmux-rd-candidate:host 192.168.1.4:51000     (repeated)
//! a=cmux-rd-display:1                             (offer: the display to show)
//! a=cmux-rd-max-width:1920                        (offer: the quality wish)
//! a=cmux-rd-max-fps:120                           (offer)
//! a=cmux-rd-displays:3342x2160,1920x1080          (answer: the host's displays)
//! a=cmux-rd-current:0                             (answer: the display it streams)
//! ```

use serde::Serialize;
use serde_json::Value;

pub const HEADER: &str = "cmux.rd/1";
pub const KEY_PREFIX: &str = "cmux-rd-key ";

#[derive(Debug, Clone, Default, PartialEq)]
pub struct RdDocument {
    /// The sender's session key (64 lowercase hex).
    pub key: String,
    pub candidates: Vec<String>,
    pub display: Option<i64>,
    pub max_width: Option<u32>,
    pub max_fps: Option<u32>,
    pub displays: Vec<(u32, u32)>,
    pub current_display: Option<usize>,
}

impl RdDocument {
    pub fn text(&self) -> String {
        let mut lines = vec![HEADER.to_owned(), format!("a=fingerprint:{KEY_PREFIX}{}", self.key)];
        lines.extend(self.candidates.iter().map(|c| format!("a=cmux-rd-candidate:{c}")));
        if let Some(d) = self.display {
            lines.push(format!("a=cmux-rd-display:{d}"));
        }
        if let Some(w) = self.max_width {
            lines.push(format!("a=cmux-rd-max-width:{w}"));
        }
        if let Some(f) = self.max_fps {
            lines.push(format!("a=cmux-rd-max-fps:{f}"));
        }
        if !self.displays.is_empty() {
            let sizes: Vec<String> =
                self.displays.iter().map(|(w, h)| format!("{w}x{h}")).collect();
            lines.push(format!("a=cmux-rd-displays:{}", sizes.join(",")));
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
                "cmux-rd-max-width" => doc.max_width = value.parse().ok(),
                "cmux-rd-max-fps" => doc.max_fps = value.parse().ok(),
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

/// One TURN relay as the link takes it (`cmux-rd serve` and `connect` read this shape).
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Turn {
    pub addr: String,
    pub username: String,
    pub password: String,
}

/// The ticket's ICE servers (`[{urls, username?, credential?}]`) as STUN addresses and UDP
/// TURN relays (the Mac's `MacScreenRdServers`; TCP TURN is not a carrier of the link).
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
            } else if let Some(host) = base.strip_prefix("turn:") {
                let (Some(user), Some(pass)) =
                    (server["username"].as_str(), server["credential"].as_str())
                else {
                    continue;
                };
                if query.contains("transport=tcp") {
                    continue;
                }
                let relay =
                    Turn { addr: address(host), username: user.into(), password: pass.into() };
                if !relay.addr.is_empty() && !turn.contains(&relay) {
                    turn.push(relay);
                }
            }
        }
    }
    (stun, turn)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn documents_round_trip_like_the_mac() {
        let doc = RdDocument {
            key: KEY.into(),
            candidates: vec!["host 10.0.0.2:5000".into()],
            display: Some(1),
            max_width: Some(1920),
            max_fps: Some(60),
            displays: vec![(2560, 1440)],
            current_display: Some(0),
        };
        let text = doc.text();
        assert!(text.starts_with("cmux.rd/1\r\na=fingerprint:cmux-rd-key 0011"));
        assert_eq!(RdDocument::parse(&text), Some(doc));
    }

    #[test]
    fn webrtc_offers_and_bad_keys_are_not_documents() {
        assert!(RdDocument::parse("v=0\r\na=fingerprint:sha-256 AB:CD\r\n").is_none());
        assert!(RdDocument::parse("cmux.rd/1\r\na=fingerprint:cmux-rd-key 1234\r\n").is_none());
        assert!(RdDocument::parse("cmux.rd/1\r\n").is_none());
    }

    #[test]
    fn ice_servers_become_stun_and_udp_turn() {
        let ice = json!([
            {"urls": ["stun:stun.example", "turn:turn.example:3478?transport=udp", "turn:turn.example:443?transport=tcp"],
             "username": "u", "credential": "p"},
            {"urls": "stun:stun.example:3478"}
        ]);
        let (stun, turn) = servers(&ice);
        assert_eq!(stun, vec!["stun.example:3478"]);
        assert_eq!(
            turn,
            vec![Turn {
                addr: "turn.example:3478".into(),
                username: "u".into(),
                password: "p".into()
            }]
        );
    }
}
