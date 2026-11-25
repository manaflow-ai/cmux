//! [`TicketCache`]: a ticket that names its grant travels with that grant for
//! at most [`GRANT_LANES`] allocations, then the pair is fetched afresh with
//! the device key (cmuxterm-hq#19075); an unbound ticket is renewed as before.

use std::sync::Arc;
use std::sync::Mutex;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::json;

use super::answer::{
    CarrierAnswer, CarrierSource, GRANT_LANES, SourceError, TicketCache, parse_answer,
    ticket_names_grant,
};

const MACHINE: &str = "vm_0123456789abcdefghij";
const KEY: [u8; 32] = [7; 32];

fn ticket(n: usize, bound: bool) -> String {
    let mut claims = json!({"version": 2, "slot": "slot-1", "expires_at_unix": 4_000_000_000_u64});
    if bound {
        claims["grant"] = json!(format!("digest-{n}"));
    }
    format!("v2.{}.mac{n}", URL_SAFE_NO_PAD.encode(claims.to_string()))
}

fn answer(n: usize, bound: bool, expires_at: u64) -> CarrierAnswer {
    parse_answer(&json!({
        "relay": "relay+do://relay.example",
        "slot": "slot-1",
        "ticket": ticket(n, bound),
        "expires_at": expires_at,
        "grant": format!("grant.{n}.sig"),
    }))
    .unwrap()
}

/// Answers its nth fetch with pair n+1, recording the key each fetch carried.
struct Counting {
    bound: bool,
    keys: Mutex<Vec<Option<[u8; 32]>>>,
}

#[async_trait]
impl CarrierSource for Counting {
    async fn fetch(
        &self,
        machine: &str,
        key: Option<&[u8; 32]>,
    ) -> Result<CarrierAnswer, SourceError> {
        assert_eq!(machine, MACHINE);
        let mut keys = self.keys.lock().unwrap();
        keys.push(key.copied());
        Ok(answer(keys.len() + 1, self.bound, 4_000_000_000))
    }
}

fn make(bound: bool, first_expires_at: u64) -> (Arc<Counting>, Arc<TicketCache>) {
    let source = Arc::new(Counting { bound, keys: Mutex::new(Vec::new()) });
    let cache =
        TicketCache::new(source.clone(), MACHINE.into(), KEY, &answer(1, bound, first_expires_at));
    (source, cache)
}

#[test]
fn a_ticket_names_a_grant_only_through_its_claims() {
    assert!(ticket_names_grant(&ticket(1, true)));
    assert!(!ticket_names_grant(&ticket(1, false)));
    for bad in ["", "v2", "v2.!!.mac", "v1.e30.mac", "v2.e30.mac.extra", "opaque-ticket"] {
        assert!(!ticket_names_grant(bad), "{bad}");
    }
}

#[tokio::test]
async fn a_bound_pair_serves_four_lanes_then_is_fetched_afresh_with_the_device_key() {
    let (source, cache) = make(true, 4_000_000_000);
    for _ in 0..GRANT_LANES {
        let credential = cache.credential().await.unwrap();
        assert_eq!(credential.ticket.as_str(), ticket(1, true));
        assert_eq!(credential.grant.as_deref().map(String::as_str), Some("grant.1.sig"));
    }
    // A control socket's authentication spends no grant.
    assert_eq!(cache.ticket().await.unwrap(), ticket(1, true));
    assert!(source.keys.lock().unwrap().is_empty());

    let fifth = cache.credential().await.unwrap();
    assert_eq!(fifth.ticket.as_str(), ticket(2, true));
    assert_eq!(fifth.grant.as_deref().map(String::as_str), Some("grant.2.sig"));
    assert_eq!(*source.keys.lock().unwrap(), vec![Some(KEY)]);
    for _ in 1..GRANT_LANES {
        assert_eq!(cache.credential().await.unwrap().ticket.as_str(), ticket(2, true));
    }
    assert_eq!(cache.credential().await.unwrap().ticket.as_str(), ticket(3, true));
    assert_eq!(*source.keys.lock().unwrap(), vec![Some(KEY), Some(KEY)]);
}

#[tokio::test]
async fn an_expiring_bound_pair_is_fetched_afresh_with_the_device_key() {
    let (source, cache) = make(true, 1);
    let credential = cache.credential().await.unwrap();
    assert_eq!(credential.ticket.as_str(), ticket(2, true));
    assert_eq!(*source.keys.lock().unwrap(), vec![Some(KEY)]);
}

#[tokio::test]
async fn an_unbound_ticket_carries_no_grant_and_is_renewed_ticket_only() {
    let (source, cache) = make(false, 4_000_000_000);
    for _ in 0..(GRANT_LANES * 3) {
        let credential = cache.credential().await.unwrap();
        assert_eq!(credential.ticket.as_str(), ticket(1, false));
        assert!(credential.grant.is_none(), "an unbound ticket's grant is not presented");
    }
    assert!(source.keys.lock().unwrap().is_empty());

    let (source, cache) = make(false, 1);
    assert_eq!(cache.credential().await.unwrap().ticket.as_str(), ticket(2, false));
    assert_eq!(*source.keys.lock().unwrap(), vec![None]);
}
