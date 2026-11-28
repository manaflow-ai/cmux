use super::*;

use cmux_remote_protocol::FrameFlags;

const CLIENT_KEY: [u8; 32] = [7; 32];
const SERVER_KEY: [u8; 32] = [9; 32];

fn client() -> RemoteWebClient {
    let mut config = RemoteWebConfig::new(CLIENT_KEY, SessionId([3; 16]), "browser-test");
    config.resume.insert(Lane::Interactive, 17);
    RemoteWebClient::from_config(config).expect("test config is valid")
}

fn take(client: &mut RemoteWebClient) -> Vec<u8> {
    client.next_outbound().expect("client queued a message")
}

fn server_read(handshake: &mut snow::HandshakeState, message: &[u8]) -> Vec<u8> {
    let mut output = vec![0; MAX_MESSAGE_BYTES];
    let size = handshake.read_message(message, &mut output).expect("server reads handshake");
    output.truncate(size);
    output
}

fn server_write(handshake: &mut snow::HandshakeState, payload: &[u8]) -> Vec<u8> {
    let mut output = vec![0; MAX_MESSAGE_BYTES];
    let size = handshake.write_message(payload, &mut output).expect("server writes handshake");
    output.truncate(size);
    output
}

fn establish(client: &mut RemoteWebClient) -> snow::StatelessTransportState {
    client.start().expect("client starts");
    let prelude = take(client);
    let params: NoiseParams = NOISE_PATTERN.parse().expect("Noise pattern is valid");
    let mut server = snow::Builder::new(params)
        .prologue(&prelude)
        .expect("server prologue")
        .local_private_key(&SERVER_KEY)
        .expect("server key")
        .build_responder()
        .expect("server handshake");
    server_read(&mut server, &take(client));
    client.receive(&server_write(&mut server, &[])).expect("client reads server handshake");
    let hello = server_read(&mut server, &take(client));
    let hello: serde_json::Value = serde_json::from_slice(&hello).expect("hello is JSON");
    assert_eq!(hello["resume"]["interactive"], 17);
    let mut transport = server.into_stateless_transport_mode().expect("server transport");
    let welcome = serde_json::to_vec(&serde_json::json!({
        "accepted": true,
        "error": null,
    }))
    .expect("welcome JSON");
    client.receive(&server_encrypt(&mut transport, 0, &welcome)).expect("client reads welcome");
    assert_eq!(client.state(), ClientState::Established);
    // The transport is stateless and can continue encrypting with the next nonce.
    transport
}

fn server_encrypt(
    transport: &mut snow::StatelessTransportState,
    nonce: u64,
    plaintext: &[u8],
) -> Vec<u8> {
    let mut output = vec![0; NONCE_BYTES + plaintext.len() + TAG_BYTES];
    output[..NONCE_BYTES].copy_from_slice(&nonce.to_be_bytes());
    let size = transport
        .write_message(nonce, plaintext, &mut output[NONCE_BYTES..])
        .expect("server encrypts record");
    output.truncate(NONCE_BYTES + size);
    output
}

#[test]
fn noise_handshake_accepts_protocol_peer_and_resumes_cursors() {
    let mut client = client();
    let _server = establish(&mut client);
    assert_eq!(client.state(), ClientState::Established);
}

#[test]
fn acpmux_open_and_payload_use_wire_frames() {
    let mut client = client();
    let mut server = establish(&mut client);

    client.open_acpmux().expect("open acpmux");
    let encrypted_open = take(&mut client);
    let open = decrypt_server(&mut server, 0, &encrypted_open);
    let frame = WireFrame::decode(&open).expect("open is a wire frame");
    assert_eq!(frame.lane, Lane::Tunnel);
    assert_eq!(frame.stream, 1);
    assert!(frame.flags.contains(FrameFlags::OPEN));
    let control: ServiceControl = serde_json::from_slice(&frame.payload).expect("open control");
    assert_eq!(
        control,
        ServiceControl::Open { service: Service::Acpmux, metadata: BTreeMap::new() }
    );

    client.send_acpmux(b"request").expect("send acpmux payload");
    let encrypted_payload = take(&mut client);
    let payload = decrypt_server(&mut server, 1, &encrypted_payload);
    let frame = WireFrame::decode(&payload).expect("payload is a wire frame");
    assert_eq!(frame.lane, Lane::Tunnel);
    assert_eq!(frame.stream, 1);
    assert_eq!(frame.payload, b"request");

    let response = WireFrame {
        session: SessionId([3; 16]),
        generation: 0,
        lane: Lane::Interactive,
        flags: FrameFlags::RELIABLE,
        sequence: 0,
        acknowledgement: 2,
        stream: 1,
        payload: b"response".to_vec(),
    }
    .encode()
    .expect("response frame");
    client.receive(&server_encrypt(&mut server, 1, &response)).expect("client reads response");
    assert_eq!(client.next_event().as_deref(), Some(&b"response"[..]));
}

#[test]
fn reconnect_starts_a_new_generation_with_the_same_resume_cursors() {
    let mut client = client();
    let _server = establish(&mut client);
    client.begin_reconnect().expect("reconnect starts");
    let prelude = take(&mut client);
    let parsed: serde_json::Value = serde_json::from_slice(&prelude).expect("prelude is JSON");
    assert_eq!(parsed["generation"], 1);
    assert_eq!(parsed["connection_attempt"].as_array().expect("attempt bytes").len(), 16);
    assert_eq!(parsed["auth"], "enrolled");
}

fn decrypt_server(
    transport: &mut snow::StatelessTransportState,
    nonce: u64,
    ciphertext: &[u8],
) -> Vec<u8> {
    assert_eq!(u64::from_be_bytes(ciphertext[..NONCE_BYTES].try_into().unwrap()), nonce);
    let mut output = vec![0; ciphertext.len() - NONCE_BYTES];
    let size = transport
        .read_message(nonce, &ciphertext[NONCE_BYTES..], &mut output)
        .expect("server decrypts record");
    output.truncate(size);
    output
}
