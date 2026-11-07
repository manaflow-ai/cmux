//! The small models' readers.

use serde_json::json;

use super::*;

#[test]
fn a_directory_entry_defaults_its_kind_and_keeps_its_facts() {
    let entries = read(
        "file_entries",
        &json!({"entries": [
            {"name": "a.txt", "size": 12, "mode": 420, "modifiedAt": 1_700_000_000_000_i64},
            {"name": "src", "kind": "directory"},
        ]}),
    )
    .unwrap();
    assert_eq!(
        entries[0],
        json!({"name": "a.txt", "kind": "file", "size": 12, "mode": 420, "modifiedAt": 1_700_000_000_000.0})
    );
    assert_eq!(
        entries[1],
        json!({"name": "src", "kind": "directory", "size": null, "mode": null, "modifiedAt": null})
    );
    assert!(read("file_entry", &json!({"kind": "file"})).is_err(), "a name is required");
    assert!(read("file_entry", &json!({"name": "a", "size": "big"})).is_err());
    assert!(read("file_entries", &json!({})).is_err());
}

#[test]
fn a_stat_reads_its_kind_or_the_directory_flag() {
    assert_eq!(
        read("file_stat", &json!({"path": "/x", "isDirectory": true})).unwrap()["kind"],
        "directory"
    );
    assert_eq!(read("file_stat", &json!({"isDirectory": false})).unwrap()["kind"], "file");
    assert_eq!(read("file_stat", &json!({})).unwrap()["kind"], "file");
    assert_eq!(
        read("file_stat", &json!({"kind": "symlink", "isDirectory": true})).unwrap()["kind"],
        "symlink"
    );
}

#[test]
fn file_contents_take_either_spelling() {
    assert_eq!(
        read("file_contents", &json!({"dataBase64": "aGk=", "size": 2})).unwrap()["dataBase64"],
        "aGk="
    );
    assert_eq!(read("file_contents", &json!({"data": "aGk="})).unwrap()["dataBase64"], "aGk=");
    assert!(read("file_contents", &json!({"path": "/x"})).is_err());
}

#[test]
fn an_exec_result_defaults_what_is_missing() {
    assert_eq!(
        read("exec_result", &json!({})).unwrap(),
        json!({"exitCode": -1, "stdout": "", "stderr": ""})
    );
    assert_eq!(
        read("exec_result", &json!({"exitCode": 0, "stdout": "ok"})).unwrap()["stdout"],
        "ok"
    );
    assert!(read("exec_result", &json!({"exitCode": "0"})).is_err());
}

#[test]
fn an_scp_route_reads_camel_or_snake_case() {
    let later = 4_000_000_000_i64;
    let camel = json!({"host": "h", "port": 22, "username": "cmux", "hostPublicKey": "ssh-ed25519 A", "expiresAtUnix": later});
    let snake = json!({"host": "h", "port": 22, "username": "cmux", "host_public_key": "ssh-ed25519 A", "expires_at_unix": later});
    assert_eq!(read("scp_endpoint", &camel).unwrap(), read("scp_endpoint", &snake).unwrap());
    assert!(read("scp_endpoint", &json!({"host": "h", "port": 22, "username": "cmux"})).is_err());
}

/// Only a safe route is read: each unsafe field alone refuses it.
#[test]
fn an_unsafe_scp_route_is_refused() {
    let now = 1_800_000_000;
    let safe = json!({"host": "h", "port": 22, "username": "cmux", "hostPublicKey": "ssh-ed25519 A", "expiresAtUnix": now + 60});
    assert!(scp_endpoint_at(&safe, now).is_ok());
    for (key, value) in [
        ("port", json!(2222)),
        ("username", json!("root")),
        ("hostPublicKey", json!("ssh-rsa A")),
        ("hostPublicKey", json!("ssh-ed25519")),
        ("expiresAtUnix", json!(now)),
        ("expiresAtUnix", json!(now - 1)),
    ] {
        let mut unsafe_route = safe.clone();
        unsafe_route[key] = value.clone();
        assert!(scp_endpoint_at(&unsafe_route, now).is_err(), "{key} = {value} was read");
    }
}

/// The server-shaped models read through `read` and refuse a field of the wrong type.
#[test]
fn every_server_shaped_model_reads() {
    let cases = [
        ("machine_stats", json!({"state": "running", "cpus": 2})),
        ("network", json!({"id": "n1", "scope": "team"})),
        (
            "firewall_rule",
            json!({"id": "r1", "action": "allow", "source": {"cidr": "10.0.0.0/8"}, "destination": {"port": 22, "protocol": "tcp"}}),
        ),
        (
            "firewall_rules",
            json!({"rules": [{"id": "r1", "action": "deny", "source": {}, "destination": {}}]}),
        ),
        ("tunnel_network_mutation", json!({"tunnelId": "t1", "networkId": "n1"})),
        ("publication", json!({"id": "p1", "protocol": "http", "port": 3000})),
        ("domain", json!({"id": "d1", "hostname": "a.example", "publications": [{"id": "p1"}]})),
        (
            "machine_previews",
            json!({"machine": "vm_1", "previews": [], "listening": [3000], "unavailable": []}),
        ),
        ("preview_share_link_revocation", json!({"revoked": true})),
    ];
    for (kind, value) in cases {
        assert!(read(kind, &value).is_ok(), "{kind} did not read");
    }
    assert_eq!(read("publication", &json!({"protocol": "http"})).unwrap()["protocol"], "http");
    assert!(read("network", &json!({"id": 1, "scope": "team"})).is_err());
    assert!(read("preview_share_link_revocation", &json!({})).is_err());
}

#[test]
fn a_snapshot_id_is_snapshot_id_else_id() {
    assert_eq!(
        read("snapshot", &json!({"snapshotId": "s1", "id": "x", "name": "n"})).unwrap(),
        json!({"id": "s1", "name": "n"})
    );
    assert_eq!(
        read("snapshots", &json!({"snapshots": [{"id": "s2"}]})).unwrap(),
        json!([{"id": "s2", "name": null}])
    );
    assert!(read("snapshot", &json!({"name": "n"})).is_err());
}

#[test]
fn machines_read_through_their_shape() {
    assert_eq!(read("machine_classic", &json!({"id": "vm-1"})).unwrap()["status"], "provisioning");
    assert_eq!(
        read("machine_next", &json!({"id": "vm_1", "status": "running"})).unwrap()["provider"],
        "cmux-next"
    );
    assert!(read("machine_next", &json!({})).is_err());
    assert!(read("nope", &json!({})).is_err());
}

#[test]
fn a_provisioned_api_answers_its_action_fields() {
    let api: ProvisionedApi = serde_json::from_value(json!({
        "url": "https://api.example.invalid", "token": "secret", "cookieName": "__Host-cmux-api-key",
        "cookie": "__Host-cmux-api-key=secret", "publication": {"id": "pub_1", "accessMode": "api_key", "protocol": "http"},
        "apiKey": {"id": "key_1", "hint": "cret"},
    }))
    .unwrap();
    assert_eq!(api.publication.protocol_name.as_deref(), Some("http"));
    let fields = provisioned_api_fields(&api);
    assert_eq!(fields.get("publication_id").map(String::as_str), Some("pub_1"));
    assert_eq!(fields.get("access").map(String::as_str), Some("api_key"));
    assert_eq!(fields.get("key").map(String::as_str), Some("secret"));
    let mut bare = api.clone();
    bare.publication = Publication::default();
    assert_eq!(
        provisioned_api_fields(&bare).keys().copied().collect::<Vec<_>>(),
        ["api_key_id", "cookie", "key", "url"]
    );
}

#[test]
fn the_network_models_keep_the_servers_names() {
    let rule: FirewallRule = serde_json::from_value(json!({
        "id": "r1", "action": "allow", "source": {"vmId": "vm-1", "public": true, "protocol": "tcp", "port": 22},
        "destination": {"cidr": "10.0.0.0/8"},
    }))
    .unwrap();
    assert_eq!(rule.source.is_public, Some(true));
    assert_eq!(serde_json::to_value(&rule).unwrap()["source"]["protocol"], "tcp");
    let network: Network =
        serde_json::from_value(json!({"id": "n1", "cidrV6": "fd00::/64", "scope": "team"}))
            .unwrap();
    assert_eq!(network.cidr_v6.as_deref(), Some("fd00::/64"));
    let mutation: TunnelNetworkMutation =
        serde_json::from_value(json!({"tunnelId": "t", "networkId": "n", "addressV4": "10.1.0.2"}))
            .unwrap();
    assert_eq!(mutation.address_v4.as_deref(), Some("10.1.0.2"));
    let previews: MachinePreviews = serde_json::from_value(json!({
        "machine": "vm-one", "listening": [22, 3000],
        "previews": [{"port": 3000, "url": "https://p.invalid/__cmux/open?token=t", "origin": "https://p.invalid", "expiresAt": 1}],
        "unavailable": [{"port": 22, "code": "machine.preview_internal_port"}],
    }))
    .unwrap();
    assert_eq!(previews.previews[0].port, 3000);
}
