use std::net::IpAddr;

use serde_json::json;

use super::model::{self, Kind, Role, Sources, State, Via};
use super::network::{
    self, Choice, DeviceNetwork, NetworkKind, NetworkNode, NetworkStatus, TailscaleNetwork,
    WeftNetwork,
};
use super::removal;

fn tailscale_up() -> NetworkStatus {
    NetworkStatus {
        kind: NetworkKind::Tailscale,
        up: true,
        this: Some("lawrence-mbp".into()),
        detail: None,
    }
}

fn ip(text: &str) -> IpAddr {
    text.parse().unwrap()
}

fn nodes() -> Vec<NetworkNode> {
    vec![
        NetworkNode {
            name: "mini-7".into(),
            dns_name: "mini-7.tail1234.ts.net".into(),
            ips: vec![ip("100.70.0.7")],
            os: "macOS".into(),
            online: true,
            mine: true,
        },
        NetworkNode {
            name: "build-box".into(),
            dns_name: "build-box.tail1234.ts.net".into(),
            ips: vec![ip("100.70.0.9")],
            os: "linux".into(),
            online: true,
            mine: false,
        },
        NetworkNode {
            name: "old-air".into(),
            dns_name: "old-air.tail1234.ts.net".into(),
            ips: vec![ip("100.70.0.3")],
            os: "macOS".into(),
            online: false,
            mine: true,
        },
        NetworkNode {
            name: "lawrence-iphone".into(),
            dns_name: "lawrence-iphone.tail1234.ts.net".into(),
            ips: vec![ip("100.70.0.4")],
            os: "iOS".into(),
            online: true,
            mine: true,
        },
    ]
}

fn sources() -> Sources {
    Sources {
        peers: json!({"peers": [
            {"name": "mini-7", "url": "ssh://mini-7.tail1234.ts.net", "state": "connected", "connected": true},
            {"name": "vm-1", "url": "ssh://agent@10.0.4.2", "state": "down", "connected": false,
             "error": "ssh: connect to host 10.0.4.2 port 22: Operation timed out"},
            {"name": "sandbox", "url": "ws://127.0.0.1:47811", "state": "connected", "connected": true}
        ]}),
        pairing: json!({
            "tickets": [
                {"id": "tk_open", "role": "client", "label": "Leo's laptop", "state": "open",
                 "created_at": "2026-10-22T07:00:00Z", "expires_at": "2026-10-22T07:15:00Z"},
                {"id": "tk_used", "role": "daemon", "label": null, "state": "used",
                 "created_at": "2026-10-22T06:00:00Z", "expires_at": "2026-10-22T06:15:00Z"},
                {"id": "tk_gone", "role": "client", "label": null, "state": "expired",
                 "created_at": "2026-10-21T06:00:00Z", "expires_at": "2026-10-21T06:15:00Z"}
            ],
            "devices": [
                {"id": "dv_sandbox", "name": "sandbox", "role": "daemon",
                 "created_at": "2026-10-22T06:01:00Z", "ticket_id": "tk_used", "revoked_at": null, "connections": 1},
                {"id": "dv_leo", "name": "leo-mbp", "role": "client",
                 "created_at": "2026-10-20T06:01:00Z", "ticket_id": null, "revoked_at": null, "connections": 0},
                {"id": "dv_watch", "name": "wall-tv", "role": "read-only",
                 "created_at": "2026-10-20T06:01:00Z", "ticket_id": null, "revoked_at": null, "connections": 2},
                {"id": "dv_old", "name": "old-box", "role": "client",
                 "created_at": "2026-10-01T06:01:00Z", "ticket_id": null, "revoked_at": "2026-10-02T00:00:00Z", "connections": 0}
            ]
        }),
        remote: json!({
            "enabled": true,
            "owner": "lawrence@manaflow.ai",
            "allow": ["austin@manaflow.ai"],
            "grants": [
                {"login": "lawrence@manaflow.ai", "scopes": ["status"], "consented_at": "2026-10-20T00:00:00Z", "revoked_at": null},
                {"login": "old@manaflow.ai", "scopes": ["shell"], "consented_at": "2026-10-01T00:00:00Z", "revoked_at": "2026-10-02T00:00:00Z"},
                {"login": "new@manaflow.ai", "scopes": ["shell"], "consented_at": null, "revoked_at": null}
            ]
        }),
    }
}

fn listing() -> model::Listing {
    model::merge(&sources(), tailscale_up(), &nodes())
}

fn device<'a>(listing: &'a model::Listing, id: &str) -> &'a model::Device {
    listing
        .devices
        .iter()
        .find(|d| d.id == id)
        .unwrap_or_else(|| panic!("no device {id} in {:#?}", listing.devices))
}

#[test]
fn a_peer_on_the_network_is_one_connected_computer_that_runs_agents() {
    let listing = listing();
    let mini = device(&listing, "peer:mini-7");
    assert_eq!(mini.name, "mini-7");
    assert_eq!(mini.kind, Kind::Computer);
    assert_eq!(mini.roles, vec![Role::RunsAgents]);
    assert_eq!(mini.state, State::Connected);
    assert_eq!(mini.os.as_deref(), Some("macOS"));
    let reach = mini.reach.as_ref().expect("reach");
    assert_eq!(reach.network, "tailscale");
    assert_eq!(reach.address, "mini-7.tail1234.ts.net");
    assert!(reach.online);
    assert_eq!(mini.via, vec![Via::Peer { name: "mini-7".into() }]);
}

#[test]
fn a_peer_that_cannot_connect_is_an_error_with_the_reason() {
    let listing = listing();
    let vm = device(&listing, "peer:vm-1");
    assert_eq!(vm.state, State::Error);
    assert!(vm.detail.as_deref().unwrap_or_default().contains("timed out"), "{vm:?}");
    assert!(vm.reach.is_none(), "10.0.4.2 is not on the tailnet: {vm:?}");
}

#[test]
fn a_daemon_pairing_and_its_peer_are_one_device_with_both_records() {
    let listing = listing();
    assert!(listing.devices.iter().all(|d| d.id != "paired:dv_sandbox"), "merged into the peer");
    let sandbox = device(&listing, "peer:sandbox");
    assert_eq!(
        sandbox.via,
        vec![Via::Peer { name: "sandbox".into() }, Via::Paired { id: "dv_sandbox".into() }]
    );
    assert_eq!(sandbox.added_at.as_deref(), Some("2026-10-22T06:01:00Z"));
}

#[test]
fn client_and_read_only_pairings_are_devices_that_use_or_watch_this_one() {
    let listing = listing();
    let leo = device(&listing, "paired:dv_leo");
    assert_eq!(leo.name, "leo-mbp");
    assert_eq!(leo.roles, vec![Role::UsesThis]);
    assert_eq!(leo.state, State::Offline);
    let tv = device(&listing, "paired:dv_watch");
    assert_eq!(tv.roles, vec![Role::WatchOnly]);
    assert_eq!(tv.state, State::Connected, "it has open connections");
}

#[test]
fn revoked_records_are_not_devices() {
    let listing = listing();
    assert!(
        listing.devices.iter().all(|d| d.id != "paired:dv_old" && d.id != "grant:old@manaflow.ai")
    );
}

#[test]
fn remote_hosting_logins_are_devices_that_use_this_one() {
    let listing = listing();
    let austin = device(&listing, "allow:austin@manaflow.ai");
    assert_eq!(austin.roles, vec![Role::UsesThis]);
    assert_eq!(austin.via, vec![Via::Allow { login: "austin@manaflow.ai".into() }]);
    let mine = device(&listing, "grant:lawrence@manaflow.ai");
    assert_eq!(mine.roles, vec![Role::WatchOnly], "a status-only grant watches");
    let pending = device(&listing, "grant:new@manaflow.ai");
    assert_eq!(pending.state, State::Pending);
    assert!(pending.detail.is_some());
}

#[test]
fn remote_hosting_that_is_off_lets_no_login_in() {
    let mut src = sources();
    src.remote["enabled"] = json!(false);
    let listing = model::merge(&src, tailscale_up(), &nodes());
    assert!(
        listing.devices.iter().all(|d| !d.id.starts_with("allow:") && !d.id.starts_with("grant:"))
    );
}

#[test]
fn available_lists_online_network_computers_that_are_not_devices_mine_first() {
    let listing = listing();
    let names: Vec<&str> = listing.available.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["build-box"],
        "mini-7 is a peer, old-air is offline, a phone is not a computer to enroll"
    );
    assert_eq!(listing.available[0].address, "build-box.tail1234.ts.net");
    let mut more = nodes();
    more.push(NetworkNode {
        name: "studio".into(),
        dns_name: "studio.tail1234.ts.net".into(),
        ips: vec![ip("100.70.0.11")],
        os: "macOS".into(),
        online: true,
        mine: true,
    });
    let listing = model::merge(&sources(), tailscale_up(), &more);
    let names: Vec<&str> = listing.available.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["studio", "build-box"]);
}

#[test]
fn open_tickets_are_invites_and_spent_ones_are_not() {
    let listing = listing();
    let ids: Vec<&str> = listing.invites.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, vec!["tk_open"]);
    assert_eq!(listing.invites[0].label.as_deref(), Some("Leo's laptop"));
}

#[test]
fn devices_sort_by_state_then_name() {
    let listing = listing();
    let ids: Vec<&str> = listing.devices.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(
        ids,
        vec![
            "grant:new@manaflow.ai",
            "peer:vm-1",
            "peer:mini-7",
            "peer:sandbox",
            "paired:dv_watch",
            "allow:austin@manaflow.ai",
            "grant:lawrence@manaflow.ai",
            "paired:dv_leo",
        ],
        "pending, then errors, then connected, then offline; by name inside each"
    );
}

#[test]
fn find_takes_an_id_a_name_or_a_network_address() {
    let listing = listing();
    assert_eq!(model::find(&listing, "peer:mini-7").map(|d| d.id.as_str()), Some("peer:mini-7"));
    assert_eq!(model::find(&listing, "MINI-7").map(|d| d.id.as_str()), Some("peer:mini-7"));
    assert_eq!(
        model::find(&listing, "mini-7.tail1234.ts.net").map(|d| d.id.as_str()),
        Some("peer:mini-7")
    );
    assert_eq!(model::find(&listing, "100.70.0.7").map(|d| d.id.as_str()), Some("peer:mini-7"));
    assert_eq!(model::find(&listing, "leo-mbp").map(|d| d.id.as_str()), Some("paired:dv_leo"));
    assert!(model::find(&listing, "nobody").is_none());
}

#[test]
fn remove_plan_revokes_credentials_before_peers_and_every_store() {
    let listing = listing();
    let steps = removal::plan(device(&listing, "peer:sandbox"));
    let args: Vec<Vec<&str>> =
        steps.iter().map(|s| s.args.iter().map(String::as_str).collect()).collect();
    assert_eq!(
        args,
        vec![
            vec!["acp", "host", "ticket", "revoke", "dv_sandbox", "--json"],
            vec!["acp", "host", "rm", "sandbox", "--json"],
        ]
    );
    assert!(steps.iter().all(|s| !s.what.is_empty()));
    let steps = removal::plan(device(&listing, "allow:austin@manaflow.ai"));
    assert_eq!(steps[0].args, vec!["host", "deny", "austin@manaflow.ai"]);
    let steps = removal::plan(device(&listing, "grant:lawrence@manaflow.ai"));
    assert_eq!(steps[0].args, vec!["host", "revoke", "lawrence@manaflow.ai", "--json"]);
}

#[test]
fn tailscale_reports_this_device_and_marks_my_nodes() {
    let raw = br#"{
      "BackendState": "Running",
      "Self": {"HostName": "Lawrence-MBP", "DNSName": "lawrence-mbp.tail1234.ts.net.", "OS": "macOS",
               "UserID": 1, "TailscaleIPs": ["100.70.0.1"], "Online": true},
      "Peer": {
        "a": {"HostName": "mini-7", "DNSName": "mini-7.tail1234.ts.net.", "OS": "macOS", "UserID": 1,
              "TailscaleIPs": ["100.70.0.7"], "Online": true},
        "b": {"HostName": "ci", "DNSName": "ci.tail1234.ts.net.", "OS": "linux", "UserID": 9,
              "Tags": ["tag:ci"], "TailscaleIPs": ["100.70.0.8"], "Online": true}
      },
      "User": {"1": {"ID": 1, "LoginName": "lawrence@manaflow.ai"}, "9": {"ID": 9, "LoginName": "tagged-devices"}}
    }"#;
    let status = acpmux::tailnet::parse_status(raw).expect("parses");
    let net = TailscaleNetwork::from_status(Ok(status));
    let status = net.status();
    assert_eq!(status.kind, NetworkKind::Tailscale);
    assert!(status.up);
    assert_eq!(status.this.as_deref(), Some("lawrence-mbp"));
    let mut nodes = net.nodes();
    nodes.sort_by(|a, b| a.name.cmp(&b.name));
    assert_eq!(nodes.len(), 2);
    assert_eq!((nodes[0].name.as_str(), nodes[0].mine), ("ci", false));
    assert_eq!((nodes[1].name.as_str(), nodes[1].mine), ("mini-7", true));
    assert_eq!(nodes[1].address(), "mini-7.tail1234.ts.net");
}

#[test]
fn no_tailscale_is_network_none_with_a_reason() {
    let net = TailscaleNetwork::from_status(Err("Tailscale is not installed".into()));
    let status = net.status();
    assert_eq!(status.kind, NetworkKind::None);
    assert!(!status.up);
    assert!(net.nodes().is_empty());
}

#[test]
fn auto_uses_weft_only_when_this_device_is_on_it() {
    let picked = network::pick(Choice::Auto, Box::new(WeftNetwork), || {
        Box::new(TailscaleNetwork::from_status(Err("x".into())))
    });
    assert_eq!(picked.status().kind, NetworkKind::None, "Weft is not up: Tailscale's answer");
    let picked = network::pick(Choice::Weft, Box::new(WeftNetwork), || unreachable!());
    assert_eq!(picked.status().kind, NetworkKind::Weft);
    assert_eq!(Choice::parse("Tailscale"), Some(Choice::Tailscale));
    assert_eq!(Choice::parse(""), Some(Choice::Auto));
    assert_eq!(Choice::parse("zerotier"), None);
}
