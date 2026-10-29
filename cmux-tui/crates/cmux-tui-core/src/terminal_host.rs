//! Terminal-host identities, capability handshakes, and process bootstrap.
//!
//! This module intentionally does not own workspace state or PTYs. It is the
//! separable security foundation used by `terminal_host_runtime`, where each
//! PTY lives in an independently adoptable process.

use crate::panic_free::RecoverPoison;
use std::fmt;
use std::io::{Read, Write};
use std::ops::{BitOr, RangeInclusive};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::terminal_host_protocol::{
    Frame, MessageKind, PROTOCOL_VERSION, ProtocolError, read_frame, wire_array, wire_u8, wire_u16,
    wire_u32, write_frame,
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

    /// Parse the canonical registry representation: lowercase UUIDv4 bytes
    /// without dashes. Keeping this strict prevents one terminal from being
    /// addressable by multiple spellings across process boundaries.
    pub fn from_hex(value: &str) -> Option<Self> {
        if value.len() != TERMINAL_ID_LEN * 2
            || !value.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
            || value.as_bytes().get(12) != Some(&b'4')
            || !matches!(value.as_bytes().get(16), Some(b'8'..=b'b'))
        {
            return None;
        }
        let mut bytes = [0u8; TERMINAL_ID_LEN];
        for (slot, pair) in bytes.iter_mut().zip(value.as_bytes().chunks_exact(2)) {
            let [high, low] = pair else {
                return None;
            };
            *slot = (hex_nibble(*high)? << 4) | hex_nibble(*low)?;
        }
        Some(Self(bytes))
    }

    pub fn to_hex(self) -> String {
        let mut output = String::with_capacity(TERMINAL_ID_LEN * 2);
        for byte in self.0 {
            for nibble in [byte >> 4, byte & 0x0f] {
                output.push(char::from_digit(u32::from(nibble), 16).unwrap_or('0'));
            }
        }
        output
    }
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
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

    /// Parse the canonical registry representation: lowercase UUIDv4 bytes
    /// without dashes. Incarnations use the same strict spelling and UUID
    /// invariants as terminal ids so records cannot be duplicated through
    /// alternate encodings.
    pub fn from_hex(value: &str) -> Option<Self> {
        TerminalId::from_hex(value).map(|id| Self::from_bytes(*id.as_bytes()))
    }

    pub fn to_hex(self) -> String {
        TerminalId::from_bytes(self.0).to_hex()
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
        for (&left, &right) in self.0.iter().zip(other.0.iter()) {
            difference |= left ^ right;
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
    pub const RENDERER: Self = Self(Self::READ.0 | Self::INPUT.0 | Self::RESIZE.0);
    pub const ADMIN: Self = Self(Self::RENDERER.0 | Self::TERMINATE.0 | Self::MINT_CAPABILITY.0);
    /// Owner-only, outside `ADMIN`: answer the terminal's OSC 52 clipboard
    /// reads. Requested only from a host whose record advertises it.
    pub const CLIPBOARD_READ: Self = Self(1 << 5);
    const KNOWN_BITS: u32 = Self::ADMIN.0 | Self::CLIPBOARD_READ.0;

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
            (Self::CLIPBOARD_READ, "clipboard-read"),
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
            Self::Renderer => CapabilityRights::RENDERER,
            Self::Admin => CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ,
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
        let short = || HostHandshakeError::MalformedPayload("bad client hello length");
        if wire_array::<3>(payload, 5).ok_or_else(short)? != [0; 3] {
            return Err(HostHandshakeError::MalformedPayload(
                "nonzero client hello reserved bytes",
            ));
        }
        let requested_rights = CapabilityRights::from_bits(wire_u32(payload, 8).ok_or_else(short)?)
            .ok_or(HostHandshakeError::MalformedPayload("unknown capability rights"))?;
        Ok(Self {
            min_version: wire_u16(payload, 0).ok_or_else(short)?,
            max_version: wire_u16(payload, 2).ok_or_else(short)?,
            role: ClientRole::try_from(wire_u8(payload, 4).ok_or_else(short)?)?,
            requested_rights,
            terminal_id: TerminalId::from_bytes(wire_array(payload, 12).ok_or_else(short)?),
            token: CapabilityToken::from_bytes(wire_array(payload, 28).ok_or_else(short)?),
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
        let short = || HostHandshakeError::MalformedPayload("bad host hello length");
        if wire_array::<2>(payload, 2).ok_or_else(short)? != [0; 2] {
            return Err(HostHandshakeError::MalformedPayload("nonzero host hello reserved bytes"));
        }
        Ok(Self {
            selected_version: wire_u16(payload, 0).ok_or_else(short)?,
            granted_rights: CapabilityRights::from_bits(wire_u32(payload, 4).ok_or_else(short)?)
                .ok_or(HostHandshakeError::MalformedPayload("unknown capability rights"))?,
            terminal_id: TerminalId::from_bytes(wire_array(payload, 8).ok_or_else(short)?),
            incarnation: HostIncarnation::from_bytes(wire_array(payload, 24).ok_or_else(short)?),
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
        // Clipboard reads belong to the owner token only; a minted grant can
        // never carry them.
        if rights.is_empty() || rights.contains(CapabilityRights::CLIPBOARD_READ) {
            return Err(HostHandshakeError::CapabilityDenied);
        }
        let now = Instant::now();
        let mut grants = self.grants.lock().recover_poison();
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
            let mut grants = self.grants.lock().recover_poison();
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
        let mut grants = self.grants.lock().recover_poison();
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
        let short = || HostHandshakeError::MalformedPayload("bad bootstrap length");
        let owner_token = CapabilityToken::from_bytes(wire_array(payload, 20).ok_or_else(short)?);
        if owner_token.is_zero() {
            return Err(HostHandshakeError::MalformedPayload("zero owner token"));
        }
        Ok(Self {
            min_version: wire_u16(payload, 0).ok_or_else(short)?,
            max_version: wire_u16(payload, 2).ok_or_else(short)?,
            terminal_id: TerminalId::from_bytes(wire_array(payload, 4).ok_or_else(short)?),
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
        let short = || HostHandshakeError::MalformedPayload("bad ready length");
        Ok(Self {
            selected_version: wire_u16(payload, 0).ok_or_else(short)?,
            terminal_id: TerminalId::from_bytes(wire_array(payload, 2).ok_or_else(short)?),
            incarnation: HostIncarnation::from_bytes(wire_array(payload, 18).ok_or_else(short)?),
        })
    }
}

/// State established through the private parent-to-host bootstrap pipe. The
/// token is retained for the owner/admin loop and never echoed in Ready.
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
/// `__terminal-host --bootstrap-stdio` mode. The runtime layers PTY ownership
/// and the long-lived admin/data socket loop on the returned state.
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
mod tests;
