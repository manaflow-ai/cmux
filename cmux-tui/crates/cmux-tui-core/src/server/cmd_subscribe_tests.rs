//! Page-relay subscriptions filter by event kind on the bus (chrome-parity
//! p13-webui-067): a page relay that hears `history-changed` is never sent,
//! queued or rendered a terminal's `surface-output`, it still hears its own
//! event, and a normal subscriber's stream is unchanged.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{SubscribeProbe, page_event_kinds, subscribed_event_json, wire_event_kinds};
use crate::event_bus::{MuxEventBroadcaster, MuxEventKind, MuxEventKinds};
use crate::server::bounded_outbound::{BoundedOutbound, QueuedSink};
use crate::server::*;

const WAIT: Duration = Duration::from_secs(5);
const OUTPUT_EVENTS: u64 = 10_000;

fn history_changed() -> MuxEvent {
    MuxEvent::HistoryChanged { revision: 7, kinds: vec!["visit".to_owned()] }
}

fn history_interest() -> MuxEventKinds {
    page_event_kinds(&["history-changed".to_owned()]).expect("history-changed has a kind")
}

#[test]
fn a_page_interest_queues_none_of_ten_thousand_surface_outputs() {
    let bus = MuxEventBroadcaster::default();
    let page = bus.subscribe_kinds(history_interest());
    let normal = bus.subscribe();
    for surface in 0..OUTPUT_EVENTS {
        bus.emit(MuxEvent::SurfaceOutput(surface % 64));
    }
    bus.emit(history_changed());

    let heard: Vec<MuxEvent> = page.try_iter().collect();
    assert!(
        matches!(heard.as_slice(), [MuxEvent::HistoryChanged { revision: 7, .. }]),
        "{heard:?}"
    );
    assert!(!page.overflowed());

    // The normal subscriber hears every surface's (coalesced) output, then history.
    let heard: Vec<MuxEvent> = normal.try_iter().collect();
    let outputs = heard.iter().filter(|event| matches!(event, MuxEvent::SurfaceOutput(_))).count();
    assert_eq!(outputs, 64, "{heard:?}");
    assert!(matches!(heard.last(), Some(MuxEvent::HistoryChanged { revision: 7, .. })));
    assert!(!normal.overflowed());
}

/// A subscribed connection writing into a queue the test reads, and its
/// subscription's probe.
fn subscribed(
    mux: &Arc<Mux>,
    page: Option<&str>,
    surface: Option<SurfaceId>,
) -> (Arc<BoundedOutbound>, Arc<SubscribeProbe>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if let Some(page) = page {
        origin_gate::set_role_for_test(mux, client, "page_relay");
        origin_gate::set_page(mux, client, page.to_owned());
    }
    let mut request = json!({"cmd": "subscribe"});
    if let Some(surface) = surface {
        request["surface"] = json!(surface);
    }
    let command = tests::json_command(request);
    assert_eq!(handle_command(mux, client, command, &writer).unwrap(), json!({}));
    (outbound, mux.control_clients.subscribe_probe(client))
}

/// The event names `outbound` writes until one is `last`, or the deadline.
fn written_until(outbound: &BoundedOutbound, last: &str) -> Vec<String> {
    let deadline = Instant::now() + WAIT;
    let mut names = Vec::new();
    while Instant::now() < deadline {
        let Some(line) = outbound.try_pop() else {
            std::thread::yield_now();
            continue;
        };
        let message: Value = serde_json::from_str(&line).unwrap();
        let name = message["event"].as_str().unwrap_or_default().to_owned();
        names.push(name.clone());
        if name == last {
            break;
        }
    }
    names
}

/// Emit `OUTPUT_EVENTS` outputs spread over `surfaces`, then one
/// `history-changed`.
fn emit_outputs_then_history(mux: &Mux, surfaces: &[SurfaceId]) {
    for surface in surfaces.iter().cycle().take(OUTPUT_EVENTS as usize) {
        mux.emit(MuxEvent::SurfaceOutput(*surface));
    }
    mux.emit(history_changed());
}

#[test]
fn a_history_page_relay_hears_its_event_and_no_surface_output() {
    let mux = Mux::new_for_test("subscribe-interest", crate::SurfaceOptions::default());
    let (relay, relay_probe) = subscribed(&mux, Some("history"), None);
    let (local, local_probe) = subscribed(&mux, None, None);

    let surfaces: Vec<SurfaceId> = (0..64).collect();
    emit_outputs_then_history(&mux, &surfaces);

    assert_eq!(written_until(&relay, "history-changed"), ["history-changed"]);
    // The bus never queued a surface output for the relay: its stream
    // neither received nor rendered one, and its own event came through.
    assert_eq!(relay_probe.received.of(MuxEventKind::SurfaceOutput), 0);
    assert_eq!(relay_probe.rendered.of(MuxEventKind::SurfaceOutput), 0);
    assert_eq!(relay_probe.received.of(MuxEventKind::HistoryChanged), 1);
    assert_eq!(relay_probe.rendered.of(MuxEventKind::HistoryChanged), 1);

    let heard = written_until(&local, "history-changed");
    assert_eq!(heard.last().map(String::as_str), Some("history-changed"), "{heard:?}");
    let outputs = heard.iter().filter(|name| *name == "surface-output").count();
    assert!(outputs > 0, "a normal subscriber still hears surface-output: {heard:?}");
    assert!(local_probe.rendered.of(MuxEventKind::SurfaceOutput) >= outputs as u64);
}

/// A surface stream is not filtered on the bus: a page relay's interest
/// still drops that surface's output before any JSON is built.
#[test]
fn a_history_page_relay_surface_stream_renders_no_surface_output() {
    let mux = Mux::new_for_test("subscribe-interest-surface", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let (relay, relay_probe) = subscribed(&mux, Some("history"), Some(surface));

    emit_outputs_then_history(&mux, &[surface]);

    assert_eq!(written_until(&relay, "history-changed"), ["history-changed"]);
    assert!(
        relay_probe.received.of(MuxEventKind::SurfaceOutput) > 0,
        "the surface stream's bus filter passes the surface's output"
    );
    assert_eq!(relay_probe.rendered.of(MuxEventKind::SurfaceOutput), 0);
    assert_eq!(relay_probe.rendered.of(MuxEventKind::HistoryChanged), 1);
}

/// Every event a page may name (page-router.json and the Channels page's
/// scoped set) has kinds, so no page relay falls back to an unfiltered bus.
#[test]
fn every_page_event_name_has_kinds() {
    let router: Value =
        serde_json::from_str(include_str!("../../../../spec/page-router.json")).unwrap();
    let pages = router["pages"].as_object().unwrap();
    for (page, entry) in pages {
        let names: Vec<String> = serde_json::from_value(entry["events"].clone()).unwrap();
        assert!(page_event_kinds(&names).is_some(), "{page}: {names:?}");
    }
    let channels = origin_gate::CHANNELS_SCOPED_EVENTS.to_vec();
    let kinds = page_event_kinds(&channels).expect("channels events have kinds");
    assert!(kinds.contains(MuxEventKind::Conversation));
    assert!(!kinds.contains(MuxEventKind::SurfaceOutput));
    assert_eq!(page_event_kinds(&[]), Some(MuxEventKinds::NONE));
    assert_eq!(page_event_kinds(&["no-such-event".to_owned()]), None);
}

/// The name an event renders as maps back to the event's own kind.
#[test]
fn a_rendered_event_name_maps_back_to_its_kind() {
    let events = [
        MuxEvent::SurfaceOutput(1),
        MuxEvent::SurfaceResized { surface: 1, cols: 80, rows: 24, reservation_id: None },
        MuxEvent::SurfaceExited(1, None),
        MuxEvent::TitleChanged { surface: 1, title: "t".into() },
        MuxEvent::Bell(1),
        MuxEvent::ProgramStatusChanged { surface: 1, status: None },
        MuxEvent::Status("s".to_owned()),
        MuxEvent::ConfigReloadRequested,
        MuxEvent::WindowTitleRequested("w".to_owned()),
        MuxEvent::ScrollChanged { surface: 1, offset: 0, at_bottom: true },
        MuxEvent::TreeChanged,
        MuxEvent::TreeSelectionChanged,
        MuxEvent::PersonalChanged { personal_revision: 1 },
        history_changed(),
        MuxEvent::TerminalReaped { terminal_id: "t".to_owned(), terminal: None, grace_ms: 1 },
        MuxEvent::ClientDetached(1),
        MuxEvent::ClientListInvalidated,
        MuxEvent::PairingResolved { request: 1 },
        MuxEvent::MachineUsageChanged(None),
        MuxEvent::Empty,
    ];
    for event in events {
        let value = subscribed_event_json(&event);
        let name = value["event"].as_str().unwrap();
        let kinds = wire_event_kinds(name).unwrap_or_else(|| panic!("{name} has no kinds"));
        assert!(kinds.accepts(&event), "{name}: {event:?}");
    }
}
