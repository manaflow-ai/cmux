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
    // Port 1337 stands for a cmux service (the daemon's control port).
    let services: crate::egress_services::ServiceCheck = Arc::new(|addr: std::net::SocketAddr| {
        (addr.port() == 1337).then(|| "loopback port 1337 is the cmux service cmux".to_owned())
    });
    let rule = EgressRule::new(
        allow,
        Arc::new(|host: &str, _| match host {
            "rebind.test" => vec!["10.0.0.5".parse().unwrap()],
            "meta.test" => vec!["169.254.169.254".parse().unwrap()],
            "public.test" => vec!["93.184.216.34".parse().unwrap()],
            _ => Vec::new(),
        }),
    )
    .with_service_check(services);
    let grants =
        Grants { isolated: Some(Arc::new(IsolatedEgress::new(rule))), ..Grants::default() };
    (Gate::new(driver.clone(), grants), driver)
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

/// A loopback answer that is not the listener's went around it.
#[test]
fn a_loopback_response_outside_the_listener_stops_the_load() {
    let (gate, driver) = isolated_gate();
    gate.grants.isolated.as_ref().unwrap().listener().expect("the listener starts");
    gate.mask_event(
        "response",
        &json!({"targetId": "T", "url": "http://localhost:3000/", "remoteIPAddress": "[::1]"}),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !methods(&driver).contains(&"tab.stop".to_owned()) {
        assert!(std::time::Instant::now() < deadline, "the load was never stopped");
        std::thread::yield_now();
    }
}
