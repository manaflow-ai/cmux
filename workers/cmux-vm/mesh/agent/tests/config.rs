use std::net::Ipv4Addr;

use cmux_mesh_agent::api::{self, PeerMap};
use cmux_mesh_agent::config::{self, Cidr, DEFAULT_KEEPALIVE_SECONDS, DEFAULT_MTU};

const SERVER_KEY: &str = "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=";

fn tunnel_json(extra: &str) -> String {
    format!(
        r#"{{"id":"tun_1","meshId":"mesh_1","deviceId":"dev_1",
            "endpointHost":"tun-xyz.beta-vpn.freestyle.sh","endpointPort":51820,
            "serverPublicKey":"{SERVER_KEY}","allowedIps":["10.128.16.0/20"]{extra}}}"#
    )
}

#[test]
fn interface_address_with_prefix() {
    let tunnel =
        config::parse_tunnel(&tunnel_json(r#","interfaceAddress":"100.64.0.1/32""#)).unwrap();
    assert_eq!(
        tunnel.interface_address,
        Cidr { address: Ipv4Addr::new(100, 64, 0, 1), prefix: 32 }
    );
    let tunnel =
        config::parse_tunnel(&tunnel_json(r#","interfaceAddress":"100.64.0.9/24""#)).unwrap();
    assert_eq!(tunnel.interface_address.prefix, 24);
}

#[test]
fn interface_address_without_prefix_is_slash_32() {
    let tunnel = config::parse_tunnel(&tunnel_json(r#","interfaceAddress":"100.64.0.1""#)).unwrap();
    assert_eq!(
        tunnel.interface_address,
        Cidr { address: Ipv4Addr::new(100, 64, 0, 1), prefix: 32 }
    );
}

#[test]
fn bad_interface_address_is_rejected() {
    for bad in ["100.64.0.1/33", "fd00::1", "nope", "100.64.0.1/x"] {
        let json = tunnel_json(&format!(r#","interfaceAddress":"{bad}""#));
        assert!(config::parse_tunnel(&json).is_err(), "{bad} accepted");
    }
}

#[test]
fn mtu_and_keepalive_default_when_absent() {
    let tunnel = config::parse_tunnel(&tunnel_json(r#","interfaceAddress":"100.64.0.1""#)).unwrap();
    assert_eq!(DEFAULT_MTU, 1280);
    assert_eq!(DEFAULT_KEEPALIVE_SECONDS, 25);
    assert_eq!(tunnel.mtu, 1280);
    assert_eq!(tunnel.persistent_keepalive_seconds, 25);
    let tunnel = config::parse_tunnel(&tunnel_json(
        r#","interfaceAddress":"100.64.0.1","mtu":null,"persistentKeepaliveSeconds":null"#,
    ))
    .unwrap();
    assert_eq!((tunnel.mtu, tunnel.persistent_keepalive_seconds), (1280, 25));
}

#[test]
fn mtu_and_keepalive_from_config() {
    let tunnel = config::parse_tunnel(&tunnel_json(
        r#","interfaceAddress":"100.64.0.1","mtu":1400,"persistentKeepaliveSeconds":10"#,
    ))
    .unwrap();
    assert_eq!((tunnel.mtu, tunnel.persistent_keepalive_seconds), (1400, 10));
}

#[test]
fn zero_keepalive_still_keeps_alive() {
    let tunnel = config::parse_tunnel(&tunnel_json(
        r#","interfaceAddress":"100.64.0.1","persistentKeepaliveSeconds":0"#,
    ))
    .unwrap();
    assert_eq!(tunnel.persistent_keepalive_seconds, 25);
}

#[test]
fn unknown_fields_and_null_mesh_address() {
    let tunnel = config::parse_tunnel(&tunnel_json(
        r#","interfaceAddress":"100.64.0.1","meshAddress":null,"futureField":{"x":1}"#,
    ))
    .unwrap();
    assert_eq!(tunnel.mesh_address, None);
    let tunnel = config::parse_tunnel(&tunnel_json(
        r#","interfaceAddress":"100.64.0.1","meshAddress":"10.128.16.7""#,
    ))
    .unwrap();
    assert_eq!(tunnel.mesh_address, Some(Ipv4Addr::new(10, 128, 16, 7)));
    assert!(tunnel.routes_contain(Ipv4Addr::new(10, 128, 31, 255)));
    assert!(!tunnel.routes_contain(Ipv4Addr::new(10, 128, 32, 0)));
}

#[test]
fn enrollment_response_is_a_config() {
    let body = format!(
        r#"{{"device":{{"id":"dev_1","meshId":"mesh_1","name":"laptop","wgPublicKey":"{SERVER_KEY}",
            "tunnelId":"tun_1","createdAt":"2026-10-06T00:00:00Z"}},
            "tunnel":{}}}"#,
        tunnel_json(r#","interfaceAddress":"100.64.0.1/32""#)
    );
    let saved = config::parse_agent_config(&body).unwrap();
    assert_eq!(saved.device_id, "dev_1");
    assert_eq!(saved.mesh_id, "mesh_1");
    assert_eq!(saved.wg_public_key.as_deref(), Some(SERVER_KEY));
    assert_eq!(saved.tunnel.endpoint_port, 51820);
}

#[test]
fn bad_server_key_is_rejected() {
    let json = tunnel_json(r#","interfaceAddress":"100.64.0.1""#).replace(SERVER_KEY, "AAAA");
    assert!(config::parse_tunnel(&json).is_err());
}

#[test]
fn empty_allowed_ips_is_rejected() {
    let json =
        tunnel_json(r#","interfaceAddress":"100.64.0.1""#).replace(r#"["10.128.16.0/20"]"#, "[]");
    assert!(config::parse_tunnel(&json).is_err());
}

#[test]
fn api_url_rules() {
    assert_eq!(api::validate_base("https://vm.cmux.dev/").unwrap(), "https://vm.cmux.dev");
    assert!(api::validate_base("http://127.0.0.1:8787").is_ok());
    assert!(api::validate_base("http://localhost:8787/").is_ok());
    for bad in [
        "http://vm.cmux.dev",
        "http://127.0.0.1.evil.example",
        "http://user@127.0.0.1",
        "ftp://vm.cmux.dev",
        "vm.cmux.dev",
    ] {
        assert!(api::validate_base(bad).is_err(), "{bad} accepted");
    }
}

#[test]
fn ids_are_checked_before_they_go_in_a_path() {
    assert!(api::check_id("mesh_abc-1", "mesh_").is_ok());
    for bad in ["mesh_", "dev_abc", "mesh_../x", "mesh_a/b", "mesh_a?b"] {
        assert!(api::check_id(bad, "mesh_").is_err(), "{bad} accepted");
    }
}

#[test]
fn peers_resolve_vm_ids_and_addresses() {
    let map: PeerMap = api::parse_peers(
        r#"{"deviceId":"dev_1","meshId":"mesh_1","aclVersion":3,"peers":[
            {"kind":"vm","id":"vm_a","address":"10.128.16.5",
             "allow":[{"protocol":"tcp","port":8080},{"protocol":"icmp"},{"protocol":"any"}]}]}"#,
    )
    .unwrap();
    assert_eq!(map.acl_version, 3);
    assert_eq!(api::resolve_peer("vm_a", Some(&map)).unwrap(), Ipv4Addr::new(10, 128, 16, 5));
    assert_eq!(api::resolve_peer("10.128.16.9", None).unwrap(), Ipv4Addr::new(10, 128, 16, 9));
    assert!(api::resolve_peer("vm_missing", Some(&map)).is_err());
}

/// The Worker returns the mesh's IPv6 /64 in allowedIps too (the provider requires it on
/// the tunnel); this IPv4-only agent keeps the IPv4 ranges and ignores the IPv6 ones.
#[test]
fn ipv6_allowed_ips_are_ignored() {
    let json = format!(
        r#"{{"id":"tun_1","meshId":"mesh_1","deviceId":"dev_1",
            "endpointHost":"203.0.113.30","endpointPort":51820,"interfaceAddress":"100.64.0.1/32",
            "serverPublicKey":"{SERVER_KEY}","allowedIps":["10.128.16.0/20","fd3b:5c80:74b4::/64"]}}"#
    );
    let tunnel = config::parse_tunnel(&json).unwrap();
    assert!(tunnel.routes_contain(Ipv4Addr::new(10, 128, 16, 5)));
}

#[test]
fn enroll_codes_are_mec_and_26_lowercase_crockford_characters() {
    assert!(api::check_enroll_code("mec_0123456789abcdefghjkmnpqrs").is_ok());
    assert!(api::check_enroll_code("mec_tvwxyz0123456789abcdefghjk").is_ok());
    for bad in [
        "",
        "mec_",
        "mec_0123456789abcdefghjkmnpqr",
        "mec_0123456789abcdefghjkmnpqrst",
        "mec_0123456789ABCDEFGHJKMNPQRS",
        "mec_0123456789abcdefghjkmnpqri",
        "mec_0123456789abcdefghjkmnpqrl",
        "mec_0123456789abcdefghjkmnpqro",
        "mec_0123456789abcdefghjkmnpqru",
        "MEC_0123456789abcdefghjkmnpqrs",
        " mec_0123456789abcdefghjkmnpqrs",
    ] {
        let error = api::check_enroll_code(bad).expect_err(bad);
        assert_eq!(error.tag, "InvalidEnrollCode");
        if bad.len() > 4 {
            assert!(!error.message.contains(bad), "the error echoes the code");
        }
    }
}

#[test]
fn device_names_are_one_nonempty_line() {
    assert!(api::check_device_name("laptop 2").is_ok());
    for bad in ["", "lap\ntop", "lap\rtop"] {
        assert_eq!(api::check_device_name(bad).unwrap_err().tag, "InvalidName");
    }
}
