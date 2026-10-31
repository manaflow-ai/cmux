use super::*;
use cmux_link::overlay_addr::overlay_address;
use serde_json::{Value, json};

const MESH: &str = "mesh_00000000000000000000000000";
const DEVICE: &str = "dev_00000000000000000000000000";
const HOST: &str = "host_11111111111111111111";

fn tunnel() -> Value {
    json!({"id": "tun_00000000000000000000000000", "meshId": MESH, "deviceId": DEVICE,
        "endpointHost": "203.0.113.30", "endpointPort": 51820,
        "serverPublicKey": STANDARD.encode([3u8; 32]), "interfaceAddress": "100.64.0.1/32",
        "meshAddress": "10.128.0.10", "allowedIps": ["10.128.0.0/20", "fd00:1::/64"],
        "mtu": 1280, "persistentKeepaliveSeconds": 25})
}

fn route(config: Value) -> io::Result<NativeRoute> {
    NativeRoute::new(
        "tenant_a".into(),
        MESH.into(),
        DEVICE,
        "10.128.0.0/20".into(),
        serde_json::from_value(config).unwrap(),
    )
}

fn info() -> ConnectInfo {
    serde_json::from_value(json!({"machine": "vm_11111111111111111111", "host": HOST, "epoch": 1, "state": "running",
        "network": {"tenant": "tenant_a", "mesh": MESH, "ipv4_cidr": "10.128.0.0/20", "ipv4": "10.128.0.5"},
        "peer": {"wg_public_key": STANDARD.encode([4u8; 32]), "overlay_address": overlay_address(HOST).to_string()},
        "gateway": null, "services": ["ssh"], "revision": "1"})).unwrap()
}

#[test]
fn native_cloud_gateway_routes_only_the_confirmed_vm_using_its_own_tunnel() {
    let route = route(tunnel()).unwrap();
    let CloudRoute::Tunnel { gateway, vpc } = route.for_vm(&info()).unwrap() else {
        panic!("Native must use its own tunnel")
    };
    assert_eq!(vpc, "10.128.0.5:4101".parse().unwrap());
    assert_eq!(gateway.endpoint, "203.0.113.30:51820");
    assert_eq!(gateway.allowed_ips, ["10.128.0.0/20"]);
    let config = super::super::mesh_cloud::gateway_config(&gateway, &[7u8; 32]).unwrap();
    assert_eq!(config.mtu, 1280);
    assert_eq!(config.persistent_keepalive, Some(25));
    assert_eq!(config.allowed_ips.len(), 1);
    let mut ipv6 = tunnel();
    ipv6["endpointHost"] = json!("2001:db8::30");
    let route = self::route(ipv6).unwrap();
    assert!(super::super::mesh_cloud::gateway_config(&route.gateway, &[7u8; 32]).is_ok());
}

#[test]
fn native_cloud_gateway_refuses_cross_scope_or_ambiguous_vm_routing() {
    let route = route(tunnel()).unwrap();
    for (field, value) in [
        ("tenant", json!("tenant_other")),
        ("mesh", json!("mesh_11111111111111111111111111")),
        ("ipv4_cidr", json!("10.128.16.0/20")),
        ("ipv4", Value::Null),
        ("ipv4", json!("10.128.16.5")),
        ("ipv4", json!("127.0.0.1")),
        ("ipv4", json!("10.128.0.0")),
        ("ipv4", json!("10.128.15.255")),
        ("ipv4", json!("10.128.0.10")),
    ] {
        let mut bad = serde_json::to_value(info()).unwrap();
        bad["network"][field] = value;
        assert!(route.for_vm(&serde_json::from_value(bad).unwrap()).is_err(), "{field}");
    }
    let mut missing = info();
    missing.network = None;
    assert!(route.for_vm(&missing).is_err());
    let mut public = info();
    public.peer.public_ipv6 = Some("2001:db8::1".parse().unwrap());
    assert!(route.for_vm(&public).is_err(), "no public fallback");
    let mut different = info();
    different.peer.vpc_endpoint = Some("10.128.0.6:4101".parse().unwrap());
    assert!(route.for_vm(&different).is_err());
    let mut different = info();
    different.gateway =
        Some(Gateway { endpoint: "198.51.100.1:51820".into(), ..route.gateway.clone() });
    assert!(route.for_vm(&different).is_err(), "backend cannot choose another tunnel");
}

#[test]
fn native_cloud_gateway_refuses_changed_tunnel_identity_and_invalid_config() {
    for (field, value) in [
        ("meshId", json!("mesh_11111111111111111111111111")),
        ("deviceId", json!("dev_11111111111111111111111111")),
        ("id", json!("tun_bad")),
        ("endpointHost", json!("https://attacker.test")),
        ("endpointHost", json!("0.0.0.0")),
        ("endpointPort", json!(0)),
        ("serverPublicKey", json!(STANDARD.encode([0u8; 32]))),
        ("interfaceAddress", json!("100.64.0.1/32\nPrivateKey = bad")),
        ("interfaceAddress", json!("100.64.0.1/0")),
        ("interfaceAddress", json!("8.8.8.8/32")),
        ("meshAddress", json!("10.129.0.5")),
        ("meshAddress", Value::Null),
        ("allowedIps", json!(["0.0.0.0/0"])),
        ("mtu", json!(9000)),
        ("persistentKeepaliveSeconds", json!(0)),
    ] {
        let mut config = tunnel();
        config[field] = value;
        assert!(route(config).is_err(), "{field}");
    }
}
