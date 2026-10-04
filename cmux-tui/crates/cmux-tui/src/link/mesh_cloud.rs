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

/// The tunnel config for `gateway` with this link's key, through the
/// wg-quick parser so every field gets the same checks as the hub's config.
pub(super) fn gateway_config(gateway: &Gateway, private_key: &[u8; 32]) -> io::Result<WgConfig> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_link::overlay_addr::overlay_address;

    fn info(gateway: bool, vpc: bool, public: bool) -> ConnectInfo {
        serde_json::from_value(serde_json::json!({
            "machine": "vm_1", "host": "host_a", "epoch": 1, "state": "running",
            "peer": {
                "wg_public_key": STANDARD.encode([1u8; 32]),
                "overlay_address": overlay_address("host_a").to_string(),
                "vpc_endpoint": vpc.then_some("[fd00::7]:4101"),
                "public_ipv6": public.then_some("2001:db8::7"),
            },
            "gateway": gateway.then(|| serde_json::json!({
                "tunnel_id": "tun_1", "endpoint": "198.51.100.4:51820",
                "server_public_key": STANDARD.encode([2u8; 32]),
                "client_address": "100.64.0.9/32", "allowed_ips": ["fd00::/64"]
            })),
            "services": ["daemon"], "revision": "1"
        }))
        .unwrap()
    }

    #[test]
    fn the_tunnel_wins_when_this_install_has_one_to_the_vpc() {
        let tunnel = choose_route(&info(true, true, true));
        assert!(matches!(tunnel, CloudRoute::Tunnel { vpc, .. } if vpc.port() == CLOUD_UDP_PORT));
        assert_eq!(
            choose_route(&info(false, true, true)),
            CloudRoute::Udp("[2001:db8::7]:4101".parse().unwrap())
        );
        assert_eq!(
            choose_route(&info(true, false, false)),
            CloudRoute::None,
            "a gateway without a VPC endpoint is no route"
        );
        assert_eq!(choose_route(&info(false, true, false)), CloudRoute::Udp("[fd00::7]:4101".parse().unwrap()));
        assert_eq!(choose_route(&info(false, false, false)), CloudRoute::None);
    }

    #[test]
    fn the_gateway_config_goes_through_the_wg_quick_checks() {
        let CloudRoute::Tunnel { gateway, .. } = choose_route(&info(true, true, false)) else {
            panic!("expected the tunnel route");
        };
        let config = gateway_config(&gateway, &[3u8; 32]).unwrap();
        assert_eq!(config.mtu, TUNNEL_MTU);
        assert_eq!(config.peer_public_key, [2u8; 32]);
        assert_eq!(config.allowed_ips.len(), 1);
        let mut broken = gateway;
        broken.server_public_key = "not a key".into();
        assert!(gateway_config(&broken, &[3u8; 32]).is_err());
    }
}
