//! RFD 0127 cut 3: a service the peer's registration does not list is refused here, before any
//! ticket or circuit, as `machine.unknown` is.

use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

/// A ticket source that counts its asks and gives none.
struct Counting(Arc<AtomicU64>);

#[async_trait]
impl Tickets for Counting {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Err("no register here".into())
    }

    async fn connect(&self, _peer: &str) -> Result<CarrierAnswer, String> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Err("machine.not_found".into())
    }
}

fn carrier() -> (Arc<HubCarrier>, Arc<AtomicU64>) {
    let asks = Arc::new(AtomicU64::new(0));
    let carrier = HubCarrier::new(Arc::new(Counting(asks.clone())), [7u8; 32], Timings::default());
    (carrier, asks)
}

fn register(carrier: &HubCarrier, services: serde_json::Value) {
    let answer: CarrierAnswer = serde_json::from_value(serde_json::json!({
        "relay": "relay+do://relay.example", "slot": "s", "ticket": "t",
        "peers": ["peer-a"], "peer_services": services,
    }))
    .unwrap();
    set_peer_services(&carrier.peer_services, &answer);
}

#[tokio::test]
async fn a_service_the_registration_leaves_out_is_refused_without_a_dial() {
    let (carrier, asks) = carrier();
    register(&carrier, serde_json::json!({"peer-a": ["acpmux", "echo"]}));
    assert_eq!(carrier.peer_services("peer-a"), Some(vec!["acpmux".to_owned(), "echo".to_owned()]));

    let started = Instant::now();
    let refused =
        carrier.dial_service("peer-a", CircuitService::CmuxTui { port: 22 }).await.unwrap_err();
    assert!(refused.contains("service.off"), "{refused}");
    assert!(refused.contains("cmux-tui"), "{refused}");
    assert!(started.elapsed() < Duration::from_millis(50), "{:?}", started.elapsed());
    assert_eq!(asks.load(Ordering::SeqCst), 0, "a ticket was asked for a refused service");
}

#[tokio::test]
async fn a_listed_service_an_unnamed_machine_and_the_acpmux_listener_are_dialed() {
    let (carrier, asks) = carrier();
    register(&carrier, serde_json::json!({"peer-a": ["cmux-tui"]}));
    // Listed: goes on to the ticket (which gives none here).
    let listed = carrier.dial_service("peer-a", CircuitService::CmuxTui { port: 22 }).await;
    assert!(!listed.unwrap_err().contains("service.off"));
    // A machine the map does not name: nothing is known, nothing is refused locally.
    let unnamed = carrier.dial_service("peer-b", CircuitService::MachineCall).await;
    assert!(!unnamed.unwrap_err().contains("service.off"));
    // The acpmux listener is how a machine is reached at all.
    let acpmux = carrier.dial_service("peer-a", CircuitService::Acpmux).await;
    assert!(!acpmux.unwrap_err().contains("service.off"));
    assert!(asks.load(Ordering::SeqCst) >= 2);
}

#[tokio::test]
async fn a_ticket_with_no_map_refuses_nothing_locally() {
    let (carrier, _) = carrier();
    register(&carrier, serde_json::json!({"peer-a": ["echo"]}));
    assert!(carrier.peer_services("peer-a").is_some());
    // A later ticket from a platform that predates the field clears what the last one said.
    let plain: CarrierAnswer = serde_json::from_value(serde_json::json!({
        "relay": "relay+do://relay.example", "slot": "s", "ticket": "t", "peers": ["peer-a"],
    }))
    .unwrap();
    set_peer_services(&carrier.peer_services, &plain);
    assert_eq!(carrier.peer_services("peer-a"), None);
    let dialed = carrier.dial_service("peer-a", CircuitService::TransferSource).await;
    assert!(!dialed.unwrap_err().contains("service.off"));
}

#[test]
fn the_echo_service_has_a_hello_and_a_name() {
    let hello = hello_record(CircuitService::Echo);
    assert_eq!(named_service(&hello), Some(Ok(CircuitService::Echo)));
    assert_eq!(service_name(CircuitService::Echo), "echo");
    assert_eq!(CircuitLane::of(CircuitService::Echo), CircuitLane::Cheap);
    // The hello of a service that takes a port, or names a target, is not an echo.
    let bad = Bytes::from([SERVICE_HELLO, br#"{"service":"echo","port":22}"#].concat());
    assert!(matches!(named_service(&bad), Some(Err(_))));
}

#[tokio::test]
async fn link_age_is_none_with_no_kept_circuit() {
    let (carrier, _) = carrier();
    assert_eq!(carrier.link_age("peer-a"), None);
}
