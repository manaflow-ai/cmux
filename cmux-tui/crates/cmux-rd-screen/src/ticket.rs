//! Device hub session signaling's rules (TicketSignaling.swift): the ticket's
//! payload, the signal URL, the frames, the SDP fingerprint and its `fpSig`.
//! Signing stays in Swift (Secure Enclave); this side only verifies.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The transport a host's `transport` frame names.
pub const RD_TRANSPORT: &str = "cmux.rd/1";

/// Why signaling stops (Swift's `ScreenSignalingError`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TicketError {
    /// The peer's `fpSig` did not verify with the ticket's `peerKey`.
    FingerprintMismatch,
    /// An offer or answer without a DTLS fingerprint or without `fpSig`.
    MissingFingerprint,
    BadTicket(String),
}

impl std::fmt::Display for TicketError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::FingerprintMismatch => {
                f.write_str("the other device's DTLS fingerprint signature does not verify")
            }
            Self::MissingFingerprint => {
                f.write_str("the other device's offer or answer has no signed DTLS fingerprint")
            }
            Self::BadTicket(detail) => write!(f, "session ticket: {detail}"),
        }
    }
}

impl std::error::Error for TicketError {}

/// What the ticket's (unverified, server-signed) payload says.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ticket {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// `viewer` or `host`: this device's role.
    pub role: String,
    /// base64 X9.63 signing key of the other device.
    pub peer_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// Seconds since 1970.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<f64>,
}

impl Ticket {
    /// Reads a compact JWS's payload.
    pub fn parse(jws: &str) -> Result<Self, TicketError> {
        let parts: Vec<&str> = jws.split('.').collect();
        let not_jws = || TicketError::BadTicket("not a compact JWS".into());
        if parts.len() != 3 {
            return Err(not_jws());
        }
        let data = base64_url(parts.get(1).copied().ok_or_else(not_jws)?).ok_or_else(not_jws)?;
        let Ok(Value::Object(payload)) = serde_json::from_slice::<Value>(&data) else {
            return Err(not_jws());
        };
        let string = |key: &str| payload.get(key).and_then(Value::as_str).map(str::to_owned);
        let (Some(sid), Some(role), Some(peer_key)) =
            (string("sid"), string("role"), string("peerKey"))
        else {
            return Err(TicketError::BadTicket("no sid, role or peerKey".into()));
        };
        if role != "viewer" && role != "host" {
            return Err(TicketError::BadTicket("no sid, role or peerKey".into()));
        }
        // `as? NSNumber` also takes a JSON boolean.
        let expires = match payload.get("exp") {
            Some(Value::Number(n)) => n.as_f64(),
            Some(Value::Bool(b)) => Some(if *b { 1.0 } else { 0.0 }),
            _ => None,
        };
        Ok(Self { session_id: sid, role, peer_key, scope: string("scope"), expires })
    }

    /// The other side's role.
    pub fn peer_role(&self) -> &'static str {
        if self.role == "viewer" { "host" } else { "viewer" }
    }
}

/// base64url, padded back to base64 (as Swift's `Ticket.base64URL`).
fn base64_url(text: &str) -> Option<Vec<u8>> {
    let mut base64 = text.replace('-', "+").replace('_', "/");
    let pad = (4 - base64.len() % 4) % 4;
    base64.push_str(&"=".repeat(pad));
    STANDARD.decode(base64).ok()
}

/// An ICE candidate (Swift's `ScreenICECandidate`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceCandidate {
    pub candidate: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_m_line_index: Option<i32>,
}

/// What this side sends (Swift's `ScreenSignal`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Signal {
    #[serde(rename_all = "camelCase")]
    Hello {
        peer_present: bool,
    },
    PeerJoined,
    PeerLeft,
    Offer {
        sdp: String,
    },
    Answer {
        sdp: String,
    },
    Candidate {
        candidate: IceCandidate,
    },
    Bye,
    Path {
        relay: bool,
    },
}

/// What a peer frame means to this side; `Transport` goes to the owner's handler.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Inbound {
    Offer { sdp: String },
    Answer { sdp: String },
    Candidate { candidate: IceCandidate },
    Bye,
    PeerJoined,
    Transport { transport: String },
}

/// One signaling frame on the Session DO socket.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fp_sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_m_line_index: Option<i32>,
    /// A `transport` frame's protocol (`cmux.rd/1`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport: Option<String>,
}

impl Frame {
    /// The text Swift's `JSONEncoder` writes (it escapes `/` as `\/`).
    pub fn to_swift_json(&self) -> String {
        let text = serde_json::to_string(self).unwrap_or_default();
        // `/` appears only inside JSON strings, so escaping it everywhere is safe.
        text.replace('/', "\\/")
    }
}

/// A session's ticket and socket URL, and its frame rules.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TicketSignaling {
    pub ticket: Ticket,
    #[serde(rename = "socketURL")]
    pub socket_url: String,
}

impl TicketSignaling {
    /// `expected_peer_key` (the push's `peer.signingKey`) must match the ticket's.
    pub fn new(
        jws: &str,
        signal_url: &str,
        expected_peer_key: Option<&str>,
    ) -> Result<Self, TicketError> {
        let ticket = Ticket::parse(jws)?;
        if let Some(expected) = expected_peer_key
            && expected != ticket.peer_key
        {
            return Err(TicketError::BadTicket("the ticket names another peer key".into()));
        }
        let socket_url = signal_url_with_ticket(signal_url, jws)?;
        Ok(Self { ticket, socket_url })
    }

    /// The hello's `peerPresent`: the Session DO queues frames, so a viewer offers at once.
    pub fn hello_peer_present(&self) -> bool {
        self.ticket.role == "viewer"
    }

    /// One frame from the peer; `None` for one this side ignores or cannot decode.
    pub fn receive(&self, text: &str) -> Result<Option<Inbound>, TicketError> {
        let Ok(frame) = serde_json::from_str::<Frame>(text) else { return Ok(None) };
        match frame.kind.as_str() {
            "offer" | "answer" => {
                let (Some(sdp), Some(fp_sig)) = (frame.sdp, frame.fp_sig) else {
                    return Err(TicketError::MissingFingerprint);
                };
                let Some(fp) = fingerprint(&sdp) else {
                    return Err(TicketError::MissingFingerprint);
                };
                let t = &self.ticket;
                if !verify(&fp_sig, &t.session_id, t.peer_role(), &fp, &t.peer_key) {
                    return Err(TicketError::FingerprintMismatch);
                }
                Ok(Some(if frame.kind == "offer" {
                    Inbound::Offer { sdp }
                } else {
                    Inbound::Answer { sdp }
                }))
            }
            "candidate" => Ok(frame.candidate.map(|candidate| Inbound::Candidate {
                candidate: IceCandidate {
                    candidate,
                    sdp_mid: frame.sdp_mid,
                    sdp_m_line_index: frame.sdp_m_line_index,
                },
            })),
            "bye" => Ok(Some(Inbound::Bye)),
            "peer-joined" => Ok(Some(Inbound::PeerJoined)),
            "transport" => Ok(frame.transport.map(|transport| Inbound::Transport { transport })),
            _ => Ok(None),
        }
    }

    /// The bytes this side signs for an offer or answer of `sdp`.
    pub fn signing_message(&self, sdp: &str) -> Result<String, TicketError> {
        let fp = fingerprint(sdp).ok_or(TicketError::MissingFingerprint)?;
        Ok(fingerprint_message(&self.ticket.session_id, &self.ticket.role, &fp))
    }

    /// The text to send for `signal`; `fp_sig` is the base64 signature of
    /// [`Self::signing_message`] (offer and answer only). `None`: send nothing.
    pub fn outbound(signal: &Signal, fp_sig: Option<&str>) -> Option<String> {
        let frame = match signal {
            Signal::Offer { sdp } | Signal::Answer { sdp } => Frame {
                kind: if matches!(signal, Signal::Offer { .. }) { "offer" } else { "answer" }
                    .into(),
                sdp: Some(sdp.clone()),
                fp_sig: Some(fp_sig?.to_owned()),
                ..Frame::default()
            },
            Signal::Candidate { candidate } => Frame {
                kind: "candidate".into(),
                candidate: Some(candidate.candidate.clone()),
                sdp_mid: candidate.sdp_mid.clone(),
                sdp_m_line_index: candidate.sdp_m_line_index,
                ..Frame::default()
            },
            Signal::Bye => Frame { kind: "bye".into(), ..Frame::default() },
            Signal::Path { relay } => {
                let path = if *relay { "relay" } else { "direct" };
                return Some(format!(r#"{{"type":"path","path":"{path}"}}"#));
            }
            Signal::Hello { .. } | Signal::PeerJoined | Signal::PeerLeft => return None,
        };
        Some(frame.to_swift_json())
    }
}

/// `signal_url` with a `ticket` query item appended (as `URLComponents.queryItems`).
pub fn signal_url_with_ticket(signal_url: &str, jws: &str) -> Result<String, TicketError> {
    let bad = || TicketError::BadTicket("bad signal URL".into());
    let scheme_end = signal_url.find(':').ok_or_else(bad)?;
    let scheme = signal_url.get(..scheme_end).ok_or_else(bad)?;
    let scheme_ok = scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    if !scheme_ok || signal_url.chars().any(|c| c.is_whitespace()) {
        return Err(bad());
    }
    let (rest, fragment) = match signal_url.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (signal_url, None),
    };
    let (base, query) = match rest.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (rest, None),
    };
    let mut items: Vec<String> = query
        .into_iter()
        .flat_map(|q| q.split('&'))
        .filter(|item| !item.is_empty())
        .map(|item| match item.split_once('=') {
            Some((name, value)) => format!(
                "{}={}",
                encode_query_item(&percent_decode(name), true),
                encode_query_item(&percent_decode(value), false)
            ),
            None => encode_query_item(&percent_decode(item), true),
        })
        .collect();
    items.push(format!("ticket={}", encode_query_item(jws, false)));
    let mut url = format!("{base}?{}", items.join("&"));
    if let Some(fragment) = fragment {
        url.push('#');
        url.push_str(fragment);
    }
    Ok(url)
}

/// Percent-encodes a query item part: the query's allowed set less `&` (and `=` in a name).
fn encode_query_item(text: &str, name: bool) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        let allowed = byte.is_ascii_alphanumeric()
            || b"-._~!$'()*+,;:@/?".contains(&byte)
            || (byte == b'=' && !name);
        if allowed {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Decodes `%XX` escapes; a malformed escape stays as written.
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes.get(i) == Some(&b'%')
            && let Some(hex) = text.get(i + 1..i + 3)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(bytes.get(i).copied().unwrap_or_default());
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// The values of the SDP's `a=fingerprint:` lines, in order, joined with `,`;
/// `None` when it has none.
pub fn fingerprint(sdp: &str) -> Option<String> {
    const PREFIX: &str = "a=fingerprint:";
    let values: Vec<&str> = sdp
        .split(is_newline)
        .filter_map(|line| {
            let line = line.trim_matches(is_space);
            line.strip_prefix(PREFIX).map(|value| value.trim_matches(is_space))
        })
        .collect();
    if values.is_empty() { None } else { Some(values.join(",")) }
}

/// Swift's `Character.isNewline`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `CharacterSet.whitespaces`: tab and the space separators (Zs).
fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// The text an `fpSig` signs: `"<sid>|<role>|<fingerprint>"`, `role` the signer's.
pub fn fingerprint_message(session_id: &str, role: &str, fingerprint: &str) -> String {
    format!("{session_id}|{role}|{fingerprint}")
}

/// Whether `fp_sig` (base64 raw r||s) is `peer_key`'s (base64 X9.63) signature
/// for `role`'s fingerprint.
pub fn verify(
    fp_sig: &str,
    session_id: &str,
    role: &str,
    fingerprint: &str,
    peer_key: &str,
) -> bool {
    let (Ok(raw), Ok(key_data)) = (STANDARD.decode(fp_sig), STANDARD.decode(peer_key)) else {
        return false;
    };
    // X9.63: uncompressed only.
    if key_data.len() != 65 || key_data.first() != Some(&0x04) || raw.len() != 64 {
        return false;
    }
    let (Ok(key), Ok(signature)) =
        (VerifyingKey::from_sec1_bytes(&key_data), Signature::from_slice(&raw))
    else {
        return false;
    };
    let message = fingerprint_message(session_id, role, fingerprint);
    key.verify(message.as_bytes(), &signature).is_ok()
}

#[cfg(test)]
#[path = "ticket_tests.rs"]
mod tests;
