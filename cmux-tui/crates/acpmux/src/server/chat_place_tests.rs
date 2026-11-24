use super::*;

fn verdict(busy: bool) -> Value {
    json!({"hosts": [{"name": "mac", "local": true, "room": if busy { 0.0 } else { 3.0 },
        "ramFree": 12e9, "load": busy, "refused": busy.then_some("no room: RAM is the limit")}]})
}

fn peers() -> Vec<Value> {
    vec![
        json!({"name": "studio", "connected": true, "state": "connected"}),
        json!({"name": "old", "connected": false, "state": "offline"}),
    ]
}

const PRO: &str = r#"{"plan": "next_pro", "signedIn": true}"#;

/// A pick is the chat's own: another chat stays Auto, and picking Auto clears it.
#[test]
fn a_pick_is_kept_for_its_chat_only() {
    keep("chat-a", PlaceMode::Cloud);
    assert_eq!(mode_of("chat-a"), (PlaceMode::Cloud, true));
    assert_eq!(mode_of("chat-b"), (PlaceMode::Auto, false));
    keep("chat-a", PlaceMode::Auto);
    assert_eq!(mode_of("chat-a"), (PlaceMode::Auto, false));
}

/// The read: Auto's chip from this Mac's room, Cloud when it is busy, a pinned peer only
/// while its link is up.
#[test]
fn the_read_names_the_place_and_the_chip() {
    let account: Value = serde_json::from_str(PRO).unwrap();
    let v = answer(&json!({"chat": "c-read-1", "account": account}), &verdict(false), &peers());
    assert_eq!(v["chip"], "Auto · This Mac: 12 GB free", "{v:#}");
    assert_eq!(v["place"], json!({"on": "this-mac"}));
    assert_eq!(v["picked"], false);
    assert_eq!(v["mode"], json!({"mode": "auto"}));

    let v = answer(&json!({"chat": "c-read-1", "account": account}), &verdict(true), &peers());
    assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy", "{v:#}");
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}));

    // Signed out (no account sent): this Mac, busy.
    let v = answer(&json!({"chat": "c-read-1"}), &verdict(true), &peers());
    assert_eq!(v["place"], json!({"on": "this-mac"}), "{v:#}");

    keep("c-read-2", PlaceMode::Machine { id: "studio".into() });
    let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers());
    assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
    assert_eq!(v["picked"], true);
    keep("c-read-2", PlaceMode::Machine { id: "old".into() });
    let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers());
    assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");

    // A mode in the params is weighed instead of the chat's.
    let v = answer(
        &json!({"chat": "c-read-2", "mode": "cloud", "account": account}),
        &verdict(false),
        &peers(),
    );
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
    assert_eq!(v["chip"], "Cloud · New VM");
    keep("c-read-2", PlaceMode::Auto);
}
