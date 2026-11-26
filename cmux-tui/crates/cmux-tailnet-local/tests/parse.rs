//! Fixture parsing and path classification.

use std::net::{IpAddr, SocketAddr};

use cmux_tailnet_local::{
    ControlKind, PeerPath, Source, is_tailnet_ip, parse_prefs_control, parse_profile, parse_status,
};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

fn ip(s: &str) -> IpAddr {
    s.parse().unwrap()
}

#[test]
fn self_and_tailnet_are_read() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    assert!(view.running());
    assert_eq!(view.this.dns_name, "laptop.example-tailnet.ts.net");
    assert_eq!(view.this.ips, vec![ip("100.64.0.1"), ip("fd7a:115c:a1e0::1")]);
    assert_eq!(view.this.user_id, 1001);
    let tailnet = view.tailnet.as_ref().unwrap();
    assert_eq!(tailnet.name, "alice@example.com");
    assert_eq!(tailnet.magic_dns_suffix, "example-tailnet.ts.net");
    assert!(tailnet.magic_dns_enabled);
    assert_eq!(view.control, ControlKind::Unknown);
    assert_eq!(view.peers.len(), 8);
    // Own address is not a peer.
    assert_eq!(view.path_hint(ip("100.64.0.1")), None);
}

#[test]
fn cur_addr_is_direct_on_v4_and_v6() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    let endpoint: SocketAddr = "192.0.2.10:41641".parse().unwrap();
    assert_eq!(view.path_hint(ip("100.64.0.2")), Some(PeerPath::Direct { endpoint }));
    // Every Tailscale address of the peer maps to it.
    assert_eq!(view.path_hint(ip("fd7a:115c:a1e0::2")), Some(PeerPath::Direct { endpoint }));
    let endpoint: SocketAddr = "[2001:db8::8]:41641".parse().unwrap();
    assert_eq!(view.path_hint(ip("100.64.0.8")), Some(PeerPath::Direct { endpoint }));
    let desk = view.peer_by_name("desk").unwrap();
    assert_eq!(desk.last_handshake.as_deref(), Some("2026-11-24T12:00:00.123456789Z"));
    assert!(desk.path.is_direct());
}

#[test]
fn active_without_cur_addr_rides_derp() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    let hint = view.path_hint(ip("100.64.0.3")).unwrap();
    assert_eq!(hint, PeerPath::Derp { region: "ord".into() });
    assert!(hint.is_relayed());
    assert!(!hint.is_direct());
}

#[test]
fn relay_alone_is_the_home_region_not_derp() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    assert_eq!(
        view.path_hint(ip("100.64.0.4")),
        Some(PeerPath::Idle { home_region: Some("dfw".into()) })
    );
    let peer = view.peer(ip("100.64.0.4")).unwrap();
    assert_eq!(peer.tags, vec!["tag:ci".to_owned()]);
    assert_eq!(peer.last_handshake, None, "Go's zero time reads as none");
}

#[test]
fn offline_peer() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    assert_eq!(view.path_hint(ip("100.64.0.7")), Some(PeerPath::Offline));
    assert!(!view.peer(ip("100.64.0.7")).unwrap().online);
}

#[test]
fn exit_node_in_use() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    let exit = view.exit_node.as_ref().unwrap();
    assert_eq!(exit.id, "nEXIT000CNTRL");
    assert!(exit.online);
    let peer = view.peer(ip("100.64.0.5")).unwrap();
    assert!(peer.exit_node && peer.exit_node_option);
    assert!(peer.path.is_direct());
    assert!(peer.allowed_ips.iter().any(|a| a == "0.0.0.0/0"));
}

#[test]
fn subnet_router_over_peer_relay() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    let peer = view.peer(ip("100.64.0.6")).unwrap();
    assert!(peer.is_subnet_router());
    assert_eq!(peer.primary_routes, vec!["10.20.0.0/16".to_owned()]);
    assert_eq!(peer.path, PeerPath::PeerRelay { relay: "203.0.113.9:7777:vni:42".into() });
    assert_eq!(peer.path.kind(), "peer-relay");
    // A subnet address is not a peer's own address: no hint.
    assert_eq!(view.path_hint(ip("10.20.1.1")), None);
}

#[test]
fn shared_node() {
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    let peer = view.peer(ip("100.64.0.9")).unwrap();
    assert!(peer.sharee_node);
    assert_eq!(peer.dns_name, "friends-server.other-tailnet.ts.net");
    assert!(!view.peer(ip("100.64.0.2")).unwrap().sharee_node);
}

#[test]
fn stopped_backend_gives_no_hints() {
    let view = parse_status(&fixture("status_stopped.json"), Source::Cli).unwrap();
    assert!(!view.running());
    assert!(view.peers.is_empty());
    assert_eq!(view.path_hint(ip("100.64.0.2")), None);
    // Status from a running node with the backend reported stopped also hides hints.
    let mut running = parse_status(&fixture("status_mixed.json"), Source::Supplied).unwrap();
    running.backend_state = "Stopped".into();
    assert_eq!(running.path_hint(ip("100.64.0.2")), None);
}

#[test]
fn old_status_without_online_is_unknown() {
    let view = parse_status(&fixture("status_old_no_online.json"), Source::Cli).unwrap();
    assert_eq!(view.path_hint(ip("100.64.0.2")), Some(PeerPath::Unknown));
}

#[test]
fn control_url_kinds() {
    assert_eq!(
        parse_prefs_control(&fixture("prefs_saas.json")).unwrap(),
        ControlKind::TailscaleSaas
    );
    assert_eq!(
        parse_prefs_control(&fixture("prefs_headscale.json")).unwrap(),
        ControlKind::SelfHosted { url: "https://headscale.example.org:8443".into() }
    );
    assert_eq!(ControlKind::from_url("https://login.tailscale.com"), ControlKind::TailscaleSaas);
    assert_eq!(ControlKind::from_url(""), ControlKind::Unknown);
    assert!(matches!(
        ControlKind::from_url("https://tailscale.com.evil.example"),
        ControlKind::SelfHosted { .. }
    ));
}

#[test]
fn profile_fills_control_when_prefs_are_denied() {
    let profile = parse_profile(&fixture("profile_current.json")).unwrap();
    assert_eq!(profile.name, "alice@example.com");
    assert_eq!(profile.tailnet, "alice@example.com");
    let view = parse_status(&fixture("status_mixed.json"), Source::Supplied)
        .unwrap()
        .with_extras(ControlKind::Unknown, Some(profile));
    assert_eq!(
        view.control,
        ControlKind::SelfHosted { url: "https://headscale.example.org:8443".into() }
    );
}

#[test]
fn garbage_is_a_parse_error() {
    assert!(parse_status(b"not json", Source::Supplied).is_err());
}

#[test]
fn tailnet_ranges() {
    assert!(is_tailnet_ip(ip("100.64.0.1")));
    assert!(is_tailnet_ip(ip("100.127.255.255")));
    assert!(!is_tailnet_ip(ip("100.128.0.1")));
    assert!(!is_tailnet_ip(ip("100.63.0.1")));
    assert!(is_tailnet_ip(ip("fd7a:115c:a1e0:ab12::1")));
    assert!(!is_tailnet_ip(ip("fd7a:115c:a1e1::1")));
}
