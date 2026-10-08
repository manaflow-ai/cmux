//! EGRESS-ISOLATED on a real Chromium (cx-d0d.7): a browser the isolated
//! host launches reaches no metadata, link-local or private address, by
//! literal, by name (DNS rebinding), through a redirect or from page
//! script, because every connection goes through the host's listener. No
//! gate is in the path: the listener alone enforces it. Only the owner's
//! allow-listed fixture port loads. A module of the `chromium` test target.

use super::*;
use cmux_browser_host::egress_scope::{EgressRule, IsolatedEgress};
use std::net::SocketAddr;

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_isolated_browser_reaches_no_limited_range() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let (port, other) = (serve(), serve());
    // The owner allows the fixture's exact port; "app.test" and
    // "rebind.test" are names only the listener can resolve (Chromium maps
    // every name to NOTFOUND), both to loopback.
    let rule = EgressRule::new(
        vec![SocketAddr::from(([127, 0, 0, 1], port))],
        Arc::new(|host: &str, _| match host {
            "app.test" | "rebind.test" => vec!["127.0.0.1".parse().unwrap()],
            "meta.test" => vec!["169.254.169.254".parse().unwrap()],
            _ => Vec::new(),
        }),
    );
    let isolated = IsolatedEgress::new(rule);
    let mut options = HeadlessOptions::new(binary.into());
    options.extra_args = isolated.chromium_args().expect("the listener starts");
    let chromium = HeadlessChromium::launch(&options).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let call = |method: &str, params: Value| driver.call(method, &params);
    let target = call("tabs.open", json!({})).unwrap()["targetId"].as_str().unwrap().to_owned();
    let go = |url: &str| {
        call(
            "tab.navigate",
            json!({"targetId": target, "url": url, "waitUntil": "load", "timeoutMs": 20000}),
        )
    };

    // Allowed: the literal fixture and a name the listener resolved.
    go(&format!("http://127.0.0.1:{port}/second")).expect("the allow-listed fixture loads");
    go(&format!("http://app.test:{port}/second")).expect("the listener resolves names");

    for url in [
        "http://169.254.169.254/latest/meta-data/".to_owned(),
        "http://[fd00:ec2::254]/latest/meta-data/".to_owned(),
        "http://metadata.google.internal/computeMetadata/v1/".to_owned(),
        "http://meta.test/latest/meta-data/".to_owned(),
        "http://10.0.0.1/".to_owned(),
        "http://172.16.0.1/".to_owned(),
        "http://192.168.1.1/".to_owned(),
        "http://100.64.0.1/".to_owned(),
        "http://[fe80::1]/".to_owned(),
        "http://[fd12::1]/".to_owned(),
        "http://[::ffff:10.0.0.1]/".to_owned(),
        format!("http://127.0.0.1:{other}/second"),
        format!("http://[::1]:{port}/second"),
        format!("http://localhost:{port}/second"),
        format!("http://rebind.test:{other}/second"),
        // A redirect from the allowed fixture to a refused origin.
        format!("http://127.0.0.1:{port}/redirect"),
    ] {
        let refused = go(&url).expect_err(&url);
        assert!(refused.message.contains("ERR_"), "{url}: {refused}");
    }

    // Page script on the allowed origin: the same rule for every request.
    go(&format!("http://127.0.0.1:{port}/second")).unwrap();
    let probe = |url: String| {
        call(
            "frame.evaluate",
            json!({"targetId": target, "world": "page", "source": format!(
                "async () => {{ try {{ await fetch({url:?}, {{mode: 'no-cors'}}); return 'reached'; }} catch (e) {{ return 'blocked'; }} }}"
            )}),
        )
        .unwrap()
    };
    assert_eq!(probe(format!("http://127.0.0.1:{port}/second")), "reached", "the control fetch");
    for url in [
        "http://169.254.169.254/latest/meta-data/".to_owned(),
        "http://[fd00:ec2::254]/latest/meta-data/".to_owned(),
        "http://10.0.0.1/".to_owned(),
        format!("http://127.0.0.1:{other}/second"),
        format!("http://rebind.test:{other}/second"),
    ] {
        assert_eq!(probe(url.clone()), "blocked", "{url}");
    }
}
