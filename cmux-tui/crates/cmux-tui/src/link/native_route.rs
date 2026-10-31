//! A Native gateway belongs to the enrolled device and one confirmed mesh.

use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::connect_info::{ConnectInfo, Gateway};
use cmux_wg::IpNetwork;
use serde::Deserialize;

use super::mesh_cloud::{CLOUD_UDP_PORT, CloudRoute};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Tunnel {
    id: String,
    mesh_id: String,
    device_id: String,
    endpoint_host: String,
    endpoint_port: u16,
    server_public_key: String,
    interface_address: String,
    mesh_address: Option<String>,
    allowed_ips: Vec<String>,
    mtu: u16,
    persistent_keepalive_seconds: u16,
}

pub(super) struct NativeRoute {
    tenant: String,
    mesh: String,
    cidr: String,
    base: u32,
    own: Ipv4Addr,
    gateway: Gateway,
}

fn refused() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "cloud.native.route_refused")
}

impl NativeRoute {
    pub(super) fn new(
        tenant: String,
        mesh: String,
        device: &str,
        cidr: String,
        tunnel: Tunnel,
    ) -> io::Result<Self> {
        let base = mesh_base(&cidr).ok_or_else(refused)?;
        let own = tunnel
            .mesh_address
            .as_deref()
            .and_then(|value| mesh_host(value, base))
            .ok_or_else(refused)?;
        let interface = tunnel
            .interface_address
            .strip_suffix("/32")
            .and_then(|value| value.parse::<Ipv4Addr>().ok());
        if tenant.is_empty()
            || tenant.len() > 128
            || !tenant.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            || tunnel.mesh_id != mesh
            || tunnel.device_id != device
            || !super::native_broker::native_id(&mesh, "mesh_")
            || !super::native_broker::native_id(device, "dev_")
            || !super::native_broker::native_id(&tunnel.id, "tun_")
            || !endpoint_host(&tunnel.endpoint_host)
            || tunnel.endpoint_port == 0
            || tunnel.mtu != 1280
            || tunnel.persistent_keepalive_seconds != 25
            || interface.is_none_or(|ip| {
                !(ip.is_private()
                    || (u32::from(ip) >> 22 == u32::from(Ipv4Addr::new(100, 64, 0, 0)) >> 22))
                    || format!("{ip}/32") != tunnel.interface_address
            })
            || !STANDARD
                .decode(&tunnel.server_public_key)
                .is_ok_and(|bytes| bytes.len() == 32 && bytes.iter().any(|b| *b != 0))
            || tunnel.allowed_ips.is_empty()
            || tunnel.allowed_ips.len() > 32
            || !tunnel.allowed_ips.contains(&cidr)
            || tunnel
                .allowed_ips
                .iter()
                .any(|value| value.len() > 128 || value.parse::<IpNetwork>().is_err())
        {
            return Err(refused());
        }
        let endpoint = match tunnel.endpoint_host.parse::<IpAddr>() {
            Ok(IpAddr::V6(ip)) => format!("[{ip}]:{}", tunnel.endpoint_port),
            _ => format!("{}:{}", tunnel.endpoint_host, tunnel.endpoint_port),
        };
        let gateway = Gateway {
            tunnel_id: tunnel.id,
            endpoint,
            server_public_key: tunnel.server_public_key,
            client_address: tunnel.interface_address,
            // The provider also returns its VPC IPv6 routes. Cloud VM routing here
            // needs only the owner-confirmed IPv4 mesh; no extra route is installed.
            allowed_ips: vec![cidr.clone()],
        };
        Ok(Self { tenant, mesh, cidr, base, own, gateway })
    }

    pub(super) fn for_vm(&self, info: &ConnectInfo) -> io::Result<CloudRoute> {
        let network = info.network.as_ref().ok_or_else(refused)?;
        if network.tenant != self.tenant
            || network.mesh != self.mesh
            || network.ipv4_cidr != self.cidr
        {
            return Err(refused());
        }
        let address = network
            .ipv4
            .as_deref()
            .and_then(|value| mesh_host(value, self.base))
            .filter(|ip| *ip != self.own)
            .ok_or_else(refused)?;
        let vpc = SocketAddr::new(IpAddr::V4(address), CLOUD_UDP_PORT);
        if info.peer.public_ipv6.is_some()
            || info.peer.vpc_endpoint.is_some_and(|supplied| supplied != vpc)
            || info.gateway.as_ref().is_some_and(|supplied| supplied != &self.gateway)
        {
            return Err(refused());
        }
        Ok(CloudRoute::Tunnel { gateway: self.gateway.clone(), vpc })
    }
}

fn mesh_base(value: &str) -> Option<u32> {
    let ip = value.strip_suffix("/20")?.parse::<Ipv4Addr>().ok()?;
    let [a, b, c, d] = ip.octets();
    (a == 10 && b >= 128 && c % 16 == 0 && d == 0 && format!("{ip}/20") == value)
        .then_some(u32::from(ip))
}

fn mesh_host(value: &str, base: u32) -> Option<Ipv4Addr> {
    let ip = value.parse::<Ipv4Addr>().ok()?;
    let number = u32::from(ip);
    (ip.to_string() == value && number > base && number < base + 4095).then_some(ip)
}

fn endpoint_host(host: &str) -> bool {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return !ip.is_unspecified() && !ip.is_multicast();
    }
    !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 63
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

#[cfg(test)]
#[path = "native_route_tests.rs"]
mod tests;
