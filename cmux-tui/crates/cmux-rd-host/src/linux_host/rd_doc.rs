//! The cmux.rd/1 offer and answer documents a hub session's signaling carries (the Mac's
//! `MacScreenRdDocument`), the fingerprint signature both sides put on them (`fpSig`,
//! PROTOCOL.md Session flow 5), and the session's ICE servers as `cmux-rd serve` takes them.

use super::b64;
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
                        .collect()
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

/// Whether `fp_sig` (base64 raw r||s) is `peer_key`'s signature of `role`'s fingerprint in `sdp`.
pub fn verify_fp_sig(sdp: &str, fp_sig: &str, session: &str, role: &str, peer_key: &str) -> bool {
    let (Some(fingerprint), Some(sig)) = (fingerprint_of(sdp), b64::decode(fp_sig)) else {
        return false;
    };
    super::hub::verify(peer_key, &fingerprint_message(session, role, &fingerprint), &sig)
}

/// One TURN relay as `cmux-rd serve` takes it.
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

/// Whether a link path kind goes through a relay (the hub's `path` report).
pub fn is_relayed(kind: &str) -> bool {
    matches!(kind, "turn_relay" | "do_relay" | "via_cloud_region")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux_host::identity::Device;
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
        assert_eq!(fingerprint_of(&text).as_deref(), Some(format!("cmux-rd-key {KEY}").as_str()));
    }

    #[test]
    fn webrtc_offers_and_bad_keys_are_not_documents() {
        assert!(RdDocument::parse("v=0\r\na=fingerprint:sha-256 AB:CD\r\n").is_none());
        assert!(RdDocument::parse("cmux.rd/1\r\na=fingerprint:cmux-rd-key 1234\r\n").is_none());
        assert!(RdDocument::parse("cmux.rd/1\r\n").is_none());
    }

    #[test]
    fn fp_sig_verifies_only_for_the_peer_role_and_key() {
        let viewer = Device::generate("viewer").unwrap().signer().unwrap();
        let other = Device::generate("other").unwrap().signer().unwrap();
        let sdp = RdDocument { key: KEY.into(), ..RdDocument::default() }.text();
        let fp = fingerprint_of(&sdp).unwrap();
        let sig = b64::encode(&viewer.sign(&fingerprint_message("sid", "viewer", &fp)).unwrap());
        assert!(verify_fp_sig(&sdp, &sig, "sid", "viewer", &viewer.public_key()));
        assert!(!verify_fp_sig(&sdp, &sig, "sid", "host", &viewer.public_key()));
        assert!(!verify_fp_sig(&sdp, &sig, "other-sid", "viewer", &viewer.public_key()));
        assert!(!verify_fp_sig(&sdp, &sig, "sid", "viewer", &other.public_key()));
        let tampered = RdDocument { key: KEY.replace("00", "ff"), ..RdDocument::default() }.text();
        assert!(!verify_fp_sig(&tampered, &sig, "sid", "viewer", &viewer.public_key()));
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
