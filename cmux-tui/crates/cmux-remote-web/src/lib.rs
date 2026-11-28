//! Browser-side Noise and service multiplexing for cmux Remote.
//!
//! The WebSocket remains in TypeScript. This crate consumes and produces one
//! binary WebSocket message at a time, keeping the browser surface small while
//! sharing the wire types and handshake dialect with the native client.

use std::collections::{BTreeMap, VecDeque};
use std::fmt;

use cmux_remote_protocol::{
    FrameFlags, Lane, REMOTE_PROTOCOL_VERSION, Service, ServiceControl, SessionId, WireFrame,
};
use serde::{Deserialize, Serialize};
use snow::params::NoiseParams;
use wasm_bindgen::prelude::*;

const HANDSHAKE_NAME: &str = "cmux-remote-noise";
const NOISE_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
const MAX_MESSAGE_BYTES: usize = 65_535;
const MAX_HANDSHAKE_PAYLOAD: usize = 16 * 1024;
const NONCE_BYTES: usize = 8;
const TAG_BYTES: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteWebConfig {
    pub private_key: [u8; 32],
    pub session: SessionId,
    pub device_name: String,
    pub grant: Option<String>,
    pub expected_daemon: Option<[u8; 32]>,
    pub resume: BTreeMap<Lane, u64>,
}

impl RemoteWebConfig {
    pub fn new(private_key: [u8; 32], session: SessionId, device_name: impl Into<String>) -> Self {
        Self {
            private_key,
            session,
            device_name: device_name.into(),
            grant: None,
            expected_daemon: None,
            resume: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientState {
    New,
    AwaitingServerHandshake,
    AwaitingWelcome,
    Established,
    Closed,
}

#[derive(Debug)]
pub enum RemoteWebError {
    InvalidConfig(String),
    InvalidState { state: ClientState, operation: &'static str },
    Json(serde_json::Error),
    Noise(snow::Error),
    MessageTooLarge(usize),
    InvalidMessage(String),
    Protocol(String),
    DaemonKeyMismatch,
}

impl fmt::Display for RemoteWebError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfig(message) => write!(formatter, "invalid config: {message}"),
            Self::InvalidState { state, operation } => {
                write!(formatter, "cannot {operation} while remote client is {state:?}")
            }
            Self::Json(error) => write!(formatter, "protocol JSON failed: {error}"),
            Self::Noise(error) => write!(formatter, "Noise handshake failed: {error}"),
            Self::MessageTooLarge(size) => write!(formatter, "message is too large: {size} bytes"),
            Self::InvalidMessage(message) => {
                write!(formatter, "invalid WebSocket message: {message}")
            }
            Self::Protocol(message) => write!(formatter, "remote protocol failed: {message}"),
            Self::DaemonKeyMismatch => {
                formatter.write_str("daemon key did not match the pinned key")
            }
        }
    }
}

impl std::error::Error for RemoteWebError {}

impl From<serde_json::Error> for RemoteWebError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[derive(Debug, Serialize)]
struct ClientPrelude {
    name: &'static str,
    protocol: u8,
    auth: AuthKind,
    invitation_id: Option<String>,
    session: SessionId,
    lane: Lane,
    lanes: Vec<Lane>,
    generation: u64,
    connection_attempt: [u8; 16],
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "kebab-case")]
enum AuthKind {
    Enrolled,
    Grant,
}

#[derive(Debug, Serialize)]
struct ClientHello {
    device_name: String,
    resume: BTreeMap<Lane, u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    grant: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ServerWelcome {
    accepted: bool,
    error: Option<String>,
}

enum HandshakeState {
    New,
    AwaitingServerHandshake(Box<snow::HandshakeState>),
    AwaitingWelcome(SecureState),
    Established(SecureState),
    Closed,
}

struct SecureState {
    transport: snow::StatelessTransportState,
    send_nonce: u64,
    receive_nonce: u64,
}

/// Queue-based browser remote session. Each outbound item is one WebSocket
/// message. Decrypted server payloads are returned by `next_event`.
#[wasm_bindgen]
pub struct RemoteWebClient {
    config: RemoteWebConfig,
    generation: u64,
    connection_attempt: u128,
    state: HandshakeState,
    outbound: VecDeque<Vec<u8>>,
    events: VecDeque<Vec<u8>>,
    next_stream: u64,
    acpmux_stream: Option<u64>,
}

impl fmt::Debug for RemoteWebClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteWebClient")
            .field("state", &self.state())
            .field("generation", &self.generation)
            .finish_non_exhaustive()
    }
}

impl RemoteWebClient {
    pub fn from_config(config: RemoteWebConfig) -> Result<Self, RemoteWebError> {
        if config.device_name.trim().is_empty() {
            return Err(RemoteWebError::InvalidConfig("device name cannot be empty".into()));
        }
        Ok(Self {
            config,
            generation: 0,
            connection_attempt: 1,
            state: HandshakeState::New,
            outbound: VecDeque::new(),
            events: VecDeque::new(),
            next_stream: 1,
            acpmux_stream: None,
        })
    }

    pub fn state(&self) -> ClientState {
        state_for(&self.state)
    }

    pub fn start(&mut self) -> Result<(), RemoteWebError> {
        if !matches!(self.state, HandshakeState::New) {
            return Err(RemoteWebError::InvalidState { state: self.state(), operation: "start" });
        }
        let prelude = self.prelude()?;
        let prelude_bytes = serde_json::to_vec(&prelude)?;
        let params: NoiseParams = NOISE_PATTERN.parse().map_err(RemoteWebError::Noise)?;
        let mut handshake = snow::Builder::new(params)
            .prologue(&prelude_bytes)
            .map_err(RemoteWebError::Noise)?
            .local_private_key(&self.config.private_key)
            .map_err(RemoteWebError::Noise)?
            .build_initiator()
            .map_err(RemoteWebError::Noise)?;
        let message = write_handshake(&mut handshake, &[])?;
        self.outbound.push_back(prelude_bytes);
        self.outbound.push_back(message);
        self.state = HandshakeState::AwaitingServerHandshake(Box::new(handshake));
        Ok(())
    }

    pub fn begin_reconnect(&mut self) -> Result<(), RemoteWebError> {
        if !matches!(self.state, HandshakeState::Established(_)) {
            return Err(RemoteWebError::InvalidState {
                state: self.state(),
                operation: "begin reconnect",
            });
        }
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or_else(|| RemoteWebError::Protocol("connection generation exhausted".into()))?;
        self.connection_attempt = self
            .connection_attempt
            .checked_add(1)
            .ok_or_else(|| RemoteWebError::Protocol("connection attempt exhausted".into()))?;
        self.state = HandshakeState::New;
        self.acpmux_stream = None;
        self.start()
    }

    pub fn receive(&mut self, message: &[u8]) -> Result<(), RemoteWebError> {
        if message.len() > MAX_MESSAGE_BYTES {
            return Err(RemoteWebError::MessageTooLarge(message.len()));
        }
        let state = std::mem::replace(&mut self.state, HandshakeState::Closed);
        match state {
            HandshakeState::AwaitingServerHandshake(mut handshake) => {
                let payload = read_handshake(&mut handshake, message)?;
                let remote_static: [u8; 32] = handshake
                    .get_remote_static()
                    .ok_or_else(|| RemoteWebError::Protocol("server omitted static key".into()))?
                    .try_into()
                    .map_err(|_| RemoteWebError::Protocol("server static key is invalid".into()))?;
                if self.config.expected_daemon.is_some_and(|expected| expected != remote_static) {
                    return Err(RemoteWebError::DaemonKeyMismatch);
                }
                if !payload.is_empty() {
                    return Err(RemoteWebError::InvalidMessage(
                        "server handshake message carried an unexpected payload".into(),
                    ));
                }
                let hello = ClientHello {
                    device_name: self.config.device_name.clone(),
                    resume: self.config.resume.clone(),
                    grant: (self.generation == 0).then(|| self.config.grant.clone()).flatten(),
                };
                let hello_payload = serde_json::to_vec(&hello)?;
                let message = write_handshake(&mut handshake, &hello_payload)?;
                let transport =
                    handshake.into_stateless_transport_mode().map_err(RemoteWebError::Noise)?;
                self.outbound.push_back(message);
                self.state = HandshakeState::AwaitingWelcome(SecureState {
                    transport,
                    send_nonce: 0,
                    receive_nonce: 0,
                });
                Ok(())
            }
            HandshakeState::AwaitingWelcome(mut secure) => {
                let welcome = decrypt_record(&mut secure, message)?;
                let welcome: ServerWelcome = serde_json::from_slice(&welcome)?;
                if !welcome.accepted {
                    return Err(RemoteWebError::Protocol(format!(
                        "daemon rejected device: {}",
                        welcome.error.unwrap_or_else(|| "no reason given".into())
                    )));
                }
                self.state = HandshakeState::Established(secure);
                Ok(())
            }
            HandshakeState::Established(mut secure) => {
                let plaintext = decrypt_record(&mut secure, message)?;
                let frame = WireFrame::decode(&plaintext)
                    .map_err(|error| RemoteWebError::Protocol(error.to_string()))?;
                self.events.push_back(frame.payload);
                self.state = HandshakeState::Established(secure);
                Ok(())
            }
            state => {
                Err(RemoteWebError::InvalidState { state: state_for(&state), operation: "receive" })
            }
        }
    }

    pub fn open_acpmux(&mut self) -> Result<(), RemoteWebError> {
        if !matches!(self.state, HandshakeState::Established(_)) {
            return Err(RemoteWebError::InvalidState {
                state: self.state(),
                operation: "open acpmux",
            });
        }
        if self.acpmux_stream.is_some() {
            return Ok(());
        }
        let stream = self.next_stream;
        self.next_stream = self
            .next_stream
            .checked_add(2)
            .ok_or_else(|| RemoteWebError::Protocol("service stream id exhausted".into()))?;
        let control = ServiceControl::Open { service: Service::Acpmux, metadata: BTreeMap::new() };
        self.send_frame(Lane::Tunnel, stream, FrameFlags::OPEN, serde_json::to_vec(&control)?)?;
        self.acpmux_stream = Some(stream);
        Ok(())
    }

    pub fn send_acpmux(&mut self, payload: &[u8]) -> Result<(), RemoteWebError> {
        let stream = self
            .acpmux_stream
            .ok_or_else(|| RemoteWebError::Protocol("acpmux service is not open".into()))?;
        if payload.len() > cmux_remote_protocol::MAX_FRAME_PAYLOAD {
            return Err(RemoteWebError::MessageTooLarge(payload.len()));
        }
        self.send_frame(Lane::Tunnel, stream, FrameFlags::empty(), payload.to_vec())
    }

    pub fn next_outbound(&mut self) -> Option<Vec<u8>> {
        self.outbound.pop_front()
    }

    pub fn next_event(&mut self) -> Option<Vec<u8>> {
        self.events.pop_front()
    }

    fn prelude(&self) -> Result<ClientPrelude, RemoteWebError> {
        Ok(ClientPrelude {
            name: HANDSHAKE_NAME,
            protocol: REMOTE_PROTOCOL_VERSION,
            auth: if self.config.grant.is_some() { AuthKind::Grant } else { AuthKind::Enrolled },
            invitation_id: None,
            session: self.config.session,
            lane: Lane::Interactive,
            lanes: Lane::ALL.to_vec(),
            generation: self.generation,
            connection_attempt: self.connection_attempt.to_be_bytes(),
        })
    }

    fn send_frame(
        &mut self,
        lane: Lane,
        stream: u64,
        flags: FrameFlags,
        payload: Vec<u8>,
    ) -> Result<(), RemoteWebError> {
        let HandshakeState::Established(secure) = &mut self.state else {
            return Err(RemoteWebError::InvalidState {
                state: self.state(),
                operation: "send frame",
            });
        };
        let sequence = secure.send_nonce;
        let frame = WireFrame {
            session: self.config.session,
            generation: self.generation,
            lane,
            flags: flags.union(FrameFlags::RELIABLE),
            sequence,
            acknowledgement: secure.receive_nonce,
            stream,
            payload,
        };
        let encoded =
            frame.encode().map_err(|error| RemoteWebError::Protocol(error.to_string()))?;
        self.outbound.push_back(encrypt_record(secure, &encoded)?);
        Ok(())
    }
}

fn state_for(state: &HandshakeState) -> ClientState {
    match state {
        HandshakeState::New => ClientState::New,
        HandshakeState::AwaitingServerHandshake(_) => ClientState::AwaitingServerHandshake,
        HandshakeState::AwaitingWelcome(_) => ClientState::AwaitingWelcome,
        HandshakeState::Established(_) => ClientState::Established,
        HandshakeState::Closed => ClientState::Closed,
    }
}

fn write_handshake(
    handshake: &mut snow::HandshakeState,
    payload: &[u8],
) -> Result<Vec<u8>, RemoteWebError> {
    if payload.len() > MAX_HANDSHAKE_PAYLOAD {
        return Err(RemoteWebError::MessageTooLarge(payload.len()));
    }
    let mut output = vec![0; MAX_MESSAGE_BYTES];
    let size = handshake.write_message(payload, &mut output).map_err(RemoteWebError::Noise)?;
    output.truncate(size);
    Ok(output)
}

fn read_handshake(
    handshake: &mut snow::HandshakeState,
    message: &[u8],
) -> Result<Vec<u8>, RemoteWebError> {
    let mut payload = vec![0; MAX_MESSAGE_BYTES];
    let size = handshake.read_message(message, &mut payload).map_err(RemoteWebError::Noise)?;
    payload.truncate(size);
    Ok(payload)
}

fn encrypt_record(secure: &mut SecureState, plaintext: &[u8]) -> Result<Vec<u8>, RemoteWebError> {
    let nonce = secure.send_nonce;
    secure.send_nonce = secure
        .send_nonce
        .checked_add(1)
        .ok_or_else(|| RemoteWebError::Protocol("Noise send nonce exhausted".into()))?;
    let mut body = vec![0; plaintext.len().saturating_add(TAG_BYTES)];
    let size = secure
        .transport
        .write_message(nonce, plaintext, &mut body)
        .map_err(RemoteWebError::Noise)?;
    body.truncate(size);
    let mut output = Vec::with_capacity(NONCE_BYTES.saturating_add(body.len()));
    output.extend_from_slice(&nonce.to_be_bytes());
    output.extend_from_slice(&body);
    Ok(output)
}

fn decrypt_record(secure: &mut SecureState, message: &[u8]) -> Result<Vec<u8>, RemoteWebError> {
    let Some((nonce_bytes, ciphertext)) = message.split_first_chunk::<NONCE_BYTES>() else {
        return Err(RemoteWebError::InvalidMessage("encrypted record is truncated".into()));
    };
    if ciphertext.len() < TAG_BYTES {
        return Err(RemoteWebError::InvalidMessage("encrypted record is truncated".into()));
    }
    let nonce = u64::from_be_bytes(*nonce_bytes);
    if nonce != secure.receive_nonce {
        return Err(RemoteWebError::Protocol(format!(
            "encrypted record nonce {nonce} does not follow {}",
            secure.receive_nonce
        )));
    }
    let mut output = vec![0; ciphertext.len()];
    let size = secure
        .transport
        .read_message(nonce, ciphertext, &mut output)
        .map_err(RemoteWebError::Noise)?;
    secure.receive_nonce = secure
        .receive_nonce
        .checked_add(1)
        .ok_or_else(|| RemoteWebError::Protocol("Noise receive nonce exhausted".into()))?;
    output.truncate(size);
    Ok(output)
}

fn js_error(error: RemoteWebError) -> JsValue {
    JsValue::from_str(&error.to_string())
}

#[wasm_bindgen]
impl RemoteWebClient {
    #[wasm_bindgen(constructor)]
    pub fn new(
        private_key: &[u8],
        session_id: &[u8],
        device_name: String,
        grant: Option<String>,
    ) -> Result<RemoteWebClient, JsValue> {
        let private_key: [u8; 32] = private_key
            .try_into()
            .map_err(|_| JsValue::from_str("private key must contain 32 bytes"))?;
        let session: [u8; 16] = session_id
            .try_into()
            .map_err(|_| JsValue::from_str("session id must contain 16 bytes"))?;
        let mut config = RemoteWebConfig::new(private_key, SessionId(session), device_name);
        config.grant = grant;
        Self::from_config(config).map_err(js_error)
    }

    #[wasm_bindgen(js_name = state)]
    pub fn wasm_state(&self) -> String {
        format!("{:?}", self.state()).to_lowercase()
    }

    #[wasm_bindgen(js_name = start)]
    pub fn wasm_start(&mut self) -> Result<(), JsValue> {
        self.start().map_err(js_error)
    }

    #[wasm_bindgen(js_name = reconnect)]
    pub fn wasm_reconnect(&mut self) -> Result<(), JsValue> {
        self.begin_reconnect().map_err(js_error)
    }

    #[wasm_bindgen(js_name = receive)]
    pub fn wasm_receive(&mut self, message: &[u8]) -> Result<(), JsValue> {
        self.receive(message).map_err(js_error)
    }

    #[wasm_bindgen(js_name = openAcpmux)]
    pub fn wasm_open_acpmux(&mut self) -> Result<(), JsValue> {
        self.open_acpmux().map_err(js_error)
    }

    #[wasm_bindgen(js_name = sendAcpmux)]
    pub fn wasm_send_acpmux(&mut self, payload: &[u8]) -> Result<(), JsValue> {
        self.send_acpmux(payload).map_err(js_error)
    }

    #[wasm_bindgen(js_name = nextOutbound)]
    pub fn wasm_next_outbound(&mut self) -> Option<Vec<u8>> {
        self.next_outbound()
    }

    #[wasm_bindgen(js_name = nextEvent)]
    pub fn wasm_next_event(&mut self) -> Option<Vec<u8>> {
        self.next_event()
    }
}

#[cfg(test)]
mod tests;
