//! Terminal-host identities, capability handshakes, and process bootstrap.
//!
//! This module intentionally does not own workspace state or spawn a PTY yet.
//! It is the separable security and process-mode foundation for moving each
//! PTY into an independently adoptable host.

use std::fmt;
use std::io::{Read, Write};
use std::ops::{BitOr, RangeInclusive};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::terminal_host_protocol::{
    Frame, MessageKind, PROTOCOL_VERSION, ProtocolError, read_frame, write_frame,
};

pub const CAPABILITY_TOKEN_LEN: usize = 32;
pub const TERMINAL_ID_LEN: usize = 16;
const CLIENT_HELLO_LEN: usize = 60;
const HOST_HELLO_LEN: usize = 40;
const BOOTSTRAP_LEN: usize = 52;
const READY_LEN: usize = 34;
const MAX_HANDSHAKE_PAYLOAD: usize = 4096;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalId([u8; TERMINAL_ID_LEN]);

impl TerminalId {
    pub fn random() -> Result<Self, HostHandshakeError> {
        Ok(Self(random_uuid_v4()?))
    }

    pub const fn from_bytes(bytes: [u8; TERMINAL_ID_LEN]) -> Self {
        Self(bytes)
    }

    pub const fn as_bytes(&self) -> &[u8; TERMINAL_ID_LEN] {
        &self.0
    }
}

impl fmt::Debug for TerminalId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "TerminalId({:02x}{:02x}{:02x}{:02x}-...)",
            self.0[0], self.0[1], self.0[2], self.0[3]
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct HostIncarnation([u8; TERMINAL_ID_LEN]);

impl HostIncarnation {
    pub fn random() -> Result<Self, HostHandshakeError> {
        Ok(Self(random_uuid_v4()?))
    }

    pub const fn from_bytes(bytes: [u8; TERMINAL_ID_LEN]) -> Self {
        Self(bytes)
    }

    pub const fn as_bytes(&self) -> &[u8; TERMINAL_ID_LEN] {
        &self.0
    }
}

impl fmt::Debug for HostIncarnation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "HostIncarnation({:02x}{:02x}{:02x}{:02x}-...)",
            self.0[0], self.0[1], self.0[2], self.0[3]
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CapabilityToken([u8; CAPABILITY_TOKEN_LEN]);

impl CapabilityToken {
    pub fn random() -> Result<Self, HostHandshakeError> {
        let mut bytes = [0u8; CAPABILITY_TOKEN_LEN];
        getrandom::fill(&mut bytes).map_err(|_| HostHandshakeError::RandomnessUnavailable)?;
        Ok(Self(bytes))
    }

    pub const fn from_bytes(bytes: [u8; CAPABILITY_TOKEN_LEN]) -> Self {
        Self(bytes)
    }

    pub const fn as_bytes(&self) -> &[u8; CAPABILITY_TOKEN_LEN] {
        &self.0
    }

    fn constant_time_eq(&self, other: &Self) -> bool {
        let mut difference = 0u8;
        for index in 0..CAPABILITY_TOKEN_LEN {
            difference |= self.0[index] ^ other.0[index];
        }
        difference == 0
    }

    fn is_zero(&self) -> bool {
        let mut combined = 0u8;
        for byte in self.0 {
            combined |= byte;
        }
        combined == 0
    }
}

impl fmt::Debug for CapabilityToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CapabilityToken([REDACTED])")
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CapabilityRights(u32);

impl CapabilityRights {
    pub const READ: Self = Self(1 << 0);
    pub const INPUT: Self = Self(1 << 1);
    pub const RESIZE: Self = Self(1 << 2);
    pub const TERMINATE: Self = Self(1 << 3);
    pub const MINT_CAPABILITY: Self = Self(1 << 4);
    pub const ADMIN: Self = Self(
        Self::READ.0 | Self::INPUT.0 | Self::RESIZE.0 | Self::TERMINATE.0 | Self::MINT_CAPABILITY.0,
    );
    const KNOWN_BITS: u32 = Self::ADMIN.0;

    pub const fn empty() -> Self {
        Self(0)
    }

    pub const fn bits(self) -> u32 {
        self.0
    }

    pub const fn from_bits(bits: u32) -> Option<Self> {
        if bits & !Self::KNOWN_BITS == 0 { Some(Self(bits)) } else { None }
    }

    pub const fn contains(self, requested: Self) -> bool {
        self.0 & requested.0 == requested.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl BitOr for CapabilityRights {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl fmt::Debug for CapabilityRights {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut names = Vec::new();
        for (right, name) in [
            (Self::READ, "read"),
            (Self::INPUT, "input"),
            (Self::RESIZE, "resize"),
            (Self::TERMINATE, "terminate"),
            (Self::MINT_CAPABILITY, "mint-capability"),
        ] {
            if self.contains(right) {
                names.push(name);
            }
        }
        f.debug_tuple("CapabilityRights").field(&names.join("|")).finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ClientRole {
    DaemonMirror = 1,
    Renderer = 2,
    Admin = 3,
}

impl ClientRole {
    fn allowed_rights(self) -> CapabilityRights {
        match self {
            Self::DaemonMirror => CapabilityRights::READ,
            Self::Renderer => {
                CapabilityRights::READ | CapabilityRights::INPUT | CapabilityRights::RESIZE
            }
            Self::Admin => CapabilityRights::ADMIN,
        }
    }
}

impl TryFrom<u8> for ClientRole {
    type Error = HostHandshakeError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DaemonMirror),
            2 => Ok(Self::Renderer),
            3 => Ok(Self::Admin),
            _ => Err(HostHandshakeError::MalformedPayload("unknown client role")),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ClientHello {
    pub min_version: u16,
    pub max_version: u16,
    pub role: ClientRole,
    pub requested_rights: CapabilityRights,
    pub terminal_id: TerminalId,
    pub token: CapabilityToken,
}

impl fmt::Debug for ClientHello {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientHello")
            .field("min_version", &self.min_version)
            .field("max_version", &self.max_version)
            .field("role", &self.role)
            .field("requested_rights", &self.requested_rights)
            .field("terminal_id", &self.terminal_id)
            .field("token", &"[REDACTED]")
            .finish()
    }
}

impl ClientHello {
    pub fn encode(&self) -> Vec<u8> {
        let mut payload = Vec::with_capacity(CLIENT_HELLO_LEN);
        payload.extend_from_slice(&self.min_version.to_le_bytes());
        payload.extend_from_slice(&self.max_version.to_le_bytes());
        payload.push(self.role as u8);
        payload.extend_from_slice(&[0; 3]);
        payload.extend_from_slice(&self.requested_rights.bits().to_le_bytes());
        payload.extend_from_slice(self.terminal_id.as_bytes());
        payload.extend_from_slice(self.token.as_bytes());
        payload
    }

    pub fn decode(payload: &[u8]) -> Result<Self, HostHandshakeError> {
        if payload.len() != CLIENT_HELLO_LEN {
            return Err(HostHandshakeError::MalformedPayload("bad client hello length"));
        }
        if payload[5..8] != [0; 3] {
            return Err(HostHandshakeError::MalformedPayload(
                "nonzero client hello reserved bytes",
            ));
        }
        let requested_rights = CapabilityRights::from_bits(u32::from_le_bytes(
            payload[8..12].try_into().expect("fixed rights slice"),
        ))
        .ok_or(HostHandshakeError::MalformedPayload("unknown capability rights"))?;
        Ok(Self {
            min_version: u16::from_le_bytes(payload[0..2].try_into().expect("fixed min slice")),
            max_version: u16::from_le_bytes(payload[2..4].try_into().expect("fixed max slice")),
            role: ClientRole::try_from(payload[4])?,
            requested_rights,
            terminal_id: TerminalId::from_bytes(
                payload[12..28].try_into().expect("fixed terminal-id slice"),
            ),
            token: CapabilityToken::from_bytes(
                payload[28..60].try_into().expect("fixed capability-token slice"),
            ),
        })
    }

    pub fn into_frame(self, request_id: u64) -> Frame {
        let mut frame = Frame::new(MessageKind::ClientHello, self.encode());
        frame.request_id = request_id;
        frame
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostHello {
    pub selected_version: u16,
    pub granted_rights: CapabilityRights,
    pub terminal_id: TerminalId,
    pub incarnation: HostIncarnation,
}

impl HostHello {
    pub fn encode(&self) -> Vec<u8> {
        let mut payload = Vec::with_capacity(HOST_HELLO_LEN);
        payload.extend_from_slice(&self.selected_version.to_le_bytes());
        payload.extend_from_slice(&[0; 2]);
        payload.extend_from_slice(&self.granted_rights.bits().to_le_bytes());
        payload.extend_from_slice(self.terminal_id.as_bytes());
        payload.extend_from_slice(self.incarnation.as_bytes());
        payload
    }

    pub fn decode(payload: &[u8]) -> Result<Self, HostHandshakeError> {
        if payload.len() != HOST_HELLO_LEN {
            return Err(HostHandshakeError::MalformedPayload("bad host hello length"));
        }
        if payload[2..4] != [0; 2] {
            return Err(HostHandshakeError::MalformedPayload("nonzero host hello reserved bytes"));
        }
        Ok(Self {
            selected_version: u16::from_le_bytes(
                payload[0..2].try_into().expect("fixed version slice"),
            ),
            granted_rights: CapabilityRights::from_bits(u32::from_le_bytes(
                payload[4..8].try_into().expect("fixed rights slice"),
            ))
            .ok_or(HostHandshakeError::MalformedPayload("unknown capability rights"))?,
            terminal_id: TerminalId::from_bytes(
                payload[8..24].try_into().expect("fixed terminal-id slice"),
            ),
            incarnation: HostIncarnation::from_bytes(
                payload[24..40].try_into().expect("fixed incarnation slice"),
            ),
        })
    }
}

struct CapabilityGrant {
    token: CapabilityToken,
    terminal_id: TerminalId,
    rights: CapabilityRights,
    expires_at: Instant,
}

pub struct CapabilityStore {
    grants: Mutex<Vec<CapabilityGrant>>,
    max_grants: usize,
}

impl CapabilityStore {
    pub fn new(max_grants: usize) -> Self {
        Self { grants: Mutex::new(Vec::new()), max_grants }
    }

    pub fn mint(
        &self,
        terminal_id: TerminalId,
        rights: CapabilityRights,
        ttl: Duration,
    ) -> Result<CapabilityToken, HostHandshakeError> {
        if rights.is_empty() {
            return Err(HostHandshakeError::CapabilityDenied);
        }
        let now = Instant::now();
        let mut grants = self.grants.lock().unwrap();
        grants.retain(|grant| grant.expires_at > now);
        if grants.len() >= self.max_grants {
            return Err(HostHandshakeError::CapabilityCapacity);
        }
        let token = loop {
            let candidate = CapabilityToken::random()?;
            if !grants.iter().any(|grant| grant.token.constant_time_eq(&candidate)) {
                break candidate;
            }
        };
        grants.push(CapabilityGrant {
            token,
            terminal_id,
            rights,
            expires_at: now.checked_add(ttl).unwrap_or(now),
        });
        Ok(token)
    }

    /// Consume a one-use capability and negotiate the highest common version.
    /// A matching token is removed before checking terminal, role, or rights,
    /// so a failed authorization cannot be probed and then reused differently.
    pub fn accept(
        &self,
        hello: &ClientHello,
        supported_versions: RangeInclusive<u16>,
        incarnation: HostIncarnation,
    ) -> Result<HostHello, HostHandshakeError> {
        let selected_version =
            negotiate_version(hello.min_version, hello.max_version, supported_versions)?;
        let now = Instant::now();
        let grant = {
            let mut grants = self.grants.lock().unwrap();
            grants.retain(|grant| grant.expires_at > now);
            let Some(index) =
                grants.iter().position(|grant| grant.token.constant_time_eq(&hello.token))
            else {
                return Err(HostHandshakeError::CapabilityDenied);
            };
            grants.remove(index)
        };
        if hello.requested_rights.is_empty()
            || !hello.role.allowed_rights().contains(hello.requested_rights)
            || grant.terminal_id != hello.terminal_id
            || !grant.rights.contains(hello.requested_rights)
        {
            return Err(HostHandshakeError::CapabilityDenied);
        }
        Ok(HostHello {
            selected_version,
            granted_rights: hello.requested_rights,
            terminal_id: hello.terminal_id,
            incarnation,
        })
    }

    pub fn active_grants(&self) -> usize {
        let now = Instant::now();
        let mut grants = self.grants.lock().unwrap();
        grants.retain(|grant| grant.expires_at > now);
        grants.len()
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct HostBootstrap {
    pub min_version: u16,
    pub max_version: u16,
    pub terminal_id: TerminalId,
    pub owner_token: CapabilityToken,
}

impl fmt::Debug for HostBootstrap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostBootstrap")
            .field("min_version", &self.min_version)
            .field("max_version", &self.max_version)
            .field("terminal_id", &self.terminal_id)
            .field("owner_token", &"[REDACTED]")
            .finish()
    }
}

impl HostBootstrap {
    pub fn encode(&self) -> Vec<u8> {
        let mut payload = Vec::with_capacity(BOOTSTRAP_LEN);
        payload.extend_from_slice(&self.min_version.to_le_bytes());
        payload.extend_from_slice(&self.max_version.to_le_bytes());
        payload.extend_from_slice(self.terminal_id.as_bytes());
        payload.extend_from_slice(self.owner_token.as_bytes());
        payload
    }

    pub fn decode(payload: &[u8]) -> Result<Self, HostHandshakeError> {
        if payload.len() != BOOTSTRAP_LEN {
            return Err(HostHandshakeError::MalformedPayload("bad bootstrap length"));
        }
        let owner_token = CapabilityToken::from_bytes(
            payload[20..52].try_into().expect("fixed owner-token slice"),
        );
        if owner_token.is_zero() {
            return Err(HostHandshakeError::MalformedPayload("zero owner token"));
        }
        Ok(Self {
            min_version: u16::from_le_bytes(payload[0..2].try_into().expect("fixed min slice")),
            max_version: u16::from_le_bytes(payload[2..4].try_into().expect("fixed max slice")),
            terminal_id: TerminalId::from_bytes(
                payload[4..20].try_into().expect("fixed terminal-id slice"),
            ),
            owner_token,
        })
    }

    pub fn into_frame(self, request_id: u64) -> Frame {
        let mut frame = Frame::new(MessageKind::Bootstrap, self.encode());
        frame.request_id = request_id;
        frame
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostReady {
    pub selected_version: u16,
    pub terminal_id: TerminalId,
    pub incarnation: HostIncarnation,
}

impl HostReady {
    pub fn encode(&self) -> Vec<u8> {
        let mut payload = Vec::with_capacity(READY_LEN);
        payload.extend_from_slice(&self.selected_version.to_le_bytes());
        payload.extend_from_slice(self.terminal_id.as_bytes());
        payload.extend_from_slice(self.incarnation.as_bytes());
        payload
    }

    pub fn decode(payload: &[u8]) -> Result<Self, HostHandshakeError> {
        if payload.len() != READY_LEN {
            return Err(HostHandshakeError::MalformedPayload("bad ready length"));
        }
        Ok(Self {
            selected_version: u16::from_le_bytes(
                payload[0..2].try_into().expect("fixed version slice"),
            ),
            terminal_id: TerminalId::from_bytes(
                payload[2..18].try_into().expect("fixed terminal-id slice"),
            ),
            incarnation: HostIncarnation::from_bytes(
                payload[18..34].try_into().expect("fixed incarnation slice"),
            ),
        })
    }
}

/// State established through the private parent-to-host bootstrap pipe.
/// The token is retained for the future owner/admin loop and is never echoed
/// in the ready response.
pub struct BootstrappedHost {
    pub terminal_id: TerminalId,
    pub incarnation: HostIncarnation,
    owner_token: CapabilityToken,
}

impl BootstrappedHost {
    pub fn owner_token(&self) -> CapabilityToken {
        self.owner_token
    }
}

impl fmt::Debug for BootstrappedHost {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BootstrappedHost")
            .field("terminal_id", &self.terminal_id)
            .field("incarnation", &self.incarnation)
            .field("owner_token", &"[REDACTED]")
            .finish()
    }
}

/// Perform the private, one-frame process bootstrap used by the hidden
/// `__terminal-host --bootstrap-stdio` mode. PTY ownership and the long-lived
/// admin/data socket loop will be layered on the returned state.
pub fn bootstrap_stdio_once(
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> Result<BootstrappedHost, HostHandshakeError> {
    let frame = read_frame(reader, MAX_HANDSHAKE_PAYLOAD)?
        .ok_or(HostHandshakeError::MalformedPayload("missing bootstrap frame"))?;
    if frame.kind != MessageKind::Bootstrap {
        return Err(HostHandshakeError::UnexpectedMessage {
            expected: MessageKind::Bootstrap,
            actual: frame.kind,
        });
    }
    let bootstrap = HostBootstrap::decode(&frame.payload)?;
    let selected_version = negotiate_version(
        bootstrap.min_version,
        bootstrap.max_version,
        PROTOCOL_VERSION..=PROTOCOL_VERSION,
    )?;
    if frame.version != selected_version {
        return Err(HostHandshakeError::UnsupportedVersion {
            client_min: frame.version,
            client_max: frame.version,
            host_min: selected_version,
            host_max: selected_version,
        });
    }
    let incarnation = HostIncarnation::random()?;
    let ready = HostReady { selected_version, terminal_id: bootstrap.terminal_id, incarnation };
    let mut response = Frame::new(MessageKind::Ready, ready.encode());
    response.version = selected_version;
    response.request_id = frame.request_id;
    write_frame(writer, &response)?;
    Ok(BootstrappedHost {
        terminal_id: bootstrap.terminal_id,
        incarnation,
        owner_token: bootstrap.owner_token,
    })
}

fn negotiate_version(
    client_min: u16,
    client_max: u16,
    host_versions: RangeInclusive<u16>,
) -> Result<u16, HostHandshakeError> {
    let host_min = *host_versions.start();
    let host_max = *host_versions.end();
    if client_min == 0
        || host_min == 0
        || client_min > client_max
        || host_min > host_max
        || client_max < host_min
        || host_max < client_min
    {
        return Err(HostHandshakeError::UnsupportedVersion {
            client_min,
            client_max,
            host_min,
            host_max,
        });
    }
    Ok(client_max.min(host_max))
}

fn random_uuid_v4() -> Result<[u8; TERMINAL_ID_LEN], HostHandshakeError> {
    let mut bytes = [0u8; TERMINAL_ID_LEN];
    getrandom::fill(&mut bytes).map_err(|_| HostHandshakeError::RandomnessUnavailable)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(bytes)
}

#[derive(Debug)]
pub enum HostHandshakeError {
    Protocol(ProtocolError),
    RandomnessUnavailable,
    MalformedPayload(&'static str),
    UnexpectedMessage { expected: MessageKind, actual: MessageKind },
    UnsupportedVersion { client_min: u16, client_max: u16, host_min: u16, host_max: u16 },
    CapabilityDenied,
    CapabilityCapacity,
}

impl fmt::Display for HostHandshakeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Protocol(error) => error.fmt(f),
            Self::RandomnessUnavailable => f.write_str("operating system randomness unavailable"),
            Self::MalformedPayload(reason) => {
                write!(f, "malformed terminal-host payload: {reason}")
            }
            Self::UnexpectedMessage { expected, actual } => {
                write!(f, "expected terminal-host {expected:?}, received {actual:?}")
            }
            Self::UnsupportedVersion { client_min, client_max, host_min, host_max } => write!(
                f,
                "no common terminal-host protocol version (client {client_min}..={client_max}, host {host_min}..={host_max})"
            ),
            Self::CapabilityDenied => f.write_str("terminal-host capability denied"),
            Self::CapabilityCapacity => f.write_str("terminal-host capability limit reached"),
        }
    }
}

impl std::error::Error for HostHandshakeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Protocol(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ProtocolError> for HostHandshakeError {
    fn from(value: ProtocolError) -> Self {
        Self::Protocol(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_host_protocol::{encode_frame, read_frame};

    fn terminal(byte: u8) -> TerminalId {
        TerminalId::from_bytes([byte; TERMINAL_ID_LEN])
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
        let minted =
            store.mint(terminal(1), CapabilityRights::READ, Duration::from_secs(60)).unwrap();
        let wrong_terminal =
            hello(terminal(2), minted, ClientRole::Renderer, CapabilityRights::READ);
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
        let minted =
            store.mint(terminal(1), CapabilityRights::ADMIN, Duration::from_secs(60)).unwrap();
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
        assert!(matches!(
            ClientHello::decode(&encoded),
            Err(HostHandshakeError::MalformedPayload(_))
        ));
        encoded[5] = 0;
        encoded[8..12].copy_from_slice(&(1u32 << 31).to_le_bytes());
        assert!(matches!(
            ClientHello::decode(&encoded),
            Err(HostHandshakeError::MalformedPayload(_))
        ));
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
}
