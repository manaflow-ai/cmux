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

#[test]
fn the_app_pane_and_the_local_socket_may_join_and_web_and_peers_may_not() {
    use super::super::Origin;
    use super::served_to;
    assert!(served_to(Origin::Local));
    // The composer's machine menu asks over the agent pane's proven LocalApp connection.
    assert!(served_to(Origin::LocalApp));
    assert!(!served_to(Origin::Web));
    assert!(!served_to(Origin::Peer));
}

/// Design rule (a): one click joins without asking only a tailnet node the tailnet says this
/// person owns. Any other host runs nothing until the person confirmed it, named with the login.
#[test]
fn a_host_the_person_does_not_own_on_the_tailnet_needs_a_confirmation_naming_host_and_login() {
    use super::unconfirmed_answer;
    let ask = unconfirmed_answer(false, "lab", |_| (false, Some("leo".into())))
        .expect("an unowned host is asked about first");
    assert_eq!(ask["ok"], false);
    assert_eq!(ask["failure"]["kind"], "needs_confirmation");
    assert_eq!(ask["confirm"], json!({"host": "lab", "login": "leo"}));
    let next = ask["failure"]["next"].as_str().unwrap();
    assert!(next.contains("lab") && next.contains("leo") && !next.contains('\n'), "{next}");

    // An owned tailnet node joins on one click.
    assert_eq!(unconfirmed_answer(false, "gcp-3", |_| (true, None)), None);
    // A confirmed host joins without checking again.
    let confirmed = unconfirmed_answer(true, "lab", |_| panic!("no check once confirmed"));
    assert_eq!(confirmed, None);
}
