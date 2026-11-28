use super::*;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use p256::ecdsa::SigningKey;
use p256::ecdsa::signature::Signer;

const SDP: &str = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 AA:BB:CC\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=fingerprint:sha-256 DD:EE:FF\r\na=setup:actpass\r\n";
const BOTH: &str = "sha-256 AA:BB:CC,sha-256 DD:EE:FF";
const URL: &str = "wss://hub.example/v1/sessions/s1/ws";

/// A software key standing in for a device's Secure Enclave key.
struct SoftwareSigner(SigningKey);

impl SoftwareSigner {
    fn new(seed: u8) -> Self {
        Self(SigningKey::from_slice(&[seed; 32]).unwrap())
    }

    fn public_key(&self) -> String {
        STANDARD.encode(self.0.verifying_key().to_encoded_point(false).as_bytes())
    }

    fn sign(&self, message: &str) -> String {
        let signature: Signature = self.0.sign(message.as_bytes());
        STANDARD.encode(signature.to_bytes())
    }
}

/// A compact JWS whose payload names `role` and `peer_key` (its signature is not checked).
fn jws(role: &str, peer_key: &str) -> String {
    let payload = serde_json::json!({
        "sid": "s1", "role": role, "dev": "device-1", "peer": "device-2", "peerKey": peer_key,
        "scope": "full", "iat": 1_800_000_000u64, "exp": 1_800_000_060u64, "jti": "j1",
    });
    format!(
        "{}.{}.c2ln",
        URL_SAFE_NO_PAD.encode(r#"{"alg":"ES256"}"#),
        URL_SAFE_NO_PAD.encode(payload.to_string())
    )
}

#[test]
fn fingerprints_are_every_fingerprint_line_in_order() {
    assert_eq!(fingerprint(SDP).as_deref(), Some(BOTH));
    assert_eq!(fingerprint("v=0\na=fingerprint:sha-256 01:02\n").as_deref(), Some("sha-256 01:02"));
    assert_eq!(fingerprint("v=0\r\na=setup:active\r\n"), None);
}

#[test]
fn fp_sig_signs_session_role_and_fingerprint() {
    let signer = SoftwareSigner::new(7);
    let message = fingerprint_message("s1", "host", "sha-256 AA");
    assert_eq!(message, "s1|host|sha-256 AA");
    let fp_sig = signer.sign(&message);
    let key = signer.public_key();
    assert!(verify(&fp_sig, "s1", "host", "sha-256 AA", &key));
    assert!(!verify(&fp_sig, "s1", "viewer", "sha-256 AA", &key));
    assert!(!verify(&fp_sig, "s2", "host", "sha-256 AA", &key));
    assert!(!verify(&fp_sig, "s1", "host", "sha-256 AB", &key));
    assert!(!verify(&fp_sig, "s1", "host", "sha-256 AA", &SoftwareSigner::new(8).public_key()));
}

#[test]
fn the_ticket_payload_is_read() {
    let ticket = Ticket::parse(&jws("viewer", "PEER")).unwrap();
    assert_eq!(ticket.session_id, "s1");
    assert_eq!(ticket.role, "viewer");
    assert_eq!(ticket.peer_role(), "host");
    assert_eq!(ticket.peer_key, "PEER");
    assert_eq!(ticket.scope.as_deref(), Some("full"));
    assert_eq!(ticket.expires, Some(1_800_000_060.0));
    assert!(Ticket::parse("not-a-jws").is_err());
    assert_eq!(
        TicketSignaling::new(&jws("viewer", "PEER"), "wss://hub/v1/sessions/s1/ws", Some("OTHER")),
        Err(TicketError::BadTicket("the ticket names another peer key".into()))
    );
}

/// The viewer: opens the ticket URL, offers with its fpSig, accepts a signed answer.
#[test]
fn a_viewer_signs_its_offer_and_verifies_the_answer() {
    let viewer = SoftwareSigner::new(1);
    let host = SoftwareSigner::new(2);
    let signaling =
        TicketSignaling::new(&jws("viewer", &host.public_key()), URL, Some(&host.public_key()))
            .unwrap();
    assert!(signaling.hello_peer_present());
    assert!(signaling.socket_url.starts_with("wss://hub.example/v1/sessions/s1/ws?ticket="));

    let message = signaling.signing_message(SDP).unwrap();
    let text =
        TicketSignaling::outbound(&Signal::Offer { sdp: SDP.into() }, Some(&viewer.sign(&message)))
            .unwrap();
    let offer: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(offer["type"], "offer");
    assert_eq!(offer["sdp"], SDP);
    assert!(verify(
        offer["fpSig"].as_str().unwrap_or(""),
        "s1",
        "viewer",
        BOTH,
        &viewer.public_key()
    ));

    let fp_sig = host.sign(&fingerprint_message("s1", "host", BOTH));
    let answer = serde_json::json!({"type": "answer", "sdp": SDP, "fpSig": fp_sig}).to_string();
    assert_eq!(signaling.receive(&answer), Ok(Some(Inbound::Answer { sdp: SDP.into() })));
    let candidate = r#"{"type":"candidate","candidate":"candidate:1 1 udp 1 10.0.0.1 5000 typ host","sdpMid":"0","sdpMLineIndex":0}"#;
    assert_eq!(
        signaling.receive(candidate),
        Ok(Some(Inbound::Candidate {
            candidate: IceCandidate {
                candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host".into(),
                sdp_mid: Some("0".into()),
                sdp_m_line_index: Some(0),
            }
        }))
    );
    assert_eq!(signaling.receive(r#"{"type":"bye"}"#), Ok(Some(Inbound::Bye)));
}

/// The host: an offer whose fpSig is not the ticket's peer's aborts, and says bye.
#[test]
fn a_mismatched_fingerprint_aborts() {
    let viewer = SoftwareSigner::new(3);
    let impostor = SoftwareSigner::new(4);
    let signaling = TicketSignaling::new(&jws("host", &viewer.public_key()), URL, None).unwrap();
    assert!(!signaling.hello_peer_present());
    let forged = impostor.sign(&fingerprint_message("s1", "viewer", BOTH));
    let offer = serde_json::json!({"type": "offer", "sdp": SDP, "fpSig": forged}).to_string();
    assert_eq!(signaling.receive(&offer), Err(TicketError::FingerprintMismatch));
    assert_eq!(TicketSignaling::outbound(&Signal::Bye, None).as_deref(), Some(r#"{"type":"bye"}"#));
}

/// The session's network path goes to the hub (`sessions.path`).
#[test]
fn the_path_is_reported() {
    let sent: Vec<String> = [true, false]
        .into_iter()
        .filter_map(|relay| TicketSignaling::outbound(&Signal::Path { relay }, None))
        .collect();
    assert_eq!(sent, [r#"{"type":"path","path":"relay"}"#, r#"{"type":"path","path":"direct"}"#]);
}

#[test]
fn an_offer_without_fp_sig_aborts() {
    let signaling =
        TicketSignaling::new(&jws("host", &SoftwareSigner::new(5).public_key()), URL, None)
            .unwrap();
    let offer = serde_json::json!({"type": "offer", "sdp": SDP}).to_string();
    assert_eq!(signaling.receive(&offer), Err(TicketError::MissingFingerprint));
}

/// A host serving cmux.rd/1 only answers with a `transport` frame, heard by the owner.
#[test]
fn a_transport_frame_is_heard_by_the_owner_not_the_stream() {
    let signaling =
        TicketSignaling::new(&jws("viewer", &SoftwareSigner::new(6).public_key()), URL, None)
            .unwrap();
    assert!(signaling.hello_peer_present());
    assert_eq!(
        signaling.receive(r#"{"type":"transport","transport":"cmux.rd/1"}"#),
        Ok(Some(Inbound::Transport { transport: RD_TRANSPORT.into() }))
    );
    assert_eq!(signaling.receive(r#"{"type":"bye"}"#), Ok(Some(Inbound::Bye)));
}

// Rust-only checks of the same rules.

#[test]
fn errors_read_as_swift_writes_them() {
    assert_eq!(
        TicketError::FingerprintMismatch.to_string(),
        "the other device's DTLS fingerprint signature does not verify"
    );
    assert_eq!(
        TicketError::MissingFingerprint.to_string(),
        "the other device's offer or answer has no signed DTLS fingerprint"
    );
    assert_eq!(
        TicketError::BadTicket("bad signal URL".into()).to_string(),
        "session ticket: bad signal URL"
    );
    assert_eq!(Ticket::parse("a.b"), Err(TicketError::BadTicket("not a compact JWS".into())));
    let no_role =
        format!("e30.{}.c2ln", URL_SAFE_NO_PAD.encode(r#"{"sid":"s","role":"x","peerKey":"k"}"#));
    assert_eq!(
        Ticket::parse(&no_role),
        Err(TicketError::BadTicket("no sid, role or peerKey".into()))
    );
}

#[test]
fn the_ticket_query_item_joins_an_existing_query() {
    assert_eq!(signal_url_with_ticket(URL, "a.b.c").unwrap(), format!("{URL}?ticket=a.b.c"));
    assert_eq!(
        signal_url_with_ticket("wss://h/ws?x=1%202&y#frag", "a b&c").unwrap(),
        "wss://h/ws?x=1%202&y&ticket=a%20b%26c#frag"
    );
    assert_eq!(
        signal_url_with_ticket("not a url", "j"),
        Err(TicketError::BadTicket("bad signal URL".into()))
    );
}

#[test]
fn frames_omit_absent_fields_and_ignore_what_this_side_does_not_use() {
    let candidate =
        IceCandidate { candidate: "c".into(), sdp_mid: None, sdp_m_line_index: Some(1) };
    assert_eq!(
        TicketSignaling::outbound(&Signal::Candidate { candidate }, None).as_deref(),
        Some(r#"{"type":"candidate","candidate":"c","sdpMLineIndex":1}"#)
    );
    assert_eq!(TicketSignaling::outbound(&Signal::Hello { peer_present: true }, None), None);
    assert_eq!(TicketSignaling::outbound(&Signal::PeerJoined, None), None);
    assert_eq!(TicketSignaling::outbound(&Signal::PeerLeft, None), None);
    let text =
        TicketSignaling::outbound(&Signal::Answer { sdp: "a/b".into() }, Some("s+/=")).unwrap();
    assert_eq!(text, r#"{"type":"answer","sdp":"a\/b","fpSig":"s+\/="}"#);

    let signaling = TicketSignaling::new(&jws("viewer", "PEER"), URL, None).unwrap();
    assert_eq!(signaling.receive("not json"), Ok(None));
    assert_eq!(signaling.receive(r#"{"sdp":"x"}"#), Ok(None));
    assert_eq!(signaling.receive(r#"{"type":"candidate"}"#), Ok(None));
    assert_eq!(signaling.receive(r#"{"type":"transport"}"#), Ok(None));
    assert_eq!(signaling.receive(r#"{"type":"peer-left"}"#), Ok(None));
    assert_eq!(signaling.receive(r#"{"type":"peer-joined"}"#), Ok(Some(Inbound::PeerJoined)));
    let no_fingerprint = r#"{"type":"offer","sdp":"v=0","fpSig":"AA=="}"#;
    assert_eq!(signaling.receive(no_fingerprint), Err(TicketError::MissingFingerprint));
    assert_eq!(signaling.signing_message("v=0"), Err(TicketError::MissingFingerprint));
}
