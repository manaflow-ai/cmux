//! Cloud VM endpoints in the link's mesh: which route connect_info offers,
//! and this install's Freestyle tunnel as a mesh gateway for the `tunnel`
//! path (cloud-client-contract.md 1.7; transport.md 3 and 6).

use std::io;
use std::net::{IpAddr, SocketAddr};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::connect_info::{ConnectInfo, Gateway};
use cmux_wg::{IpNetwork, WgConfig, WgNet};
use zeroize::Zeroizing;

/// The outer WireGuard port of Cloud VM endpoints (transport.md 3.1).
pub(super) const CLOUD_UDP_PORT: u16 = 4101;

/// The MTU of this install's Freestyle tunnel (transport.md 3.1, measured).
const TUNNEL_MTU: u16 = 1280;

/// The tunnel port the mesh's gateway datagrams use.
const GATEWAY_DATAGRAM_PORT: u16 = 4101;

/// How the link reaches a Cloud VM endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum CloudRoute {
    /// Through this install's Freestyle tunnel to the VM's VPC endpoint.
    Tunnel { gateway: Gateway, vpc: SocketAddr },
    /// Directly over UDP (the VM's public IPv6, or its VPC endpoint when this
    /// link is itself a VPC member).
    Udp(SocketAddr),
    /// No route this caller may use.
    None,
}

/// The route connect_info offers: the tunnel when this install has one to
/// the VM's VPC, else the VM's public IPv6, else its VPC endpoint.
pub(super) fn choose_route(info: &ConnectInfo) -> CloudRoute {
    match (&info.gateway, info.peer.vpc_endpoint, info.peer.public_ipv6) {
        (Some(gateway), Some(vpc), _) => CloudRoute::Tunnel { gateway: gateway.clone(), vpc },
        (_, _, Some(public)) => {
            CloudRoute::Udp(SocketAddr::new(IpAddr::V6(public), CLOUD_UDP_PORT))
        }
        (_, Some(vpc), _) => CloudRoute::Udp(vpc),
        _ => CloudRoute::None,
    }
}

/// The VM endpoint's networks: its overlay `/128`.
pub(super) fn cloud_networks(info: &ConnectInfo) -> io::Result<Vec<IpNetwork>> {
    Ok(vec![IpNetwork::new(IpAddr::V6(info.peer.overlay_address), 128).map_err(io::Error::other)?])
}

/// True when a backend string may go into a wg-quick line: no line breaks,
/// comments, sections or extra keys, and not empty.
fn plain_field(value: &str) -> bool {
    !value.is_empty() && !value.contains(['\r', '\n', '#', '[', ']', '='])
}

/// The tunnel config for `gateway` with this link's key, through the
/// wg-quick parser so every field gets the same checks as the hub's config.
pub(super) fn gateway_config(gateway: &Gateway, private_key: &[u8; 32]) -> io::Result<WgConfig> {
    let fields = [&gateway.client_address, &gateway.endpoint];
    let key_ok = STANDARD.decode(&gateway.server_public_key).is_ok_and(|bytes| bytes.len() == 32);
    if !key_ok || !fields.into_iter().chain(&gateway.allowed_ips).all(|value| plain_field(value)) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "a tunnel field is not valid"));
    }
    let text = Zeroizing::new(format!(
        "[Interface]\nPrivateKey = {}\nAddress = {}\nMTU = {TUNNEL_MTU}\n\n[Peer]\nPublicKey = {}\nAllowedIPs = {}\nEndpoint = {}\nPersistentKeepalive = 25\n",
        Zeroizing::new(STANDARD.encode(private_key)).as_str(),
        gateway.client_address,
        gateway.server_public_key,
        gateway.allowed_ips.join(", "),
        gateway.endpoint,
    ));
    WgConfig::parse_wg_quick(&text).map_err(|error| io::Error::other(error.to_string()))
}

/// Start this install's tunnel to `gateway` and bind the datagram socket the
/// mesh sends nested WireGuard through.
pub(super) async fn start_gateway(
    gateway: &Gateway,
    private_key: &[u8; 32],
) -> io::Result<(WgNet, cmux_wg::WgDatagramSocket)> {
    let net = WgNet::start_with_new_socket(gateway_config(gateway, private_key)?)
        .await
        .map_err(io::Error::other)?;
    let socket = net.bind_datagram(GATEWAY_DATAGRAM_PORT).await.map_err(io::Error::other)?;
    Ok((net, socket))
}
