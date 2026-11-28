use super::*;
use std::sync::Arc;

fn answer(json: serde_json::Value) -> CarrierAnswer {
    serde_json::from_value(json).unwrap()
}

fn placed(relays: &[&str]) -> Vec<PlacedTicket> {
    relays
        .iter()
        .map(|r| PlacedTicket { relay: (*r).to_owned(), ticket: format!("t-{r}"), expires_at: 0 })
        .collect()
}

#[test]
fn an_answer_with_no_placed_reads_as_before() {
    let old = answer(serde_json::json!({"relay": "relay+do://a", "slot": "s", "ticket": "t"}));
    assert!(old.placed.is_empty());
    assert_eq!(ticket_on(&old, "relay+do://a"), "t");
    assert_eq!(dial_order(None, vec!["relay+do://a".into()]), vec!["relay+do://a"]);
}

#[test]
fn each_relay_authenticates_with_its_own_ticket() {
    let new = answer(serde_json::json!({"relay": "relay+do://a", "slot": "s", "ticket": "cloud",
    "placed": [
        {"relay": "relay+wss://west.example", "ticket": "west", "expires_at": 9},
        {"relay": "relay+https://east.example:8443", "ticket": "east"},
    ]}));
    assert_eq!(ticket_on(&new, "relay+do://a"), "cloud");
    assert_eq!(ticket_on(&new, "relay+wss://west.example"), "west");
    assert_eq!(ticket_on(&new, "relay+https://east.example:8443"), "east");
    // The Debug form never shows a ticket.
    assert!(!format!("{:?}", new.placed).contains("west\""));
}

#[test]
fn rank_puts_the_nearest_first_and_drops_the_unreachable() {
    let ms = |n| Some(Duration::from_millis(n));
    let ranked = rank(vec![
        ("far".into(), ms(80)),
        ("gone".into(), None),
        ("near".into(), ms(4)),
        ("mid".into(), ms(30)),
        ("mid2".into(), ms(30)),
    ]);
    assert_eq!(ranked, vec!["near", "mid", "mid2", "far"]);
    assert!(rank(vec![("gone".into(), None)]).is_empty());
}

#[test]
fn a_dial_tries_the_nearest_placed_relay_then_the_platforms() {
    let order = dial_order(
        Some("relay+wss://near.example".into()),
        vec!["relay+do://a".into(), "relay+do://b".into()],
    );
    assert_eq!(order, vec!["relay+wss://near.example", "relay+do://a", "relay+do://b"]);
}

#[test]
fn addresses_take_the_schemes_port() {
    assert_eq!(address("relay+wss://r.example"), Some(("r.example".into(), 443)));
    assert_eq!(address("relay+https://r.example:8443"), Some(("r.example".into(), 8443)));
    assert_eq!(address("relay+ws://127.0.0.1:9"), Some(("127.0.0.1".into(), 9)));
    assert_eq!(address("relay+do://r.example"), None);
}

#[tokio::test]
async fn nearest_picks_by_measured_round_trip_and_never_waits_on_a_dial() {
    let nearest = Arc::new(Nearest::default());
    let list = placed(&["relay+wss://a.example", "relay+wss://b.example", "relay+wss://c.example"]);
    nearest.record("relay+wss://a.example", Some(Duration::from_millis(50)));
    nearest.record("relay+wss://b.example", Some(Duration::from_millis(5)));
    nearest.record("relay+wss://c.example", None);
    assert_eq!(nearest.now(&list).as_deref(), Some("relay+wss://b.example"));
    assert_eq!(nearest.nearest(&list).await.as_deref(), Some("relay+wss://b.example"));
    // No placed relay: nothing to measure, nothing first.
    assert_eq!(nearest.now(&[]), None);
}

#[tokio::test]
async fn a_probe_times_a_listening_relay_and_misses_a_closed_one() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let up = probe(&format!("relay+ws://127.0.0.1:{port}"), PROBE_WAIT).await;
    assert!(up.is_some_and(|rtt| rtt < PROBE_WAIT));
    drop(listener);
    assert_eq!(probe(&format!("relay+ws://127.0.0.1:{port}"), PROBE_WAIT).await, None);
    assert_eq!(probe("relay+do://r.example", PROBE_WAIT).await, None);
}

#[tokio::test]
async fn an_unmeasured_relay_is_measured_behind_the_dial() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let relay = format!("relay+ws://127.0.0.1:{port}");
    let nearest = Arc::new(Nearest::default());
    let list = placed(&[relay.as_str()]);
    // The first dial goes the platform's way; the probe runs behind it.
    assert_eq!(nearest.now(&list), None);
    let deadline = Instant::now() + Duration::from_secs(5);
    while nearest.now(&list).is_none() {
        assert!(Instant::now() < deadline, "the probe never came in");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(nearest.now(&list), Some(relay));
}
