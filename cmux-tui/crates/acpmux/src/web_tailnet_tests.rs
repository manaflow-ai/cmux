use super::*;
use crate::tailnet::parse_status;

fn status(state: &str, dns: &str) -> Status {
    parse_status(
        serde_json::json!({
            "BackendState": state,
            "Self": {"HostName": "laptop", "DNSName": dns, "Online": true,
                     "TailscaleIPs": ["100.64.0.1"]},
        })
        .to_string()
        .as_bytes(),
    )
    .unwrap()
}

#[test]
fn plan_takes_the_name_and_the_loopback_port() {
    let p =
        plan(&status("Running", "Laptop.tail1.ts.net."), "ws://127.0.0.1:4455/#token=t").unwrap();
    assert_eq!(p, Plan { fqdn: "laptop.tail1.ts.net".into(), port: 4455 });
}

#[test]
fn plan_refuses_what_it_cannot_serve() {
    let url = "http://127.0.0.1:4455/#token=t";
    let e = plan(&status("NeedsLogin", "a.ts.net."), url).unwrap_err().to_string();
    assert!(e.contains("NeedsLogin"), "{e}");
    assert!(plan(&status("Running", ""), url).unwrap_err().to_string().contains("MagicDNS"));
    let e = plan(&status("Running", "a.ts.net."), "http://0.0.0.0:4455/").unwrap_err();
    assert!(e.to_string().contains("not loopback"), "{e}");
}

#[test]
fn allow_is_idempotent() {
    let mut ws: WebSocketConfig = serde_json::from_str(r#"{"listen":"127.0.0.1:0"}"#).unwrap();
    assert!(allow(&mut ws, "a.ts.net"));
    assert!(!allow(&mut ws, "A.ts.net"));
    assert_eq!(ws.allowed_hosts, ["a.ts.net"]);
    assert_eq!(ws.allowed_origins, ["https://a.ts.net"]);
}

#[test]
fn the_listener_admits_the_tailnet_name_and_its_https_origin_once_allowed() {
    let mut ws: WebSocketConfig = serde_json::from_str(r#"{"listen":"127.0.0.1:0"}"#).unwrap();
    let addr: std::net::SocketAddr = "127.0.0.1:4455".parse().unwrap();
    let before = crate::server::listener_policy(addr, &[], &[]);
    assert!(before.check(&["a.ts.net"], &["https://a.ts.net"]).is_err());
    allow(&mut ws, "a.ts.net");
    let after = crate::server::listener_policy(addr, &ws.allowed_origins, &ws.allowed_hosts);
    assert!(after.check(&["a.ts.net"], &["https://a.ts.net"]).is_ok());
    assert!(after.check(&["evil.example"], &["https://a.ts.net"]).is_err());
    assert!(after.check(&["a.ts.net"], &["https://evil.example"]).is_err());
}

#[test]
fn the_link_is_https_with_the_token_in_the_fragment() {
    assert_eq!(link("a.ts.net", "T"), "https://a.ts.net/app/#token=T");
}
