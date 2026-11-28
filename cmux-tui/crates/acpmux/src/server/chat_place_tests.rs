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
    let v = answer(
        &json!({"chat": "c-read-1", "account": account}),
        &verdict(false),
        &peers(),
        false,
        None,
    );
    assert_eq!(v["chip"], "Auto · This Mac: 12 GB free", "{v:#}");
    assert_eq!(v["place"], json!({"on": "this-mac"}));
    assert_eq!(v["picked"], false);
    assert_eq!(v["mode"], json!({"mode": "auto"}));

    let v = answer(
        &json!({"chat": "c-read-1", "account": account}),
        &verdict(true),
        &peers(),
        false,
        None,
    );
    assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy", "{v:#}");
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}));

    // Signed out (no account sent): this Mac, busy.
    let v = answer(&json!({"chat": "c-read-1"}), &verdict(true), &peers(), false, None);
    assert_eq!(v["place"], json!({"on": "this-mac"}), "{v:#}");

    keep("c-read-2", PlaceMode::Machine { id: "studio".into() });
    let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), false, None);
    assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
    assert_eq!(v["picked"], true);
    keep("c-read-2", PlaceMode::Machine { id: "old".into() });
    let v = answer(&json!({"chat": "c-read-2"}), &verdict(false), &peers(), false, None);
    assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");

    // A mode in the params is weighed instead of the chat's.
    let v = answer(
        &json!({"chat": "c-read-2", "mode": "cloud", "account": account}),
        &verdict(false),
        &peers(),
        false,
        None,
    );
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
    assert_eq!(v["chip"], "Cloud · New VM");
    keep("c-read-2", PlaceMode::Auto);

    // An existing chat with no pick here reads as its stored pin.
    let pinned = Some((PlaceMode::Machine { id: "studio".into() }, true));
    let v = answer(&json!({"chat": "c-read-3"}), &verdict(false), &peers(), false, pinned);
    assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
    assert_eq!(v["picked"], true);
}

/// A busy Mac's verdict with `studio` enrolled and accepting (its `autoCloud` block, as
/// `placement.rs` copies it from studio's health) and `old` on an older build (none).
fn verdict_enrolled() -> Value {
    json!({"hosts": [
        {"name": "mac", "local": true, "room": 0.0, "ramFree": 1e9, "load": true,
         "refused": "no room: RAM is the limit",
         "autoCloud": {"v": 1, "enrolled": false, "caps": ["arm64", "macos"]}},
        {"name": "studio", "local": false, "room": 6.0, "ramFree": 40e9, "load": false,
         "autoCloud": {"v": 1, "enrolled": true, "accepting": true, "ownerIdle": true,
            "caps": ["arm64", "macos", "xcode"], "policy": {"teams": [], "agents": []}}},
        {"name": "old", "local": false, "room": 9.0, "load": false}]})
}

/// New: with AutoCloud on here, a busy Mac places on the enrolled, idle peer before Cloud,
/// and says so (`v: 2`, `tier: "enrolled"`). Off (the default): Cloud, as before.
#[test]
fn auto_takes_an_enrolled_idle_machine_before_cloud_only_with_autocloud_on() {
    let account: Value = serde_json::from_str(PRO).unwrap();
    let p = json!({"chat": "c-enr-1", "account": account});
    let v = answer(&p, &verdict_enrolled(), &peers(), true, None);
    assert_eq!(v["v"], 3);
    assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
    assert_eq!(v["tier"], "enrolled");
    assert_eq!(v["chip"], "Auto · studio: 40 GB free");
    assert_eq!(v["enrolled"].as_array().map(Vec::len), Some(1), "{v:#}");
    let off = answer(&p, &verdict_enrolled(), &peers(), false, None);
    assert_eq!(off["place"], json!({"on": "cloud", "hybrid": true}), "{off:#}");
    assert_eq!(off["tier"], "freestyle");
    // Our pool, when the caller says it can take the chat: the same Cloud place, its tier.
    let pooled = json!({"chat": "c-enr-1", "account": account, "cloudPool": true});
    let v = answer(&pooled, &verdict_enrolled(), &peers(), false, None);
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
    assert_eq!(v["tier"], "cloud-pool");
    // A version 2 answer's tier still reads.
    assert_eq!(
        serde_json::from_value::<place_mode::Tier>(json!("cloud")).unwrap(),
        place_mode::Tier::Freestyle
    );
    // Its link down: not a candidate.
    let down = vec![json!({"name": "studio", "connected": false, "state": "offline"})];
    let v = answer(&p, &verdict_enrolled(), &down, true, None);
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
    // Mac work no enrolled Mac fits (no simulator on studio) never goes to the cloud.
    let need = json!({"chat": "c-enr-1", "account": account,
        "need": {"caps": ["ios-simulator"]}});
    let v = answer(&need, &verdict_enrolled(), &peers(), true, None);
    assert_eq!(v["place"], json!({"on": "nowhere"}), "{v:#}");
    assert_eq!(v["chip"], "Auto · needs a Mac");
    assert!(v["why"].as_str().unwrap().contains("no enrolled Mac is free"), "{v:#}");
    // Xcode work studio fits goes to studio.
    let need = json!({"chat": "c-enr-1", "account": account, "need": {"caps": ["xcode"]}});
    let v = answer(&need, &verdict_enrolled(), &peers(), true, None);
    assert_eq!(v["place"], json!({"on": "machine", "id": "studio"}), "{v:#}");
}

/// Old against new, both ways: a version 1 reader (the fields it read before) reads a
/// version 2 answer; a version 1 request (no `need`) and a verdict from an older acpmux
/// (no `autoCloud` on any row) give the version 1 answer.
#[test]
fn chat_place_v1_and_v2_read_each_other() {
    #[derive(serde::Deserialize)]
    #[allow(dead_code)]
    struct V1 {
        chat: Option<String>,
        mode: PlaceMode,
        picked: bool,
        place: place_mode::Place,
        why: String,
        chip: String,
        local: Value,
    }
    let account: Value = serde_json::from_str(PRO).unwrap();
    let p = json!({"chat": "c-enr-2", "account": account});
    let new = answer(&p, &verdict_enrolled(), &peers(), true, None);
    let old: V1 = serde_json::from_value(new).expect("a v1 reader reads v2");
    assert_eq!(old.place, place_mode::Place::Machine { id: "studio".into() });
    let v1_verdict = verdict(true);
    let v = answer(&p, &v1_verdict, &peers(), true, None);
    assert_eq!(v["place"], json!({"on": "cloud", "hybrid": true}), "{v:#}");
    assert_eq!(v["chip"], "Auto · Cloud: this Mac is busy");
    assert_eq!(v["enrolled"], json!([]));
    // A v1 Facts (no enrolled, no need, no caps) still parses.
    let facts: Facts = serde_json::from_value(json!({"local": {"name": "mac"},
        "account": {}, "machines": []}))
    .unwrap();
    assert!(facts.enrolled.is_empty() && facts.need == place_mode::Need::default());
    // A v1 Decision (no tier) still parses.
    let d: place_mode::Decision =
        serde_json::from_value(json!({"place": {"on": "this-mac"}, "why": "", "chip": ""}))
            .unwrap();
    assert_eq!(d.tier, None);
}
