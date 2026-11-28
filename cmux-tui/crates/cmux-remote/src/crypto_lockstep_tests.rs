use super::*;

/// `ClientPrelude` and `ServerWelcome` as they were before IK.
#[derive(Serialize, Deserialize)]
struct OldPrelude {
    name: String,
    protocol: u8,
    auth: AuthKind,
    invitation_id: Option<String>,
    session: SessionId,
    lane: Lane,
    lanes: Vec<Lane>,
    generation: u64,
    connection_attempt: ConnectionAttemptId,
}

#[derive(Serialize, Deserialize)]
struct OldWelcome {
    accepted: bool,
    error: Option<String>,
    daemon_name: Option<String>,
    device_id: Option<String>,
    revocation_generation: Option<u64>,
}

fn prelude(pattern: Option<Pattern>) -> ClientPrelude {
    ClientPrelude {
        name: HANDSHAKE_NAME.into(),
        protocol: REMOTE_PROTOCOL_VERSION,
        auth: AuthKind::Carrier,
        invitation_id: None,
        session: SessionId([1; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation: 3,
        connection_attempt: ConnectionAttemptId([2; 16]),
        pattern,
    }
}

#[test]
fn an_xx_prelude_is_the_old_prelude_byte_for_byte() {
    let new = serde_json::to_vec(&prelude(None)).unwrap();
    let old = serde_json::to_vec(&OldPrelude {
        name: HANDSHAKE_NAME.into(),
        protocol: REMOTE_PROTOCOL_VERSION,
        auth: AuthKind::Carrier,
        invitation_id: None,
        session: SessionId([1; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation: 3,
        connection_attempt: ConnectionAttemptId([2; 16]),
    })
    .unwrap();
    assert_eq!(new, old, "an older daemon must read a new client's XX prelude unchanged");
    // And the new daemon reads the old one as XX.
    let read: ClientPrelude = serde_json::from_slice(&old).unwrap();
    assert_eq!(read.pattern, None);
    let ik = serde_json::to_string(&prelude(Some(Pattern::Ik))).unwrap();
    assert!(ik.ends_with(r#","pattern":"ik"}"#), "{ik}");
}

#[test]
fn welcomes_read_across_the_ik_offer_in_both_directions() {
    // A new daemon's welcome, read by an old client: the offer is an unknown field.
    let new = serde_json::to_vec(&ServerWelcome {
        accepted: true,
        error: None,
        daemon_name: Some("d".into()),
        device_id: Some("x".into()),
        revocation_generation: Some(0),
        capabilities: Some(Capabilities { ik: true, ..Capabilities::default() }),
    })
    .unwrap();
    let old: OldWelcome = serde_json::from_slice(&new).unwrap();
    assert!(old.accepted);
    // An old daemon's welcome, read by a new client: no offer, so the client stays on XX.
    let old = serde_json::to_vec(&OldWelcome {
        accepted: true,
        error: None,
        daemon_name: Some("d".into()),
        device_id: Some("x".into()),
        revocation_generation: Some(0),
    })
    .unwrap();
    let new: ServerWelcome = serde_json::from_slice(&old).unwrap();
    assert!(new.accepted);
    assert_eq!(new.capabilities, None);
}
/// `ClientHello` as it was before early data.
#[derive(Serialize, Deserialize)]
struct OldHello {
    device_name: String,
    resume: BTreeMap<Lane, u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    grant: Option<String>,
}

fn hello(early: Vec<String>, grant: Option<String>) -> ClientHello {
    ClientHello { device_name: "c".into(), resume: BTreeMap::new(), grant, early }
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[test]
fn hellos_read_across_early_data_in_both_directions() {
    // A new client with nothing to send early writes the old hello byte for byte.
    let new = serde_json::to_vec(&hello(Vec::new(), None)).unwrap();
    let old = serde_json::to_vec(&OldHello {
        device_name: "c".into(),
        resume: BTreeMap::new(),
        grant: None,
    })
    .unwrap();
    assert_eq!(new, old);
    // An old client's hello, read by a new daemon: no early data.
    let read: ClientHello = serde_json::from_slice(&old).unwrap();
    assert!(read.early.is_empty());
    // A new client's early data, read by an old daemon: an unknown field it ignores (the
    // frames reach it in the replay after the commit).
    let new = serde_json::to_vec(&hello(vec![b64(b"frame")], None)).unwrap();
    let read: OldHello = serde_json::from_slice(&new).unwrap();
    assert_eq!(read.device_name, "c");
}

#[test]
fn a_daemon_reads_early_data_only_on_an_ik_resume_with_no_bearer_secret() {
    let early = vec![b64(b"one"), b64(b"two")];
    let read = hello_early(&hello(early.clone(), None), Pattern::Ik, AuthKind::Carrier, 1)
        .expect("an IK resume's early data");
    assert_eq!(read, vec![Bytes::from_static(b"one"), Bytes::from_static(b"two")]);
    // Nothing early is nothing to refuse, on any link.
    assert!(
        hello_early(&hello(Vec::new(), None), Pattern::Xx, AuthKind::Carrier, 0)
            .unwrap()
            .is_empty()
    );
    for (what, hello, pattern, auth, generation) in [
        (
            "alongside a grant",
            hello(early.clone(), Some("g".into())),
            Pattern::Ik,
            AuthKind::Grant,
            1,
        ),
        ("at generation 0", hello(early.clone(), None), Pattern::Ik, AuthKind::Carrier, 0),
        ("on XX", hello(early.clone(), None), Pattern::Xx, AuthKind::Carrier, 1),
        ("with an invitation", hello(early, None), Pattern::Ik, AuthKind::Invitation, 1),
        ("not base64", hello(vec!["%%".into()], None), Pattern::Ik, AuthKind::Carrier, 1),
        (
            "over the cap",
            hello(vec![b64(&vec![0; EARLY_DATA_MAX_BYTES + 1])], None),
            Pattern::Ik,
            AuthKind::Carrier,
            1,
        ),
    ] {
        assert!(
            matches!(
                hello_early(&hello, pattern, auth, generation),
                Err(CryptoError::BadPrelude(_))
            ),
            "early data {what} must be refused"
        );
    }
}
