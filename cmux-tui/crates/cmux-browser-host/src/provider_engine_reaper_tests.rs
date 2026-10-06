//! A session's end on the person's tabs, at close and at the idle deadline
//! alike (one `end_session` path).
//!
//! Classic main (docs/browser-repl/driver-protocol.md:46, README.md ~:396
//! and ~:455): the tabs a session created (`tabs.open` and their popups)
//! close when it ends, by reset or 30 minutes idle, unless kept
//! (`page.keep()` / `tab.keep`); tabs it did not create (the person's tabs
//! it drove) stay open and are released. cmux-next addition, which classic
//! has no state for: a session-created tab whose lease the person has taken
//! (user_driving or paused) counts as kept, so it stays open as theirs and
//! only its lease is released.

use super::tests::{FakeApp, tab, wait_for_lease};
use super::*;
use crate::host::{Caller, Engines, Host, SessionContext};
use crate::provider::Frame;
use std::sync::Mutex;
use std::sync::mpsc;
use std::time::Duration;

/// HostEngines::provider for the fake app: every session's driver is a
/// ProviderEngine on its provider link, tee'd like the real one.
struct AppEngines {
    provider: Arc<ProviderDriver>,
    drivers: Mutex<Vec<Arc<dyn Driver>>>,
}

impl Engines for AppEngines {
    fn driver(
        &self,
        engine: &str,
        events: EventSink,
        session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        let lease = LeaseCaller {
            session: session.name.clone(),
            actor: session.caller.actor.clone(),
            on_behalf_of: session.caller.on_behalf_of.clone(),
            origin: session.caller.origin.clone(),
            label: session.label.clone(),
            implicit_session: false,
            engine: engine.to_owned(),
        };
        let events = crate::provider_link::tee_inputs(events, &self.provider, &session.name);
        let driver: Arc<dyn Driver> = Arc::new(ProviderEngine::new(
            self.provider.clone(),
            engine,
            Arc::from("/* agent */"),
            events,
            lease,
        )?);
        self.drivers.lock().unwrap().push(driver.clone());
        Ok(driver)
    }
}

struct Fixture {
    app: FakeApp,
    provider: Arc<ProviderDriver>,
    engines: Arc<AppEngines>,
    host: Host,
    ended: mpsc::Receiver<String>,
    root: std::path::PathBuf,
}

impl Fixture {
    fn start(tag: &str, tabs: &[&str], idle: Duration) -> Fixture {
        let (app, provider) = FakeApp::start(tabs.iter().map(|t| tab(t, "webkit")).collect());
        let engines =
            Arc::new(AppEngines { provider: provider.clone(), drivers: Mutex::new(Vec::new()) });
        let root = std::env::temp_dir().join(format!("reaper-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let host = Host::new(engines.clone(), root.display().to_string()).with_idle_timeout(idle);
        let (tx, ended) = mpsc::channel();
        host.on_idle_end(tx);
        let caller = Caller {
            actor: "uid:501".into(),
            on_behalf_of: None,
            origin: "mcp".into(),
            locality: Default::default(),
        };
        host.dispatch(&caller, "browser.repl.open", &json!({"session": "s", "engine": "webkit"}))
            .unwrap();
        Fixture { app, provider, engines, host, ended, root }
    }

    fn driver(&self) -> Arc<dyn Driver> {
        self.engines.drivers.lock().unwrap()[0].clone()
    }

    fn call(&self, method: &str, params: Value) -> Value {
        self.driver().call(method, &params).unwrap()
    }

    fn open(&self, target: &str) {
        self.call("tabs.open", json!({"url": format!("https://a.test/{target}")}));
    }

    fn act(&self, target: &str) {
        self.call("input.key", json!({"targetId": target, "type": "down", "key": "a"}));
    }

    /// The app has handled every frame sent before this call's reply.
    fn barrier(&self) {
        self.provider.call("tab.info", &json!({"targetId": "U"})).unwrap();
    }

    fn wait_idle_end(&self) {
        let name = self.ended.recv_timeout(Duration::from_secs(10)).expect("the idle end");
        assert_eq!(name, "s");
    }

    fn closed_tabs(&self) -> Vec<String> {
        let mut closed: Vec<String> = self
            .app
            .frames
            .lock()
            .unwrap()
            .iter()
            .filter_map(|f| match f {
                Frame::Call { method, params, .. } if method == "tabs.close" => {
                    params["targetId"].as_str().map(str::to_owned)
                }
                _ => None,
            })
            .collect();
        closed.sort();
        closed
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn idle_end_closes_only_the_session_tabs_nobody_kept() {
    let f = Fixture::start("tabs", &["N1", "N2", "N3", "N4", "P1", "U"], Duration::from_secs(2));
    for target in ["N1", "N2", "N3", "N4"] {
        f.open(target);
    }
    // P1 is a popup of N1, so it is the session's too.
    f.app.send(Frame::Event {
        name: "tab.created".into(),
        payload: json!({"targetId": "P1", "openerTargetId": "N1"}),
    });
    f.call("tab.keep", json!({"targetId": "N2"}));
    for target in ["N3", "N4", "U"] {
        f.act(target);
    }
    f.app.send(Frame::LeaseUser {
        op: "take_over".into(),
        target_id: Some("N3".into()),
        actor: None,
    });
    f.app.send(Frame::UserInput { target_id: "N4".into() });
    f.barrier();
    assert!(f.closed_tabs().is_empty(), "nothing closes before the session ends");

    f.wait_idle_end();
    f.barrier();
    assert_eq!(
        f.closed_tabs(),
        vec!["N1".to_owned(), "P1".to_owned()],
        "unkept session tabs close; kept (N2), the person's lease (N3 driving, N4 paused) and the person's own tab (U) stay"
    );
    for target in ["N3", "N4", "U"] {
        wait_for_lease(&f.app, target, "released at the idle end", Option::is_none);
    }
}

/// The app's view of a session's end: the calls and lease frames, without
/// call ids and lease timestamps.
fn end_frames(f: &Fixture, from: usize) -> Vec<Value> {
    f.app.frames.lock().unwrap()[from..]
        .iter()
        .filter_map(|frame| match frame {
            Frame::Call { method, params, .. } => Some(json!({"call": method, "params": params})),
            Frame::Lease { target_id, lease } => Some(json!({
                "lease": target_id,
                "state": lease.as_ref().map(|l| l.state),
                "session": lease.as_ref().map(|l| l.session.clone()),
            })),
            Frame::Input { event } => Some(json!({"input": event["kind"]})),
            _ => None,
        })
        .collect()
}

#[test]
fn idle_end_sends_the_app_what_close_sends() {
    let run = |tag: &str, close: bool| {
        let idle = if close { Duration::from_secs(600) } else { Duration::from_millis(500) };
        let f = Fixture::start(tag, &["N1", "U"], idle);
        f.open("N1");
        f.act("N1");
        f.act("U");
        f.barrier();
        let from = f.app.frames.lock().unwrap().len();
        if close {
            f.host
                .dispatch(
                    &Caller {
                        actor: "uid:501".into(),
                        on_behalf_of: None,
                        origin: "mcp".into(),
                        locality: Default::default(),
                    },
                    "browser.repl.close",
                    &json!({"session": "s"}),
                )
                .unwrap();
        } else {
            f.wait_idle_end();
        }
        f.barrier();
        end_frames(&f, from)
    };
    let closed = run("close", true);
    let idle = run("idle", false);
    assert!(
        closed.iter().any(|f| f["call"] == "tabs.close")
            && closed.iter().any(|f| f["lease"] == "U" && f["state"].is_null()),
        "close ends the session in the app: {closed:?}"
    );
    assert_eq!(
        idle, closed,
        "the idle end clears the agent cursor and driving state exactly as close does"
    );
}

/// The session's end asks the app to close its tabs with reason
/// `session_end` (the store leaves them out of Reopen Closed); the agent's
/// own `tabs.close` carries no reason, even when the agent sends one.
#[test]
fn session_end_closes_carry_the_session_end_reason() {
    let f = Fixture::start("reason", &["N1", "N2", "U"], Duration::from_secs(600));
    f.open("N1");
    f.open("N2");
    f.call("tabs.close", json!({"targetId": "N2", "reason": "session_end"}));
    f.barrier();
    f.host
        .dispatch(
            &Caller {
                actor: "uid:501".into(),
                on_behalf_of: None,
                origin: "mcp".into(),
                locality: Default::default(),
            },
            "browser.repl.close",
            &json!({"session": "s"}),
        )
        .unwrap();
    f.barrier();
    let closes: Vec<Value> = end_frames(&f, 0)
        .into_iter()
        .filter(|frame| frame["call"] == "tabs.close")
        .map(|frame| frame["params"].clone())
        .collect();
    let first = |target: &str| {
        closes.iter().find(|params| params["targetId"] == target).cloned().unwrap_or_default()
    };
    assert!(first("N2").get("reason").is_none(), "the agent's close has no reason: {closes:?}");
    assert_eq!(first("N1")["reason"], "session_end", "{closes:?}");
    assert!(first("N1")["timeoutMs"].is_u64(), "{closes:?}");
}
