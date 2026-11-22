//! The spare bounds and the kept Connect ticket, with no relay: tickets that never answer hold a
//! spare in its opening, and a relay no one listens on fails it fast.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;

use super::{MAX_SPARES, TICKET_MARGIN_SECS, now_unix};
use crate::hub_carrier::{CarrierAnswer, HubCarrier, Tickets, Timings};

/// Connect tickets that expire at `expires_at` (or never come, with `hang`), naming a relay on a
/// closed loopback port. Counts the asks.
struct TestTickets {
    expires_at: u64,
    hang: bool,
    asked: AtomicU64,
}

#[async_trait]
impl Tickets for TestTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Err("no register in this test".into())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        self.asked.fetch_add(1, Ordering::SeqCst);
        if self.hang {
            std::future::pending::<()>().await;
        }
        Ok(CarrierAnswer {
            relay: "relay+ws://127.0.0.1:1".into(),
            slot: "slot".into(),
            ticket: "ticket".into(),
            expires_at: self.expires_at,
            peer_key: Some(peer.to_owned()),
            peers: vec![],
        })
    }
}

fn carrier(tickets: Arc<TestTickets>, timings: Timings) -> Arc<HubCarrier> {
    HubCarrier::new(tickets, [7u8; 32], timings)
}

fn key(n: u8) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode([n; 32])
}

fn opening(carrier: &HubCarrier) -> usize {
    carrier.warm.parked().filling.len()
}

#[tokio::test]
async fn one_spare_opens_a_machine_and_no_more_than_the_cap_in_all() {
    let tickets = Arc::new(TestTickets { expires_at: 0, hang: true, asked: AtomicU64::new(0) });
    let carrier = carrier(tickets.clone(), Timings::default());
    carrier.refill_spare(&key(1));
    carrier.refill_spare(&key(1));
    tokio::task::yield_now().await;
    assert_eq!(opening(&carrier), 1, "a second refill for the same machine opened another");
    for n in 2..(MAX_SPARES as u8 + 5) {
        carrier.refill_spare(&key(n));
    }
    assert_eq!(opening(&carrier), MAX_SPARES);
}

#[tokio::test]
async fn a_zero_ttl_opens_no_spare() {
    let tickets = Arc::new(TestTickets { expires_at: 0, hang: true, asked: AtomicU64::new(0) });
    let timings = Timings { spare_ttl: Duration::ZERO, ..Timings::default() };
    let carrier = carrier(tickets.clone(), timings);
    carrier.refill_spare(&key(1));
    assert_eq!(opening(&carrier), 0);
    tokio::task::yield_now().await;
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_spare_that_fails_to_open_frees_its_place_and_parks_nothing() {
    let tickets = Arc::new(TestTickets { expires_at: 0, hang: false, asked: AtomicU64::new(0) });
    let timings = Timings { control: Duration::from_secs(2), ..Timings::default() };
    let carrier = carrier(tickets, timings);
    carrier.refill_spare(&key(1));
    tokio::time::timeout(Duration::from_secs(10), async {
        while opening(&carrier) > 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the failed opening never ended");
    assert_eq!(carrier.warm_spares(), 0);
}

#[tokio::test]
async fn a_rekey_or_a_take_of_no_spare_finds_none() {
    let tickets = Arc::new(TestTickets { expires_at: 0, hang: true, asked: AtomicU64::new(0) });
    let carrier = carrier(tickets, Timings::default());
    assert!(carrier.take_spare(&key(1), 0).await.is_none());
    carrier.rekey([8u8; 32], || Ok::<_, ()>(())).unwrap();
    assert_eq!(carrier.warm_spares(), 0);
}

#[tokio::test]
async fn a_connect_ticket_is_kept_until_shortly_before_it_expires() {
    let lasting = now_unix() + 10 * 60;
    let tickets =
        Arc::new(TestTickets { expires_at: lasting, hang: false, asked: AtomicU64::new(0) });
    let carrier = carrier(tickets.clone(), Timings::default());
    let opener = carrier.opener();
    let (_, kept) = opener.ticket(&key(1)).await.unwrap();
    assert!(!kept);
    let (again, kept) = opener.ticket(&key(1)).await.unwrap();
    assert!(kept, "a ticket with ten minutes left was asked for again");
    assert_eq!(again.expires_at, lasting);
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 1);
    // Another machine has its own ticket.
    let (_, kept) = opener.ticket(&key(2)).await.unwrap();
    assert!(!kept);

    let closing = now_unix() + TICKET_MARGIN_SECS / 2;
    let tickets =
        Arc::new(TestTickets { expires_at: closing, hang: false, asked: AtomicU64::new(0) });
    let carrier = self::carrier(tickets.clone(), Timings::default());
    let opener = carrier.opener();
    opener.ticket(&key(1)).await.unwrap();
    let (_, kept) = opener.ticket(&key(1)).await.unwrap();
    assert!(!kept, "a ticket about to expire was kept");
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 2);

    // No expiry named: never kept.
    let tickets = Arc::new(TestTickets { expires_at: 0, hang: false, asked: AtomicU64::new(0) });
    let carrier = self::carrier(tickets.clone(), Timings::default());
    let opener = carrier.opener();
    opener.ticket(&key(1)).await.unwrap();
    opener.ticket(&key(1)).await.unwrap();
    assert_eq!(tickets.asked.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn a_relay_that_refuses_a_kept_ticket_gets_a_fresh_one() {
    let lasting = now_unix() + 10 * 60;
    let tickets =
        Arc::new(TestTickets { expires_at: lasting, hang: false, asked: AtomicU64::new(0) });
    let timings = Timings { control: Duration::from_secs(2), ..Timings::default() };
    let carrier = carrier(tickets.clone(), timings);
    let opener = carrier.opener();
    // The first opening asks the platform and keeps the ticket; the relay is not there.
    assert!(opener.open(&key(1)).await.is_err());
    let after_first = tickets.asked.load(Ordering::SeqCst);
    // The second takes the kept ticket, is refused at the connect, and asks once more.
    assert!(opener.open(&key(1)).await.is_err());
    assert_eq!(tickets.asked.load(Ordering::SeqCst), after_first + 1);
}
