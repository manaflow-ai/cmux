use super::*;

fn ana() -> Who {
    Who { id: "tailnet:ana".to_owned(), name: "Ana".to_owned() }
}

fn typing(presence: &Presence) -> Option<bool> {
    let note = presence.snapshot("c");
    note["participants"].as_array()?.first().map(|p| p["typing"] == true)
}

/// A newer `on` restarts the 8 s and the older timer ends without effect; an `off` and a close
/// end it at once. (The 8 s expiry itself: `tests/hub_integration/presence.rs`.)
#[tokio::test(start_paused = true)]
async fn a_newer_on_restarts_the_expiry_and_off_or_close_ends_it() {
    let presence = Presence::default();
    presence.typing("c", "conn", &ana(), true).unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    presence.typing("c", "conn", &ana(), true).unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(typing(&presence), Some(true), "the first timer ended the newer on");
    tokio::time::sleep(Duration::from_millis(3001)).await;
    assert_eq!(typing(&presence), None);

    presence.typing("c", "conn", &ana(), true).unwrap();
    presence.typing("c", "conn", &ana(), false).unwrap();
    assert_eq!(typing(&presence), None);
    presence.typing("c", "other", &ana(), true).unwrap();
    presence.close("other");
    assert_eq!(presence.snapshot("c")["participants"], json!([]));
}
