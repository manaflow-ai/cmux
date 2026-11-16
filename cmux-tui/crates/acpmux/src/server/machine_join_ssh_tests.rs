use serde_json::json;

use super::list;
use crate::ssh_config_hosts::SshConfigHost;
use crate::tailnet::{Node, Status};

fn node(name: &str, online: bool) -> Node {
    Node {
        host_name: name.into(),
        dns_name: format!("{name}.tail9.ts.net"),
        os: "linux".into(),
        login: Some("leo@example.com".into()),
        tags: Vec::new(),
        ips: vec!["100.64.0.9".parse().unwrap()],
        online,
        shared: false,
    }
}

#[test]
fn candidates_are_the_online_nodes_and_ssh_hosts_not_added_yet() {
    let status = Status {
        backend_state: "Running".into(),
        this: node("this-mac", true),
        peers: vec![node("gcp-3", true), node("asleep", false), node("added", true)],
    };
    let peers = [json!({"name": "added", "url": "ssh://added.tail9.ts.net"})];
    let ssh = [
        SshConfigHost { alias: "gcp-3".into(), host_name: Some("gcp-3.tail9.ts.net".into()) },
        SshConfigHost { alias: "lab".into(), host_name: Some("10.0.0.7".into()) },
        SshConfigHost { alias: "added-alias".into(), host_name: Some("added.tail9.ts.net".into()) },
    ];
    let answer = list(Some(&status), &ssh, &peers, None);
    let rows = answer["candidates"].as_array().unwrap();
    let names: Vec<(&str, &str)> =
        rows.iter().map(|r| (r["name"].as_str().unwrap(), r["found"].as_str().unwrap())).collect();
    assert_eq!(names, [("gcp-3", "tailnet"), ("lab", "ssh-config")], "{answer}");
    assert_eq!(rows[0]["address"], "gcp-3.tail9.ts.net");
    assert!(answer.get("tailnet").is_none());
}

#[test]
fn no_tailnet_still_lists_ssh_hosts_and_says_why() {
    let ssh = [SshConfigHost { alias: "lab".into(), host_name: None }];
    let answer = list(None, &ssh, &[], Some("Tailscale is not installed".into()));
    assert_eq!(answer["candidates"][0]["name"], "lab");
    assert_eq!(answer["tailnet"]["error"], "Tailscale is not installed");
}
