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
    /// The device's own mesh address, when the provider has attached it yet (cmux-vm sends null until then).
    own: Option<Ipv4Addr>,
    gateway: Gateway,
}

/// `step` names the check, never a value: the app shows the message in `link_route`.
fn refused(step: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, format!("cloud.native.route_refused: {step}"))
}

impl NativeRoute {
    pub(super) fn new(
        tenant: String,
        mesh: String,
        device: &str,
        cidr: String,
        tunnel: Tunnel,
    ) -> io::Result<Self> {
        let base = mesh_base(&cidr).ok_or_else(|| refused("ipv4_cidr"))?;
        let own = tunnel
            .mesh_address
            .as_deref()
            .map(|value| {
                mesh_host(value, base).ok_or_else(|| refused("meshAddress outside ipv4_cidr"))
            })
            .transpose()?;
        // The provider sends a bare address or `/32` (the cmux-vm mesh agent reads both).
        let interface = tunnel
            .interface_address
            .strip_suffix("/32")
            .unwrap_or(tunnel.interface_address.as_str())
            .parse::<Ipv4Addr>()
            .ok();
        let checks = [
            (
                "tenant",
                tenant.is_empty()
                    || tenant.len() > 128
                    || !tenant.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)),
            ),
            ("meshId", tunnel.mesh_id != mesh || !super::native_broker::native_id(&mesh, "mesh_")),
            (
                "deviceId",
                tunnel.device_id != device || !super::native_broker::native_id(device, "dev_"),
            ),
            ("id", !super::native_broker::native_id(&tunnel.id, "tun_")),
            ("endpointHost", !endpoint_host(&tunnel.endpoint_host)),
            ("endpointPort", tunnel.endpoint_port == 0),
            ("mtu", tunnel.mtu != 1280),
            ("persistentKeepaliveSeconds", tunnel.persistent_keepalive_seconds != 25),
            (
                "interfaceAddress",
                interface.is_none_or(|ip| {
                    !(ip.is_private()
                        || (u32::from(ip) >> 22 == u32::from(Ipv4Addr::new(100, 64, 0, 0)) >> 22))
                        || !(tunnel.interface_address == ip.to_string()
                            || tunnel.interface_address == format!("{ip}/32"))
                }),
            ),
            (
                "serverPublicKey",
                !STANDARD
                    .decode(&tunnel.server_public_key)
                    .is_ok_and(|bytes| bytes.len() == 32 && bytes.iter().any(|b| *b != 0)),
            ),
            (
                "allowedIps",
                tunnel.allowed_ips.is_empty()
                    || tunnel.allowed_ips.len() > 32
                    || tunnel
                        .allowed_ips
                        .iter()
                        .any(|value| value.len() > 128 || value.parse::<IpNetwork>().is_err()),
            ),
            ("allowedIps lacks ipv4_cidr", !tunnel.allowed_ips.contains(&cidr)),
        ];
        if let Some((step, _)) = checks.iter().find(|(_, failed)| *failed) {
            return Err(refused(step));
        }
        let endpoint = match tunnel.endpoint_host.parse::<IpAddr>() {
            Ok(IpAddr::V6(ip)) => format!("[{ip}]:{}", tunnel.endpoint_port),
            _ => format!("{}:{}", tunnel.endpoint_host, tunnel.endpoint_port),
        };
        let gateway = Gateway {
            tunnel_id: tunnel.id,
            endpoint,
            server_public_key: tunnel.server_public_key,
            client_address: format!("{}/32", interface.ok_or_else(|| refused("interfaceAddress"))?),
            // The provider also returns its VPC IPv6 routes. Cloud VM routing here
            // needs only the owner-confirmed IPv4 mesh; no extra route is installed.
            allowed_ips: vec![cidr.clone()],
        };
        Ok(Self { tenant, mesh, cidr, base, own, gateway })
    }

    pub(super) fn for_vm(&self, info: &ConnectInfo) -> io::Result<CloudRoute> {
        let network = info.network.as_ref().ok_or_else(|| refused("vm network missing"))?;
        if network.tenant != self.tenant
            || network.mesh != self.mesh
            || network.ipv4_cidr != self.cidr
        {
            return Err(refused("vm network scope"));
        }
        let address = network
            .ipv4
            .as_deref()
            .and_then(|value| mesh_host(value, self.base))
            .filter(|ip| Some(*ip) != self.own)
            .ok_or_else(|| refused("vm ipv4"))?;
        let vpc = SocketAddr::new(IpAddr::V4(address), CLOUD_UDP_PORT);
        if info.peer.public_ipv6.is_some()
            || info.peer.vpc_endpoint.is_some_and(|supplied| supplied != vpc)
            || info.gateway.as_ref().is_some_and(|supplied| supplied != &self.gateway)
        {
            return Err(refused("vm peer"));
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
