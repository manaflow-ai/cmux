//! Share This Mac confirmed on the owner's other device, the asker's flow: no
//! click means no share, a click is recorded and delivered, and the target's
//! decision lands in its host audit log.

use std::cell::{Cell, RefCell};

use acpmux::share_approval::VERSION;
use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;

const TARGET: &str = "6f1c2a7e-0b1d-4c55-9a63-2f1e7d9b8a10";
const ASKER: &str = "0d4b9e21-77aa-4f0e-8c3b-5a6d1e2f3c40";
const ACCOUNT: &str = "user_2abc";
const NOW: u64 = 1_794_700_000;

/// One device's Secure Enclave key, as the app holds it.
struct DeviceKey {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl DeviceKey {
    fn new() -> Self {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
            .unwrap();
        Self { pair, rng }
    }

    /// base64 X9.63, the device hub's `signingKey`.
    fn public(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.public_key().as_ref())
    }

    /// What the app does after the Allow click.
    fn sign(&self, mut approval: ShareApproval) -> ShareApproval {
        let signature = self.pair.sign(&self.rng, approval.canonical().as_bytes()).unwrap();
        approval.signature = base64::engine::general_purpose::STANDARD.encode(signature.as_ref());
        approval
    }
}

fn unsigned() -> ShareApproval {
    ShareApproval {
        v: VERSION.into(),
        target: TARGET.into(),
        target_name: "Studio".into(),
        asker: ASKER.into(),
        asker_name: "Laptop".into(),
        confirmed_by: ACCOUNT.into(),
        confirmed_at: NOW - 5,
        nonce: "nonce-1".into(),
        signature: String::new(),
    }
}

/// The target writes its decision to its own host audit log.
#[test]
fn target_writes_the_decision_to_its_audit_log() {
    struct Grant(bool);
    impl SameAccountGrant for Grant {
        fn covers(&self, _asker: &acpmux::share_approval::Asker<'_>) -> bool {
            self.0
        }
    }
    struct Keys(String);
    impl AskerKeys for Keys {
        fn signing_key(&self, device: &str) -> Option<String> {
            (device == ASKER).then(|| self.0.clone())
        }
    }
    let key = DeviceKey::new();
    let keys = Keys(key.public());
    let approval = key.sign(unsigned());
    let target = Target { device: TARGET, account: ACCOUNT, now: NOW };
    let dir = tempfile::tempdir().unwrap();
    let write = |entry: &Value| super::super::audit::append_in(dir.path(), entry).unwrap();
    let mut seen = HashSet::new();
    let refused = admit_and_record(&approval, &target, &Grant(false), &keys, &mut seen, write);
    assert_eq!(refused.unwrap_err().code, "share.not_granted");
    let admitted = admit_and_record(&approval, &target, &Grant(true), &keys, &mut seen, write);
    assert_eq!(admitted, Ok(()));
    let text = std::fs::read_to_string(dir.path().join(super::super::audit::FILE)).unwrap();
    let lines: Vec<Value> = text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["event"], "remote_host.share_refused");
    assert_eq!(lines[0]["code"], "share.not_granted");
    assert_eq!(lines[1]["event"], "remote_host.share_admitted");
    for line in &lines {
        assert_eq!(line["confirmed_by"], ACCOUNT);
        assert_eq!(line["confirmed_on"], ASKER);
        assert!(line["ts"].is_string());
    }
}

/// Counts deliveries; answers like the target would.
struct Counting(Cell<u32>);

impl Deliver for Counting {
    fn deliver(&self, _approval: &ShareApproval) -> Result<Value, Value> {
        self.0.set(self.0.get() + 1);
        Ok(json!({"sharing": true}))
    }
}

fn run(answer: Result<Value, Value>) -> (Result<Value, Value>, u32, Vec<(String, Value)>) {
    let deliver = Counting(Cell::new(0));
    let audit = RefCell::new(Vec::new());
    let asked = RefCell::new(None);
    let result = share_from_here(
        "Studio",
        |params| {
            *asked.borrow_mut() = Some(params);
            answer
        },
        &deliver,
        |event, fields| audit.borrow_mut().push((event.to_owned(), fields)),
    );
    assert_eq!(
        asked.into_inner(),
        Some(json!({"action": "share", "on": true, "device": "Studio"})),
        "the asker's app is asked with the device"
    );
    (result, deliver.0.get(), audit.into_inner())
}

/// The confirm-required path: without the person's Allow, nothing reaches the target.
#[test]
fn asker_without_a_click_is_refused_and_delivers_nothing() {
    let cases = [
        ("declined", Ok(json!({"ok": false, "declined": true})), "share.declined"),
        // An "ok" with no signed approval, as an agent could forge or an old app answers.
        ("no approval", Ok(json!({"ok": true})), "share.not_confirmed"),
        (
            "unsigned approval",
            Ok(json!({"ok": true, "approval": serde_json::to_value(unsigned()).unwrap()})),
            "share.not_confirmed",
        ),
        ("timeout", Err(json!({"code": "timeout", "message": "nobody answered"})), "timeout"),
    ];
    for (name, answer, code) in cases {
        let (result, delivered, audit) = run(answer);
        let error = result.unwrap_err();
        assert_eq!(error["code"], code, "{name}: {error}");
        assert_eq!(delivered, 0, "{name}: nothing may reach the target");
        assert_eq!(audit.len(), 1, "{name}");
        assert_ne!(audit[0].0, "remote_host.share_confirmed", "{name}");
    }
}

#[test]
fn asker_refuses_an_approval_for_another_mac() {
    let key = DeviceKey::new();
    let other =
        key.sign(ShareApproval { target: "x".into(), target_name: "Mini".into(), ..unsigned() });
    let (result, delivered, _) =
        run(Ok(json!({"ok": true, "approval": serde_json::to_value(other).unwrap()})));
    assert_eq!(result.unwrap_err()["code"], "share.not_confirmed");
    assert_eq!(delivered, 0);
}

#[test]
fn asker_with_a_click_records_it_and_delivers() {
    let key = DeviceKey::new();
    let approval = key.sign(unsigned());
    let (result, delivered, audit) =
        run(Ok(json!({"ok": true, "approval": serde_json::to_value(&approval).unwrap()})));
    let value = result.unwrap();
    assert_eq!(value["shared"], true);
    assert_eq!(value["device"], TARGET);
    assert_eq!(delivered, 1);
    let [(event, fields)] = audit.as_slice() else { panic!("one audit line: {audit:?}") };
    assert_eq!(event, "remote_host.share_confirmed");
    assert_eq!(fields["device"], TARGET);
    assert_eq!(fields["device_name"], "Studio");
    assert_eq!(fields["confirmed_by"], ACCOUNT);
    assert_eq!(fields["confirmed_on"], ASKER);
    assert_eq!(fields["confirmed_on_name"], "Laptop");
    assert_eq!(fields["confirmed_at"], super::super::grant::rfc3339(NOW - 5));
}

/// Until cut 1, a confirmed approval is recorded and the caller is told why it stops there.
#[test]
fn delivery_before_same_account_control_says_what_is_missing() {
    let error = AwaitingSameAccountControl.deliver(&unsigned()).unwrap_err();
    assert_eq!(error["code"], "share.needs_same_account_control");
    assert_eq!(error["details"]["confirmed"], true);
    assert_eq!(error["details"]["delivered"], false);
    assert!(error["message"].as_str().unwrap().contains("Studio"));
}

/// The app finds a device by name without case, Unicode included (Swift
/// `caseInsensitiveCompare`); the CLI reads its approval the same way, so a click
/// for "München" asked as `MÜNCHEN` is not refused after the person allowed it.
#[test]
fn asker_matches_a_device_name_without_case_as_the_app_does() {
    let key = DeviceKey::new();
    let approval = key.sign(ShareApproval { target_name: "München".into(), ..unsigned() });
    let answer = json!({"ok": true, "approval": serde_json::to_value(&approval).unwrap()});
    assert!(matches!(asker_outcome(&answer, "MÜNCHEN"), AskerOutcome::Confirmed(_)));
    assert!(matches!(asker_outcome(&answer, "münchen"), AskerOutcome::Confirmed(_)));
    assert!(matches!(asker_outcome(&answer, "Mini"), AskerOutcome::NotConfirmed(_)));
}
