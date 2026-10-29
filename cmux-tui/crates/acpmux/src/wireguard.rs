//! Labs-gated userspace WireGuard transport for acpmux peer streams.
//!
//! This is a thin acpmux seam over [`cmux_wg`]. `cmux-wg` uses boringtun's
//! sans-I/O WireGuard engine and smoltcp's userspace TCP stack, so the daemon
//! binds one UDP socket and never creates a TUN device, system route or root
//! requirement. Its `WgStream` implements Tokio's ordered, reliable stream
//! traits and can therefore carry the existing peer WebSocket protocol.
//!
//! Static peers are intentional in this first slice. Node-registry and
//! endpoint-discovery lanes can supply the peer key, allowed addresses and
//! endpoint later without changing this stream API.

use cmux_wg::{Endpoint, InterfaceAddress, IpNetwork, WgError, WgMesh, WgMeshConfig, WgPeer};
use std::net::{IpAddr, SocketAddr};
use zeroize::Zeroizing;

/// One static WireGuard peer. `allowed_ips` is both the route and the receive
/// source-address filter enforced by cmux-wg.
#[derive(Clone, Debug)]
pub struct StaticPeer {
    pub public_key: [u8; 32],
    pub endpoint: Endpoint,
    pub allowed_ips: Vec<IpNetwork>,
    pub persistent_keepalive: Option<u16>,
}

/// Inputs for one userspace mesh. The caller owns the node key and supplies
/// the overlay addresses assigned by the control plane.
#[derive(Clone, Debug)]
pub struct WireGuardTransportConfig {
    /// Labs switch. `false` returns before binding `listen`.
    pub enabled: bool,
    pub private_key: Zeroizing<[u8; 32]>,
    pub addresses: Vec<InterfaceAddress>,
    pub mtu: u16,
    pub listen: SocketAddr,
    pub peers: Vec<StaticPeer>,
}

/// The static peer URL accepted by the additive `wg://` peer transport.
///
/// The authority is the underlay endpoint (`wg://host:port`). Query values
/// are `key` (standard padded base64), `remote` (overlay `IP:port`), `local`
/// (this node's overlay IP), and optional `listen` (the local UDP port, zero
/// by default). The control-plane lanes can emit this URL without changing
/// the peer protocol; discovery and relay are deliberately outside this
/// first transport slice.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireGuardPeerSpec {
    pub key: [u8; 32],
    pub endpoint: Endpoint,
    pub remote: SocketAddr,
    pub local: IpAddr,
    pub listen: SocketAddr,
}

/// Parse one static `wg://` peer URL. Percent decoding preserves `+` in a
/// standard base64 key (form-urlencoding would incorrectly turn it into a
/// space), while still accepting the usual `%2B` and `%2F` spellings.
pub fn parse_peer_url(value: &str) -> Result<WireGuardPeerSpec, String> {
    let url = url::Url::parse(value).map_err(|_| "invalid WireGuard peer URL".to_owned())?;
    if url.scheme() != "wg"
        || url.username() != ""
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(
            "WireGuard peer URL must be wg://host:port with no credentials or fragment".to_owned()
        );
    }
    let host =
        url.host_str().ok_or_else(|| "WireGuard peer URL has no endpoint host".to_owned())?;
    let port = url.port().ok_or_else(|| "WireGuard peer URL has no endpoint port".to_owned())?;
    let mut key = None;
    let mut remote = None;
    let mut local = None;
    let mut listen = 0u16;
    for pair in url.query().unwrap_or_default().split('&').filter(|pair| !pair.is_empty()) {
        let (raw_name, raw_value) = pair
            .split_once('=')
            .ok_or_else(|| "WireGuard peer URL has a malformed query".to_owned())?;
        let name = percent_decode(raw_name)?;
        let value = percent_decode(raw_value)?;
        match name.as_str() {
            "key" => key = Some(decode_public_key(&value)?),
            "remote" => {
                remote = Some(
                    value
                        .parse::<SocketAddr>()
                        .map_err(|_| "WireGuard remote must be IP:port".to_owned())?,
                )
            }
            "local" => {
                local = Some(
                    value
                        .parse::<IpAddr>()
                        .map_err(|_| "WireGuard local must be an IP address".to_owned())?,
                )
            }
            "listen" => {
                listen = value
                    .parse::<u16>()
                    .map_err(|_| "WireGuard listen must be a port".to_owned())?
            }
            _ => return Err(format!("unknown WireGuard peer URL query field {name}")),
        }
    }
    let key = key.ok_or_else(|| "WireGuard peer URL has no key".to_owned())?;
    let remote = remote.ok_or_else(|| "WireGuard peer URL has no remote".to_owned())?;
    let local = local.ok_or_else(|| "WireGuard peer URL has no local".to_owned())?;
    Ok(WireGuardPeerSpec {
        key,
        endpoint: Endpoint { host: host.to_owned(), port },
        remote,
        local,
        listen: SocketAddr::new(
            if host.contains(':') { "[::]" } else { "0.0.0.0" }.parse().unwrap(),
            listen,
        ),
    })
}

fn percent_decode(value: &str) -> Result<String, String> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut chars = value.as_bytes().iter().copied();
    while let Some(byte) = chars.next() {
        if byte != b'%' {
            bytes.push(byte);
            continue;
        }
        let hi = chars.next().ok_or_else(|| "invalid percent escape".to_owned())?;
        let lo = chars.next().ok_or_else(|| "invalid percent escape".to_owned())?;
        let digit = |byte| match byte {
            b'0'..=b'9' => Some(byte - b'0'),
            b'a'..=b'f' => Some(byte - b'a' + 10),
            b'A'..=b'F' => Some(byte - b'A' + 10),
            _ => None,
        };
        bytes.push(
            digit(hi)
                .zip(digit(lo))
                .map(|(hi, lo)| hi * 16 + lo)
                .ok_or_else(|| "invalid percent escape".to_owned())?,
        );
    }
    String::from_utf8(bytes).map_err(|_| "WireGuard URL query is not UTF-8".to_owned())
}

/// A running userspace WireGuard mesh. Dropping it shuts down its driver and
/// closes all streams; no operating-system network state is changed.
pub struct WireGuardTransport {
    mesh: WgMesh,
}

impl std::fmt::Debug for WireGuardTransport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("WireGuardTransport").field("mesh", &self.mesh).finish()
    }
}

impl WireGuardTransport {
    /// Start a transport when Labs is enabled. The disabled path performs no
    /// socket bind, which keeps existing peer behaviour byte-for-byte intact.
    pub async fn start(config: WireGuardTransportConfig) -> Result<Option<Self>, WgError> {
        if !config.enabled {
            return Ok(None);
        }
        let socket = tokio::net::UdpSocket::bind(config.listen).await?;
        let mesh = WgMesh::start(
            WgMeshConfig {
                private_key: config.private_key,
                addresses: config.addresses,
                mtu: config.mtu,
            },
            socket,
        )?;
        let transport = Self { mesh };
        for peer in config.peers {
            let endpoint = peer.endpoint.resolve().await.map_err(WgError::Io)?;
            let route = endpoint
                .first()
                .copied()
                .ok_or_else(|| WgError::EndpointUnresolved(peer.endpoint.host.clone()))?;
            transport
                .mesh
                .add_peer(WgPeer {
                    public_key: peer.public_key,
                    preshared_key: None,
                    allowed_ips: peer.allowed_ips,
                    route: Some(route.into()),
                    persistent_keepalive: peer.persistent_keepalive,
                })
                .await?;
        }
        Ok(Some(transport))
    }

    /// The UDP address selected by the userspace socket.
    pub fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.mesh.local_addr()
    }

    /// Open an ordered reliable stream to an overlay address and port.
    pub async fn connect(&self, remote: SocketAddr) -> Result<cmux_wg::WgStream, WgError> {
        self.mesh.connect(remote).await
    }

    /// Listen for streams from any configured peer on an overlay port.
    pub async fn listen(&self, port: u16) -> Result<cmux_wg::WgMeshListener, WgError> {
        self.mesh.listen(port).await
    }

    /// Stop the driver and reset open streams.
    pub async fn shutdown(self) {
        self.mesh.shutdown().await;
    }
}

/// Parse a standard padded WireGuard public key. Platform join and registry
/// payloads use exactly this encoding and must decode to 32 bytes.
pub fn decode_public_key(value: &str) -> Result<[u8; 32], String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| "wg public key is not standard base64".to_owned())?;
    bytes.try_into().map_err(|_| "wg public key must decode to 32 bytes".to_owned())
}

/// Make a one-address `/32` or `/128` route for a static peer.
pub fn host_route(address: IpAddr) -> IpNetwork {
    let prefix = if address.is_ipv4() { 32 } else { 128 };
    IpNetwork::new(address, prefix).expect("host address is a valid network")
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_wg::testing::random_keypair;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn address(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn config(
        private: [u8; 32],
        address: IpAddr,
        peer_public: [u8; 32],
        peer_address: IpAddr,
        endpoint: SocketAddr,
        enabled: bool,
    ) -> WireGuardTransportConfig {
        WireGuardTransportConfig {
            enabled,
            private_key: Zeroizing::new(private),
            addresses: vec![InterfaceAddress {
                address,
                prefix: if address.is_ipv4() { 32 } else { 128 },
            }],
            mtu: 1200,
            listen: "127.0.0.1:0".parse().unwrap(),
            peers: vec![StaticPeer {
                public_key: peer_public,
                endpoint: Endpoint { host: endpoint.ip().to_string(), port: endpoint.port() },
                allowed_ips: vec![host_route(peer_address)],
                persistent_keepalive: Some(1),
            }],
        }
    }

    #[tokio::test]
    async fn disabled_does_not_bind_and_enabled_round_trips_a_stream() {
        let (a_private, a_public) = random_keypair();
        let (b_private, b_public) = random_keypair();
        let disabled = WireGuardTransport::start(config(
            a_private,
            address("10.200.0.1"),
            b_public,
            address("10.200.0.2"),
            "127.0.0.1:9".parse().unwrap(),
            false,
        ))
        .await
        .unwrap();
        assert!(disabled.is_none(), "Labs-off transport must not bind UDP");

        // Bind each underlay first so the static endpoint can be filled in.
        let a_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let a_endpoint = b_socket.local_addr().unwrap();
        let b_endpoint = a_socket.local_addr().unwrap();
        drop(a_socket);
        drop(b_socket);
        // `start` owns its UDP socket; use a fresh pair of known addresses by
        // constructing the transports after binding their real sockets below.
        let a_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let a_bind = a_socket.local_addr().unwrap();
        let b_bind = b_socket.local_addr().unwrap();
        let a = WireGuardTransport {
            mesh: WgMesh::start(
                WgMeshConfig {
                    private_key: Zeroizing::new(a_private),
                    addresses: vec![InterfaceAddress {
                        address: address("10.200.0.1"),
                        prefix: 32,
                    }],
                    mtu: 1200,
                },
                a_socket,
            )
            .unwrap(),
        };
        let b = WireGuardTransport {
            mesh: WgMesh::start(
                WgMeshConfig {
                    private_key: Zeroizing::new(b_private),
                    addresses: vec![InterfaceAddress {
                        address: address("10.200.0.2"),
                        prefix: 32,
                    }],
                    mtu: 1200,
                },
                b_socket,
            )
            .unwrap(),
        };
        a.mesh
            .add_peer(WgPeer {
                public_key: b_public,
                preshared_key: None,
                allowed_ips: vec![host_route(address("10.200.0.2"))],
                route: Some(b_bind.into()),
                persistent_keepalive: Some(1),
            })
            .await
            .unwrap();
        b.mesh
            .add_peer(WgPeer {
                public_key: a_public,
                preshared_key: None,
                allowed_ips: vec![host_route(address("10.200.0.1"))],
                route: Some(a_bind.into()),
                persistent_keepalive: Some(1),
            })
            .await
            .unwrap();
        let mut listener = b.listen(1337).await.unwrap();
        let accept = tokio::spawn(async move {
            let (mut stream, key) = listener.accept().await.unwrap();
            assert_eq!(key, a_public);
            let mut input = [0u8; 4];
            stream.read_exact(&mut input).await.unwrap();
            stream.write_all(&input).await.unwrap();
        });
        let mut stream = tokio::time::timeout(
            Duration::from_secs(5),
            a.connect(SocketAddr::new(address("10.200.0.2"), 1337)),
        )
        .await
        .unwrap()
        .unwrap();
        stream.write_all(b"mesh").await.unwrap();
        let mut output = [0u8; 4];
        stream.read_exact(&mut output).await.unwrap();
        assert_eq!(&output, b"mesh");
        accept.await.unwrap();
        a.shutdown().await;
        b.shutdown().await;
    }

    #[test]
    fn public_key_requires_padded_standard_base64_and_32_bytes() {
        let (_, key) = random_keypair();
        use base64::Engine;
        let encoded = base64::engine::general_purpose::STANDARD.encode(key);
        assert_eq!(decode_public_key(&encoded).unwrap(), key);
        assert!(decode_public_key("not-base64").is_err());
        assert!(decode_public_key("AQ==").is_err());
    }
}
