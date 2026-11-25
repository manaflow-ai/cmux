use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;

use super::{CarrierAnswer, TicketCache, Tickets};

/// A platform that mints a numbered ticket per ask, good for `life` seconds, and refuses while
/// `refusing` is set. `wait` holds each ask that long (a slow platform).
struct Minting {
    asks: AtomicU64,
    life: u64,
    refusing: Mutex<bool>,
    wait: Duration,
    premint: Option<Vec<String>>,
}

impl Minting {
    fn new(life: u64) -> Arc<Self> {
        Arc::new(Self {
            asks: AtomicU64::new(0),
            life,
            refusing: Mutex::new(false),
            wait: Duration::ZERO,
            premint: None,
        })
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn ticket(peer: &str, n: u64, life: u64) -> CarrierAnswer {
    serde_json::from_value(serde_json::json!({
        "relay": "relay+do://relay.example", "slot": format!("slot-{peer}"),
        "ticket": format!("t{n}"), "expires_at": now() + life, "peer_key": peer,
    }))
    .unwrap()
}

#[async_trait]
impl Tickets for Minting {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Err("no register here".into())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        let n = self.asks.fetch_add(1, Ordering::SeqCst) + 1;
        tokio::time::sleep(self.wait).await;
        if *self.refusing.lock().unwrap() {
            return Err("machine.not_found".into());
        }
        Ok(ticket(peer, n, self.life))
    }

    async fn connects(&self) -> Result<Option<Vec<CarrierAnswer>>, String> {
        Ok(self
            .premint
            .as_ref()
            .map(|peers| peers.iter().map(|p| ticket(p, 100, self.life)).collect::<Vec<_>>()))
    }
}

#[tokio::test]
async fn a_kept_ticket_serves_every_dial_until_its_renew_point() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    for _ in 0..20 {
        assert_eq!(cache.connect("A").await.unwrap().ticket, "t1");
    }
    assert_eq!(platform.asks.load(Ordering::SeqCst), 1);
    assert_eq!(cache.stats().hits, 19);
    // Another machine has its own ticket.
    assert_eq!(cache.connect("B").await.unwrap().ticket, "t2");
}

#[tokio::test]
async fn dials_that_arrive_together_share_one_ask() {
    let platform = Arc::new(Minting {
        wait: Duration::from_millis(50),
        ..Arc::into_inner(Minting::new(300)).unwrap()
    });
    let cache = TicketCache::new(platform.clone());
    let dials: Vec<_> = (0..16)
        .map(|_| {
            let cache = cache.clone();
            tokio::spawn(async move { cache.connect("A").await.unwrap().ticket })
        })
        .collect();
    for dial in dials {
        assert_eq!(dial.await.unwrap(), "t1");
    }
    assert_eq!(platform.asks.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_refusal_is_never_kept() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    *platform.refusing.lock().unwrap() = true;
    assert!(cache.connect("A").await.is_err());
    assert!(cache.connect("A").await.is_err());
    *platform.refusing.lock().unwrap() = false;
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t3");
}

#[tokio::test]
async fn a_relay_refusal_asks_fresh_and_keeps_the_new_ticket() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t1");
    assert_eq!(cache.fresh("A").await.unwrap().ticket, "t2");
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t2");
}

#[tokio::test]
async fn a_ticket_too_short_to_use_is_not_kept() {
    // Under the margin from the start: every dial asks, as before the cache.
    let platform = Minting::new(10);
    let cache = TicketCache::new(platform.clone());
    cache.connect("A").await.unwrap();
    cache.connect("A").await.unwrap();
    assert_eq!(platform.asks.load(Ordering::SeqCst), 2);
}

#[tokio::test(start_paused = true)]
async fn past_two_thirds_a_dial_takes_the_kept_ticket_and_one_renewal_runs() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t1");
    tokio::time::advance(Duration::from_secs(201)).await;
    // Due: the dial still gets t1 at once, and t2 is asked behind it (once, not per dial).
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t1");
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t1");
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    assert_eq!(platform.asks.load(Ordering::SeqCst), 2);
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t2");
}

#[tokio::test]
async fn seeded_tickets_answer_a_first_dial_without_an_ask() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    cache.seed(vec![ticket("A", 100, 300), ticket("B", 100, 300)]).await;
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t100");
    assert_eq!(cache.connect("B").await.unwrap().ticket, "t100");
    assert_eq!(platform.asks.load(Ordering::SeqCst), 0);
    // A seed with less life left than the kept ticket leaves it.
    cache.seed(vec![ticket("A", 200, 60)]).await;
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t100");
}

#[tokio::test]
async fn clear_forgets_every_ticket() {
    let platform = Minting::new(300);
    let cache = TicketCache::new(platform.clone());
    cache.connect("A").await.unwrap();
    cache.clear();
    assert_eq!(cache.connect("A").await.unwrap().ticket, "t2");
}

#[tokio::test(start_paused = true)]
async fn premint_seeds_every_peer_and_stops_with_the_carrier() {
    let platform = Arc::new(Minting {
        premint: Some(vec!["A".into(), "B".into()]),
        ..Arc::into_inner(Minting::new(300)).unwrap()
    });
    let cache = TicketCache::new(platform.clone());
    let alive = Arc::new(());
    let loop_ = tokio::spawn(cache.clone().premint_until(Arc::downgrade(&alive)));
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    assert_eq!(cache.connect("B").await.unwrap().ticket, "t100");
    assert_eq!(platform.asks.load(Ordering::SeqCst), 0);
    drop(alive);
    tokio::time::advance(Duration::from_secs(201)).await;
    tokio::time::timeout(Duration::from_secs(1), loop_).await.unwrap().unwrap();
}
