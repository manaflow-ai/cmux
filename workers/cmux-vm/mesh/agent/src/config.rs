//! The tunnel config the Worker returns at enrollment.
//!
//! `enroll` saves the whole 201 body (`{"device":…,"tunnel":…}`); the other
//! commands read that file. A bare `TunnelConfig` object is accepted too.
//! Unknown fields are ignored. The file never holds a private key.

use std::fmt;
use std::net::Ipv4Addr;
use std::path::Path;
use std::str::FromStr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;

/// MTU when the config has none. Measured safe on the provider gateway.
pub const DEFAULT_MTU: u16 = 1280;
/// PersistentKeepalive when the config has none. The provider's own configs
/// carry no keepalive, and its gateway forgets idle state after 300-600 s.
pub const DEFAULT_KEEPALIVE_SECONDS: u16 = 25;

/// An IPv4 network: an address and a prefix length.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cidr {
    pub address: Ipv4Addr,
    pub prefix: u8,
}

impl Cidr {
    pub fn contains(&self, address: Ipv4Addr) -> bool {
        if self.prefix == 0 {
            return true;
        }
        let mask = u32::MAX << (32 - u32::from(self.prefix));
        u32::from(self.address) & mask == u32::from(address) & mask
    }
}

impl FromStr for Cidr {
    type Err = ConfigError;

    /// `a.b.c.d/n`, or `a.b.c.d` for a single address (`/32`).
    fn from_str(text: &str) -> Result<Self, ConfigError> {
        let bad = || ConfigError(format!("not an IPv4 address or network: {text:?}"));
        let (address, prefix) = match text.trim().split_once('/') {
            Some((address, prefix)) => (address, prefix.parse::<u8>().map_err(|_| bad())?),
            None => (text.trim(), 32),
        };
        if prefix > 32 {
            return Err(bad());
        }
        Ok(Self { address: address.parse().map_err(|_| bad())?, prefix })
    }
}

impl fmt::Display for Cidr {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.address, self.prefix)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

/// A validated tunnel config.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelConfig {
    pub id: String,
    pub mesh_id: String,
    pub device_id: String,
    pub endpoint_host: String,
    pub endpoint_port: u16,
    pub server_public_key: [u8; 32],
    pub interface_address: Cidr,
    pub mesh_address: Option<Ipv4Addr>,
    pub allowed_ips: Vec<Cidr>,
    pub mtu: u16,
    pub persistent_keepalive_seconds: u16,
}

impl TunnelConfig {
    pub fn routes_contain(&self, address: Ipv4Addr) -> bool {
        self.allowed_ips.iter().any(|network| network.contains(address))
    }
}

/// The saved enrollment: the device and its tunnel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentConfig {
    pub device_id: String,
    pub mesh_id: String,
    /// The public key the device enrolled with, when the file records it.
    pub wg_public_key: Option<String>,
    pub tunnel: TunnelConfig,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTunnel {
    id: String,
    mesh_id: String,
    device_id: String,
    endpoint_host: String,
    endpoint_port: u16,
    server_public_key: String,
    interface_address: String,
    #[serde(default)]
    mesh_address: Option<String>,
    #[serde(default)]
    allowed_ips: Vec<String>,
    #[serde(default)]
    mtu: Option<u16>,
    #[serde(default)]
    persistent_keepalive_seconds: Option<u16>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawDevice {
    id: String,
    mesh_id: String,
    #[serde(default)]
    wg_public_key: Option<String>,
}

#[derive(Deserialize)]
struct RawEnrollment {
    #[serde(default)]
    device: Option<RawDevice>,
    tunnel: RawTunnel,
}

/// Decode a base64 WireGuard key (32 bytes).
pub fn decode_key(text: &str) -> Result<[u8; 32], ConfigError> {
    let bytes =
        STANDARD.decode(text.trim()).map_err(|_| ConfigError("key is not base64".into()))?;
    bytes.try_into().map_err(|_| ConfigError("key is not 32 bytes".into()))
}

fn tunnel_from_raw(raw: RawTunnel) -> Result<TunnelConfig, ConfigError> {
    if raw.endpoint_host.trim().is_empty() {
        return Err(ConfigError("endpointHost is empty".into()));
    }
    if raw.endpoint_port == 0 {
        return Err(ConfigError("endpointPort is 0".into()));
    }
    let server_public_key = decode_key(&raw.server_public_key)
        .map_err(|error| ConfigError(format!("serverPublicKey: {error}")))?;
    let interface_address: Cidr = raw.interface_address.parse()?;
    let mesh_address = match raw.mesh_address.as_deref() {
        None | Some("") => None,
        Some(text) => Some(
            text.parse().map_err(|_| ConfigError(format!("meshAddress is not IPv4: {text:?}")))?,
        ),
    };
    // IPv4 only inside the tunnel: the mesh's IPv6 range is listed too and skipped here.
    let allowed_ips = raw
        .allowed_ips
        .iter()
        .filter(|entry| !entry.contains(':'))
        .map(|entry| entry.parse())
        .collect::<Result<Vec<Cidr>, _>>()?;
    if allowed_ips.is_empty() {
        return Err(ConfigError("allowedIps is empty".into()));
    }
    let mtu = match raw.mtu {
        None => DEFAULT_MTU,
        Some(mtu) if (576..=1500).contains(&mtu) => mtu,
        Some(mtu) => return Err(ConfigError(format!("mtu {mtu} is outside 576..=1500"))),
    };
    // 0 would turn keepalive off, which the gateway's idle expiry forbids.
    let persistent_keepalive_seconds = match raw.persistent_keepalive_seconds {
        None | Some(0) => DEFAULT_KEEPALIVE_SECONDS,
        Some(seconds) => seconds,
    };
    Ok(TunnelConfig {
        id: raw.id,
        mesh_id: raw.mesh_id,
        device_id: raw.device_id,
        endpoint_host: raw.endpoint_host,
        endpoint_port: raw.endpoint_port,
        server_public_key,
        interface_address,
        mesh_address,
        allowed_ips,
        mtu,
        persistent_keepalive_seconds,
    })
}

/// Parse a bare `TunnelConfig` JSON object.
pub fn parse_tunnel(json: &str) -> Result<TunnelConfig, ConfigError> {
    let raw: RawTunnel = serde_json::from_str(json)
        .map_err(|error| ConfigError(format!("tunnel config: {error}")))?;
    tunnel_from_raw(raw)
}

/// Parse a saved enrollment (`{"device","tunnel"}`) or a bare tunnel config.
pub fn parse_agent_config(json: &str) -> Result<AgentConfig, ConfigError> {
    let value: serde_json::Value =
        serde_json::from_str(json).map_err(|error| ConfigError(format!("config: {error}")))?;
    if value.get("tunnel").is_some() {
        let raw: RawEnrollment = serde_json::from_value(value)
            .map_err(|error| ConfigError(format!("config: {error}")))?;
        let tunnel = tunnel_from_raw(raw.tunnel)?;
        let (device_id, mesh_id, wg_public_key) = match raw.device {
            Some(device) => (device.id, device.mesh_id, device.wg_public_key),
            None => (tunnel.device_id.clone(), tunnel.mesh_id.clone(), None),
        };
        if device_id != tunnel.device_id {
            return Err(ConfigError("device.id and tunnel.deviceId differ".into()));
        }
        Ok(AgentConfig { device_id, mesh_id, wg_public_key, tunnel })
    } else {
        let tunnel = tunnel_from_raw(
            serde_json::from_value(value)
                .map_err(|error| ConfigError(format!("tunnel config: {error}")))?,
        )?;
        Ok(AgentConfig {
            device_id: tunnel.device_id.clone(),
            mesh_id: tunnel.mesh_id.clone(),
            wg_public_key: None,
            tunnel,
        })
    }
}

pub fn load(path: &Path) -> Result<AgentConfig, ConfigError> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| ConfigError(format!("read {}: {error}", path.display())))?;
    parse_agent_config(&text)
}

/// The saved config after a key rotation: `saved_text` with its tunnel
/// replaced by the rotate-key response `tunnel_json`, and the device record's
/// `wgPublicKey` set to the new key. Other fields are kept. A bare tunnel
/// config becomes the response. The response must be for the same device and
/// mesh.
pub fn rotated_config(
    saved_text: &str,
    tunnel_json: &str,
    new_wg_public_key: &str,
) -> Result<String, ConfigError> {
    let saved = parse_agent_config(saved_text)?;
    let tunnel = parse_tunnel(tunnel_json)?;
    if tunnel.device_id != saved.device_id || tunnel.mesh_id != saved.mesh_id {
        return Err(ConfigError(format!(
            "the rotated tunnel is for {}/{}, not {}/{}",
            tunnel.mesh_id, tunnel.device_id, saved.mesh_id, saved.device_id
        )));
    }
    let parse = |text: &str| {
        serde_json::from_str::<serde_json::Value>(text)
            .map_err(|error| ConfigError(format!("config: {error}")))
    };
    let response = parse(tunnel_json)?;
    let mut value = parse(saved_text)?;
    if value.get("tunnel").is_some() {
        value["tunnel"] = response;
        if let Some(device) = value.get_mut("device").and_then(serde_json::Value::as_object_mut) {
            device.insert("wgPublicKey".into(), new_wg_public_key.into());
            if device.contains_key("tunnelId") {
                device.insert("tunnelId".into(), tunnel.id.clone().into());
            }
        }
    } else {
        value = response;
    }
    let text = value.to_string();
    parse_agent_config(&text)?;
    Ok(text)
}
