//! The wg-quick configuration of one point-to-point tunnel.
//!
//! The parser accepts the file a WireGuard control plane hands out (Freestyle's
//! tunnel config, `wg-quick(8)` syntax) and ignores keys that only matter to a
//! system interface (`DNS`, `Table`, `PreUp`, `PostDown`, `FwMark`,
//! `ListenPort`, `SaveConfig`). Exactly one `[Peer]` is supported: this crate
//! models one client reaching one network, not a mesh.
//!
//! Secrets never appear in errors or in `Debug` output.

use std::fmt;
use std::io;
use std::net::{IpAddr, SocketAddr};

use base64::Engine;
use ip_network::IpNetwork;
use zeroize::Zeroizing;

/// The WireGuard default interface MTU, used when the config sets none.
pub const DEFAULT_MTU: u16 = 1420;

/// Smallest MTU the stack accepts. Below this TCP cannot carry a useful segment.
const MIN_MTU: u16 = 576;

/// The interface holds at most this many addresses (smoltcp's compiled-in
/// `IFACE_MAX_ADDR_COUNT`). Freestyle issues one IPv4 and one IPv6 address.
pub(crate) const MAX_ADDRESSES: usize = 2;

/// Where the peer listens. A host name is resolved when the tunnel starts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

impl Endpoint {
    /// Resolve to socket addresses. A literal IP resolves to itself without a
    /// DNS query.
    pub async fn resolve(&self) -> io::Result<Vec<SocketAddr>> {
        if let Ok(ip) = self.host.parse::<IpAddr>() {
            return Ok(vec![SocketAddr::new(ip, self.port)]);
        }
        let addresses =
            tokio::net::lookup_host((self.host.as_str(), self.port)).await?.collect::<Vec<_>>();
        if addresses.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{} resolved to no addresses", self.host),
            ));
        }
        Ok(addresses)
    }
}

impl fmt::Display for Endpoint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.host.contains(':') {
            write!(formatter, "[{}]:{}", self.host, self.port)
        } else {
            write!(formatter, "{}:{}", self.host, self.port)
        }
    }
}

/// One `Address =` entry: this side's host address and the prefix of the
/// subnet it sits in. Unlike an `AllowedIPs` network the host bits matter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InterfaceAddress {
    pub address: IpAddr,
    pub prefix: u8,
}

impl fmt::Display for InterfaceAddress {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.address, self.prefix)
    }
}

/// One tunnel: this side's identity and addresses plus the single peer.
#[derive(Clone)]
pub struct WgConfig {
    /// This side's Curve25519 private key.
    pub private_key: Zeroizing<[u8; 32]>,
    /// Addresses assigned to this side inside the network (`Address =`).
    pub addresses: Vec<InterfaceAddress>,
    /// Largest IP packet the tunnel carries.
    pub mtu: u16,
    /// The peer's Curve25519 public key.
    pub peer_public_key: [u8; 32],
    /// Optional symmetric pre-shared key mixed into the handshake.
    pub preshared_key: Option<Zeroizing<[u8; 32]>>,
    /// Networks reachable through the peer (`AllowedIPs =`). Also the
    /// crypto-key routing filter for packets the peer sends.
    pub allowed_ips: Vec<IpNetwork>,
    /// The peer's listening endpoint. `None` for a side that only answers,
    /// which learns the endpoint from the first authenticated datagram.
    pub endpoint: Option<Endpoint>,
    /// Seconds between keepalives that hold NAT mappings open.
    pub persistent_keepalive: Option<u16>,
}

impl fmt::Debug for WgConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WgConfig")
            .field("addresses", &self.addresses)
            .field("mtu", &self.mtu)
            .field(
                "peer_public_key",
                &base64::engine::general_purpose::STANDARD.encode(self.peer_public_key),
            )
            .field("preshared_key", &self.preshared_key.as_ref().map(|_| "<set>"))
            .field("allowed_ips", &self.allowed_ips)
            .field("endpoint", &self.endpoint)
            .field("persistent_keepalive", &self.persistent_keepalive)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// A section other than `[Interface]` or `[Peer]`.
    UnexpectedSection(String),
    /// A line that is not `key = value`, or one outside any section.
    MalformedLine(usize),
    /// A second `[Peer]` section.
    MultiplePeers,
    /// A key with a value that failed to parse. Key material is never echoed;
    /// for addresses the offending text is included.
    InvalidValue { key: &'static str, detail: String },
    MissingPrivateKey,
    MissingAddress,
    MissingPeerPublicKey,
    MissingAllowedIps,
    /// More addresses than the interface can hold.
    TooManyAddresses { maximum: usize },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnexpectedSection(name) => write!(formatter, "unexpected section [{name}]"),
            Self::MalformedLine(line) => write!(formatter, "line {line} is not `key = value`"),
            Self::MultiplePeers => formatter.write_str("more than one [Peer] section"),
            Self::InvalidValue { key, detail } => write!(formatter, "invalid {key}: {detail}"),
            Self::MissingPrivateKey => formatter.write_str("[Interface] has no PrivateKey"),
            Self::MissingAddress => formatter.write_str("[Interface] has no Address"),
            Self::MissingPeerPublicKey => formatter.write_str("[Peer] has no PublicKey"),
            Self::MissingAllowedIps => formatter.write_str("[Peer] has no AllowedIPs"),
            Self::TooManyAddresses { maximum } => {
                write!(formatter, "[Interface] has more than {maximum} Address entries")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

#[derive(PartialEq, Eq)]
enum Section {
    None,
    Interface,
    Peer,
}

impl WgConfig {
    /// Parse a wg-quick configuration file.
    pub fn parse_wg_quick(text: &str) -> Result<Self, ConfigError> {
        let mut section = Section::None;
        let mut saw_peer = false;
        let mut private_key = None;
        let mut addresses = Vec::new();
        let mut mtu = DEFAULT_MTU;
        let mut peer_public_key = None;
        let mut preshared_key = None;
        let mut allowed_ips = Vec::new();
        let mut endpoint = None;
        let mut persistent_keepalive = None;

        for (index, raw) in text.lines().enumerate() {
            let line_number = index + 1;
            let line = strip_comment(raw).trim();
            if line.is_empty() {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')) {
                section = match name.trim().to_ascii_lowercase().as_str() {
                    "interface" => Section::Interface,
                    "peer" => {
                        if saw_peer {
                            return Err(ConfigError::MultiplePeers);
                        }
                        saw_peer = true;
                        Section::Peer
                    }
                    other => return Err(ConfigError::UnexpectedSection(other.to_owned())),
                };
                continue;
            }
            let (key, value) =
                line.split_once('=').ok_or(ConfigError::MalformedLine(line_number))?;
            let key = key.trim().to_ascii_lowercase();
            let value = value.trim();
            match section {
                Section::None => return Err(ConfigError::MalformedLine(line_number)),
                Section::Interface => match key.as_str() {
                    "privatekey" => private_key = Some(parse_key(value, "PrivateKey")?),
                    "address" => {
                        for entry in comma_separated(value) {
                            addresses.push(parse_interface_address(entry)?);
                        }
                    }
                    "mtu" => {
                        mtu = value.parse::<u16>().ok().filter(|mtu| *mtu >= MIN_MTU).ok_or_else(
                            || ConfigError::InvalidValue {
                                key: "MTU",
                                detail: format!("{value} is not an integer of at least {MIN_MTU}"),
                            },
                        )?;
                    }
                    // System-interface concerns; irrelevant to an in-process peer.
                    _ => {}
                },
                Section::Peer => match key.as_str() {
                    "publickey" => peer_public_key = Some(*parse_key(value, "PublicKey")?),
                    "presharedkey" => preshared_key = Some(parse_key(value, "PresharedKey")?),
                    "allowedips" => {
                        for entry in comma_separated(value) {
                            allowed_ips.push(parse_allowed_network(entry)?);
                        }
                    }
                    "endpoint" => endpoint = Some(parse_endpoint(value)?),
                    "persistentkeepalive" => {
                        let seconds =
                            value.parse::<u16>().map_err(|_| ConfigError::InvalidValue {
                                key: "PersistentKeepalive",
                                detail: format!("{value} is not a number of seconds"),
                            })?;
                        persistent_keepalive = (seconds > 0).then_some(seconds);
                    }
                    _ => {}
                },
            }
        }

        let private_key = private_key.ok_or(ConfigError::MissingPrivateKey)?;
        if addresses.is_empty() {
            return Err(ConfigError::MissingAddress);
        }
        if addresses.len() > MAX_ADDRESSES {
            return Err(ConfigError::TooManyAddresses { maximum: MAX_ADDRESSES });
        }
        let peer_public_key = peer_public_key.ok_or(ConfigError::MissingPeerPublicKey)?;
        if allowed_ips.is_empty() {
            return Err(ConfigError::MissingAllowedIps);
        }
        Ok(Self {
            private_key,
            addresses,
            mtu,
            peer_public_key,
            preshared_key,
            allowed_ips,
            endpoint,
            persistent_keepalive,
        })
    }

    /// Whether `address` is reachable through this tunnel.
    pub fn routes_contain(&self, address: IpAddr) -> bool {
        self.allowed_ips.iter().any(|network| network.contains(address))
    }

    /// This side's address in the same family as `remote`, if any.
    pub fn local_address_for(&self, remote: IpAddr) -> Option<IpAddr> {
        self.addresses
            .iter()
            .map(|entry| entry.address)
            .find(|address| address.is_ipv4() == remote.is_ipv4())
    }
}

fn strip_comment(line: &str) -> &str {
    match line.find('#') {
        Some(index) => &line[..index],
        None => line,
    }
}

fn comma_separated(value: &str) -> impl Iterator<Item = &str> {
    value.split(',').map(str::trim).filter(|entry| !entry.is_empty())
}

fn parse_key(value: &str, key: &'static str) -> Result<Zeroizing<[u8; 32]>, ConfigError> {
    let invalid =
        || ConfigError::InvalidValue { key, detail: "expected 32 bytes of base64".into() };
    let decoded = Zeroizing::new(
        base64::engine::general_purpose::STANDARD.decode(value).map_err(|_| invalid())?,
    );
    let mut bytes = Zeroizing::new([0u8; 32]);
    if decoded.len() != bytes.len() {
        return Err(invalid());
    }
    bytes.copy_from_slice(&decoded);
    Ok(bytes)
}

fn split_prefix(value: &str, key: &'static str) -> Result<(IpAddr, Option<u8>), ConfigError> {
    let invalid = |detail: String| ConfigError::InvalidValue { key, detail };
    match value.split_once('/') {
        Some((address, prefix)) => {
            let address = address
                .parse::<IpAddr>()
                .map_err(|_| invalid(format!("{value} is not an IP address")))?;
            let prefix = prefix
                .parse::<u8>()
                .ok()
                .filter(|prefix| *prefix <= if address.is_ipv4() { 32 } else { 128 })
                .ok_or_else(|| invalid(format!("{value} has an invalid prefix length")))?;
            Ok((address, Some(prefix)))
        }
        None => {
            let address = value
                .parse::<IpAddr>()
                .map_err(|_| invalid(format!("{value} is not an IP address")))?;
            Ok((address, None))
        }
    }
}

fn parse_interface_address(value: &str) -> Result<InterfaceAddress, ConfigError> {
    let (address, prefix) = split_prefix(value, "Address")?;
    let prefix = prefix.unwrap_or(if address.is_ipv4() { 32 } else { 128 });
    Ok(InterfaceAddress { address, prefix })
}

fn parse_allowed_network(value: &str) -> Result<IpNetwork, ConfigError> {
    let (address, prefix) = split_prefix(value, "AllowedIPs")?;
    let prefix = prefix.unwrap_or(if address.is_ipv4() { 32 } else { 128 });
    // `wg` truncates host bits of an allowed network the same way.
    IpNetwork::new_truncate(address, prefix).map_err(|_| ConfigError::InvalidValue {
        key: "AllowedIPs",
        detail: format!("{value} has an invalid prefix length"),
    })
}

fn parse_endpoint(value: &str) -> Result<Endpoint, ConfigError> {
    let invalid =
        || ConfigError::InvalidValue { key: "Endpoint", detail: format!("{value} is not host:port") };
    if let Some(rest) = value.strip_prefix('[') {
        let (host, port) = rest.split_once("]:").ok_or_else(invalid)?;
        let port = port.parse::<u16>().map_err(|_| invalid())?;
        if host.is_empty() {
            return Err(invalid());
        }
        return Ok(Endpoint { host: host.to_owned(), port });
    }
    let (host, port) = value.rsplit_once(':').ok_or_else(invalid)?;
    if host.is_empty() || host.contains(':') {
        return Err(invalid());
    }
    let port = port.parse::<u16>().map_err(|_| invalid())?;
    Ok(Endpoint { host: host.to_owned(), port })
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY_A: &str = "GDYq0RJ4LWL6jJhLMAlM1oHcCTdSiXPMZ4X5D8WzGdw=";
    const KEY_B: &str = "Bo2I0OcpKnXtElGwH6EXV3MwDQctaIrFJ4tDX44DoWs=";

    fn freestyle_shaped() -> String {
        format!(
            "[Interface]\nPrivateKey = {KEY_A}\nAddress = 100.64.0.1/32\nAddress = fd7a:7570:6c6b::1/128\nMTU = 1200\nDNS = 10.0.0.53\n\n[Peer]\nPublicKey = {KEY_B}\nAllowedIPs = 10.0.0.0/8, fd00::/8\nEndpoint = [2606:4700::1]:51820\nPersistentKeepalive = 25\n"
        )
    }

    #[test]
    fn parses_a_freestyle_shaped_config() {
        let config = WgConfig::parse_wg_quick(&freestyle_shaped()).unwrap();
        assert_eq!(config.mtu, 1200);
        assert_eq!(config.addresses.len(), 2);
        assert_eq!(config.addresses[0].to_string(), "100.64.0.1/32");
        assert_eq!(config.addresses[1].to_string(), "fd7a:7570:6c6b::1/128");
        assert_eq!(config.allowed_ips.len(), 2);
        assert_eq!(config.allowed_ips[0].to_string(), "10.0.0.0/8");
        assert_eq!(config.allowed_ips[1].to_string(), "fd00::/8");
        assert_eq!(config.endpoint, Some(Endpoint { host: "2606:4700::1".into(), port: 51820 }));
        assert_eq!(config.endpoint.as_ref().unwrap().to_string(), "[2606:4700::1]:51820");
        assert_eq!(config.persistent_keepalive, Some(25));
        assert!(config.preshared_key.is_none());
        assert!(config.routes_contain("10.100.0.10".parse().unwrap()));
        assert!(config.routes_contain("fd12::1".parse().unwrap()));
        assert!(!config.routes_contain("192.168.1.1".parse().unwrap()));
        assert_eq!(
            config.local_address_for("10.100.0.10".parse().unwrap()),
            Some("100.64.0.1".parse().unwrap())
        );
        assert_eq!(
            config.local_address_for("fd12::1".parse().unwrap()),
            Some("fd7a:7570:6c6b::1".parse().unwrap())
        );
    }

    #[test]
    fn debug_output_omits_the_private_key() {
        let config = WgConfig::parse_wg_quick(&freestyle_shaped()).unwrap();
        let debug = format!("{config:?}");
        assert!(!debug.contains(KEY_A));
        assert!(debug.contains(KEY_B));
    }

    #[test]
    fn hostname_endpoints_and_comma_lists_parse() {
        let text = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/24, fdaa::2/64 # tunnel\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.7/24\nEndpoint=vpn.example.com:51820\n"
        );
        let config = WgConfig::parse_wg_quick(&text).unwrap();
        assert_eq!(config.mtu, DEFAULT_MTU);
        assert_eq!(config.endpoint.as_ref().unwrap().to_string(), "vpn.example.com:51820");
        // Interface addresses keep their host bits; allowed networks drop them.
        assert_eq!(config.addresses[0].to_string(), "10.1.0.2/24");
        assert_eq!(config.addresses[1].to_string(), "fdaa::2/64");
        assert_eq!(config.allowed_ips[0].to_string(), "10.1.0.0/24");
        assert_eq!(
            config.local_address_for("10.1.0.9".parse().unwrap()),
            Some("10.1.0.2".parse().unwrap())
        );
    }

    #[test]
    fn a_bare_address_is_a_host() {
        let text = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.9\n"
        );
        let config = WgConfig::parse_wg_quick(&text).unwrap();
        assert_eq!(config.addresses[0].to_string(), "10.1.0.2/32");
        assert_eq!(config.allowed_ips[0].to_string(), "10.1.0.9/32");
        assert!(config.endpoint.is_none());
    }

    #[test]
    fn rejects_missing_and_malformed_fields() {
        let missing_key = format!(
            "[Interface]\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
        );
        assert_eq!(
            WgConfig::parse_wg_quick(&missing_key).unwrap_err(),
            ConfigError::MissingPrivateKey
        );

        let bad_key = format!(
            "[Interface]\nPrivateKey=short\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
        );
        let error = WgConfig::parse_wg_quick(&bad_key).unwrap_err();
        assert!(matches!(error, ConfigError::InvalidValue { key: "PrivateKey", .. }));
        assert!(!error.to_string().contains("short"));

        let two_peers = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.2.0.0/24\n"
        );
        assert_eq!(WgConfig::parse_wg_quick(&two_peers).unwrap_err(), ConfigError::MultiplePeers);

        let small_mtu = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\nMTU=100\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
        );
        assert!(matches!(
            WgConfig::parse_wg_quick(&small_mtu),
            Err(ConfigError::InvalidValue { key: "MTU", .. })
        ));

        let bad_endpoint = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\nEndpoint=fd00::1:51820\n"
        );
        assert!(matches!(
            WgConfig::parse_wg_quick(&bad_endpoint),
            Err(ConfigError::InvalidValue { key: "Endpoint", .. })
        ));

        let bad_prefix = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/40\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
        );
        assert!(matches!(
            WgConfig::parse_wg_quick(&bad_prefix),
            Err(ConfigError::InvalidValue { key: "Address", .. })
        ));

        let stray = format!("PrivateKey={KEY_A}\n");
        assert_eq!(WgConfig::parse_wg_quick(&stray).unwrap_err(), ConfigError::MalformedLine(1));

        let three_addresses = format!(
            "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32, 10.1.0.3/32, 10.1.0.4/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
        );
        assert_eq!(
            WgConfig::parse_wg_quick(&three_addresses).unwrap_err(),
            ConfigError::TooManyAddresses { maximum: 2 }
        );
    }
}
