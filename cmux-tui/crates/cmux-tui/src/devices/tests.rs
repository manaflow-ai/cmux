use std::net::IpAddr;

use serde_json::{Value, json};

use super::model::{self, Kind, Role, Sources, State, Via};
use super::network::{
    self, Choice, DeviceNetwork, NetworkKind, NetworkNode, NetworkStatus, TailscaleNetwork,
    WeftNetwork,
};
use super::removal;
use crate::machine_runtime::SshConfigHost;

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
                 "created_at": "2026-10-20T06:01:00Z", "ticket_id": null, "revoked_at": null, "connections": 0,
                 "full_access": true},
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
        ssh_hosts: Vec::new(),
        joined: json!([
            {"kind": "joined", "id": "m_lane3", "name": "lane-vm-3", "state": "online",
             "platform": "linux", "createdAt": "2026-10-29T03:00:00Z"},
            {"kind": "joined", "id": "m_quiet", "name": "quiet-box", "state": "offline"},
            {"kind": "joined", "id": "m_gone", "name": "gone-box", "state": "revoked"}
        ]),
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
fn a_peer_down_for_days_is_offline_with_a_plain_detail_not_an_error() {
    // 2026-11-14: four lane VMs, retired and stopped for a week, sat at the top of a
    // dogfood list as "not working" with a retry countdown that never moved.
    let mut src = sources();
    src.peers["peers"].as_array_mut().unwrap().push(json!({
        "name": "retired-lane", "url": "ssh://retired-lane", "state": "reconnecting",
        "connected": false, "parked": true, "downSince": 1_794_064_328_690_u64,
        "nextRetryAt": 1_794_690_000_000_u64,
        "error": "peer unavailable; next automatic retry in 2519s"
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let lane = device(&listing, "peer:retired-lane");
    assert_eq!(lane.state, State::Offline, "{lane:?}");
    let detail = lane.detail.as_deref().unwrap_or_default();
    assert_eq!(detail, "Not reachable for over a day; tried again hourly.", "no frozen countdown");
    // The app's rows show `detail` too: a CLI command in it is a command they cannot run.
    assert!(!detail.contains("cmux device remove"), "{detail}");
    assert_eq!(serde_json::to_value(lane).unwrap()["parked"], true, "{lane:?}");
    assert_eq!(device(&listing, "peer:vm-1").state, State::Error, "a fresh failure stays an error");
}

#[test]
fn a_peer_parked_after_failing_for_a_day_keeps_its_last_error_in_the_detail() {
    // Offline hides a failure that lasted over a day (a dead key, a refused login): the reason
    // it failed stays readable beside "tried again hourly".
    let mut src = sources();
    src.peers["peers"].as_array_mut().unwrap().push(json!({
        "name": "old-box", "url": "ssh://old-box", "state": "reconnecting",
        "connected": false, "parked": true,
        "error": "ssh: Permission denied (publickey)"
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let old = device(&listing, "peer:old-box");
    assert_eq!(old.state, State::Offline, "{old:?}");
    assert_eq!(
        old.detail.as_deref(),
        Some(
            "Not reachable for over a day; tried again hourly. Last error: ssh: Permission denied (publickey)"
        ),
    );
    let fresh = device(&listing, "peer:vm-1");
    assert_eq!(serde_json::to_value(fresh).unwrap().get("parked"), None, "{fresh:?}");
}

#[test]
fn only_the_cli_says_how_to_remove_a_parked_peer() {
    let mut src = sources();
    src.peers["peers"].as_array_mut().unwrap().push(json!({
        "name": "retired-lane", "url": "ssh://retired-lane", "connected": false, "parked": true
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let line = super::cli_detail(device(&listing, "peer:retired-lane")).unwrap_or_default();
    assert!(line.ends_with("If it is gone for good: cmux device remove retired-lane"), "{line}");
    let failing = device(&listing, "peer:vm-1");
    assert_eq!(super::cli_detail(failing), failing.detail, "a failing peer prints its error as is");
}

#[test]
fn short_lived_pool_machines_fold_into_one_line_and_named_machines_stay() {
    let mut more = nodes();
    let node = |name: &str, n: u8| NetworkNode {
        name: name.into(),
        dns_name: format!("{name}.tail1234.ts.net"),
        ips: vec![ip(&format!("100.70.1.{n}"))],
        os: "linux".into(),
        online: true,
        mine: false,
    };
    more.push(node("ci-linux-pool-1114-162023-3fa17bde", 1));
    more.push(node("ci-linux-pool-1114-171948-3bede61c", 2));
    more.push(node("ci-linux-pool-1114-171948-8e3cefa4", 3));
    more.push(node("swarm-01", 4));
    more.push(node("swarm-02", 5));
    more.push(node("swarm-03", 6));
    more.push(node("release-20261114", 7));
    let listing = model::merge(&sources(), tailscale_up(), &more);
    let names: Vec<&str> = listing.available.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["build-box", "release-20261114", "swarm-01", "swarm-02", "swarm-03"]);
    assert_eq!(listing.pools.len(), 1, "{:?}", listing.pools);
    assert_eq!(listing.pools[0].stem, "ci-linux-pool");
    assert_eq!(listing.pools[0].count, 3);
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
    // Only a client machine has the Full-access setting.
    assert_eq!(leo.full_access, Some(true));
    assert_eq!(tv.full_access, None);
    assert_eq!(device(&listing, "peer:mini-7").full_access, None);
    let mut src = sources();
    src.pairing["devices"][1].as_object_mut().unwrap().remove("full_access");
    let older = model::merge(&src, tailscale_up(), &nodes());
    assert_eq!(device(&older, "paired:dv_leo").full_access, Some(false), "absent reads as off");
}

#[test]
fn a_phone_pairing_is_a_phone_row_with_the_setting() {
    let mut src = sources();
    src.pairing["devices"].as_array_mut().unwrap().push(json!({
        "id": "dv_phone", "name": "phone-6a7b", "role": "phone", "created_at": "2026-10-24T00:00:00Z",
        "revoked_at": null, "connections": 1, "full_access": true,
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let phone = device(&listing, "paired:dv_phone");
    assert_eq!((phone.kind, phone.full_access), (Kind::Phone, Some(true)));
    assert_eq!(phone.roles, vec![Role::UsesThis]);
    assert_eq!(phone.state, State::Connected);
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

/// hq#11835 row 12: on Leo's air-blue, cmux16 (a peer joined over the mesh, `url: null`) was
/// "connected" under Devices and again under "Not added yet" with a `cmux device add` line.
/// A record with no address takes its network node by name: a URL-less peer, a joined
/// machine and a paired computer each keep their node out of `available` and get its reach.
#[test]
fn a_device_with_no_address_takes_its_network_node_by_name() {
    let mut more = nodes();
    for name in ["mesh-mac", "lane-vm-3", "leo-mbp"] {
        more.push(NetworkNode {
            name: name.into(),
            dns_name: format!("{name}.tail1234.ts.net"),
            ips: vec![ip("100.70.0.20")],
            os: "linux".into(),
            online: true,
            mine: true,
        });
    }
    let mut src = sources();
    src.peers["peers"].as_array_mut().unwrap().push(json!({
        "name": "mesh-mac", "url": null, "state": "connected", "connected": true
    }));
    let listing = model::merge(&src, tailscale_up(), &more);
    let names: Vec<&str> = listing.available.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["build-box"], "{:#?}", listing.available);
    for (id, address) in [
        ("peer:mesh-mac", "mesh-mac.tail1234.ts.net"),
        ("joined:m_lane3", "lane-vm-3.tail1234.ts.net"),
        ("paired:dv_leo", "leo-mbp.tail1234.ts.net"),
    ] {
        let row = device(&listing, id);
        assert_eq!(row.reach.as_ref().map(|r| r.address.as_str()), Some(address), "{id}");
        assert_eq!(row.os.as_deref(), Some("linux"), "{id}");
    }
}

#[test]
fn ssh_config_hosts_follow_the_network_computers_without_repeats() {
    let mut src = sources();
    let host = |alias: &str, host_name: Option<&str>| SshConfigHost {
        alias: alias.to_owned(),
        host_name: host_name.map(str::to_owned),
    };
    src.ssh_hosts = vec![
        host("Zeta", None),
        host("github.com", None),
        host("vm-1", None),
        host("10.0.4.2", None),
        host("mini-7", None),
        host("build-box", None),
        host("old-air", None),
        host("alpha", Some("alpha.internal")),
        // Already a device (a paired one, by any case).
        host("Leo-MBP", None),
        host("sandbox", Some("127.0.0.1")),
        // Aliases of a forge, a peer's address and a tailnet node.
        host("gh", Some("github.com")),
        host("vm", Some("10.0.4.2")),
        host("studio-ts", Some("old-air.tail1234.ts.net")),
    ];
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let rows: Vec<(&str, model::Found)> =
        listing.available.iter().map(|a| (a.name.as_str(), a.found)).collect();
    assert_eq!(
        rows,
        vec![
            ("build-box", model::Found::Network),
            ("alpha", model::Found::SshConfig),
            ("Zeta", model::Found::SshConfig),
        ],
        "a device, a peer's name or host, a tailnet node (online or not) and a git forge are not offered again"
    );
    let alpha = &listing.available[1];
    assert_eq!((alpha.address.as_str(), alpha.os.as_str(), alpha.mine), ("alpha", "", true));
    let row = serde_json::to_value(alpha).unwrap();
    assert_eq!(row["found"], "ssh-config");

    // With no network at all, the ssh config still offers its hosts; with no
    // tailnet to say otherwise, an alias of a tailnet name is one of them.
    let listing = model::merge(&src, NetworkStatus::none("no tailscale"), &[]);
    let names: Vec<&str> = listing.available.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["alpha", "build-box", "old-air", "studio-ts", "Zeta"]);
}

/// hq#11835 row 3: `cmux device list` offered `cmux device add HOST.tailnet.ts.net --yes` for a
/// tailnet computer the person's ssh config already names, and that MagicDNS name failed `Host
/// key verification failed` (the config pins the key under its alias) while `cmux device add
/// HOST --yes` reached it. A computer an ssh alias names is offered by that alias.
#[test]
fn a_network_computer_the_ssh_config_names_is_offered_by_its_alias() {
    let host = |alias: &str, host_name: Option<&str>| SshConfigHost {
        alias: alias.to_owned(),
        host_name: host_name.map(str::to_owned),
    };
    let address = |hosts: Vec<SshConfigHost>| {
        let mut src = sources();
        src.ssh_hosts = hosts;
        let listing = model::merge(&src, tailscale_up(), &nodes());
        let row = listing.available.iter().find(|a| a.name == "build-box").cloned().unwrap();
        assert_eq!(row.found, model::Found::Network);
        row.address
    };
    // No alias: the MagicDNS name, as before.
    assert_eq!(address(Vec::new()), "build-box.tail1234.ts.net");
    // Its short name as a Host (HostKeyAlias and the rest under it).
    assert_eq!(address(vec![host("build-box", None)]), "build-box");
    // An alias whose HostName is its MagicDNS name, short name or address wins over its name.
    assert_eq!(
        address(vec![host("build-box", None), host("bb", Some("build-box.tail1234.ts.net"))]),
        "bb"
    );
    assert_eq!(address(vec![host("bb", Some("100.70.0.9"))]), "bb");
    assert_eq!(address(vec![host("BB", Some("Build-Box"))]), "BB");
    // An alias named as the node that goes elsewhere is not it.
    assert_eq!(address(vec![host("build-box", Some("10.9.9.9"))]), "build-box.tail1234.ts.net");
    // The printed command is the alias, a shell word.
    let mut src = sources();
    src.ssh_hosts = vec![host("build-box", None)];
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let row = serde_json::to_value(&listing.available[0]).unwrap();
    assert_eq!(
        (row["name"].as_str(), row["address"].as_str()),
        (Some("build-box"), Some("build-box"))
    );
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
            "joined:m_lane3",
            "peer:mini-7",
            "peer:sandbox",
            "paired:dv_watch",
            "allow:austin@manaflow.ai",
            "grant:lawrence@manaflow.ai",
            "paired:dv_leo",
            "joined:m_quiet",
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

#[test]
fn the_add_command_quotes_an_alias_a_shell_would_read() {
    assert_eq!(super::shell_word("build-box.tail1234.ts.net"), "build-box.tail1234.ts.net");
    assert_eq!(super::shell_word("leo@10.0.4.2"), "leo@10.0.4.2");
    assert_eq!(super::shell_word("foo$(touch /tmp/x)"), "'foo$(touch /tmp/x)'");
    assert_eq!(super::shell_word("a;b"), "'a;b'");
    assert_eq!(super::shell_word("it's"), "'it'\\''s'");
}

#[test]
fn a_joined_machine_is_a_computer_that_runs_agents_and_its_remove_revokes_it() {
    let listing = listing();
    let lane = device(&listing, "joined:m_lane3");
    assert_eq!(lane.name, "lane-vm-3");
    assert_eq!(lane.kind, Kind::Computer);
    assert_eq!(lane.roles, vec![Role::RunsAgents]);
    assert_eq!(lane.state, State::Connected);
    assert_eq!(lane.os.as_deref(), Some("linux"));
    assert_eq!(lane.added_at.as_deref(), Some("2026-10-29T03:00:00Z"));
    assert_eq!(lane.via, vec![Via::Joined { machine_id: "m_lane3".into() }]);
    assert_eq!(device(&listing, "joined:m_quiet").state, State::Offline);
    assert!(
        listing.devices.iter().all(|d| d.id != "joined:m_gone"),
        "a revoked machine is not a device"
    );
    assert_eq!(model::find(&listing, "lane-vm-3").map(|d| d.id.as_str()), Some("joined:m_lane3"));
    let steps = removal::plan(lane);
    assert_eq!(steps.len(), 1);
    assert_eq!(steps[0].args, vec!["machine", "revoke", "m_lane3", "--yes", "--json"]);
    assert!(steps[0].what.contains("lane-vm-3"), "{:?}", steps[0].what);
}

#[test]
fn no_joined_source_adds_no_rows() {
    let mut sources = sources();
    sources.joined = Value::Null;
    let listing = model::merge(&sources, tailscale_up(), &nodes());
    assert!(listing.devices.iter().all(|d| !d.id.starts_with("joined:")));
}

#[test]
fn jsonl_reads_as_json_and_quiet_is_taken_out() {
    let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        super::output_flags(&words(&["--jsonl", "x", "--quiet"])),
        (words(&["--json", "x"]), true)
    );
    assert_eq!(
        super::output_flags(&words(&["-q", "--", "--quiet"])),
        (words(&["--", "--quiet"]), true)
    );
    assert_eq!(super::output_flags(&words(&["--json"])), (words(&["--json"]), false));
}

#[test]
fn output_flags_may_come_before_device_or_the_verb() {
    let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    let args = |w: &[&str]| super::device_args(&words(w));
    assert_eq!(args(&["--json", "device", "list"]), Some(words(&["--json", "list"])));
    assert_eq!(args(&["device", "--jsonl", "-q", "ls"]), Some(words(&["--jsonl", "-q", "ls"])));
    assert_eq!(
        args(&["-q", "device", "remove", "x", "--yes"]),
        Some(words(&["-q", "remove", "x", "--yes"]))
    );
    assert_eq!(args(&["device"]), Some(vec![]));
    assert_eq!(
        args(&["device", "--json", "add", "h", "--yes"]),
        Some(words(&["--json", "add", "h", "--yes"]))
    );
    assert_eq!(
        args(&["device", "--json", "add", "h"]),
        None,
        "add without --yes is the app's card"
    );
    assert_eq!(args(&["--json", "machine", "list"]), None);
    assert_eq!(args(&["--socket", "s", "device", "list"]), None);
    assert_eq!(args(&["device", "--json", "nope"]), None);
    let split = |w: &[&str]| super::verb_and_args(&words(w));
    let (rest, quiet) = super::output_flags(&words(&["--jsonl", "-q", "ls", "--network", "weft"]));
    assert!(quiet);
    assert_eq!(
        super::verb_and_args(&rest),
        ("ls".to_owned(), words(&["--json", "--network", "weft"]))
    );
    assert_eq!(split(&["--json"]), ("help".to_owned(), words(&["--json"])));
    assert_eq!(split(&["remove", "x"]), ("remove".to_owned(), words(&["x"])));
}

/// A removed joined machine leaves the machine list; one that was only revoked stays.
#[test]
fn removed_joined_machines_leave_the_list_and_revoked_ones_stay() {
    use super::removed;
    let dir = tempfile::tempdir().unwrap();
    assert!(removed::ids_in(dir.path()).is_empty(), "no file: nothing hidden");
    removed::add_in(dir.path(), "m_1", 1).unwrap();
    removed::add_in(dir.path(), "m_1", 2).unwrap();
    let ids = removed::ids_in(dir.path());
    assert_eq!(ids.len(), 1, "recorded once");
    let rows = vec![
        json!({"kind": "joined", "id": "m_1", "name": "lane-vm-3", "state": "revoked"}),
        json!({"kind": "joined", "id": "m_2", "name": "build-box", "state": "revoked"}),
        json!({"kind": "joined", "name": "no id"}),
    ];
    let shown = removed::without(rows, &ids);
    let names: Vec<&str> = shown.iter().filter_map(|r| r["name"].as_str()).collect();
    assert_eq!(names, ["build-box", "no id"], "only the removed one leaves; a revoked one stays");
}

/// A removed-machines file that cannot be read hides nothing, and a removal refuses to write
/// over it (that would bring back every machine it hid).
#[test]
fn an_unreadable_removed_file_hides_nothing() {
    use super::removed;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(removed::FILE);
    std::fs::write(&path, b"{not json").unwrap();
    assert!(removed::ids_in(dir.path()).is_empty());
    assert!(removed::add_in(dir.path(), "m_9", 3).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json", "left as it was");
    std::fs::remove_file(&path).unwrap();
    removed::add_in(dir.path(), "m_9", 3).unwrap();
    assert!(removed::ids_in(dir.path()).contains("m_9"));
    assert!(!dir.path().join(format!("{}.{}.tmp", removed::FILE, std::process::id())).exists());
}

/// Removing a joined machine without a revoke needs the hub's own list to show it revoked: a
/// list that could not be read, or a machine still live or unknown, is never a quiet removal.
#[test]
fn only_a_machine_the_hub_lists_as_revoked_leaves_without_a_revoke() {
    use super::removed::listed_revoked;
    let rows = || {
        Some(Ok(vec![
            json!({"id": "m_gone", "state": "revoked"}),
            json!({"id": "m_live", "state": "online"}),
        ]))
    };
    assert!(listed_revoked(rows(), "m_gone").unwrap());
    assert!(!listed_revoked(rows(), "m_live").unwrap(), "a live machine is revoked first");
    assert!(!listed_revoked(rows(), "m_unknown").unwrap(), "an unknown id proves nothing");
    assert!(listed_revoked(Some(Err("hub down".into())), "m_gone").is_err(), "an unread list");
    assert!(listed_revoked(None, "m_gone").is_err(), "signed out");
}

/// Removals at once all stay recorded: the read, append and write hold the file's lock.
#[test]
fn removals_at_once_all_stay_recorded() {
    use super::removed;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    let threads: Vec<_> = (0..16)
        .map(|n| {
            let path = path.clone();
            std::thread::spawn(move || removed::add_in(&path, &format!("m_{n}"), n).unwrap())
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    assert_eq!(removed::ids_in(&path).len(), 16);
}

/// `cmux device --help` prints the device verbs (it fell through to the resource grammar), and
/// the usage names the verbs `device` runs as `machine …` and sends VMs to `cmux vm`
/// (cmuxterm-hq#7487 item 6). `device add` without `--yes` stays the app's Add Device card.
#[test]
fn device_help_names_every_device_verb_and_points_vms_at_vm() {
    let words = |w: &[&str]| w.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    for help in ["--help", "-h", "help"] {
        assert_eq!(super::device_args(&words(&["device", help])), Some(words(&[help])), "{help}");
        assert_eq!(super::verb_and_args(&words(&[help])).0, help);
    }
    assert_eq!(super::device_args(&words(&["device", "add", "studio"])), None);
    // hq#11835 row 13: `device SELECTOR show` reads the device list first; `--catalog` and the
    // other selector verbs stay the machine catalog's.
    assert_eq!(
        super::device_args(&words(&["device", "mac-mini", "show"])),
        Some(words(&["show", "mac-mini"]))
    );
    assert_eq!(
        super::device_args(&words(&["--json", "device", "mac-mini", "show"])),
        Some(words(&["--json", "show", "mac-mini"]))
    );
    assert_eq!(
        super::device_args(&words(&["device", "mac-mini", "show", "--json"])),
        Some(words(&["show", "mac-mini", "--json"]))
    );
    assert_eq!(super::device_args(&words(&["device", "mac-mini", "show", "--catalog"])), None);
    assert_eq!(super::device_args(&words(&["device", "mac-mini", "session"])), None);
    assert_eq!(super::device_args(&words(&["device", "revoke", "m_1"])), None);
    for verb in [
        "device list",
        "device add",
        "device invite",
        "device remove",
        "device setup",
        "device start",
        "SELECTOR show",
        "device revoke|rotate",
        "device doctor",
        "cmux vm --help",
        "`cmux machine` is the old name",
    ] {
        assert!(super::USAGE.contains(verb), "{verb} missing:\n{}", super::USAGE);
    }
}

/// Every row says what its device is, with the glyph its kind names: what a peer reported, the
/// source (a `ws://` peer is a Cloud machine), the OS, a phone pairing, else generic.
#[test]
fn every_row_carries_its_device_kind_and_glyph() {
    use cmux_device_kind::DeviceKind;
    let mut src = sources();
    src.peers["peers"][0]["health"] = json!({"os": "macos", "device": "mac-mini"});
    src.pairing["devices"].as_array_mut().unwrap().push(json!({
        "id": "dv_phone", "name": "phone-6a7b", "role": "phone", "created_at": "2026-10-24T00:00:00Z",
        "revoked_at": null, "connections": 1,
    }));
    src.pairing["devices"].as_array_mut().unwrap().push(json!({
        "id": "dv_tab", "name": "tab-1", "role": "phone", "created_at": "2026-10-24T00:00:00Z",
        "revoked_at": null, "connections": 0, "device": "ipad",
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    for (id, kind) in [
        ("peer:mini-7", DeviceKind::MacMini),
        ("peer:vm-1", DeviceKind::Generic),
        ("peer:sandbox", DeviceKind::Cloud),
        ("paired:dv_phone", DeviceKind::IPhone),
        ("paired:dv_tab", DeviceKind::IPad),
        ("paired:dv_leo", DeviceKind::Generic),
    ] {
        let row = device(&listing, id);
        assert_eq!((row.device, row.symbol), (kind, kind.symbol()), "{id}");
    }
    let wire = serde_json::to_value(device(&listing, "peer:mini-7")).unwrap();
    assert_eq!(
        (wire["device"].as_str(), wire["symbol"].as_str()),
        (Some("mac-mini"), Some("macmini"))
    );
    for row in &listing.devices {
        assert_eq!(row.symbol, row.device.symbol(), "{}", row.id);
    }
}

/// Leo, 2026-11-15: "and why dont' i see the other linked up vms and such? and [a Linux desktop]?" The
/// Screen Sharing page lists every linked machine, and each row says what its kind can do there:
/// a Mac or a Linux desktop is viewed through the device hub, a Cloud machine through its desktop,
/// and every other machine is listed with why it has nothing to press. Leo, 2026-11-15: "we do
/// have mac to windows and mac to linux and mac to mac on top of the other way around too right?"
#[test]
fn every_machine_says_what_the_screen_sharing_page_offers_for_it() {
    use cmux_device_kind::screen::{NoScreen, Screen, ScreenRoute};
    let mut src = sources();
    src.peers["peers"][0]["health"] = json!({"os": "macos", "device": "mac-mini"});
    src.peers["peers"][1]["health"] = json!({"os": "linux", "device": "linux-server"});
    let peers = src.peers["peers"].as_array_mut().unwrap();
    peers.push(json!({"name": "linux-desk", "url": "ssh://linux-desk", "connected": true,
                      "health": {"os": "linux", "device": "linux-desktop"}}));
    peers.push(
        json!({"name": "old-air", "url": "ssh://old-air.tail1234.ts.net", "connected": false}),
    );
    src.pairing["devices"].as_array_mut().unwrap().push(json!({
        "id": "dv_phone", "name": "phone-6a7b", "role": "phone", "created_at": "2026-10-24T00:00:00Z",
        "revoked_at": null, "connections": 1,
    }));
    let listing = model::merge(&src, tailscale_up(), &nodes());
    let view = |route| Some(Screen::View { route });
    let none = |reason| Some(Screen::None { reason });
    for (id, screen) in [
        ("peer:mini-7", view(ScreenRoute::Hub)),
        ("peer:sandbox", view(ScreenRoute::Cloud)),
        // A Mac that is not connected (its OS from the network, no health yet).
        ("peer:old-air", none(NoScreen::Offline)),
        ("peer:vm-1", none(NoScreen::NoDesktop)),
        // A Linux desktop is viewed through the device hub like a Mac (`cmux-rd linux-host`).
        ("peer:linux-desk", view(ScreenRoute::Hub)),
        // A joined Linux machine that reported no kind: desktop or server, nothing tells.
        ("joined:m_lane3", none(NoScreen::Unknown)),
        ("joined:m_quiet", none(NoScreen::Unknown)),
        ("paired:dv_phone", none(NoScreen::Phone)),
        ("paired:dv_leo", none(NoScreen::Unknown)),
        // A person's login is not a machine: the page leaves it out.
        ("allow:austin@manaflow.ai", None),
        ("grant:new@manaflow.ai", None),
    ] {
        assert_eq!(device(&listing, id).screen, screen, "{id}");
    }
    let wire = |id| serde_json::to_value(device(&listing, id)).unwrap()["screen"].clone();
    assert_eq!(wire("peer:mini-7"), json!({"action": "view", "route": "hub"}));
    assert_eq!(wire("peer:sandbox"), json!({"action": "view", "route": "cloud"}));
    assert_eq!(wire("peer:linux-desk"), json!({"action": "view", "route": "hub"}));
    assert_eq!(wire("peer:vm-1"), json!({"action": "none", "reason": "no-desktop"}));
    assert!(wire("allow:austin@manaflow.ai").is_null());
}

/// A machine reached only through the mesh hub (`via: "hub"`) has no ssh health: its kind and
/// its offer come from what the device hub says of it (`deviceHub`). Leo, 2026-11-21: "...plus
/// most of our vms (if we even have any lanes on freestyle vms yet!?) dont have screns..."
#[test]
fn a_hub_only_machine_reads_its_screen_from_the_device_hub() {
    use cmux_device_kind::DeviceKind;
    use cmux_device_kind::screen::{NoScreen, Screen, ScreenRoute};
    let hub_row = |name: &str, device_hub: Value| {
        let mut row = json!({"name": name, "connected": true, "state": "connected", "via": "hub",
                             "lastSeen": 1, "sessions": 0});
        if !device_hub.is_null() {
            row["deviceHub"] = device_hub;
        }
        row
    };
    let src = Sources {
        peers: json!({"peers": [
            hub_row("lane-desk", json!({"listed": true, "platform": "linux", "screenShared": true})),
            hub_row("lane-off", json!({"listed": true, "platform": "linux", "screenShared": false})),
            hub_row("lane-bare", json!({"listed": false})),
            hub_row("hub-mac", json!({"listed": true, "platform": "macos", "screenShared": false})),
            hub_row("lane-unread", Value::Null),
        ]}),
        ..Sources::default()
    };
    let listing = model::merge(&src, tailscale_up(), &[]);
    let view = |route| Some(Screen::View { route });
    let none = |reason| Some(Screen::None { reason });
    for (id, kind, screen) in [
        ("peer:lane-desk", DeviceKind::LinuxDesktop, view(ScreenRoute::Hub)),
        ("peer:lane-off", DeviceKind::Generic, none(NoScreen::SharingOff)),
        ("peer:lane-bare", DeviceKind::Generic, none(NoScreen::NoScreenHost)),
        ("peer:hub-mac", DeviceKind::Generic, view(ScreenRoute::Hub)),
        // No share host here read the hub's list: nothing tells.
        ("peer:lane-unread", DeviceKind::Generic, none(NoScreen::Unknown)),
    ] {
        let d = device(&listing, id);
        assert_eq!((d.device, d.screen), (kind, screen), "{id}");
    }
    assert_eq!(device(&listing, "peer:lane-off").os.as_deref(), Some("linux"));
    let wire = |id| serde_json::to_value(device(&listing, id)).unwrap()["screen"].clone();
    assert_eq!(wire("peer:lane-desk"), json!({"action": "view", "route": "hub"}));
    assert_eq!(wire("peer:lane-bare"), json!({"action": "none", "reason": "no-screen-host"}));
    // A hub-only machine that is down says so first.
    let mut down = src;
    down.peers["peers"][2]["connected"] = json!(false);
    let listing = model::merge(&down, tailscale_up(), &[]);
    assert_eq!(device(&listing, "peer:lane-bare").screen, none(NoScreen::Offline));
}

/// A Linux desktop reached over ssh (`linux-desktop` in its health) is shared through the screen
/// host the device hub lists for it: its row carries that host's hub id (what `macScreen.open
/// --device` opens), and with none listed it says so instead of a View that opens nothing.
/// 2026-11-23: a Linux desktop's row read "view" while `--device peer:NAME` named no device.
/// Leo, 2026-11-18: "i should be able to see into any connected mac or linux machine".
#[test]
fn an_ssh_linux_desktop_is_shared_through_the_screen_host_the_hub_lists() {
    use cmux_device_kind::screen::{NoScreen, Screen, ScreenRoute};
    let row = |name: &str, device_hub: Value| {
        let mut row = json!({"name": name, "url": format!("ssh://{name}"), "connected": true,
                             "health": {"os": "linux", "device": "linux-desktop"}});
        if !device_hub.is_null() {
            row["deviceHub"] = device_hub;
        }
        row
    };
    let src = Sources {
        peers: json!({"peers": [
            row("desk-on", json!({"listed": true, "id": "dev_on", "platform": "linux",
                                  "online": true, "screenShared": true})),
            row("desk-off", json!({"listed": true, "id": "dev_off", "platform": "linux",
                                   "online": true, "screenShared": false})),
            row("desk-none", json!({"listed": false})),
            row("desk-unread", Value::Null),
        ]}),
        ..Sources::default()
    };
    let listing = model::merge(&src, tailscale_up(), &[]);
    let view = Some(Screen::View { route: ScreenRoute::Hub });
    let none = |reason| Some(Screen::None { reason });
    for (id, screen, hub_device) in [
        ("peer:desk-on", view, Some("dev_on")),
        ("peer:desk-off", none(NoScreen::SharingOff), Some("dev_off")),
        ("peer:desk-none", none(NoScreen::NoScreenHost), None),
        // No share host here read the hub's list: its kind decides, as before.
        ("peer:desk-unread", view, None),
    ] {
        let d = device(&listing, id);
        assert_eq!((d.screen, d.hub_device.as_deref()), (screen, hub_device), "{id}");
    }
    let wire = serde_json::to_value(device(&listing, "peer:desk-on")).unwrap();
    assert_eq!(wire["hub_device"], json!("dev_on"));
    assert!(
        serde_json::to_value(device(&listing, "peer:desk-none"))
            .unwrap()
            .get("hub_device")
            .is_none()
    );
}
