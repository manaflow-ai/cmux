use super::*;
use crate::terminal_host_protocol::{encode_frame, read_frame};

fn terminal(byte: u8) -> TerminalId {
    TerminalId::from_bytes([byte; TERMINAL_ID_LEN])
}

#[test]
fn canonical_terminal_hex_requires_lowercase_uuid_v4() {
    let canonical = "00000000000040008000000000000001";
    assert_eq!(TerminalId::from_hex(canonical).unwrap().to_hex(), canonical);
    assert!(TerminalId::from_hex("00000000000030008000000000000001").is_none());
    assert!(TerminalId::from_hex("00000000000040007000000000000001").is_none());
    assert!(TerminalId::from_hex("0000000000004000800000000000000A").is_none());
    assert!(TerminalId::from_hex("short").is_none());
}

fn token(byte: u8) -> CapabilityToken {
    CapabilityToken::from_bytes([byte; CAPABILITY_TOKEN_LEN])
}

fn hello(
    terminal_id: TerminalId,
    token: CapabilityToken,
    role: ClientRole,
    rights: CapabilityRights,
) -> ClientHello {
    ClientHello {
        min_version: 1,
        max_version: 3,
        role,
        requested_rights: rights,
        terminal_id,
        token,
    }
}

#[test]
fn hello_payloads_are_fixed_width_little_endian_and_redact_tokens() {
    let hello = ClientHello {
        min_version: 1,
        max_version: 0x0203,
        role: ClientRole::Renderer,
        requested_rights: CapabilityRights::READ | CapabilityRights::INPUT,
        terminal_id: terminal(0x44),
        token: token(0xa5),
    };
    let encoded = hello.encode();
    assert_eq!(encoded.len(), CLIENT_HELLO_LEN);
    assert_eq!(&encoded[0..4], &[1, 0, 3, 2]);
    assert_eq!(ClientHello::decode(&encoded).unwrap(), hello);
    assert!(!format!("{hello:?}").contains("a5a5"));
    assert_eq!(format!("{:?}", hello.token), "CapabilityToken([REDACTED])");

    let response = HostHello {
        selected_version: 2,
        granted_rights: CapabilityRights::READ,
        terminal_id: hello.terminal_id,
        incarnation: HostIncarnation::from_bytes([7; TERMINAL_ID_LEN]),
    };
    assert_eq!(HostHello::decode(&response.encode()).unwrap(), response);
}

#[test]
fn one_use_capability_is_bound_to_terminal_role_and_rights() {
    let store = CapabilityStore::new(8);
    let terminal_id = terminal(1);
    let minted = store
        .mint(
            terminal_id,
            CapabilityRights::READ | CapabilityRights::INPUT,
            Duration::from_secs(60),
        )
        .unwrap();
    let request = hello(
        terminal_id,
        minted,
        ClientRole::Renderer,
        CapabilityRights::READ | CapabilityRights::INPUT,
    );
    let incarnation = HostIncarnation::from_bytes([2; TERMINAL_ID_LEN]);
    let accepted = store.accept(&request, 1..=2, incarnation).unwrap();
    assert_eq!(accepted.selected_version, 2);
    assert_eq!(accepted.granted_rights, request.requested_rights);
    assert_eq!(store.active_grants(), 0);
    assert!(matches!(
        store.accept(&request, 1..=2, incarnation),
        Err(HostHandshakeError::CapabilityDenied)
    ));
}

#[test]
fn failed_binding_check_consumes_the_matching_token() {
    let store = CapabilityStore::new(8);
    let minted = store.mint(terminal(1), CapabilityRights::READ, Duration::from_secs(60)).unwrap();
    let wrong_terminal = hello(terminal(2), minted, ClientRole::Renderer, CapabilityRights::READ);
    let incarnation = HostIncarnation::from_bytes([3; TERMINAL_ID_LEN]);
    assert!(matches!(
        store.accept(&wrong_terminal, 1..=1, incarnation),
        Err(HostHandshakeError::CapabilityDenied)
    ));
    let corrected = hello(terminal(1), minted, ClientRole::Renderer, CapabilityRights::READ);
    assert!(matches!(
        store.accept(&corrected, 1..=1, incarnation),
        Err(HostHandshakeError::CapabilityDenied)
    ));
}

#[test]
fn role_violation_consumes_even_a_broad_matching_token() {
    let store = CapabilityStore::new(8);
    let minted = store.mint(terminal(1), CapabilityRights::ADMIN, Duration::from_secs(60)).unwrap();
    let request = hello(terminal(1), minted, ClientRole::Renderer, CapabilityRights::TERMINATE);
    assert!(matches!(
        store.accept(&request, 1..=1, HostIncarnation::from_bytes([4; 16])),
        Err(HostHandshakeError::CapabilityDenied)
    ));
    // Any matching token is one-use even when its role or requested
    // rights are invalid, so rejected handshakes cannot probe and retry.
    let admin = hello(terminal(1), minted, ClientRole::Admin, CapabilityRights::TERMINATE);
    assert!(matches!(
        store.accept(&admin, 1..=1, HostIncarnation::from_bytes([4; 16])),
        Err(HostHandshakeError::CapabilityDenied)
    ));
}

#[test]
fn expired_grants_are_denied_and_do_not_consume_capacity() {
    let store = CapabilityStore::new(1);
    let expired = store.mint(terminal(1), CapabilityRights::READ, Duration::ZERO).unwrap();
    assert_eq!(store.active_grants(), 0);
    let replacement =
        store.mint(terminal(1), CapabilityRights::READ, Duration::from_secs(60)).unwrap();
    assert_ne!(expired, replacement);
    assert!(matches!(
        store.accept(
            &hello(terminal(1), expired, ClientRole::Renderer, CapabilityRights::READ,),
            1..=1,
            HostIncarnation::from_bytes([5; 16]),
        ),
        Err(HostHandshakeError::CapabilityDenied)
    ));
    assert!(matches!(
        store.mint(terminal(1), CapabilityRights::READ, Duration::from_secs(60)),
        Err(HostHandshakeError::CapabilityCapacity)
    ));
}

#[test]
fn malformed_reserved_and_unknown_rights_are_rejected() {
    let mut encoded =
        hello(terminal(1), token(2), ClientRole::Renderer, CapabilityRights::READ).encode();
    encoded[5] = 1;
    assert!(matches!(ClientHello::decode(&encoded), Err(HostHandshakeError::MalformedPayload(_))));
    encoded[5] = 0;
    encoded[8..12].copy_from_slice(&(1u32 << 31).to_le_bytes());
    assert!(matches!(ClientHello::decode(&encoded), Err(HostHandshakeError::MalformedPayload(_))));
}

#[test]
fn version_negotiation_selects_highest_common_version() {
    assert_eq!(negotiate_version(1, 4, 2..=3).unwrap(), 3);
    assert!(matches!(
        negotiate_version(4, 5, 1..=3),
        Err(HostHandshakeError::UnsupportedVersion { .. })
    ));
    assert!(matches!(
        negotiate_version(3, 2, 1..=3),
        Err(HostHandshakeError::UnsupportedVersion { .. })
    ));
}

#[test]
fn stdio_bootstrap_echoes_identity_not_owner_secret() {
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id: terminal(0x42),
        owner_token: token(0xa5),
    };
    let input = encode_frame(&bootstrap.into_frame(77)).unwrap();
    let mut output = Vec::new();
    let state = bootstrap_stdio_once(&mut input.as_slice(), &mut output).unwrap();
    assert_eq!(state.terminal_id, terminal(0x42));
    assert_eq!(state.owner_token(), token(0xa5));
    assert!(!output.windows(CAPABILITY_TOKEN_LEN).any(|window| window == [0xa5; 32]));

    let frame = read_frame(&mut output.as_slice(), MAX_HANDSHAKE_PAYLOAD).unwrap().unwrap();
    assert_eq!(frame.kind, MessageKind::Ready);
    assert_eq!(frame.request_id, 77);
    let ready = HostReady::decode(&frame.payload).unwrap();
    assert_eq!(ready.terminal_id, terminal(0x42));
    assert_eq!(ready.incarnation, state.incarnation);
}

#[test]
fn stdio_bootstrap_requires_the_bootstrap_message_kind() {
    let input = encode_frame(&Frame::new(MessageKind::Input, vec![])).unwrap();
    assert!(matches!(
        bootstrap_stdio_once(&mut input.as_slice(), &mut Vec::new()),
        Err(HostHandshakeError::UnexpectedMessage {
            expected: MessageKind::Bootstrap,
            actual: MessageKind::Input,
        })
    ));
}

#[test]
fn clipboard_read_is_a_known_owner_only_right_outside_admin() {
    let clipboard = CapabilityRights::CLIPBOARD_READ;
    assert_eq!(clipboard.bits(), 0x20);
    assert_eq!(CapabilityRights::from_bits(0x20), Some(clipboard));
    assert_eq!(CapabilityRights::from_bits(0x3f), Some(CapabilityRights::ADMIN | clipboard));
    assert_eq!(CapabilityRights::from_bits(0x40), None);
    assert!(!CapabilityRights::ADMIN.contains(clipboard));
    assert_eq!(format!("{clipboard:?}"), "CapabilityRights(\"clipboard-read\")");

    let mut encoded =
        hello(terminal(1), token(2), ClientRole::Admin, CapabilityRights::ADMIN | clipboard)
            .encode();
    assert_eq!(
        ClientHello::decode(&encoded).unwrap().requested_rights,
        CapabilityRights::ADMIN | clipboard
    );
    encoded[8..12].copy_from_slice(&0x40u32.to_le_bytes());
    assert!(ClientHello::decode(&encoded).is_err());
}

#[test]
fn minted_and_renderer_capabilities_never_carry_clipboard_reads() {
    let store = CapabilityStore::new(8);
    for rights in [
        CapabilityRights::CLIPBOARD_READ,
        CapabilityRights::READ | CapabilityRights::CLIPBOARD_READ,
        CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ,
    ] {
        assert!(matches!(
            store.mint(terminal(1), rights, Duration::from_secs(60)),
            Err(HostHandshakeError::CapabilityDenied)
        ));
    }
    assert_eq!(store.active_grants(), 0);

    let incarnation = HostIncarnation::from_bytes([6; TERMINAL_ID_LEN]);
    for (role, rights) in [
        (ClientRole::Renderer, CapabilityRights::READ | CapabilityRights::CLIPBOARD_READ),
        (ClientRole::DaemonMirror, CapabilityRights::READ | CapabilityRights::CLIPBOARD_READ),
        (ClientRole::Admin, CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ),
    ] {
        let minted =
            store.mint(terminal(1), CapabilityRights::ADMIN, Duration::from_secs(60)).unwrap();
        assert!(matches!(
            store.accept(&hello(terminal(1), minted, role, rights), 1..=1, incarnation),
            Err(HostHandshakeError::CapabilityDenied)
        ));
    }
    assert!(ClientRole::Admin.allowed_rights().contains(CapabilityRights::CLIPBOARD_READ));
    assert!(!ClientRole::Renderer.allowed_rights().contains(CapabilityRights::CLIPBOARD_READ));
    assert!(!ClientRole::DaemonMirror.allowed_rights().contains(CapabilityRights::CLIPBOARD_READ));
}
