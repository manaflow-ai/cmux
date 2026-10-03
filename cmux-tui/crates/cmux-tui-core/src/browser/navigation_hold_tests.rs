#![cfg(test)]
//! A navigation that arrives before the browser surface has a live CDP
//! session must be held (latest wins) and applied when the surface attaches,
//! and the attach must load the record's current URL rather than the URL the
//! bootstrap captured when it started.

use super::{BrowserCommand, BrowserRuntime, BrowserSource, new_surface};
use crate::{Surface, SurfaceOptions};
use serde_json::{Value, json};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Weak};
use std::thread;
use std::time::{Duration, Instant};
use tungstenite::{Message, WebSocket, accept};

const BOOTSTRAP_URL: &str = "https://bootstrap.test";
const WAIT: Duration = Duration::from_secs(5);
const QUIET: Duration = Duration::from_millis(300);

struct FakeCdp {
    runtime: Arc<BrowserRuntime>,
    navigations: Receiver<String>,
    navigation_sessions: Receiver<String>,
    methods: Receiver<String>,
}

impl FakeCdp {
    // Runtime shutdown does not close the WebSocket, so the fake server
    // thread stays blocked in read; it is detached rather than joined.
    fn shutdown(self) {
        self.runtime.shutdown();
    }
}

fn read_request(ws: &mut WebSocket<TcpStream>) -> Option<Value> {
    loop {
        match ws.read().ok()? {
            Message::Text(text) => return serde_json::from_str(&text).ok(),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).ok(),
            Message::Close(_) => return None,
            _ => {}
        }
    }
}

/// A CDP endpoint that accepts surface setup and reports every Page.navigate
/// URL. Each navigation commits a new loader so the daemon settles it.
fn fake_cdp() -> FakeCdp {
    fake_cdp_gated(None)
}

/// With a gate, the first Page.navigate waits for the gate and then fails the
/// way Chrome answers a call on a session that was detached meanwhile.
fn fake_cdp_gated(mut first_navigation_gate: Option<Receiver<()>>) -> FakeCdp {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (navigation_tx, navigations) = mpsc::channel();
    let (session_tx, navigation_sessions) = mpsc::channel();
    let (method_tx, methods) = mpsc::channel();
    let _detached = thread::Builder::new()
        .name("browser-navigation-hold-fake-cdp".into())
        .spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = accept(stream).unwrap();
            let mut loader = 1;
            while let Some(request) = read_request(&mut ws) {
                let id = request["id"].clone();
                let _ = method_tx.send(request["method"].as_str().unwrap_or_default().to_string());
                if request["method"] == "Page.navigate" {
                    let _ = session_tx.send(request["sessionId"].as_str().unwrap_or_default().into());
                }
                if request["method"] == "Page.navigate"
                    && let Some(gate) = first_navigation_gate.take()
                {
                    let url = request["params"]["url"].as_str().unwrap_or_default();
                    let _ = navigation_tx.send(url.to_string());
                    let _ = gate.recv_timeout(WAIT);
                    let error = json!({"code": -32001, "message": "Session with given id not found."});
                    let reply = json!({"id": id, "error": error}).to_string();
                    if ws.send(Message::Text(reply.into())).is_err() {
                        break;
                    }
                    continue;
                }
                let result = match request["method"].as_str().unwrap_or_default() {
                    "Page.getFrameTree" => json!({
                        "frameTree": {
                            "frame": {"id": "main-frame", "loaderId": "loader-1", "url": BOOTSTRAP_URL}
                        }
                    }),
                    "Page.navigate" => {
                        loader += 1;
                        let url = request["params"]["url"].as_str().unwrap_or_default();
                        let _ = navigation_tx.send(url.to_string());
                        json!({"frameId": "main-frame", "loaderId": format!("loader-{loader}")})
                    }
                    _ => json!({}),
                };
                let reply = json!({"id": id, "result": result}).to_string();
                if ws.send(Message::Text(reply.into())).is_err() {
                    break;
                }
            }
        })
        .unwrap();
    let runtime = BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        None,
        BrowserSource::Provider,
    )
    .unwrap();
    FakeCdp { runtime, navigations, navigation_sessions, methods }
}

fn starting_surface() -> Arc<Surface> {
    let opts = SurfaceOptions::default();
    new_surface(7, BOOTSTRAP_URL.into(), (10, 5), (8, 16), &opts, Weak::new()).unwrap()
}

/// Wait until the worker has run every command queued so far. Commands run
/// in sequence order, so a later Hold entering proves earlier work finished.
fn drain_worker(surface: &Surface) {
    let browser = surface.as_browser().expect("browser surface");
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
    started.recv_timeout(WAIT).expect("browser worker reached the drain barrier");
    release.send(()).unwrap();
}

fn attach(cdp: &FakeCdp, surface: &Arc<Surface>) {
    cdp.runtime.setup_attached_surface(surface, "target-1", "session-1", BOOTSTRAP_URL).unwrap();
}

fn wait_for_record_url(surface: &Surface, expected: &str) {
    let browser = surface.as_browser().expect("browser surface");
    let deadline = Instant::now() + WAIT;
    while browser.url() != expected {
        assert!(
            Instant::now() < deadline,
            "record URL stayed {:?}, expected {expected:?}",
            browser.url()
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn navigation_hold_applies_a_navigation_sent_while_the_surface_attaches() {
    let cdp = fake_cdp();
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");

    browser.navigate("https://target.test").expect("raw navigate is accepted while starting");
    drain_worker(&surface);
    attach(&cdp, &surface);

    let loaded = cdp
        .navigations
        .recv_timeout(WAIT)
        .expect("a navigation accepted before attach must reach the page after attach");
    assert_eq!(loaded, "https://target.test");
    wait_for_record_url(&surface, "https://target.test");

    browser.kill();
    cdp.shutdown();
}

#[test]
fn navigation_hold_keeps_only_the_latest_navigation_sent_while_starting() {
    let cdp = fake_cdp();
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");

    browser.navigate("https://first.test").unwrap();
    drain_worker(&surface);
    browser.navigate("https://latest.test").unwrap();
    drain_worker(&surface);
    attach(&cdp, &surface);

    let loaded = cdp.navigations.recv_timeout(WAIT).expect("the held navigation is applied");
    assert_eq!(loaded, "https://latest.test", "a newer navigation replaces the pending one");
    assert!(
        cdp.navigations.recv_timeout(QUIET).is_err(),
        "the superseded navigation must never load"
    );
    wait_for_record_url(&surface, "https://latest.test");

    browser.kill();
    cdp.shutdown();
}

#[test]
fn navigation_hold_attach_loads_the_record_url_not_the_stale_bootstrap_url() {
    let cdp = fake_cdp();
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");
    // The record moved on (for example the page navigated on an earlier
    // provider lease) after the bootstrap captured its URL.
    browser.set_url("https://record.test".to_string());

    attach(&cdp, &surface);
    assert_ne!(browser.url(), BOOTSTRAP_URL, "attach must not stamp the stale bootstrap URL");

    let loaded = cdp.navigations.recv_timeout(WAIT).expect("attach loads the record's URL");
    assert_eq!(loaded, "https://record.test");
    wait_for_record_url(&surface, "https://record.test");

    browser.kill();
    cdp.shutdown();
}

#[test]
fn navigation_hold_survives_a_rejected_confirmed_navigation() {
    let cdp = fake_cdp();
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");

    browser.navigate("https://raw.test").unwrap();
    drain_worker(&surface);
    let confirmed = browser.navigate_confirmed("https://confirmed.test");
    assert!(confirmed.is_err(), "a confirmed navigation is refused while starting");
    attach(&cdp, &surface);

    let loaded = cdp.navigations.recv_timeout(WAIT).expect("the acknowledged navigation loads");
    assert_eq!(loaded, "https://raw.test");
    wait_for_record_url(&surface, "https://raw.test");

    browser.kill();
    cdp.shutdown();
}

#[test]
fn navigation_hold_refuses_navigation_after_the_bootstrap_failed_for_good() {
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");

    browser.navigate("https://held.test").unwrap();
    drain_worker(&surface);
    browser.abandon_attach("no browser endpoint".to_string());

    let error = browser.navigate("https://late.test").expect_err("no attach will come");
    assert!(error.to_string().contains("no browser endpoint"), "{error}");
    assert!(!browser.has_held_navigation(), "a held navigation is dropped");

    browser.expect_attach();
    browser.navigate("https://retry.test").expect("a new bootstrap attempt accepts navigation");
    browser.kill();
}

#[test]
fn navigation_hold_replays_a_navigation_whose_session_was_replaced() {
    let (release_navigation, gate) = mpsc::channel();
    let cdp = fake_cdp_gated(Some(gate));
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");
    attach(&cdp, &surface);

    browser.navigate("https://target.test").unwrap();
    assert_eq!(cdp.navigations.recv_timeout(WAIT).unwrap(), "https://target.test");
    assert_eq!(cdp.navigation_sessions.recv_timeout(WAIT).unwrap(), "session-1");
    // The provider replaces the target lease while Page.navigate is in flight.
    assert!(browser.prepare_provider_lease_replacement(None));
    release_navigation.send(()).unwrap();
    drain_worker(&surface);
    assert_eq!(browser.url(), BOOTSTRAP_URL, "a failed navigation never claims its URL");

    cdp.runtime.setup_attached_surface(&surface, "target-2", "session-2", BOOTSTRAP_URL).unwrap();
    let replayed = cdp.navigations.recv_timeout(WAIT).expect("the held navigation is replayed");
    assert_eq!(replayed, "https://target.test");
    assert_eq!(cdp.navigation_sessions.recv_timeout(WAIT).unwrap(), "session-2");
    wait_for_record_url(&surface, "https://target.test");

    browser.kill();
    cdp.shutdown();
}

#[test]
fn navigation_hold_refuses_history_commands_before_the_surface_attaches() {
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");

    for (command, result) in
        [("back", browser.back()), ("forward", browser.forward()), ("reload", browser.reload())]
    {
        let error = result.expect_err("a history command before attach is refused, not acked");
        assert!(error.to_string().contains("still starting"), "{command}: {error}");
    }

    browser.abandon_attach("no browser endpoint".to_string());
    let error = browser.reload().expect_err("no attach will come");
    assert!(error.to_string().contains("no browser endpoint"), "{error}");
    browser.kill();
}

#[test]
fn navigation_hold_accepts_history_commands_once_attached() {
    let cdp = fake_cdp();
    let surface = starting_surface();
    let browser = surface.as_browser().expect("browser surface");
    attach(&cdp, &surface);

    browser.reload().expect("reload is accepted once the surface attached");
    browser.back().expect("back is accepted once the surface attached");
    drain_worker(&surface);
    let sent: Vec<String> = cdp.methods.try_iter().collect();
    for method in ["Page.reload", "Page.getNavigationHistory"] {
        assert!(sent.iter().any(|sent| sent == method), "{method} never reached CDP: {sent:?}");
    }

    browser.kill();
    cdp.shutdown();
}
