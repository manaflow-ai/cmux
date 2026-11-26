use super::*;
use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair};

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const C: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn pair(seed: u8) -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap()
}

fn keys(pair: &Ed25519KeyPair) -> Vec<cmux_signed_envelope::Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(cmux_signed_envelope::key_id(&raw), raw)]
}

/// `payload` in the envelope web-ota-pointer.py `sign` writes, signed by `pair`.
fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    json!({"schema": 1, "payload": b64.encode(&bytes),
           "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw),
                           "sig": b64.encode(pair.sign(&bytes).as_ref())}]})
    .to_string()
}

fn file(serial: u64, pieces: Value, refuse: Value) -> Value {
    json!({"schema": 1, "purpose": PURPOSE, "channel": "every-merge", "serial": serial,
           "published_at": 1_795_340_000u64, "pieces": pieces, "refuse": refuse})
}

fn opened(payload: &Value) -> Result<Switches, Refusal> {
    let pair = pair(7);
    open(envelope(&pair, payload).as_bytes(), &keys(&pair), "every-merge", 0)
}

#[test]
fn a_signed_file_opens_with_its_switches() {
    let switches = opened(&file(
        3,
        json!({"agent-pane": {"serve": "last-good", "reason": "cmux#1"},
               "pages": {"serve": "bundled"}}),
        json!([A]),
    ))
    .unwrap();
    assert_eq!(switches.serial, 3);
    assert_eq!(switches.pieces["agent-pane"].serve, Serve::LastGood);
    assert_eq!(switches.pieces["agent-pane"].reason, "cmux#1");
    assert_eq!(switches.pieces["pages"].serve, Serve::Bundled);
    assert!(switches.refuse.contains(A));
    assert!(switches.unknown.is_empty());
}

#[test]
fn a_file_signed_by_another_key_is_refused() {
    let body = envelope(&pair(8), &file(1, json!({}), json!([])));
    let refusal = open(body.as_bytes(), &keys(&pair(7)), "every-merge", 0).unwrap_err();
    assert_eq!(refusal.code(), "unsigned");
}

#[test]
fn a_changed_payload_is_refused() {
    let pair = pair(7);
    let mut body: Value =
        serde_json::from_str(&envelope(&pair, &file(1, json!({}), json!([])))).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    body["payload"] = json!(b64.encode(file(2, json!({}), json!([])).to_string()));
    let refusal = open(body.to_string().as_bytes(), &keys(&pair), "every-merge", 0).unwrap_err();
    assert_eq!(refusal.code(), "unsigned");
}

#[test]
fn another_kind_of_signed_file_is_refused() {
    // A web update pointer carries no purpose; the Mac live file carries its own.
    let mut pointer = file(1, json!({}), json!([]));
    pointer.as_object_mut().unwrap().remove("purpose");
    assert_eq!(opened(&pointer).unwrap_err().code(), "wrong_purpose");
    let mut live = file(1, json!({}), json!([]));
    live["purpose"] = json!("cmux-mac-live-update");
    assert_eq!(opened(&live).unwrap_err().code(), "wrong_purpose");
}

#[test]
fn another_channels_file_is_refused() {
    let mut nightly = file(1, json!({}), json!([]));
    nightly["channel"] = json!("nightly");
    assert_eq!(opened(&nightly).unwrap_err(), Refusal::WrongChannel("nightly".to_owned()));
}

#[test]
fn an_older_file_is_refused_and_the_same_one_is_taken_again() {
    let pair = pair(7);
    let body = envelope(&pair, &file(5, json!({}), json!([])));
    let keys = keys(&pair);
    assert_eq!(
        open(body.as_bytes(), &keys, "every-merge", 6).unwrap_err(),
        Refusal::Stale { serial: 5, floor: 6 }
    );
    assert!(open(body.as_bytes(), &keys, "every-merge", 5).is_ok());
}

#[test]
fn a_refuse_entry_that_is_no_key_is_refused() {
    let refusal = opened(&file(1, json!({}), json!(["../../etc"]))).unwrap_err();
    assert_eq!(refusal.code(), "malformed");
}

#[test]
fn an_oversized_file_is_refused_before_it_is_parsed() {
    let body = vec![b' '; MAX_BYTES + 1];
    assert_eq!(open(&body, &[], "every-merge", 0).unwrap_err().code(), "too_large");
}

#[test]
fn a_switch_this_build_cannot_read_serves_the_bundle() {
    let switches = opened(&file(
        1,
        json!({"a-later-piece": {"serve": "bundled"}, "pages": {"serve": "from-the-moon"}}),
        json!([]),
    ))
    .unwrap();
    assert_eq!(switches.unknown, ["a-later-piece", "pages"]);
    let plan = plan(Some(&switches), Some(A), &[B]);
    assert_eq!(plan.source("pages"), &Source::Bundled);
    assert_eq!(plan.source("agent-pane"), &Source::Update(A.to_owned()));
}

#[test]
fn a_finer_id_switches_its_whole_piece() {
    assert_eq!(piece_of("pages"), Some("pages"));
    assert_eq!(piece_of("pages/settings"), Some("pages"));
    assert_eq!(piece_of("agent-pane/pr-49884"), Some("agent-pane"));
    // A name that only starts like a piece is no piece.
    assert_eq!(piece_of("pages-later"), None);
    assert_eq!(piece_of("agent"), None);
    let switches = opened(&file(
        1,
        json!({
            "pages/settings": {"serve": "last-good", "reason": "blank settings"},
            "pages/onboarding": {"serve": "bundled"},
            "agent-pane/composer": {"serve": "from-the-moon"},
        }),
        json!([]),
    ))
    .unwrap();
    assert_eq!(switches.unknown, ["agent-pane"]);
    let plan = plan(Some(&switches), Some(A), &[B]);
    // Of two switches on one piece the bundle wins.
    assert_eq!(plan.source("pages"), &Source::Bundled);
    assert_eq!(plan.source("agent-pane"), &Source::Bundled);
    assert_eq!(plan.source("inspector"), &Source::Update(A.to_owned()));
}

#[test]
fn no_file_serves_the_active_update_everywhere() {
    let plan = plan(None, Some(A), &[B]);
    assert!(plan.pieces.iter().all(|(_, source)| *source == Source::Update(A.to_owned())));
    assert!(!plan.refused_active);
    let bundled = super::plan(None, None, &[]);
    assert!(bundled.pieces.iter().all(|(_, source)| *source == Source::Bundled));
}

#[test]
fn one_piece_is_switched_out_and_the_rest_stay_live() {
    let switches = opened(&file(
        1,
        json!({"agent-pane": {"serve": "last-good"}, "inspector": {"serve": "bundled"}}),
        json!([]),
    ))
    .unwrap();
    let plan = plan(Some(&switches), Some(A), &[B, C]);
    assert_eq!(plan.source("agent-pane"), &Source::Update(B.to_owned()));
    assert_eq!(plan.source("inspector"), &Source::Bundled);
    assert_eq!(plan.source("pages"), &Source::Update(A.to_owned()));
    assert_eq!(plan.source("webviews-app"), &Source::Update(A.to_owned()));
    assert_eq!(plan.pieces.len(), PIECES.len());
}

#[test]
fn last_good_skips_refused_updates_and_ends_at_the_bundle() {
    let switches = opened(&file(1, json!({"pages": {"serve": "last-good"}}), json!([B]))).unwrap();
    assert_eq!(
        plan(Some(&switches), Some(A), &[B, C]).source("pages"),
        &Source::Update(C.to_owned())
    );
    assert_eq!(plan(Some(&switches), Some(A), &[B]).source("pages"), &Source::Bundled);
    // The active update is never its own last good one.
    assert_eq!(plan(Some(&switches), Some(A), &[A]).source("pages"), &Source::Bundled);
}

#[test]
fn a_refused_active_update_rolls_every_piece_back() {
    let switches = opened(&file(1, json!({}), json!([A]))).unwrap();
    let plan = plan(Some(&switches), Some(A), &[B]);
    assert!(plan.refused_active);
    assert!(plan.pieces.iter().all(|(_, source)| *source == Source::Update(B.to_owned())));
    let none_kept = super::plan(Some(&switches), Some(A), &[]);
    assert!(none_kept.pieces.iter().all(|(_, source)| *source == Source::Bundled));
}

#[test]
fn evaluate_takes_a_file_and_gives_the_host_its_next_state() {
    let pair = pair(7);
    let body = envelope(
        &pair,
        &file(4, json!({"agent-pane": {"serve": "last-good", "reason": "cmux#1"}}), json!([])),
    );
    let reply = evaluate_with(
        &json!({"envelope": body, "channel": "every-merge", "floor": 3, "active": A,
                "kept": [B], "now": 10}),
        &keys(&pair),
    );
    assert_eq!(reply["taken"], true);
    assert_eq!(reply["refusal"], Value::Null);
    assert_eq!(reply["serial"], 4);
    assert_eq!(reply["pieces"]["agent-pane"]["update"], B);
    assert_eq!(reply["pieces"]["agent-pane"]["serve"], "last-good");
    assert_eq!(reply["pieces"]["agent-pane"]["reason"], "cmux#1");
    assert_eq!(reply["pieces"]["agent-pane"]["output"], PIECES[0].1);
    assert_eq!(reply["pieces"]["pages"]["update"], A);
    assert_eq!(reply["pieces"]["pages"]["serve"], "live");
    assert_eq!(reply["log"]["verdict"], "taken");
    assert_eq!(reply["log"]["switched"], json!(["agent-pane=last-good"]));
    assert_eq!(reply["log"]["at"], 10);
}

#[test]
fn a_refused_or_missing_file_keeps_the_last_switches() {
    let pair = pair(7);
    let keys = keys(&pair);
    let first = evaluate_with(
        &json!({"envelope": envelope(&pair, &file(4, json!({"pages": {"serve": "bundled"}}), json!([]))),
                "channel": "every-merge", "floor": 0, "active": A, "kept": []}),
        &keys,
    );
    let last = first["switches"].clone();
    // A replayed older file that switches nothing: refused, pages stays out.
    let replay = evaluate_with(
        &json!({"envelope": envelope(&pair, &file(2, json!({}), json!([]))),
                "channel": "every-merge", "floor": 4, "active": A, "kept": [], "last": last}),
        &keys,
    );
    assert_eq!(replay["taken"], false);
    assert_eq!(replay["refusal"]["code"], "stale");
    assert_eq!(replay["serial"], 4);
    assert_eq!(replay["pieces"]["pages"]["update"], Value::Null);
    assert_eq!(replay["pieces"]["pages"]["serve"], "bundled");
    assert_eq!(replay["log"]["verdict"], "stale");
    // No file read at all (offline): the same.
    let offline = evaluate_with(
        &json!({"envelope": null, "channel": "every-merge", "floor": 4, "active": A,
                "kept": [], "last": last}),
        &keys,
    );
    assert_eq!(offline["taken"], false);
    assert_eq!(offline["pieces"]["pages"]["serve"], "bundled");
    assert_eq!(offline["log"]["verdict"], "no_file");
    // The next file switches it back in.
    let back = evaluate_with(
        &json!({"envelope": envelope(&pair, &file(5, json!({}), json!([]))),
                "channel": "every-merge", "floor": 4, "active": A, "kept": [], "last": last}),
        &keys,
    );
    assert_eq!(back["taken"], true);
    assert_eq!(back["pieces"]["pages"]["update"], A);
    assert_eq!(back["pieces"]["pages"]["serve"], "live");
}

#[test]
fn the_last_switches_of_another_channel_are_not_used() {
    let pair = pair(7);
    let first = evaluate_with(
        &json!({"envelope": envelope(&pair, &file(4, json!({"pages": {"serve": "bundled"}}), json!([]))),
                "channel": "every-merge", "floor": 0, "active": A, "kept": []}),
        &keys(&pair),
    );
    let nightly = evaluate_with(
        &json!({"envelope": null, "channel": "nightly", "floor": 0, "active": A, "kept": [],
                "last": first["switches"]}),
        &keys(&pair),
    );
    assert_eq!(nightly["pieces"]["pages"]["serve"], "live");
}

#[test]
fn the_production_keys_refuse_a_test_signed_file() {
    let body = envelope(&pair(7), &file(1, json!({"pages": {"serve": "bundled"}}), json!([])));
    let reply = evaluate(&json!({"envelope": body, "channel": "every-merge", "active": A}));
    assert_eq!(reply["taken"], false);
    assert_eq!(reply["refusal"]["code"], "unsigned");
    assert_eq!(reply["pieces"]["pages"]["serve"], "live");
}

fn repo(path: &str) -> String {
    // affected-reads: Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json scripts/cmux-next/web-bundle-key.py
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../");
    std::fs::read_to_string(format!("{root}{path}")).unwrap_or_else(|e| panic!("{path}: {e}"))
}

#[test]
fn keys_match_the_web_update_keys() {
    let pinned = cmux_signed_envelope::keys_from_json(&repo(
        "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json",
    ));
    assert!(!pinned.is_empty());
    assert_eq!(trusted_keys(), pinned);
    assert_eq!(trusted_keys().len(), KEYS.len());
}

#[test]
fn pieces_are_the_web_bundle_outputs() {
    let script = repo("scripts/cmux-next/web-bundle-key.py");
    let list = script.split("OUTPUTS = [").nth(1).unwrap().split(']').next().unwrap();
    let outputs: Vec<&str> = list
        .lines()
        .map(|line| line.trim().trim_matches(|c| c == '"' || c == ','))
        .filter(|l| !l.is_empty())
        .collect();
    let pieces: Vec<&str> = PIECES.iter().map(|(_, output)| *output).collect();
    assert_eq!(pieces, outputs);
    for (name, output) in PIECES {
        assert!(output.contains(name), "{name} names {output}");
    }
}
