//! `server-diagnostic-site`: the forwarder keeps each site
//! once and emits it once; a `diagnostic-sites-v1` app connection gets the
//! sites seen before its `subscribe`, then each new one, once; any other
//! subscriber gets none; the capability is advertised; and the request
//! watchdog's slow request and holder-link hang go through the process's
//! first-sighting feed to that connection, once each.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_threads::blocking::{BlockingKind, FirstSite};
use serde_json::{Value, json};

use super::super::*;
use super::{DIAGNOSTIC_SITES_CAPABILITY, forward_diagnostic_sites, forward_first_sites};
use crate::diagnostics::DiagnosticSite;
use crate::server::tests::captured_writer;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("diagnostic-sites-{label}"), crate::SurfaceOptions::default())
}

fn fs_site(line: u32) -> FirstSite {
    FirstSite::Blocking {
        file: "crates/cmux-tui-core/src/server/cmd_server.rs",
        line,
        column: 5,
        kind: BlockingKind::Fs,
        lane_sync: false,
    }
}

struct Subscriber {
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

impl Subscriber {
    fn subscribe(mux: &Arc<Mux>, capabilities: Value) -> Self {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        for command in [
            json!({"cmd": "set-client-info", "capabilities": capabilities}),
            json!({"cmd": "subscribe"}),
        ] {
            let command: Command = serde_json::from_value(command).unwrap();
            handle_command(mux, client, command, &writer).unwrap();
        }
        Self { writer, outbound }
    }

    /// The event lines up to the first `bell` (the test's end marker),
    /// waiting for the events-out thread to write them.
    fn events_until_bell(&self) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut events = Vec::new();
        loop {
            let Some(line) = self.outbound.try_pop() else {
                assert!(Instant::now() < deadline, "no bell after {events:?}");
                std::thread::yield_now();
                continue;
            };
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["event"] == "bell" {
                return events;
            }
            if value.get("event").is_some() {
                events.push(value);
            }
        }
    }
}

#[test]
fn the_forwarder_keeps_and_emits_each_site_once() {
    let mux = mux("forwarder");
    let events = mux.subscribe();
    let (feed, sites) = mpsc::channel();
    let hang = FirstSite::Hang { scope: "request", name: "list-workspaces" };
    for first in [fs_site(10), fs_site(10), hang] {
        feed.send(first).unwrap();
    }
    feed.send(hang).unwrap();
    drop(feed);
    forward_first_sites(&sites, &Arc::downgrade(&mux));
    let emitted: Vec<DiagnosticSite> = std::iter::from_fn(|| events.try_recv_caused().ok())
        .filter_map(|(event, _)| match event {
            MuxEvent::DiagnosticSite(site) => Some(site.as_ref().clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        emitted,
        vec![
            DiagnosticSite::of(fs_site(10)),
            DiagnosticSite::Hang { scope: "request", method: "list-workspaces" },
        ]
    );
    let kept: Vec<DiagnosticSite> =
        mux.diagnostic_sites.snapshot().iter().map(|site| site.as_ref().clone()).collect();
    assert_eq!(kept, emitted);
    mux.shutdown();
}

#[test]
fn an_app_connection_gets_earlier_sites_then_new_ones_and_others_get_none() {
    let mux = mux("subscribe");
    mux.note_diagnostic_site(DiagnosticSite::of(fs_site(20)));
    let app = Subscriber::subscribe(&mux, json!([DIAGNOSTIC_SITES_CAPABILITY]));
    let plain = Subscriber::subscribe(&mux, json!([]));
    mux.note_diagnostic_site(DiagnosticSite::of(fs_site(20)));
    mux.note_diagnostic_site(DiagnosticSite::of(FirstSite::Hang {
        scope: "request",
        name: "frame:apps",
    }));
    mux.emit(MuxEvent::Bell(9));
    let sites = |subscriber: &Subscriber| -> Vec<Value> {
        subscriber
            .events_until_bell()
            .into_iter()
            .filter(|event| event["event"] == "server-diagnostic-site")
            .collect()
    };
    assert_eq!(
        sites(&app),
        vec![
            subscribed_event_json(&MuxEvent::DiagnosticSite(Arc::new(DiagnosticSite::of(
                fs_site(20)
            )))),
            json!({"event": "server-diagnostic-site", "family": "hang", "kind": "request", "method": "frame.apps"}),
        ]
    );
    assert_eq!(sites(&plain), Vec::<Value>::new());
    assert!(app.writer.is_open());
    mux.shutdown();
}

#[test]
fn the_capability_is_advertised_and_negotiable() {
    assert!(advertised_capabilities(false).contains(&DIAGNOSTIC_SITES_CAPABILITY));
    let mux = mux("capability");
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let command: Command = serde_json::from_value(
        json!({"cmd": "set-client-info", "capabilities": [DIAGNOSTIC_SITES_CAPABILITY]}),
    )
    .unwrap();
    handle_command(&mux, client, command, &writer).unwrap();
    assert!(mux.control_clients.supports_capability(client, DIAGNOSTIC_SITES_CAPABILITY));
    mux.shutdown();
}

/// The only test in this binary that takes the process's first-sighting
/// feed: a request past the watchdog threshold (twice) and a holder-link
/// frame past its hang tier reach a `diagnostic-sites-v1` subscriber as one
/// event each.
#[cfg(unix)]
#[test]
fn watchdog_sites_reach_an_app_subscriber_through_the_feed_once_each() {
    let mux = mux("watchdog");
    forward_diagnostic_sites(&mux);
    let app = Subscriber::subscribe(&mux, json!([DIAGNOSTIC_SITES_CAPABILITY]));
    let watchdog = RequestWatchdog::new(Duration::from_millis(20));
    for _ in 0..2 {
        let run = watchdog.begin(1, WatchedMethod::frame(FrameStage::Scripts));
        std::thread::sleep(Duration::from_millis(80));
        drop(run);
    }
    // The holder link has only its hang tier (1 s).
    let frame = 3;
    let holder = watchdog.watch(WatchKind::HolderLink, frame);
    std::thread::sleep(crate::holder_runtime::HOLDER_LINK_HANG + Duration::from_millis(200));
    drop(holder);
    let expected = vec![
        json!({"event": "server-diagnostic-site", "family": "hang", "kind": "request", "method": "frame.scripts"}),
        json!({
            "event": "server-diagnostic-site",
            "family": "hang",
            "kind": "holder-link",
            "method": WatchKind::HolderLink.method_name(frame),
        }),
    ];
    let noted = |value: &Value| {
        mux.diagnostic_sites
            .snapshot()
            .into_iter()
            .any(|site| subscribed_event_json(&MuxEvent::DiagnosticSite(site)) == *value)
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while !expected.iter().all(noted) {
        assert!(Instant::now() < deadline, "the forwarder never noted {expected:?}");
        std::thread::yield_now();
    }
    mux.emit(MuxEvent::Bell(9));
    let ours: Vec<Value> =
        app.events_until_bell().into_iter().filter(|event| expected.contains(event)).collect();
    assert_eq!(ours, expected);
    drop(watchdog);
    mux.shutdown();
}
