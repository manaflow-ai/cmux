//! EGRESS-ISOLATED in the gate (cx-d0d.7): on a Cloud machine a LOCAL
//! caller is refused every limited range, by literal and by resolution,
//! before dispatch; sessions set no proxy; a response that reports the
//! egress listener's own address stops nothing.

use super::*;
use crate::egress_scope::{EgressRule, IsolatedEgress};

fn isolated_gate() -> (Gate, Arc<FakeDriver>) {
    isolated_gate_allowing(Vec::new())
}

fn isolated_gate_allowing(allow: Vec<std::net::SocketAddr>) -> (Gate, Arc<FakeDriver>) {
    let (_, driver) = make_gate(Value::Null, false);
    let rule = EgressRule::new(
        allow,
        Arc::new(|host: &str, _| match host {
            "rebind.test" => vec!["10.0.0.5".parse().unwrap()],
            "meta.test" => vec!["169.254.169.254".parse().unwrap()],
            "public.test" => vec!["93.184.216.34".parse().unwrap()],
            _ => Vec::new(),
        }),
    );
    let grants =
        Grants { isolated: Some(Arc::new(IsolatedEgress::new(rule))), ..Grants::default() };
    (Gate::new(driver.clone(), grants), driver)
}

#[test]
fn a_local_caller_on_a_cloud_machine_is_refused_every_limited_range() {
    let (gate, driver) = isolated_gate();
    for url in [
        "http://169.254.169.254/latest/meta-data/",
        "http://[fd00:ec2::254]/latest/meta-data/",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://10.0.0.1/",
        "http://172.16.5.4/",
        "http://192.168.1.1/",
        "http://100.64.0.1/",
        "http://0.0.0.0:3000/",
        "http://[fe80::1]/",
        "http://[fd12::1]/",
        "http://[::ffff:10.0.0.1]/",
        "http://rebind.test/",
        "http://meta.test/",
    ] {
        for (method, params) in [
            ("tabs.open", json!({"url": url})),
            ("tab.navigate", json!({"targetId": "T", "url": url})),
            ("net.fetch", json!({"targetId": "T", "url": url})),
        ] {
            let refused = gate.driver_call(method, params).unwrap_err();
            assert_eq!(refused.code, ErrorCode::Forbidden, "{method} {url}: {refused}");
        }
    }
    assert!(methods(&driver).is_empty(), "nothing reached the engine: {:?}", methods(&driver));
    for url in ["https://public.test/", "http://localhost:3000/", "http://127.0.0.1:3000/"] {
        assert!(gate.driver_call("tabs.open", json!({"url": url})).is_ok(), "{url}");
    }
}

#[test]
fn a_session_on_a_cloud_machine_sets_no_proxy() {
    let (gate, driver) = isolated_gate();
    for server in ["http://203.0.113.7:3128", "socks5://127.0.0.1:1080"] {
        let refused = gate
            .driver_call("session.configure", json!({"proxy": {"server": server}}))
            .unwrap_err();
        assert_eq!(refused.code, ErrorCode::Forbidden, "{server}: {refused}");
    }
    assert!(!methods(&driver).contains(&"session.configure".to_owned()));
    assert!(gate.driver_call("session.configure", json!({"proxy": null})).is_ok());
}

/// Every connection goes through the listener, which reports itself as the
/// remote address: that answer is no rebinding sign and stops nothing.
#[test]
fn the_listener_address_in_a_response_is_not_a_rebinding() {
    let (gate, driver) = isolated_gate();
    gate.grants.isolated.as_ref().unwrap().listener().expect("the listener starts");
    gate.mask_event(
        "response",
        &json!({"targetId": "T", "url": "https://public.test/", "remoteIPAddress": "127.0.0.1"}),
    );
    *driver.fetch_reply.lock().unwrap() = json!({"url": "https://public.test/x", "status": 200,
        "headers": [], "bodyBase64": "", "remoteIPAddress": "127.0.0.1"});
    let out =
        gate.driver_call("net.fetch", json!({"targetId": "T", "url": "https://public.test/x"}));
    assert!(out.is_ok(), "{out:?}");
    assert!(!methods(&driver).contains(&"tab.stop".to_owned()), "{:?}", methods(&driver));
}

/// A response from any address but the listener's went around it (an
/// engine the host did not launch, a proxy setting it did not make): a
/// refused address stops the load.
#[test]
fn a_response_from_another_refused_address_stops_the_load() {
    let (gate, driver) = isolated_gate();
    gate.grants.isolated.as_ref().unwrap().listener().expect("the listener starts");
    gate.mask_event(
        "response",
        &json!({"targetId": "T", "url": "https://public.test/", "remoteIPAddress": "10.0.0.5"}),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !methods(&driver).contains(&"tab.stop".to_owned()) {
        assert!(std::time::Instant::now() < deadline, "the load was never stopped");
        std::thread::yield_now();
    }
}

/// The owner's allow list reaches the request filter too: a fetch to an
/// allowed dev server port runs, page requests to it pass with a policy
/// active, and other private targets stay refused there.
#[test]
fn the_owner_allow_list_reaches_fetch_and_the_request_filter() {
    let allow = crate::egress_scope::parse_allow("localhost:3000").0;
    let (gate, driver) = isolated_gate_allowing(allow);
    *driver.fetch_reply.lock().unwrap() = json!({"url": "http://localhost:3000/", "status": 200,
        "headers": [], "bodyBase64": ""});
    let out =
        gate.driver_call("net.fetch", json!({"targetId": "T", "url": "http://localhost:3000/"}));
    assert!(out.is_ok(), "{out:?}");
    policy(&gate, "set", json!({"prohibited": ["peer.test"]})).unwrap();
    let filter = driver.filter.lock().unwrap().clone().expect("a policy installs the filter");
    let decide = |url: &str| {
        filter(&crate::driver::RequestInfo {
            target: "T",
            url,
            kind: crate::driver::RequestKind::Subresource,
        })
    };
    assert_eq!(decide("http://localhost:3000/app.js"), None);
    assert_eq!(decide("http://127.0.0.1:3000/app.js"), None);
    assert_eq!(decide("https://public.test/x"), None, "names are the listener's");
    assert_eq!(decide("http://127.0.0.1:3001/"), None, "the VM's own loopback");
    for refused in [
        "http://10.0.0.1/",
        "http://169.254.169.254/",
        "http://metadata.google.internal/",
    ] {
        assert!(decide(refused).is_some(), "{refused}");
    }
}
