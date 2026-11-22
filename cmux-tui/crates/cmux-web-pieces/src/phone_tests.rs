use super::*;
use crate::MAX_BYTES;
use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair};

fn pair(seed: u8) -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap()
}

fn keys(pair: &Ed25519KeyPair) -> Vec<cmux_signed_envelope::Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(cmux_signed_envelope::key_id(&raw), raw)]
}

fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    json!({"schema": 1, "payload": b64.encode(&bytes),
           "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw),
                           "sig": b64.encode(pair.sign(&bytes).as_ref())}]})
    .to_string()
}

fn file(serial: u64, pieces: Value) -> Value {
    json!({"schema": 1, "purpose": PURPOSE, "channel": "internal", "serial": serial,
           "published_at": 1_795_340_000u64, "pieces": pieces})
}

/// One read of `envelope` by a phone that last took `last` at serial `floor`.
fn read(envelope: Option<&str>, floor: u64, last: Option<&Value>) -> Value {
    let mut input = json!({"envelope": envelope, "channel": "internal", "floor": floor, "now": 10});
    if let Some(last) = last {
        input["last"] = last.clone();
    }
    evaluate_with(&input, &keys(&pair(7)))
}

fn signed(payload: &Value) -> String {
    envelope(&pair(7), payload)
}

/// The phone holding `markdown-web` off at serial 3.
fn held() -> Value {
    read(
        Some(&signed(&file(3, json!({"markdown-web": {"serve": "bundled", "reason": "r"}})))),
        0,
        None,
    )
}

/// A refused read leaves the phone exactly where it was: the piece it held off stays off, and
/// nothing else is switched.
fn keeps(reply: &Value, code: &str) {
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["refusal"]["code"], code);
    assert_eq!(reply["log"]["verdict"], code);
    assert_eq!(reply["off"], json!({"markdown-web": "r"}));
    assert_eq!(reply["serial"], 3);
}

#[test]
fn only_the_internal_testflight_build_reads_a_file() {
    assert_eq!(channel("dev.cmux.app.internal", false), Some("internal"));
    // The App Store app stays off until Leo says so.
    assert_eq!(channel("com.cmux.app", false), None);
    assert_eq!(channel("dev.cmux.app.beta", false), None);
    assert_eq!(channel("dev.cmux.app.demo", false), None);
    assert_eq!(channel("dev.cmux.app.dev", true), None);
    assert_eq!(channel("dev.cmux.app.internal", true), None);
    assert_eq!(channel("", false), None);
    assert_eq!(file_name("internal"), "pieces-ios-internal.json");
}

#[test]
fn a_piece_goes_off_and_comes_back_on() {
    // Nothing published: everything is on.
    let none = read(None, 0, None);
    assert_eq!(none["off"], json!({}));
    assert_eq!(none["log"]["verdict"], "no_file");

    // A switch turns the piece off, with its reason.
    let off = held();
    assert_eq!(off["taken"], true);
    assert_eq!(off["off"], json!({"markdown-web": "r"}));
    assert_eq!(off["serial"], 3);
    assert_eq!(off["log"]["verdict"], "taken");
    assert_eq!(off["log"]["off"], json!(["markdown-web"]));

    // The next launch, reading only the disk, holds it off before any request.
    let launch = read(None, 3, Some(&off["switches"]));
    assert_eq!(launch["off"], json!({"markdown-web": "r"}));
    assert_eq!(launch["taken"], false);

    // A later file that no longer names it turns it on again.
    let on = read(Some(&signed(&file(4, json!({})))), 3, Some(&off["switches"]));
    assert_eq!(on["taken"], true);
    assert_eq!(on["off"], json!({}));
    assert_eq!(on["serial"], 4);
    let launch = read(None, 4, Some(&on["switches"]));
    assert_eq!(launch["off"], json!({}));
}

#[test]
fn every_piece_can_be_switched_and_each_alone() {
    for (piece, _) in PIECES {
        let reply = read(Some(&signed(&file(1, json!({(*piece): {"serve": "bundled"}})))), 0, None);
        assert_eq!(reply["off"], json!({(*piece): ""}), "{piece}");
    }
    let all: serde_json::Map<String, Value> = PIECES
        .iter()
        .map(|(piece, _)| ((*piece).to_owned(), json!({"serve": "last-good", "reason": "x"})))
        .collect();
    let reply = read(Some(&signed(&file(1, Value::Object(all)))), 0, None);
    assert_eq!(reply["off"].as_object().unwrap().len(), PIECES.len());
}

#[test]
fn a_finer_id_and_an_unreadable_switch_turn_the_whole_piece_off() {
    let reply = read(
        Some(&signed(&file(
            1,
            json!({"markdown-web/math": {"serve": "bundled", "reason": "m"},
                   "terminal-predictive-echo": {"serve": "something-newer"}}),
        ))),
        0,
        None,
    );
    assert_eq!(reply["off"], json!({"markdown-web": "m", "terminal-predictive-echo": ""}));
    assert_eq!(reply["unknown"], json!([]));
    // And it survives the disk.
    let launch = read(None, 1, Some(&reply["switches"]));
    assert_eq!(launch["off"], reply["off"]);
}

#[test]
fn an_unknown_piece_name_switches_nothing() {
    // A piece of a later build, and the Mac's piece names, are no piece of this one.
    let reply = read(
        Some(&signed(&file(
            1,
            json!({"some-later-piece": {"serve": "bundled"}, "agent-pane": {"serve": "bundled"},
                   "markdown-webs": {"serve": "bundled"}}),
        ))),
        0,
        None,
    );
    assert_eq!(reply["taken"], true);
    assert_eq!(reply["off"], json!({}));
    assert_eq!(reply["unknown"], json!(["agent-pane", "markdown-webs", "some-later-piece"]));
    assert_eq!(reply["log"]["unknown"], reply["unknown"]);
}

#[test]
fn an_unsigned_file_is_refused() {
    let last = held();
    let plain = file(9, json!({})).to_string();
    keeps(&read(Some(&plain), 3, Some(&last["switches"])), "unsigned");
    keeps(&read(Some("<html>not json</html>"), 3, Some(&last["switches"])), "unsigned");
    keeps(&read(Some(""), 3, Some(&last["switches"])), "unsigned");
}

#[test]
fn a_file_signed_by_another_key_is_refused() {
    let last = held();
    let forged = envelope(&pair(8), &file(9, json!({})));
    keeps(&read(Some(&forged), 3, Some(&last["switches"])), "unsigned");
}

#[test]
fn a_changed_payload_is_refused() {
    let last = held();
    let mut body: Value = serde_json::from_str(&signed(&file(9, json!({})))).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    body["payload"] = json!(b64.encode(file(10, json!({})).to_string()));
    keeps(&read(Some(&body.to_string()), 3, Some(&last["switches"])), "unsigned");
}

#[test]
fn an_older_serial_is_refused() {
    let last = held();
    // A replay of an older file that had the piece on.
    let reply = read(Some(&signed(&file(2, json!({})))), 3, Some(&last["switches"]));
    keeps(&reply, "stale");
    // The same serial again is the same file read again: taken.
    let again = read(
        Some(&signed(&file(3, json!({"markdown-web": {"serve": "bundled", "reason": "r"}})))),
        3,
        Some(&last["switches"]),
    );
    assert_eq!(again["taken"], true);
    assert_eq!(again["off"], json!({"markdown-web": "r"}));
}

#[test]
fn an_oversize_file_is_refused() {
    let last = held();
    let big = signed(&file(
        9,
        json!({"markdown-web": {"serve": "bundled",
                                                        "reason": "x".repeat(MAX_BYTES)}}),
    ));
    keeps(&read(Some(&big), 3, Some(&last["switches"])), "too_large");
}

#[test]
fn the_macs_file_and_another_channels_file_are_refused() {
    let last = held();
    let mut mac = file(9, json!({}));
    mac["purpose"] = json!(crate::PURPOSE);
    keeps(&read(Some(&signed(&mac)), 3, Some(&last["switches"])), "wrong_purpose");
    let mut none = file(9, json!({}));
    none.as_object_mut().unwrap().remove("purpose");
    keeps(&read(Some(&signed(&none)), 3, Some(&last["switches"])), "wrong_purpose");
    let mut other = file(9, json!({}));
    other["channel"] = json!("app-store");
    keeps(&read(Some(&signed(&other)), 3, Some(&last["switches"])), "wrong_channel");
    // The phone's file does not open as the Mac's either.
    let pair = pair(7);
    let phone = envelope(&pair, &file(9, json!({})));
    let refusal = crate::open(phone.as_bytes(), &keys(&pair), "internal", 0).unwrap_err();
    assert_eq!(refusal.code(), "wrong_purpose");
}

#[test]
fn a_malformed_payload_is_refused() {
    let last = held();
    let mut schema = file(9, json!({}));
    schema["schema"] = json!(2);
    keeps(&read(Some(&signed(&schema)), 3, Some(&last["switches"])), "malformed");
    let mut pieces = file(9, json!({}));
    pieces["pieces"] = json!(["markdown-web"]);
    keeps(&read(Some(&signed(&pieces)), 3, Some(&last["switches"])), "malformed");
}

#[test]
fn a_refused_first_read_switches_nothing() {
    let reply = read(Some("garbage"), 0, None);
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["off"], json!({}));
    assert_eq!(reply["switches"], Value::Null);
}

#[test]
fn kept_switches_of_another_channel_are_not_used() {
    let mut last = held()["switches"].clone();
    last["channel"] = json!("app-store");
    let reply = read(None, 3, Some(&last));
    assert_eq!(reply["off"], json!({}));
}

#[test]
fn the_pinned_keys_refuse_a_file_signed_by_a_test_key() {
    let input = json!({"envelope": signed(&file(1, json!({"markdown-web": {"serve": "bundled"}}))),
                       "channel": "internal", "floor": 0, "now": 1});
    let reply = evaluate(&input);
    assert_eq!(reply["refusal"]["code"], "unsigned");
    assert_eq!(reply["off"], json!({}));
}
