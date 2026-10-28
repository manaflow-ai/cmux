//! `frontend.visibility.set` on the wire: the verified
//! app's set scopes its own subscription, a subscription made after the set is
//! scoped too, a CLI subscriber on the same daemon is not, and only the
//! verified app may send it.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
    handle_connection_message,
};
use crate::{MuxEvent, SurfaceOptions};

const HIDDEN: SurfaceId = 41;
const SHOWN: SurfaceId = 42;
const WAIT: Duration = Duration::from_secs(5);

struct Caller {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    /// Event lines read while waiting for a reply.
    skipped: std::cell::RefCell<Vec<Value>>,
}

impl Caller {
    fn new(mux: &Arc<Mux>, app: bool) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let id = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        if app {
            origin_gate::set_role_for_test(mux, id, "main");
            origin_gate::set_verified_app_for_test(mux, id, true);
        }
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { id, writer, outbound, scheduler, skipped: Default::default() }
    }

    /// Sends `request` through the whole frame path and returns the next
    /// reply line (subscribe events are skipped).
    fn call(&self, mux: &Arc<Mux>, request: Value) -> Value {
        assert!(handle_connection_message(
            mux,
            self.id,
            &request.to_string(),
            &self.writer,
            &self.scheduler,
        ));
        let deadline = Instant::now() + WAIT;
        while Instant::now() < deadline {
            let Some(line) = self.outbound.try_pop() else {
                std::thread::yield_now();
                continue;
            };
            let message: Value = serde_json::from_str(&line).unwrap();
            if message.get("event").is_none() {
                return message;
            }
            self.skipped.borrow_mut().push(message);
        }
        panic!("no reply to {request}");
    }

    fn subscribe(&self, mux: &Arc<Mux>) {
        assert_eq!(self.call(mux, json!({"id": 1, "cmd": "subscribe"}))["ok"], true);
    }

    /// The `title-changed` surfaces written until `deadline`.
    fn titles_until(&self, deadline: Instant) -> Vec<u64> {
        let mut messages: Vec<Value> = self.skipped.borrow_mut().drain(..).rev().collect();
        let mut surfaces = Vec::new();
        loop {
            let message = match messages.pop() {
                Some(message) => message,
                None if Instant::now() >= deadline => break,
                None => {
                    let Some(line) = self.outbound.try_pop() else {
                        std::thread::sleep(Duration::from_millis(2));
                        continue;
                    };
                    serde_json::from_str(&line).unwrap()
                }
            };
            if message["event"] == "title-changed" {
                surfaces.push(message["surface"].as_u64().unwrap());
            }
        }
        surfaces
    }
}

fn code(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    reply["error_code"].as_str().unwrap_or_default()
}

fn retitle(mux: &Mux, surface: SurfaceId, n: usize) {
    mux.emit(MuxEvent::TitleChanged { surface, title: format!("t{n}").into() });
}

#[test]
fn frontend_visibility_set_scopes_the_apps_stream_and_not_the_clis() {
    let mux = Mux::new_for_test("frontend-visibility-scope", SurfaceOptions::default());
    let app = Caller::new(&mux, true);
    let cli = Caller::new(&mux, false);
    app.subscribe(&mux);
    cli.subscribe(&mux);
    let set = app.call(&mux, json!({"id": 2, "cmd": SET, "visible": [SHOWN]}));
    assert_eq!(set["data"], json!({"visible": 1, "released": 0}), "{set}");

    for n in 0..1000 {
        retitle(&mux, HIDDEN, n);
    }
    retitle(&mux, SHOWN, 0);
    // Within the first half second the app hears only the shown surface.
    let early = app.titles_until(Instant::now() + Duration::from_millis(150));
    assert!(early.contains(&SHOWN) && !early.contains(&HIDDEN), "{early:?}");
    // The CLI's stream is not scoped: it hears the hidden surface at once.
    let cli_heard = cli.titles_until(Instant::now() + Duration::from_millis(150));
    assert!(cli_heard.contains(&HIDDEN), "{cli_heard:?}");

    // Showing the surface flushes its one coalesced title.
    let shown = app.call(&mux, json!({"id": 3, "cmd": SET, "visible": [SHOWN, HIDDEN]}));
    assert_eq!(shown["data"]["released"], 1, "{shown}");
    let late = app.titles_until(Instant::now() + Duration::from_millis(150));
    assert_eq!(late, [HIDDEN]);
}

#[test]
fn frontend_visibility_a_later_subscription_is_scoped_and_null_clears_it() {
    let mux = Mux::new_for_test("frontend-visibility-later", SurfaceOptions::default());
    let app = Caller::new(&mux, true);
    let set = app.call(&mux, json!({"id": 2, "cmd": SET, "visible": []}));
    assert_eq!(set["data"]["visible"], 0, "{set}");
    app.subscribe(&mux);
    retitle(&mux, HIDDEN, 1);
    assert!(app.titles_until(Instant::now() + Duration::from_millis(200)).is_empty());

    let cleared = app.call(&mux, json!({"id": 3, "cmd": SET, "visible": null}));
    assert_eq!(cleared["data"], json!({"visible": null, "released": 1}), "{cleared}");
    assert_eq!(app.titles_until(Instant::now() + Duration::from_millis(200)), [HIDDEN]);
}

#[test]
fn frontend_visibility_set_needs_the_verified_app_and_well_formed_fields() {
    let mux = Mux::new_for_test("frontend-visibility-refusals", SurfaceOptions::default());
    let app = Caller::new(&mux, true);
    let cli = Caller::new(&mux, false);
    assert_eq!(
        code(&cli.call(&mux, json!({"id": 1, "cmd": SET, "visible": []}))),
        "frontend_visibility.not_trusted"
    );
    let too_many: Vec<u64> = (0..=MAX_VISIBLE as u64).collect();
    for bad in [
        json!({"id": 2, "cmd": SET}),
        json!({"id": 3, "cmd": SET, "visible": "all"}),
        json!({"id": 4, "cmd": SET, "visible": [-1]}),
        json!({"id": 5, "cmd": SET, "visible": [], "extra": 1}),
        json!({"id": 6, "cmd": SET, "visible": too_many}),
    ] {
        assert_eq!(code(&app.call(&mux, bad.clone())), "frontend_visibility.bad_request", "{bad}");
    }
}

#[test]
fn frontend_visibility_is_routed_and_advertised() {
    let route = crate::server::routes::find(SET).expect("routed");
    assert_eq!(route.stage, crate::server::FrameStage::Route);
    let mux = Mux::new_for_test("frontend-visibility-capability", SurfaceOptions::default());
    assert!(crate::server::identify_capabilities(&mux).contains(&CAPABILITY));
}
