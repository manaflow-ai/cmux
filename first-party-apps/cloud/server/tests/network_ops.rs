//! Network, tunnel and firewall ops against recorded fixtures: each op maps
//! to the exact method, path and body of the Cloud API route
//! (`web/app/api/vm/{network,tunnel/network,firewall}`), the origin rules
//! hold, and API answers become typed errors.

mod common;

use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

const PUBLIC_KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

fn server(fixtures: &[&str]) -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(fixtures))
}

fn only_call(s: &Server<FakeControlPlane>) -> (&'static str, String, Option<Value>) {
    let calls = &s.control_plane().calls;
    assert_eq!(calls.len(), 1, "{calls:?}");
    (calls[0].method, calls[0].path.clone(), calls[0].body.clone())
}

#[test]
fn network_list_reads_the_owner_network() {
    let mut s = server(&["network-list"]);
    let list = s.handle(&Request::new("cmux.cloud.network.list", json!({}))).expect("list");
    assert_eq!(only_call(&s), ("GET", "/api/vm/network".into(), None));
    assert_eq!(list["networks"][0]["id"], "vpc-test01");
    assert_eq!(list["networks"][0]["cidrV6"], "fd00:64::/48");
    assert_eq!(list["networks"][0]["scope"], "user");
}

#[test]
fn tunnel_attach_and_detach_post_to_the_tunnel_network_route() {
    let args = json!({ "deviceFingerprint": "mac-test.01", "network": "vpc-test01" });
    let mut s = server(&["tunnel-attach"]);
    let attached = s
        .handle(&Request::new("cloud.tunnel.attach", args).origin(Origin::User).key("t-1"))
        .expect("attach");
    let body = json!({ "deviceFingerprint": "mac-test.01", "networkId": "vpc-test01" });
    assert_eq!(only_call(&s), ("POST", "/api/vm/tunnel/network/attach".into(), Some(body)));
    assert_eq!(attached["tunnelId"], "tun-test01");
    assert_eq!(attached["networkId"], "vpc-test01");
    assert_eq!(attached["addressV4"], "10.64.0.9");

    let mut s = server(&["tunnel-detach"]);
    let detach = json!({
        "deviceFingerprint": "mac-test.01", "network": "vpc-test01", "tunnelPurpose": "terminal"
    });
    let detached =
        s.handle(&Request::new("cloud.tunnel.detach", detach).key("t-2")).expect("detach");
    let body = json!({
        "deviceFingerprint": "mac-test.01", "networkId": "vpc-test01", "tunnelPurpose": "terminal"
    });
    assert_eq!(only_call(&s), ("POST", "/api/vm/tunnel/network/detach".into(), Some(body)));
    assert_eq!(detached["detached"], true);
}

#[test]
fn rotate_key_sends_a_public_key_and_never_returns_a_private_key() {
    let mut s = server(&["tunnel-rotate-key"]);
    let args = json!({ "deviceFingerprint": "mac-test.01", "clientPublicKey": PUBLIC_KEY });
    let rotated = s
        .handle(&Request::new("cloud.tunnel.rotate_key", args).origin(Origin::User).key("k-1"))
        .expect("rotate");
    let body = json!({ "deviceFingerprint": "mac-test.01", "clientPublicKey": PUBLIC_KEY });
    assert_eq!(only_call(&s), ("POST", "/api/vm/tunnel/network/rotate-key".into(), Some(body)));
    assert_eq!(rotated["clientPublicKey"], PUBLIC_KEY);
    assert_eq!(rotated["tunnelId"], "tun-test01");
    assert!(rotated["clientConfig"].as_str().expect("config").contains("PrivateKey = \n"));

    // An answer whose config carries a private key is refused, not passed on.
    let mut leaky = FakeControlPlane::fixture_body("tunnel-rotate-key");
    leaky["clientConfig"] = json!("[Interface]\nPrivateKey = c2VjcmV0\n");
    let mut s = server(&[]);
    s.control_plane_mut().respond("POST", "/api/vm/tunnel/network/rotate-key", 200, leaky);
    let args = json!({ "deviceFingerprint": "mac-test.01", "clientPublicKey": PUBLIC_KEY });
    let error = s
        .handle(&Request::new("cloud.tunnel.rotate_key", args).origin(Origin::User).key("k-2"))
        .unwrap_err();
    assert_eq!(error.code, "cmux.cloud.bad_response");
    assert!(!error.message.contains("c2VjcmV0"), "the error never echoes key material");
}

#[test]
fn rotate_key_refuses_a_value_that_is_not_a_wireguard_public_key() {
    let bad = [
        "not-a-key",
        // 31 bytes.
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        // 33 bytes.
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        // 32 bytes, but the last character has bits past the key (not canonical).
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=",
        // URL-safe alphabet.
        "-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        // 64 hex characters.
        "0000000000000000000000000000000000000000000000000000000000000000",
    ];
    for key in bad {
        let mut s = server(&["tunnel-rotate-key"]);
        let args = json!({ "deviceFingerprint": "mac-test.01", "clientPublicKey": key });
        let error = s
            .handle(&Request::new("cloud.tunnel.rotate_key", args).origin(Origin::User).key("k-3"))
            .unwrap_err();
        assert_eq!(error.code, "cmux.cloud.invalid_args", "{key}");
        assert!(s.control_plane().calls.is_empty(), "{key}: no call for a bad key");
    }
    // A private key is never an argument.
    let mut s = server(&["tunnel-rotate-key"]);
    let args = json!({
        "deviceFingerprint": "mac-test.01", "clientPublicKey": PUBLIC_KEY, "privateKey": PUBLIC_KEY
    });
    let error = s
        .handle(&Request::new("cloud.tunnel.rotate_key", args).origin(Origin::User).key("k-4"))
        .unwrap_err();
    assert_eq!(error.code, "cmux.cloud.invalid_args");
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn attach_and_rotate_key_need_origin_user() {
    // Any valid public key would let the caller join the network as the device.
    for origin in [Origin::Mcp, Origin::Agent, Origin::Cli, Origin::Script] {
        let mut s = server(&["tunnel-attach", "tunnel-rotate-key"]);
        let attach = json!({ "deviceFingerprint": "mac-test.01", "network": "vpc-test01" });
        let rotate = json!({ "deviceFingerprint": "mac-test.01", "clientPublicKey": PUBLIC_KEY });
        for (op, args) in [("cloud.tunnel.attach", attach), ("cloud.tunnel.rotate_key", rotate)] {
            let request = Request::new(op, args).origin(origin).key("o-1");
            assert_eq!(s.handle(&request).unwrap_err().code, "cmux.cloud.origin_refused");
        }
        assert!(s.control_plane().calls.is_empty(), "{origin:?}: no call");
    }
}

#[test]
fn a_create_with_a_lost_answer_is_not_sent_again() {
    let mut s = server(&["firewall-create"]);
    s.control_plane_mut().fail_next = 1;
    let create = Request::new("cloud.firewall.create", new_rule()).origin(Origin::User).key("l-1");
    assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.relay_unavailable");
    // The rule may exist: the Cloud API does not dedup, so no second POST.
    assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.outcome_unknown");
    assert_eq!(s.control_plane().calls.len(), 1);
    let fresh = Request::new("cloud.firewall.create", new_rule()).origin(Origin::User).key("l-2");
    assert_eq!(s.handle(&fresh).expect("a new key")["id"], "fw-test02");

    // A 4xx answer made nothing: the same key may retry.
    let mut s = server(&["firewall-create-forbidden"]);
    let create = Request::new("cloud.firewall.create", new_rule()).origin(Origin::User).key("l-3");
    assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.forbidden");
    // (The fake replays the 403 for the same derived key; what matters is
    // that the server sent the retry instead of answering outcome_unknown.)
    assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.forbidden");
    assert_eq!(s.control_plane().calls.len(), 2);
}

#[test]
fn tunnel_ops_need_a_key_and_a_safe_fingerprint() {
    let mut s = server(&["tunnel-attach"]);
    let args = json!({ "deviceFingerprint": "mac-test.01", "network": "vpc-test01" });
    let error =
        s.handle(&Request::new("cloud.tunnel.attach", args).origin(Origin::User)).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.idempotency_key_required");
    let args = json!({ "deviceFingerprint": "../etc", "network": "vpc-test01" });
    let error = s
        .handle(&Request::new("cloud.tunnel.attach", args).origin(Origin::User).key("t-9"))
        .unwrap_err();
    assert_eq!(error.code, "cmux.cloud.invalid_args");
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn firewall_list_and_get_use_query_parameters() {
    let mut s = server(&["firewall-list"]);
    let list = s
        .handle(&Request::new("cmux.cloud.firewall.list", json!({ "machine": "vm-alpha01" })))
        .expect("list");
    assert_eq!(only_call(&s), ("GET", "/api/vm/firewall?vmId=vm-alpha01".into(), None));
    assert_eq!(list["rules"][0]["id"], "fw-test01");
    assert_eq!(list["rules"][0]["source"], json!({ "public": true }));
    assert_eq!(list["rules"][0]["destination"]["port"], 443);

    let mut s = server(&["firewall-get"]);
    let rule =
        s.handle(&Request::new("cloud.firewall.get", json!({ "rule": "fw-test01" }))).expect("get");
    assert_eq!(only_call(&s), ("GET", "/api/vm/firewall?ruleId=fw-test01".into(), None));
    assert_eq!(rule["action"], "allow");

    let mut s = server(&[]);
    let error = s
        .handle(&Request::new("cloud.firewall.get", json!({ "rule": "fw-1&vmId=x" })))
        .unwrap_err();
    assert_eq!(error.code, "cmux.cloud.invalid_args", "no argument adds a query parameter");
    assert!(s.control_plane().calls.is_empty());
}

fn new_rule() -> Value {
    json!({
        "source": { "cidr": "203.0.113.0/24" },
        "destination": { "vmId": "vm-alpha01", "port": 22, "protocol": "tcp" },
        "description": "office ssh"
    })
}

#[test]
fn firewall_create_and_delete_need_origin_user() {
    for origin in [Origin::Mcp, Origin::Agent, Origin::Cli, Origin::Script] {
        let mut s = server(&["firewall-create", "firewall-delete"]);
        let create = Request::new("cloud.firewall.create", new_rule()).origin(origin).key("f-1");
        assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.origin_refused");
        let delete = Request::new("cloud.firewall.delete", json!({ "rule": "fw-test01" }))
            .origin(origin)
            .key("f-2");
        assert_eq!(s.handle(&delete).unwrap_err().code, "cmux.cloud.origin_refused");
        assert!(s.control_plane().calls.is_empty(), "{origin:?}: no call");
    }

    let mut s = server(&["firewall-create"]);
    let create = Request::new("cloud.firewall.create", new_rule()).origin(Origin::User).key("f-1");
    let rule = s.handle(&create).expect("create");
    assert_eq!(only_call(&s), ("POST", "/api/vm/firewall".into(), Some(new_rule())));
    assert_eq!(rule["id"], "fw-test02");
    assert_eq!(s.handle(&create).expect("same-key retry"), rule);
    assert_eq!(s.control_plane().calls.len(), 1, "a same-key retry makes no second call");

    let mut s = server(&["firewall-delete"]);
    let delete = Request::new("cloud.firewall.delete", json!({ "rule": "fw-test01" }))
        .origin(Origin::User)
        .key("f-2");
    assert_eq!(s.handle(&delete).expect("delete"), json!({ "ok": true }));
    assert_eq!(only_call(&s), ("DELETE", "/api/vm/firewall?ruleId=fw-test01".into(), None));
}

#[test]
fn firewall_create_checks_endpoints_before_any_call() {
    let bad = [
        json!({ "source": { "public": true, "cidr": "10.0.0.0/8" }, "destination": { "vmId": "vm-alpha01" } }),
        json!({ "source": { "public": false }, "destination": { "vmId": "vm-alpha01" } }),
        json!({ "source": {}, "destination": { "vmId": "vm-alpha01" } }),
        json!({ "source": { "cidr": "10.0.0.0/33" }, "destination": { "vmId": "vm-alpha01" } }),
        json!({ "source": { "public": true }, "destination": { "vmId": "vm-alpha01", "port": 22 } }),
        json!({ "source": { "public": true }, "destination": { "vmId": "vm-alpha01", "port": 7, "protocol": "icmp" } }),
        json!({ "source": { "public": true }, "destination": { "vmId": "vm-alpha01", "vpcId": "vpc-test01" } }),
        json!({ "source": { "public": true }, "destination": { "vmId": "vm-alpha01", "host": "x" } }),
        json!({ "source": { "public": true } }),
    ];
    for args in bad {
        let mut s = server(&["firewall-create"]);
        let create =
            Request::new("cloud.firewall.create", args.clone()).origin(Origin::User).key("f-3");
        assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.invalid_args", "{args}");
        assert!(s.control_plane().calls.is_empty(), "{args}");
    }
}

#[test]
fn api_refusals_become_typed_errors() {
    let mut s = server(&["firewall-create-forbidden"]);
    let create = Request::new("cloud.firewall.create", new_rule()).origin(Origin::User).key("f-4");
    let error = s.handle(&create).unwrap_err();
    assert_eq!((error.code, error.status), ("cmux.cloud.forbidden", Some(403)));
    assert_eq!(error.upstream_code.as_deref(), Some("vm_forbidden"));

    let mut s = server(&["firewall-create-plan"]);
    let error = s.handle(&create).unwrap_err();
    assert_eq!((error.code, error.status), ("cmux.cloud.plan_limit", Some(403)));

    let mut s = server(&["unauthorized"]);
    s.control_plane_mut().respond(
        "GET",
        "/api/vm/network",
        401,
        FakeControlPlane::fixture_body("unauthorized"),
    );
    let error = s.handle(&Request::new("cloud.network.list", json!({}))).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.auth_required");

    // No fixture for this rule: the fake answers 404.
    let mut s = server(&[]);
    let error =
        s.handle(&Request::new("cloud.firewall.get", json!({ "rule": "fw-gone" }))).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.not_found");
}

#[test]
fn reads_take_no_key() {
    let mut s = server(&["network-list"]);
    let error = s.handle(&Request::new("cloud.network.list", json!({})).key("r-1")).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.idempotency_key_forbidden");
}
