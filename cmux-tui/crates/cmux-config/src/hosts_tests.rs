use serde_json::json;

use super::*;

#[test]
fn a_host_has_a_label_and_endpoints_tried_in_order() {
    let value = json!([
        {"label": "studio", "endpoints": ["studio.local", "ssh://leo@100.64.0.7:2222"], "icon": "desktopcomputer"},
        {"label": "build box", "endpoint": "build-1", "id": "b1"}
    ]);
    assert!(accepts(&value));
    let (hosts, problems) = parse(&value);
    assert!(problems.is_empty());
    assert_eq!(hosts[0].label, "studio");
    assert_eq!(hosts[0].endpoints, ["studio.local", "ssh://leo@100.64.0.7:2222"]);
    assert_eq!(hosts[0].icon.as_deref(), Some("desktopcomputer"));
    assert_eq!(hosts[1].endpoints, ["build-1"]);
    assert_eq!(hosts[1].id.as_deref(), Some("b1"));
    assert_eq!(find(&hosts, "BUILD BOX").map(|h| h.label.as_str()), Some("build box"));
}

#[test]
fn bad_hosts_are_refused_and_parse_names_each_one() {
    for bad in [
        json!("studio"),
        json!([{"endpoints": ["a"]}]),
        json!([{"label": " ", "endpoints": ["a"]}]),
        json!([{"label": "a", "endpoints": []}]),
        json!([{"label": "a"}]),
        json!([{"label": "a", "endpoint": "a", "endpoints": ["a"]}]),
        json!([{"label": "a", "endpoints": ["http://a"]}]),
        json!([{"label": "a", "endpoints": ["-oProxyCommand=x"]}]),
        json!([{"label": "a", "endpoints": ["a b"]}]),
        json!([{"label": "a", "endpoints": ["ssh://a:0"]}]),
        json!([{"label": "a", "endpoints": ["ssh://@a"]}]),
        json!([{"label": "a", "endpoints": ["a"], "icon": 1}]),
        json!([{"label": "a", "endpoints": ["a"]}, {"label": "A", "endpoints": ["b"]}]),
        json!([{"label": "x".repeat(MAX_LABEL + 1), "endpoints": ["a"]}]),
    ] {
        assert!(!accepts(&bad), "accepted {bad}");
    }
    let (hosts, problems) = parse(&json!([
        {"label": "a", "endpoints": ["a"]},
        {"label": "A", "endpoints": ["b"]},
        7
    ]));
    assert_eq!(hosts.len(), 1);
    assert_eq!(problems.len(), 2);
    assert!(problems[0].contains("used twice"), "{problems:?}");
    assert!(problems[1].starts_with("machines.hosts[2]"), "{problems:?}");
}

#[test]
fn endpoints_become_ssh_destinations() {
    let at = |text: &str| ssh_endpoint(text);
    assert_eq!(at("studio"), Some(SshEndpoint { destination: "studio".into(), port: None }));
    assert_eq!(
        at("leo@studio"),
        Some(SshEndpoint { destination: "leo@studio".into(), port: None })
    );
    assert_eq!(
        at("ssh://leo@10.0.0.2:2222"),
        Some(SshEndpoint { destination: "leo@10.0.0.2".into(), port: Some(2222) })
    );
    assert_eq!(at("SSH://box/"), Some(SshEndpoint { destination: "box".into(), port: None }));
    assert_eq!(
        at("ssh://[fd7a::1]:22"),
        Some(SshEndpoint { destination: "fd7a::1".into(), port: Some(22) })
    );
    assert_eq!(at("ssh://box/path"), None);
    assert_eq!(at("ssh://fd7a::1"), None);
    assert_eq!(at("unix:///tmp/server.sock"), None);
}
