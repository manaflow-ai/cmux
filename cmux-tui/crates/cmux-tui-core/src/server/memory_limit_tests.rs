//! `memory.limit` on the wire: a critical push from the app
//! makes the daemon release its lossless consumers before the reply, the
//! limit ends with the app's connection, and only the verified local app may
//! send it (never a CLI, a WebSocket page or a remote relay).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cmux_memory::{MemoryConsumer, PressureLevel, Retention};
use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink, disconnect_client,
    handle_connection_message,
};

struct Caller {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Caller {
    fn new(mux: &Arc<Mux>, transport: ClientTransport, app: bool) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let id = mux.control_clients.register(transport, writer.clone());
        if app {
            origin_gate::set_role_for_test(mux, id, "main");
            origin_gate::set_verified_app_for_test(mux, id, true);
        }
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { id, writer, outbound, scheduler }
    }

    /// The reply to `request`, through the whole frame path.
    fn call(&self, mux: &Arc<Mux>, request: Value) -> Value {
        assert!(handle_connection_message(
            mux,
            self.id,
            &request.to_string(),
            &self.writer,
            &self.scheduler,
        ));
        let line = self.outbound.try_pop().expect("the route answers before it returns");
        serde_json::from_str(&line).unwrap()
    }
}

fn code(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    reply["error_code"].as_str().unwrap_or_default()
}

/// A lossless consumer in `mux`'s registry that counts its releases.
fn lossless(mux: &Mux) -> (Arc<AtomicUsize>, cmux_memory::Registration) {
    let releases = Arc::new(AtomicUsize::new(0));
    let seen = Arc::clone(&releases);
    let registration = mux.memory.registry().register(MemoryConsumer::new(
        "test.lossless",
        Retention::Lossless,
        || Some(0),
        move |level| {
            if level != PressureLevel::Normal {
                seen.fetch_add(1, Ordering::SeqCst);
            }
        },
    ));
    (releases, registration)
}

#[test]
fn memory_limit_critical_releases_lossless_consumers_within_a_second() {
    let mux = Mux::new_for_test("memory-limit-critical", SurfaceOptions::default());
    let (releases, _registration) = lossless(&mux);
    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let started = Instant::now();
    let reply = app.call(
        &mux,
        json!({"id": 1, "cmd": LIMIT, "level": "critical", "mode": "medium", "override": null}),
    );
    assert_eq!(reply["data"], json!({"changed": true, "level": "critical"}), "{reply}");
    assert_eq!(releases.load(Ordering::SeqCst), 1, "released before the reply");
    assert!(started.elapsed() < Duration::from_secs(1));

    let again =
        app.call(&mux, json!({"id": 2, "cmd": LIMIT, "level": "critical", "mode": "medium"}));
    assert_eq!(again["data"]["changed"], false, "{again}");
    assert_eq!(releases.load(Ordering::SeqCst), 1, "a repeat releases nothing");

    // The app quits: its limit goes with its connection.
    assert!(disconnect_client(&mux, app.id, false));
    assert_eq!(mux.memory.registry().level(), PressureLevel::Normal);
    assert_eq!(mux.memory.app_limit(), None);
}

#[test]
fn memory_limit_needs_the_verified_local_app_and_is_denied_on_relays() {
    let mux = Mux::new_for_test("memory-limit-refusals", SurfaceOptions::default());
    let (releases, _registration) = lossless(&mux);
    let cli = Caller::new(&mux, ClientTransport::Unix, false);
    let web = Caller::new(&mux, ClientTransport::WebSocket, true);
    let relay = Caller::new(&mux, ClientTransport::Remote, true);
    let critical = json!({"id": 1, "cmd": LIMIT, "level": "critical", "mode": "aggressive"});
    for caller in [&cli, &web] {
        assert_eq!(code(&caller.call(&mux, critical.clone())), "memory.not_trusted");
    }
    // The remote relay's default deny refuses it before the route runs.
    assert_eq!(code(&relay.call(&mux, critical)), "remote_denied");
    assert_eq!(releases.load(Ordering::SeqCst), 0, "no refused line votes");

    let app = Caller::new(&mux, ClientTransport::Unix, true);
    for bad in [
        json!({"id": 2, "cmd": LIMIT}),
        json!({"id": 3, "cmd": LIMIT, "level": "high", "mode": "medium"}),
        json!({"id": 4, "cmd": LIMIT, "level": "critical", "mode": "max"}),
        json!({"id": 5, "cmd": LIMIT, "level": "critical", "mode": "medium", "override": "loud"}),
        json!({"id": 6, "cmd": LIMIT, "level": "critical", "mode": "medium", "extra": 1}),
    ] {
        assert_eq!(code(&app.call(&mux, bad.clone())), "memory.bad_request", "{bad}");
    }
    assert_eq!(mux.memory.registry().level(), PressureLevel::Normal);
}

#[test]
fn memory_limit_is_routed_and_its_capability_is_advertised() {
    let route = crate::server::routes::find(LIMIT).expect("routed");
    assert_eq!(route.stage, crate::server::FrameStage::Route);
    let mux = Mux::new_for_test("memory-limit-capability", SurfaceOptions::default());
    assert!(crate::server::identify_capabilities(&mux).contains(&CAPABILITY));
}
