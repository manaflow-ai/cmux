//! EGRESS-ISOLATED in the gate (cx-d0d.7): on a Cloud machine a LOCAL
//! caller is refused every limited range, by literal and by resolution,
//! before dispatch; sessions set no proxy; a response that reports the
//! egress listener's own address stops nothing.

use super::*;
use crate::egress_scope::{EgressRule, IsolatedEgress};

fn isolated_gate() -> (Gate, Arc<FakeDriver>) {
    let (_, driver) = make_gate(Value::Null, false);
    let rule = EgressRule::new(
        Vec::new(),
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
        "http://127.0.0.1:3000/",
        "http://localhost:3000/",
        "http://10.0.0.1/",
        "http://172.16.5.4/",
        "http://192.168.1.1/",
        "http://100.64.0.1/",
        "http://[::1]/",
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
    assert!(gate.driver_call("tabs.open", json!({"url": "https://public.test/"})).is_ok());
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
