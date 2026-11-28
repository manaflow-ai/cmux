//! BR-R3 on a real Chromium (cx-d0d.79, coordinator call 2026-10-12): under a
//! domain policy a headless session's WebSocket reaches only an allowed
//! host; one to a host outside the policy never leaves the browser. With no
//! policy both connect, and a tab the session opened before its policy
//! reopens under it. The fixture records the Host header of every upgrade
//! request that arrives, so a blocked socket is one that never reached it.
//! A module of the `chromium` test target.

use super::proxy_ranges::gated_session;
use super::*;
use cmux_browser_host::gate::Gate;
use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
use cmux_browser_host::policy::{Layer, parse_patterns};
use cmux_browser_host::vm::VmHost;

/// A listener that records the Host header of each WebSocket upgrade
/// request and closes the connection.
fn upgrade_recorder() -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind upgrade recorder");
    let port = listener.local_addr().unwrap().port();
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let record = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let record = record.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream);
                let (mut upgrade, mut host) = (false, String::new());
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).map(|n| n == 0).unwrap_or(true) || line == "\r\n"
                    {
                        break;
                    }
                    let lower = line.to_ascii_lowercase();
                    upgrade |= lower.starts_with("upgrade: websocket");
                    if let Some(value) = lower.strip_prefix("host:") {
                        host = value.trim().split(':').next().unwrap_or("").to_owned();
                    }
                }
                if upgrade {
                    record.lock().unwrap().push(host);
                }
            });
        }
    });
    (port, seen)
}

/// The page every socket opens from (on the allowed host).
fn page_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/second")
}

/// The session's call; a refusal panics.
fn call(gate: &Gate, method: &str, params: Value) -> Value {
    gate.driver_call(method, params).unwrap_or_else(|error| panic!("{method}: {error}"))
}

/// A page on the allowed host in a new tab of the session.
fn open_page(gate: &Gate, port: u16) -> String {
    let target = call(gate, "tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    call(
        gate,
        "tab.navigate",
        json!({"targetId": target, "url": page_url(port), "waitUntil": "load"}),
    );
    target
}

/// A WebSocket from `target`'s page to `host`; how it ended in the page.
fn socket(gate: &Gate, target: &str, host: &str, ws_port: u16) -> Value {
    call(
        gate,
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": format!(
            "() => new Promise(done => {{ let ws; try {{ ws = new WebSocket('ws://{host}:{ws_port}/ws'); }} \
             catch (e) {{ return done('thrown'); }} ws.onopen = () => done('open'); \
             ws.onerror = () => done('error'); setTimeout(() => done('timeout'), 5000); }})"
        )}),
    )
}

/// Upgrades to `host` once `count` arrived or 15 s passed: Chromium delays
/// a renderer's sockets after earlier ones fail (the fixture never
/// completes a handshake), so an allowed one gets time.
fn arrives(upgrades: &Mutex<Vec<String>>, host: &str, count: usize) -> usize {
    let arrived = || upgrades.lock().unwrap().iter().filter(|h| *h == host).count();
    let deadline = Instant::now() + Duration::from_secs(15);
    while arrived() < count && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    arrived()
}

/// How long a refused socket gets to arrive after an allowed one did.
const SETTLE: Duration = Duration::from_secs(3);

/// Allowed: 127.0.0.1 only.
fn allow_only_loopback_ip(gate: &Gate) {
    let allowed = parse_patterns(&["127.0.0.1".to_owned()]).unwrap();
    gate.set_owner_policy(Layer { allowed: Some(allowed), ..Layer::default() }, false).unwrap();
}

fn launch() -> Arc<HeadlessSource> {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
        .expect("launch the shared browser")
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn websockets_reach_only_allowed_hosts_under_a_domain_policy() {
    let port = serve();
    let (ws_port, upgrades) = upgrade_recorder();
    let source = launch();
    let browsers: HeadlessBrowsers = Arc::default();
    let (gate, _) = gated_session(&source, &browsers, "ws", false);

    // No policy: a socket to any host arrives.
    let tab = open_page(&gate, port);
    let page = socket(&gate, &tab, "localhost", ws_port);
    assert_eq!(
        arrives(&upgrades, "localhost", 1),
        1,
        "with no policy the WebSocket never arrived ({page})"
    );

    // A socket to localhost stays in the browser; one to the allowed host
    // still arrives.
    allow_only_loopback_ip(&gate);
    let tab = open_page(&gate, port);
    let refused = socket(&gate, &tab, "localhost", ws_port);
    let tab = open_page(&gate, port);
    let page = socket(&gate, &tab, "127.0.0.1", ws_port);
    assert_eq!(
        arrives(&upgrades, "127.0.0.1", 1),
        1,
        "a WebSocket to an allowed host never arrived ({page})"
    );
    // Checked once the later, allowed socket is in and a while after, so a
    // delayed one counts.
    std::thread::sleep(SETTLE);
    assert_eq!(
        arrives(&upgrades, "localhost", 1),
        1,
        "a WebSocket outside the policy arrived ({refused})"
    );

    // Cleared: every host connects again.
    gate.set_owner_policy(Layer::default(), false).unwrap();
    let tab = open_page(&gate, port);
    let page = socket(&gate, &tab, "localhost", ws_port);
    assert_eq!(
        arrives(&upgrades, "localhost", 2),
        2,
        "a cleared policy still held the WebSocket ({page})"
    );
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_tab_opened_before_the_policy_reopens_under_it() {
    let port = serve();
    let (ws_port, upgrades) = upgrade_recorder();
    let source = launch();
    let browsers: HeadlessBrowsers = Arc::default();
    let (gate, _) = gated_session(&source, &browsers, "early", false);

    let early = open_page(&gate, port);
    allow_only_loopback_ip(&gate);

    // The early tab is gone; a tab at its page took its place.
    let tabs = call(&gate, "tabs.list", json!({}));
    let tabs = tabs.as_array().expect("tabs.list is a list");
    assert!(
        tabs.iter().all(|tab| tab["targetId"].as_str() != Some(early.as_str())),
        "the tab from before the policy is still open: {tabs:?}"
    );
    let reopened = tabs
        .iter()
        .find(|tab| tab["url"].as_str() == Some(page_url(port).as_str()))
        .and_then(|tab| tab["targetId"].as_str())
        .unwrap_or_else(|| panic!("no tab reopened at {}: {tabs:?}", page_url(port)))
        .to_owned();

    // Its sockets go through the policy like any new tab's.
    let refused = socket(&gate, &reopened, "localhost", ws_port);
    let page = socket(&gate, &reopened, "127.0.0.1", ws_port);
    assert_eq!(
        arrives(&upgrades, "127.0.0.1", 1),
        1,
        "the reopened tab's allowed WebSocket never arrived ({page})"
    );
    std::thread::sleep(SETTLE);
    assert_eq!(
        arrives(&upgrades, "localhost", 0),
        0,
        "the reopened tab's WebSocket left the policy ({refused})"
    );
}
