//! The braid session layer (RFD 0164, slice B8).
//!
//! A braid session is one static key per peer, kept across every path and carrier the session
//! ever uses. This crate holds the two things every client of that key has to agree on:
//!
//! - which Noise pattern a link's handshake runs ([`choose`]), and
//! - the resume ticket a client keeps once it has met a peer ([`ResumeTicket`]), the same bytes
//!   on the Mac, the phone and the daemon's own dialers.
//!
//! A first meeting runs XX (`-> e`, `<- e ee s es`, `-> s se`): the client learns the peer's key
//! from the handshake, and the peer's first answer (its welcome) reaches the client two round
//! trips after the client spoke. Once the client holds the peer's key and the peer has said it
//! takes IK, a link runs IK (`-> e es s ss`, `<- e ee se`): the client's hello rides the first
//! message, encrypted to the peer's key, and the answer is back after one round trip. A link's
//! setup is the handshake plus the welcome plus the session's link-ready, so every lane link of
//! a reconnect saves one round trip, and a reconnect that opens its first link and then the rest
//! saves two.
//!
//! IK's first message is not forward secret: someone who later steals the peer's static key can
//! read it. It carries only the device name and resume cursors, never a bearer secret (a carrier
//! grant, an invitation's PSK), so [`choose`] keeps those on XX.
//!
//! Lockstep: the pattern a client picks is named in its plaintext prelude, which is the Noise
//! prologue, so a relay that rewrites it breaks the handshake rather than downgrading it. A peer
//! that never said it takes IK never gets an IK message: the offer travels in the welcome, and a
//! client that has not seen it runs XX.

use serde::{Deserialize, Serialize};

/// A first meeting, or a link whose client does not hold the peer's key.
pub const NOISE_XX: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
/// An invitation's first meeting: XX with the invitation's secret mixed in after the third message.
pub const NOISE_XX_PSK3: &str = "Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s";
/// A link to a peer the client already holds the key of, and which said it takes IK.
pub const NOISE_IK: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";

/// The Noise pattern of one link's handshake, as the client's prelude names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Pattern {
    Xx,
    XxPsk3,
    Ik,
}

impl Pattern {
    pub fn noise_name(self) -> &'static str {
        match self {
            Self::Xx => NOISE_XX,
            Self::XxPsk3 => NOISE_XX_PSK3,
            Self::Ik => NOISE_IK,
        }
    }

    /// Round trips from the client's first byte to the peer's first answer (its welcome).
    pub fn round_trips_to_welcome(self) -> u32 {
        match self {
            Self::Xx | Self::XxPsk3 => 2,
            Self::Ik => 1,
        }
    }
}

/// What a client knows when it opens one link.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LinkFacts {
    /// The link enrolls with an invitation secret.
    pub invitation: bool,
    /// The client holds the peer's static key and will refuse any other.
    pub pinned_peer: bool,
    /// The peer said, in a welcome on this session or in a ticket, that it takes IK.
    pub peer_takes_ik: bool,
    /// The hello carries a bearer secret (a carrier grant) that must stay forward secret.
    pub carries_bearer_secret: bool,
}

/// The pattern a link runs.
pub fn choose(facts: LinkFacts) -> Pattern {
    if facts.invitation {
        return Pattern::XxPsk3;
    }
    if facts.pinned_peer && facts.peer_takes_ik && !facts.carries_bearer_secret {
        return Pattern::Ik;
    }
    Pattern::Xx
}

/// Whether a connect opens every lane link at once instead of its first link and then the rest.
///
/// A client that pins the peer's key needs nothing from the first link's welcome: every link can
/// authenticate against that key on its own, so waiting for the first welcome only costs a whole
/// link's setup (a relay allocation, a circuit join and a handshake). That holds on a first
/// connect too: a carrier dial always pins the daemon key, and without the peer's IK offer each
/// link runs XX, which is still one handshake in parallel instead of two in a row. A client with
/// no pinned key (TOFU) learns it from the first welcome, so that link goes alone. An invitation
/// never opens at once: its welcome waits on a person's approval, and the other links enroll
/// after it.
pub fn open_lanes_at_once(facts: LinkFacts) -> bool {
    !facts.invitation && facts.pinned_peer
}

/// The most replay bytes a link's first message carries as early data ([`may_send_early`]): well
/// under the handshake's 16 KiB payload cap once base64 and the hello's other fields are added, so
/// a big replay buffer never makes the first message the one that fails.
pub const EARLY_DATA_MAX_BYTES: usize = 4 * 1024;

/// Whether a link's first message may carry early data: the client's replay of reliable Control
/// frames, so a reconnect's first answer is not held behind the link's setup and the replay that
/// follows it.
///
/// Only an IK link of a reconnect (generation 1 or later) to a peer that said it takes it. IK's
/// first message is not forward secret, so it never carries a bearer secret (a grant or an
/// invitation's secret), and it is open to replay until the handshake finishes, so it never
/// carries a first meeting (generation 0, where nothing is yet there to dedupe against). Early
/// data is Control frames only: never Tunnel (which does not replay across generations) and never
/// Interactive keystrokes, which wait on a forward secrecy sign-off.
pub fn may_send_early(facts: LinkFacts, generation: u64, peer_takes_early_data: bool) -> bool {
    choose(facts) == Pattern::Ik
        && generation >= 1
        && peer_takes_early_data
        && !facts.invitation
        && !facts.carries_bearer_secret
}

/// What a peer said it can do, in its welcome. Every field is optional on the wire, so a peer
/// that predates a capability reads as not having it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    /// The peer's responder takes [`Pattern::Ik`].
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ik: bool,
    /// The peer keeps a WireGuard session dormant after its link drops, so a client can resume
    /// it without a fresh dial (the phone's handshake-first redial).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wg_resume: bool,
    /// The peer's responder takes early data in an IK link's first message ([`may_send_early`])
    /// and applies it when the link group commits, through the session's usual dedupe.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub early_data: bool,
}

/// The ticket format this build writes.
pub const TICKET_VERSION: u8 = 1;

/// What a client keeps once it has met a peer: the peer's static key and what the peer said it
/// can do, so the next link (this process's next reconnect, or the next launch) can start with
/// IK. A ticket is a hint, never a credential: the handshake still proves the peer holds the key,
/// and a link that fails with IK is retried with XX.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeTicket {
    pub peer_static: [u8; 32],
    pub capabilities: Capabilities,
    /// When the peer last said so, in milliseconds since the Unix epoch.
    pub issued_unix_ms: u64,
    /// How long the peer holds a dormant session after the link drops, in milliseconds.
    /// `None`: no dormant hold, so the client makes the full dial.
    pub dormant_hold_ms: Option<u64>,
    /// When the session went dormant, in milliseconds since the Unix epoch.
    pub dormant_since_unix_ms: Option<u64>,
}

#[derive(Serialize, Deserialize)]
struct WireTicket {
    v: u8,
    peer_static: String,
    #[serde(default)]
    caps: Capabilities,
    issued_unix_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    dormant_hold_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    dormant_since_unix_ms: Option<u64>,
}

impl ResumeTicket {
    /// The ticket as JSON: `{"v":1,"peer_static":"<64 hex>","caps":{"ik":true},"issued_unix_ms":N}`,
    /// plus `dormant_hold_ms` and `dormant_since_unix_ms` when the peer holds a dormant session.
    pub fn encode(&self) -> Vec<u8> {
        let wire = WireTicket {
            v: TICKET_VERSION,
            peer_static: hex(&self.peer_static),
            caps: self.capabilities,
            issued_unix_ms: self.issued_unix_ms,
            dormant_hold_ms: self.dormant_hold_ms,
            dormant_since_unix_ms: self.dormant_since_unix_ms,
        };
        // Strings, bools and integers only: serializing it cannot fail.
        serde_json::to_vec(&wire).unwrap_or_default()
    }

    /// A ticket this build can use, or `None` for one it cannot read (garbage, or a newer
    /// version): the client then meets the peer again with XX and writes a fresh one.
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let wire: WireTicket = serde_json::from_slice(bytes).ok()?;
        if wire.v != TICKET_VERSION {
            return None;
        }
        Some(Self {
            peer_static: unhex32(&wire.peer_static)?,
            capabilities: wire.caps,
            issued_unix_ms: wire.issued_unix_ms,
            dormant_hold_ms: wire.dormant_hold_ms,
            dormant_since_unix_ms: wire.dormant_since_unix_ms,
        })
    }

    /// Whether the peer still holds the dormant session at `now_unix_ms`, so a WireGuard resume
    /// can skip the full dial. A ticket without a hold, or one past it, takes the full dial.
    pub fn dormant_resumable(&self, now_unix_ms: u64) -> bool {
        match (self.capabilities.wg_resume, self.dormant_hold_ms, self.dormant_since_unix_ms) {
            (true, Some(hold), Some(since)) => now_unix_ms.saturating_sub(since) < hold,
            _ => false,
        }
    }

    /// Whether this ticket lets a link to `peer` start with IK.
    pub fn takes_ik_for(&self, peer: &[u8; 32]) -> bool {
        self.capabilities.ik && &self.peer_static == peer
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(bytes.len().saturating_mul(2));
    for byte in bytes {
        // Writing to a String never fails.
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn unhex32(text: &str) -> Option<[u8; 32]> {
    let text = text.as_bytes();
    if text.len() != 64 {
        return None;
    }
    let digit = |c: u8| (c as char).to_digit(16).and_then(|d| u8::try_from(d).ok());
    let mut out = [0_u8; 32];
    for (slot, pair) in out.iter_mut().zip(text.chunks_exact(2)) {
        let [hi, lo] = pair else { return None };
        *slot = digit(*hi)? << 4 | digit(*lo)?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ik_needs_a_pinned_key_the_peers_offer_and_no_bearer_secret() {
        let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
        assert_eq!(choose(resume), Pattern::Ik);
        assert_eq!(choose(LinkFacts { pinned_peer: false, ..resume }), Pattern::Xx);
        assert_eq!(choose(LinkFacts { peer_takes_ik: false, ..resume }), Pattern::Xx);
        assert_eq!(choose(LinkFacts { carries_bearer_secret: true, ..resume }), Pattern::Xx);
        assert_eq!(choose(LinkFacts { invitation: true, ..resume }), Pattern::XxPsk3);
        assert_eq!(choose(LinkFacts::default()), Pattern::Xx);
    }

    #[test]
    fn lanes_open_at_once_with_a_pinned_key_unless_invited() {
        let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
        assert!(open_lanes_at_once(resume));
        // A grant keeps each link on XX, but the key is known: still at once.
        assert!(open_lanes_at_once(LinkFacts { carries_bearer_secret: true, ..resume }));
        assert!(!open_lanes_at_once(LinkFacts { pinned_peer: false, ..resume }));
        // A first connect that pins the key but has no IK offer yet: XX on every link, at once.
        assert!(open_lanes_at_once(LinkFacts { peer_takes_ik: false, ..resume }));
        assert!(!open_lanes_at_once(LinkFacts { invitation: true, ..resume }));
        assert!(!open_lanes_at_once(LinkFacts::default()));
    }

    #[test]
    fn early_data_rides_only_an_ik_reconnect_with_no_bearer_secret() {
        let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
        assert!(may_send_early(resume, 1, true));
        assert!(may_send_early(resume, 9, true));
        // A first meeting, a peer that never said it takes it, and an XX link: never.
        assert!(!may_send_early(resume, 0, true));
        assert!(!may_send_early(resume, 1, false));
        assert!(!may_send_early(LinkFacts { peer_takes_ik: false, ..resume }, 1, true));
        assert!(!may_send_early(LinkFacts { pinned_peer: false, ..resume }, 1, true));
        // A grant or an invitation: never (both also keep the link off IK).
        assert!(!may_send_early(LinkFacts { carries_bearer_secret: true, ..resume }, 1, true));
        assert!(!may_send_early(LinkFacts { invitation: true, ..resume }, 1, true));
    }

    #[test]
    fn tickets_read_across_the_early_data_capability_in_both_directions() {
        // A ticket from a build before early data: no `early_data`, so the client sends none.
        let key = "ef".repeat(32);
        let old =
            format!(r#"{{"v":1,"peer_static":"{key}","caps":{{"ik":true}},"issued_unix_ms":1}}"#);
        let read = ResumeTicket::decode(old.as_bytes()).unwrap();
        assert!(read.capabilities.ik && !read.capabilities.early_data);
        // A new ticket read by a build before early data: `Capabilities` as it was then.
        #[derive(Deserialize)]
        struct OldCapabilities {
            #[serde(default)]
            ik: bool,
        }
        #[derive(Deserialize)]
        struct OldTicket {
            v: u8,
            caps: OldCapabilities,
        }
        let new = ResumeTicket {
            peer_static: [0xef; 32],
            capabilities: Capabilities { ik: true, early_data: true, ..Capabilities::default() },
            issued_unix_ms: 1,
            dormant_hold_ms: None,
            dormant_since_unix_ms: None,
        };
        let bytes = new.encode();
        assert!(std::str::from_utf8(&bytes).unwrap().contains(r#""early_data":true"#));
        let old: OldTicket = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(old.v, TICKET_VERSION);
        assert!(old.caps.ik);
        assert_eq!(ResumeTicket::decode(&bytes), Some(new));
    }

    #[test]
    fn ik_saves_a_round_trip_to_the_welcome() {
        assert_eq!(Pattern::Xx.round_trips_to_welcome(), 2);
        assert_eq!(Pattern::Ik.round_trips_to_welcome(), 1);
    }

    #[test]
    fn a_ticket_round_trips_and_names_its_version() {
        let ticket = ResumeTicket {
            peer_static: [0xab; 32],
            capabilities: Capabilities { ik: true, ..Capabilities::default() },
            issued_unix_ms: 1_795_000_000_000,
            dormant_hold_ms: None,
            dormant_since_unix_ms: None,
        };
        let bytes = ticket.encode();
        let text = std::str::from_utf8(&bytes).unwrap();
        assert!(text.starts_with(r#"{"v":1,"peer_static":"abab"#), "{text}");
        assert!(text.contains(r#""caps":{"ik":true}"#), "{text}");
        assert_eq!(ResumeTicket::decode(&bytes), Some(ticket.clone()));
        assert!(ticket.takes_ik_for(&[0xab; 32]));
        assert!(!ticket.takes_ik_for(&[0xac; 32]));
    }

    #[test]
    fn a_newer_or_broken_ticket_reads_as_none_and_unknown_fields_are_ignored() {
        let key = "cd".repeat(32);
        let newer = format!(r#"{{"v":2,"peer_static":"{key}","issued_unix_ms":1}}"#);
        assert_eq!(ResumeTicket::decode(newer.as_bytes()), None);
        assert_eq!(ResumeTicket::decode(b"not json"), None);
        let short = r#"{"v":1,"peer_static":"cdcd","issued_unix_ms":1}"#;
        assert_eq!(ResumeTicket::decode(short.as_bytes()), None);
        // A v1 ticket from a newer writer that added fields, and one from a writer with no caps.
        let extra = format!(
            r#"{{"v":1,"peer_static":"{key}","caps":{{"ik":true,"later":7}},"issued_unix_ms":1,"x":0}}"#
        );
        assert!(ResumeTicket::decode(extra.as_bytes()).unwrap().capabilities.ik);
        let bare = format!(r#"{{"v":1,"peer_static":"{key}","issued_unix_ms":1}}"#);
        assert!(!ResumeTicket::decode(bare.as_bytes()).unwrap().capabilities.ik);
    }

    #[test]
    fn a_dormant_hold_round_trips_and_lapses() {
        let ticket = ResumeTicket {
            peer_static: [0x11; 32],
            capabilities: Capabilities { ik: true, wg_resume: true, ..Capabilities::default() },
            issued_unix_ms: 1_000,
            dormant_hold_ms: Some(150_000),
            dormant_since_unix_ms: Some(2_000),
        };
        let bytes = ticket.encode();
        assert_eq!(ResumeTicket::decode(&bytes), Some(ticket.clone()));
        assert!(ticket.dormant_resumable(2_000 + 149_999));
        assert!(!ticket.dormant_resumable(2_000 + 150_000));
        // No hold (an older writer, or a peer without it): the full dial.
        let plain = ResumeTicket { dormant_hold_ms: None, ..ticket };
        assert!(!plain.dormant_resumable(2_001));
        let text = String::from_utf8(plain.encode()).unwrap();
        assert!(!text.contains("dormant_hold_ms"), "{text}");
        assert!(
            !ResumeTicket { capabilities: Capabilities::default(), ..ticket }
                .dormant_resumable(2_001)
        );
    }
}
