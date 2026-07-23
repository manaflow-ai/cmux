//! Versioned wire types for the outbound cmux machine-agent tunnel.
//!
//! The transport is newline-delimited JSON over one authenticated SSH exec
//! channel. Every envelope and message body is strict so a newer field cannot
//! silently weaken authentication, generation migration, or flow control.

use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD_NO_PAD;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use zeroize::Zeroize;

pub const PROTOCOL_NAME: &str = "cmux.machine-agent";
pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
pub const MAX_DATA_BYTES: usize = 24 * 1024;
pub const MAX_STREAM_WINDOW_BYTES: u32 = 1024 * 1024;
pub const MAX_ACTIVE_STREAMS: usize = 64;
pub const MAX_RECENT_OPEN_IDS: usize = 1024;
pub const MAX_RECENT_MIGRATIONS: usize = 64;

const MAX_ID_BYTES: usize = 128;
const MAX_SESSION_BYTES: usize = 128;
const MAX_AGENT_VERSION_BYTES: usize = 128;
const MIN_SECRET_BYTES: usize = 32;
const MAX_SECRET_BYTES: usize = 256;
const MIN_MIGRATION_TOKEN_BYTES: usize = 16;
const MAX_MIGRATION_TOKEN_BYTES: usize = 256;
const MAX_PAIRING_CODE_BYTES: usize = 32;
const MAX_ERROR_CODE_BYTES: usize = 64;

macro_rules! impl_string_serde {
    ($type:ty) => {
        impl Serialize for $type {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $type {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                Self::new(String::deserialize(deserializer)?).map_err(D::Error::custom)
            }
        }
    };
}

macro_rules! impl_redacted_secret {
    ($type:ty) => {
        impl fmt::Debug for $type {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(concat!(stringify!($type), "([redacted])"))
            }
        }

        impl Drop for $type {
            fn drop(&mut self) {
                self.0.zeroize();
            }
        }

        impl_string_serde!($type);
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Protocol;

impl Serialize for Protocol {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(PROTOCOL_NAME)
    }
}

impl<'de> Deserialize<'de> for Protocol {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        if value == PROTOCOL_NAME {
            Ok(Self)
        } else {
            Err(D::Error::custom("unsupported machine-agent protocol"))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version;

impl Serialize for Version {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u16(PROTOCOL_VERSION)
    }
}

impl<'de> Deserialize<'de> for Version {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = u16::deserialize(deserializer)?;
        if value == PROTOCOL_VERSION {
            Ok(Self)
        } else {
            Err(D::Error::custom("unsupported machine-agent protocol version"))
        }
    }
}

/// One bounded protocol message with an explicit protocol/version fence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub protocol: Protocol,
    pub version: Version,
    pub message: Message,
}

impl Envelope {
    pub fn new(message: Message) -> Self {
        Self { protocol: Protocol, version: Version, message }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "body", rename_all = "snake_case")]
pub enum Message {
    Hello(Hello),
    Registered(Registered),
    ReconnectGeneration(ReconnectGeneration),
    GenerationReady(GenerationReady),
    GenerationRejected(GenerationRejected),
    DrainComplete(DrainComplete),
    Open(OpenStream),
    Opened(StreamOpened),
    Reject(StreamRejected),
    Data(StreamData),
    Window(StreamWindow),
    Close(StreamClosed),
    Ping(Heartbeat),
    Pong(Heartbeat),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub machine_id: OpaqueId,
    pub secret: MachineSecret,
    pub connection_nonce: OpaqueId,
    pub session: SessionName,
    pub agent_version: AgentVersion,
    pub minimum_generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub migration: Option<MigrationProof>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MigrationProof {
    pub generation: u64,
    pub token: MigrationToken,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registered {
    pub machine_id: OpaqueId,
    pub generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pairing_code: Option<PairingCode>,
    pub heartbeat_interval_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReconnectGeneration {
    pub generation: u64,
    pub token: MigrationToken,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationReady {
    pub from_generation: u64,
    pub to_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationRejected {
    pub generation: u64,
    pub code: ErrorCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DrainComplete {
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenStream {
    pub stream_id: u32,
    pub open_id: OpaqueId,
    pub initial_window: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamOpened {
    pub stream_id: u32,
    pub receive_window: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamRejected {
    pub stream_id: u32,
    pub code: ErrorCode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamData {
    pub stream_id: u32,
    pub payload: DataPayload,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamWindow {
    pub stream_id: u32,
    pub bytes: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamClosed {
    pub stream_id: u32,
    pub code: ErrorCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Heartbeat {
    pub nonce: u64,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OpaqueId(String);

impl OpaqueId {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let value = value.into();
        valid_identifier(&value, MAX_ID_BYTES).then_some(Self(value)).ok_or(InvalidValue)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for OpaqueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("OpaqueId").field(&self.0).finish()
    }
}

impl Serialize for OpaqueId {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for OpaqueId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::new(String::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct SessionName(String);

impl SessionName {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let value = value.into();
        valid_identifier(&value, MAX_SESSION_BYTES).then_some(Self(value)).ok_or(InvalidValue)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SessionName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("SessionName").field(&self.0).finish()
    }
}

impl_string_serde!(SessionName);

#[derive(Clone, PartialEq, Eq)]
pub struct AgentVersion(String);

impl AgentVersion {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let value = value.into();
        valid_text(&value, 1, MAX_AGENT_VERSION_BYTES).then_some(Self(value)).ok_or(InvalidValue)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AgentVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("AgentVersion").field(&self.0).finish()
    }
}

impl_string_serde!(AgentVersion);

#[derive(Clone, PartialEq, Eq)]
pub struct MachineSecret(String);

impl MachineSecret {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let mut value = value.into();
        if valid_text(&value, MIN_SECRET_BYTES, MAX_SECRET_BYTES) {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidValue)
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl_redacted_secret!(MachineSecret);

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct MigrationToken(String);

impl MigrationToken {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let mut value = value.into();
        if valid_text(&value, MIN_MIGRATION_TOKEN_BYTES, MAX_MIGRATION_TOKEN_BYTES) {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidValue)
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl_redacted_secret!(MigrationToken);

#[derive(Clone, PartialEq, Eq)]
pub struct PairingCode(String);

impl PairingCode {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let mut value = value.into();
        let valid = !value.is_empty()
            && value.len() <= MAX_PAIRING_CODE_BYTES
            && value.trim() == value
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b' '));
        if valid {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidValue)
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl_redacted_secret!(PairingCode);

#[derive(Clone, PartialEq, Eq)]
pub struct ErrorCode(String);

impl ErrorCode {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidValue> {
        let value = value.into();
        valid_identifier(&value, MAX_ERROR_CODE_BYTES).then_some(Self(value)).ok_or(InvalidValue)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ErrorCode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("ErrorCode").field(&self.0).finish()
    }
}

impl_string_serde!(ErrorCode);

#[derive(Clone, PartialEq, Eq)]
pub struct DataPayload(Vec<u8>);

impl DataPayload {
    pub fn new(mut value: Vec<u8>) -> Result<Self, InvalidValue> {
        if value.len() <= MAX_DATA_BYTES {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidValue)
        }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn into_bytes(mut self) -> Vec<u8> {
        std::mem::take(&mut self.0)
    }
}

impl fmt::Debug for DataPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "DataPayload([{} bytes])", self.0.len())
    }
}

impl Drop for DataPayload {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl Serialize for DataPayload {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut encoded = STANDARD_NO_PAD.encode(&self.0);
        let result = serializer.serialize_str(&encoded);
        encoded.zeroize();
        result
    }
}

impl<'de> Deserialize<'de> for DataPayload {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut encoded = String::deserialize(deserializer)?;
        if encoded.len() > MAX_DATA_BYTES.div_ceil(3) * 4 {
            encoded.zeroize();
            return Err(D::Error::custom("machine-agent data payload is too large"));
        }
        let mut decoded = Vec::with_capacity(encoded.len().saturating_mul(3) / 4);
        let result = STANDARD_NO_PAD.decode_vec(encoded.as_bytes(), &mut decoded);
        encoded.zeroize();
        if result.is_err() {
            decoded.zeroize();
            return Err(D::Error::custom("invalid machine-agent data payload"));
        }
        Self::new(decoded).map_err(D::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidValue;

impl fmt::Display for InvalidValue {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("invalid or oversized machine-agent protocol value")
    }
}

impl std::error::Error for InvalidValue {}

fn valid_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

fn valid_text(value: &str, minimum: usize, maximum: usize) -> bool {
    value.len() >= minimum
        && value.len() <= maximum
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn id(value: &str) -> OpaqueId {
        OpaqueId::new(value).unwrap()
    }

    fn secret() -> MachineSecret {
        MachineSecret::new("0123456789abcdef0123456789abcdef").unwrap()
    }

    #[test]
    fn hello_and_migration_frames_match_the_v1_wire_shape() {
        let hello = Envelope::new(Message::Hello(Hello {
            machine_id: id("machine-1"),
            secret: secret(),
            connection_nonce: id("connection-1"),
            session: SessionName::new("agents").unwrap(),
            agent_version: AgentVersion::new("0.1.0").unwrap(),
            minimum_generation: 7,
            migration: Some(MigrationProof {
                generation: 8,
                token: MigrationToken::new("migration-token-1234").unwrap(),
            }),
        }));
        assert_eq!(
            serde_json::to_value(&hello).unwrap(),
            json!({
                "protocol": "cmux.machine-agent",
                "version": 1,
                "message": {
                    "type": "hello",
                    "body": {
                        "machine_id": "machine-1",
                        "secret": "0123456789abcdef0123456789abcdef",
                        "connection_nonce": "connection-1",
                        "session": "agents",
                        "agent_version": "0.1.0",
                        "minimum_generation": 7,
                        "migration": {
                            "generation": 8,
                            "token": "migration-token-1234"
                        }
                    }
                }
            })
        );
        let debug = format!("{hello:?}");
        assert!(!debug.contains("0123456789abcdef"));
        assert!(!debug.contains("migration-token"));
    }

    #[test]
    fn data_is_base64_bounded_and_redacted_from_debug() {
        let frame = Envelope::new(Message::Data(StreamData {
            stream_id: 9,
            payload: DataPayload::new(b"\0secret\n".to_vec()).unwrap(),
        }));
        let encoded = serde_json::to_value(&frame).unwrap();
        assert_eq!(encoded["message"]["body"]["payload"], "AHNlY3JldAo");
        assert_eq!(serde_json::from_value::<Envelope>(encoded).unwrap(), frame);
        assert!(!format!("{frame:?}").contains("secret"));
        assert!(DataPayload::new(vec![0; MAX_DATA_BYTES + 1]).is_err());
    }

    #[test]
    fn strict_decode_rejects_downgraded_oversized_and_ambiguous_values() {
        let wrong_version = json!({
            "protocol": "cmux.machine-agent",
            "version": 0,
            "message": {"type": "ping", "body": {"nonce": 1}}
        });
        assert!(serde_json::from_value::<Envelope>(wrong_version).is_err());

        let unknown = json!({
            "protocol": "cmux.machine-agent",
            "version": 1,
            "message": {
                "type": "open",
                "body": {
                    "stream_id": 1,
                    "open_id": "open-1",
                    "initial_window": 1024,
                    "command": "sh"
                }
            }
        });
        assert!(serde_json::from_value::<Envelope>(unknown).is_err());
        assert!(PairingCode::new(" code").is_err());
        assert!(PairingCode::new("CODE\n123").is_err());
        assert!(OpaqueId::new("x".repeat(MAX_ID_BYTES + 1)).is_err());
        assert!(SessionName::new("../agents").is_err());

        let oversized_payload = json!({
            "protocol": "cmux.machine-agent",
            "version": 1,
            "message": {
                "type": "data",
                "body": {
                    "stream_id": 1,
                    "payload": "A".repeat(MAX_DATA_BYTES.div_ceil(3) * 4 + 1)
                }
            }
        });
        assert!(serde_json::from_value::<Envelope>(oversized_payload).is_err());
    }

    #[test]
    fn every_message_round_trips() {
        let messages = vec![
            Message::Registered(Registered {
                machine_id: id("machine-1"),
                generation: 4,
                pairing_code: Some(PairingCode::new("ABCD-EFGH").unwrap()),
                heartbeat_interval_ms: 1_000,
            }),
            Message::ReconnectGeneration(ReconnectGeneration {
                generation: 5,
                token: MigrationToken::new("migration-token-1234").unwrap(),
            }),
            Message::GenerationReady(GenerationReady { from_generation: 4, to_generation: 5 }),
            Message::GenerationRejected(GenerationRejected {
                generation: 5,
                code: ErrorCode::new("replay").unwrap(),
            }),
            Message::DrainComplete(DrainComplete { generation: 4 }),
            Message::Open(OpenStream { stream_id: 1, open_id: id("open-1"), initial_window: 4096 }),
            Message::Opened(StreamOpened { stream_id: 1, receive_window: 4096 }),
            Message::Reject(StreamRejected {
                stream_id: 1,
                code: ErrorCode::new("replay").unwrap(),
            }),
            Message::Data(StreamData {
                stream_id: 1,
                payload: DataPayload::new(vec![1, 2, 3]).unwrap(),
            }),
            Message::Window(StreamWindow { stream_id: 1, bytes: 3 }),
            Message::Close(StreamClosed { stream_id: 1, code: ErrorCode::new("eof").unwrap() }),
            Message::Ping(Heartbeat { nonce: 1 }),
            Message::Pong(Heartbeat { nonce: 1 }),
        ];
        for message in messages {
            let frame = Envelope::new(message);
            let encoded = serde_json::to_vec(&frame).unwrap();
            assert!(encoded.len() <= MAX_FRAME_BYTES);
            assert_eq!(serde_json::from_slice::<Envelope>(&encoded).unwrap(), frame);
        }
    }
}
