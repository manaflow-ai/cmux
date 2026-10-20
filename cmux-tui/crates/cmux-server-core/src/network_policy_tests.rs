use super::*;
use serde_json::json;

fn body() -> Value {
    let mut point = [0u8; 65];
    point[0] = 4;
    let mut peer_point = point;
    peer_point[1] = 1;
    json!({"schema_version":1,"host":"host_00000000000000000001","team":"team_00000000000000000001",
        "user":"user_00000000000000000001","install":"inst_00000000000000000001",
        "origin":"https://native.example.test","tenant":"native_team","mesh":"mesh_00000000000000000000000000","device":"dev_00000000000000000000000000",
        "wg_public_key":STANDARD.encode([1u8;32]),"install_public_key":STANDARD.encode(point),"authority_version":"a".repeat(64),
        "checked_at":1000,"expires_at":31000,"acl_version":1,"policy_digest":"b".repeat(64),
        "peers":[{"host":"host_00000000000000000002","user":"user_00000000000000000002","install":"inst_00000000000000000002",
            "device":"dev_00000000000000000000000001","wg_public_key":STANDARD.encode([2u8;32]),"install_public_key":STANDARD.encode(peer_point),
            "authority_version":"c".repeat(64),"inbound":[{"protocol":"tcp","port":22}],"outbound":[]}]})
}
fn parse(value: &Value) -> Result<HostNetworkPolicy, &'static str> {
    HostNetworkPolicy::parse(
        value,
        &Expected {
            host: "host_00000000000000000001",
            user: "user_00000000000000000001",
            install: "inst_00000000000000000001",
            team: "team_00000000000000000001",
        },
    )
}
#[test]
fn host_network_policy_retains_directed_identity_and_drops_unknown_private_fields() {
    let mut value = body();
    value["accountCredential"] = "secret".into();
    let parsed = parse(&value).unwrap();
    assert_eq!(parsed.lifetime_ms(), 30_000);
    assert_eq!(parsed.peers[0].inbound[0].port, Some(22));
    assert!(parsed.peers[0].outbound.is_empty());
    assert!(!serde_json::to_string(&parsed).unwrap().contains("secret"));
}
#[test]
fn host_network_policy_refuses_cross_scope_and_extended_lifetimes() {
    for (path, value) in [
        ("/host", json!("host_00000000000000000002")),
        ("/team", json!("team_00000000000000000002")),
        ("/user", json!("user_00000000000000000002")),
        ("/install", json!("inst_00000000000000000002")),
        ("/schema_version", json!(2)),
        ("/expires_at", json!(31001)),
        ("/expires_at", json!(1000)),
        ("/checked_at", json!(0)),
    ] {
        let mut input = body();
        *input.pointer_mut(path).unwrap() = value;
        assert!(parse(&input).is_err(), "accepted {path}");
    }
}
#[test]
fn host_network_policy_refuses_ambiguous_peer_or_self_keys() {
    for key in ["host", "install", "device", "wg_public_key", "install_public_key"] {
        let mut input = body();
        input["peers"][0][key] = input[key].clone();
        assert!(parse(&input).is_err(), "accepted self {key}");
        let mut input = body();
        let copy = input["peers"][0].clone();
        input["peers"].as_array_mut().unwrap().push(copy);
        assert!(parse(&input).is_err(), "accepted duplicate {key}");
    }
}
#[test]
fn host_network_policy_refuses_unsupported_ports_and_protocols() {
    for rule in [
        json!({"protocol":"tcp","port":0}),
        json!({"protocol":"tcp","port":65536}),
        json!({"protocol":"any","port":22}),
        json!({"protocol":"icmp","port":22}),
        json!({"protocol":"ssh"}),
        json!({"protocol":"tcp","owner_session":true}),
    ] {
        let mut input = body();
        input["peers"][0]["inbound"] = json!([rule]);
        assert!(parse(&input).is_err());
    }
}
