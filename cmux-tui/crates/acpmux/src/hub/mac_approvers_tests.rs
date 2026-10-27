use super::*;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};

fn key() -> EcdsaKeyPair {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    super::super::approvers::hex(bytes)
}

fn dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("macap-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(path: &Path, macs: Value) {
    crate::config::write_atomic(path, json!({"macs": macs}).to_string().as_bytes()).unwrap();
}

fn enrolled(k: &EcdsaKeyPair, tag: &str) -> (MacApprovers, PathBuf) {
    let path = dir(tag).join(FILE);
    write(
        &path,
        json!([{"id": "mac-1", "publicKey": hex(k.public_key().as_ref()), "name": "Mac"}]),
    );
    let set = MacApprovers::default();
    set.open(path.clone());
    (set, path)
}

fn tool_ask() -> Value {
    json!({"toolCall": {"toolCallId": "call-1", "title": "rm", "kind": "execute"},
           "options": [{"optionId": "yes", "kind": "allow_once"},
                       {"optionId": "always", "kind": "allow_always"},
                       {"optionId": "no", "kind": "reject_once"}]})
}

fn parts<'a>(tool_call: &'a str, option: &'a str, expires: u64, answers: &'a str) -> Parts<'a> {
    Parts {
        instance: "inst",
        mac: "mac-1",
        session: "s1",
        permission: "p1",
        tool_call,
        option,
        nonce: "n1",
        expires_at: expires,
        answers,
    }
}

fn sign(k: &EcdsaKeyPair, p: &Parts<'_>) -> String {
    hex(k.sign(&ring::rand::SystemRandom::new(), &message(p)).unwrap().as_ref())
}

#[allow(clippy::too_many_arguments)]
fn check(
    set: &MacApprovers,
    request: &Value,
    option: &str,
    sig: &str,
    expires: u64,
    answers: Option<&Value>,
    now: u64,
) -> bool {
    let decision = json!({"approver": "mac-1", "expiresAt": expires, "signature": sig});
    set.verifies_then("inst", "s1", "p1", request, option, "n1", answers, &decision, now, || true)
}

#[test]
fn the_wire_payload_is_fixed() {
    // The same vector is in the app's AcpmuxMacApproverTests.
    use sha2::Digest;
    let nonce = "ab".repeat(32);
    let m = message(&Parts {
        instance: "0123abcd",
        mac: "mac-9f1c2d3e4f5a6b7c",
        session: "sess-1",
        permission: "perm-7",
        tool_call: "toolu_01",
        option: "allow_once",
        nonce: &nonce,
        expires_at: 1_760_000_000,
        answers: "",
    });
    assert!(m.starts_with(b"acpmux-mac-approver-decision-v1\0"));
    assert_eq!(
        hex(&sha2::Sha256::digest(&m)),
        "e78a2bf7ed824fa614115c1c2fdc73b913c3486d1213b74e73b57c6bafcec4a0"
    );
}

#[test]
fn a_macs_signature_counts_for_its_one_time_allow_and_every_change_fails() {
    let k = key();
    let (set, _) = enrolled(&k, "allow");
    let now = 1_000;
    let ask = tool_ask();
    let good = sign(&k, &parts("call-1", "yes", now + 120, ""));
    assert!(check(&set, &ask, "yes", &good, now + 120, None, now));
    // Expired, too far ahead, a changed expiry, another key.
    assert!(!check(&set, &ask, "yes", &good, now + 120, None, now + 121));
    let far = sign(&k, &parts("call-1", "yes", now + MAX_LIFETIME + 1, ""));
    assert!(!check(&set, &ask, "yes", &far, now + MAX_LIFETIME + 1, None, now));
    assert!(!check(&set, &ask, "yes", &good, now + 119, None, now));
    let other = sign(&key(), &parts("call-1", "yes", now + 120, ""));
    assert!(!check(&set, &ask, "yes", &other, now + 120, None, now));
    // Another tool call, session, permission, nonce or daemon run.
    let mut moved = ask.clone();
    moved["toolCall"]["toolCallId"] = json!("call-2");
    assert!(!check(&set, &moved, "yes", &good, now + 120, None, now));
    let decision = json!({"approver": "mac-1", "expiresAt": now + 120, "signature": good});
    for (inst, s, p, n) in [
        ("x", "s1", "p1", "n1"),
        ("inst", "s2", "p1", "n1"),
        ("inst", "s1", "p2", "n1"),
        ("inst", "s1", "p1", "n2"),
    ] {
        assert!(!set.verifies_then(inst, s, p, &ask, "yes", n, None, &decision, now, || true));
    }
    // An unknown Mac.
    let decision = json!({"approver": "mac-2", "expiresAt": now + 120, "signature": good});
    assert!(!set.verifies_then(
        "inst",
        "s1",
        "p1",
        &ask,
        "yes",
        "n1",
        None,
        &decision,
        now,
        || true
    ));
    // A lasting allow is never a Mac's, even signed.
    let always = sign(&k, &parts("call-1", "always", now + 120, ""));
    assert!(!check(&set, &ask, "always", &always, now + 120, None, now));
    // A failed commit (a spent nonce) counts nothing.
    let decision = json!({"approver": "mac-1", "expiresAt": now + 120, "signature": good});
    assert!(!set.verifies_then(
        "inst",
        "s1",
        "p1",
        &ask,
        "yes",
        "n1",
        None,
        &decision,
        now,
        || false
    ));
}

#[test]
fn a_mac_never_allows_a_plan_a_mode_switch_or_a_folder_trust() {
    let once = json!([{"optionId": "yes", "kind": "allow_once"}]);
    let plan = json!({"toolCall": {"toolCallId": "c", "kind": "switch_mode"}, "options": once});
    let exit = json!({"toolCall": {"toolCallId": "c", "kind": "other",
                      "_meta": {"claude": {"tool": "ExitPlanMode"}}}, "options": once});
    let trust = json!({"toolCall": {"toolCallId": "c", "_meta": {"acpmux": {"trust": {"cwd": "/w"}}}},
                       "options": once});
    for request in [plan, exit, trust] {
        assert!(!may_allow(&request, "yes", None), "{request}");
    }
    // An option offered twice is no one-time allow.
    let twice = json!({"toolCall": {"toolCallId": "c", "kind": "execute"},
                       "options": [{"optionId": "yes", "kind": "allow_once"},
                                   {"optionId": "yes", "kind": "allow_once"}]});
    assert!(!may_allow(&twice, "yes", None));
    assert!(may_allow(&tool_ask(), "yes", None));
    // Answers go with a question only.
    assert!(!may_allow(&tool_ask(), "yes", Some(&json!({"q": "A"}))));
}

#[test]
fn a_macs_signed_answer_covers_exactly_its_answers() {
    let k = key();
    let (set, _) = enrolled(&k, "answers");
    let question = json!({"toolCall": {"toolCallId": "q-1", "kind": "other",
                          "_meta": {"claude": {"tool": "AskUserQuestion"}}},
                          "options": [{"optionId": "yes", "kind": "allow_once"}]});
    let answers = json!({"Which?": "A"});
    let digest = answers_digest(Some(&answers));
    let sig = sign(&k, &parts("q-1", "yes", 200, &digest));
    assert!(check(&set, &question, "yes", &sig, 200, Some(&answers), 100));
    assert!(!check(&set, &question, "yes", &sig, 200, Some(&json!({"Which?": "B"})), 100));
    assert!(!check(&set, &question, "yes", &sig, 200, None, 100));
}

#[test]
fn removing_a_mac_from_the_file_stops_its_signatures() {
    let k = key();
    let (set, path) = enrolled(&k, "rm");
    let good = sign(&k, &parts("call-1", "yes", 200, ""));
    assert!(check(&set, &tool_ask(), "yes", &good, 200, None, 100));
    assert_eq!(set.view(&json!({}))["macs"][0]["id"], "mac-1");
    write(&path, json!([]));
    // The reload of `host approvals rm`; a check after it reads the change.
    assert_eq!(set.view(&json!({"reload": true}))["macs"], json!([]));
    assert!(!check(&set, &tool_ask(), "yes", &good, 200, None, 100));
}

/// Like `ApproverSet`'s: a reload that drops the Mac while its signed answer
/// is being committed returns only after that commit, and from then on the
/// same signature counts nothing.
#[test]
fn a_reload_during_a_commit_waits_for_it_and_then_the_signature_counts_nothing() {
    use std::time::Duration;
    let k = key();
    let (set, path) = enrolled(&k, "race");
    let set = std::sync::Arc::new(set);
    let good = sign(&k, &parts("call-1", "yes", 200, ""));
    let decision = json!({"approver": "mac-1", "expiresAt": 200, "signature": good});
    let (reloaded, returned) = std::sync::mpsc::channel();
    let reloader = set.clone();
    let ask = tool_ask();
    let committed =
        set.verifies_then("inst", "s1", "p1", &ask, "yes", "n1", None, &decision, 100, || {
            write(&path, json!([]));
            std::thread::spawn(move || {
                reloader.view(&json!({"reload": true}));
                let _ = reloaded.send(());
            });
            returned.recv_timeout(Duration::from_millis(300)).is_err()
        });
    assert!(committed, "the reload returned while the answer was being committed");
    returned.recv_timeout(Duration::from_secs(10)).expect("the reload returns");
    assert!(!check(&set, &ask, "yes", &good, 200, None, 100));
}

#[cfg(unix)]
#[test]
fn a_file_others_may_write_enrolls_no_mac() {
    use std::os::unix::fs::PermissionsExt;
    let k = key();
    let (set, path) = enrolled(&k, "open");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
    let good = sign(&k, &parts("call-1", "yes", 200, ""));
    set.view(&json!({"reload": true}));
    assert!(!check(&set, &tool_ask(), "yes", &good, 200, None, 100));
}

#[test]
fn only_a_valid_key_is_this_machines_own() {
    let set = MacApprovers::default();
    let k = key();
    assert!(set.set_own(&json!({"id": "mac-1", "publicKey": "04"})).is_err());
    let r = set
        .set_own(&json!({"id": "mac-1", "publicKey": hex(k.public_key().as_ref()), "name": "M"}))
        .unwrap();
    assert_eq!(r["fingerprint"], fingerprint(k.public_key().as_ref()));
    assert_eq!(set.view(&json!({}))["thisMac"]["id"], "mac-1");
}
