//! The target end of the carrier: an approval the hub carries from the owner's own device is
//! admitted and turns sharing on with nobody at the Mac; an unsigned one, one an agent signed
//! with another key, one from a device not on the account's hub list (a fleet or CLI token is
//! not a device), or one the hub did not carry from the device that signed it is refused, and
//! sharing stays off. Every decision is audited.

use super::*;
use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use std::cell::{Cell, RefCell};

const MAC: &str = "6f1c2a7e-0b1d-4c55-9a63-2f1e7d9b8a10";
const PHONE: &str = "0d4b9e21-77aa-4f0e-8c3b-5a6d1e2f3c40";
const ACCOUNT: &str = "user_2abc";
const NOW: u64 = 1_794_700_000;

/// The phone's device key (its Secure Enclave key, faked).
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

    fn public(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.public_key().as_ref())
    }

    /// What the phone does after the tap.
    fn sign(&self, mut approval: ShareApproval) -> ShareApproval {
        let signature = self.pair.sign(&self.rng, approval.canonical().as_bytes()).unwrap();
        approval.signature = base64::engine::general_purpose::STANDARD.encode(signature.as_ref());
        approval
    }
}

fn unsigned(nonce: &str) -> ShareApproval {
    ShareApproval {
        v: crate::share_approval::VERSION.into(),
        target: MAC.into(),
        target_name: "Studio".into(),
        asker: PHONE.into(),
        asker_name: "iPhone".into(),
        confirmed_by: ACCOUNT.into(),
        confirmed_at: NOW - 3,
        nonce: nonce.into(),
        signature: String::new(),
    }
}

/// The push the hub sends this Mac: `from` is the hub's record of the sender.
fn carried(approval: &ShareApproval, from: &str) -> Value {
    json!({"type": PUSH, "from": from, "approval": approval})
}

/// This Mac's hub, faked: its account's device list, and whether sharing was turned on.
struct FakeHub {
    account: Option<&'static str>,
    devices: Value,
    shared: Cell<u32>,
}

impl FakeHub {
    fn with_phone(key: &DeviceKey) -> Self {
        Self {
            account: Some(ACCOUNT),
            devices: json!({"devices": [
                {"id": MAC, "platform": "macos", "signingKey": "bWFj"},
                {"id": PHONE, "platform": "ios", "signingKey": key.public()},
            ]}),
            shared: Cell::new(0),
        }
    }
}

impl TargetHub for FakeHub {
    fn device_id(&self) -> String {
        MAC.into()
    }
    fn account(&self) -> Option<String> {
        self.account.map(str::to_owned)
    }
    fn devices(&self) -> Result<Value, String> {
        Ok(self.devices.clone())
    }
    fn share_on(&self) -> Result<(), String> {
        self.shared.set(self.shared.get() + 1);
        Ok(())
    }
}

/// [`receive`], with its audit lines collected.
fn run(hub: &FakeHub, push: &Value, seen: &mut HashSet<String>) -> (Result<(), Refused>, Value) {
    let line = RefCell::new(Value::Null);
    let result = receive(hub, push, NOW, seen, |entry| *line.borrow_mut() = entry.clone());
    (result, line.into_inner())
}

#[test]
fn the_owners_own_device_turns_sharing_on_with_nobody_at_the_mac() {
    let phone = DeviceKey::new();
    let hub = FakeHub::with_phone(&phone);
    let approval = phone.sign(unsigned("n1"));
    let mut seen = HashSet::new();
    let (result, entry) = run(&hub, &carried(&approval, PHONE), &mut seen);
    assert_eq!(result, Ok(()));
    assert_eq!(hub.shared.get(), 1, "the Mac turns sharing on itself");
    assert_eq!(entry["event"], "remote_host.share_admitted");
    assert_eq!(entry["carrier"], "device-hub");
    assert_eq!(entry["confirmed_on"], PHONE);
    assert_eq!(entry["confirmed_by"], ACCOUNT);
    assert_eq!(entry["nonce"], "n1");
    // The same tap carried again (a replay) is refused, and nothing turns on twice.
    let (again, entry) = run(&hub, &carried(&approval, PHONE), &mut seen);
    assert_eq!(again.unwrap_err().code, "share.replayed");
    assert_eq!(entry["event"], "remote_host.share_refused");
    assert_eq!(hub.shared.get(), 1);
}

/// An agent alone never completes it: no device signature, another key's signature, a device
/// the account's hub list does not have (a fleet or CLI token), a sender the hub did not see as
/// the signer, another account, or a stale tap. Sharing stays off and each refusal is audited.
#[test]
fn an_agent_or_unsigned_request_through_the_carrier_is_refused() {
    let phone = DeviceKey::new();
    let agent = DeviceKey::new();
    let hub = FakeHub::with_phone(&phone);
    let fleet = ShareApproval { asker: "fleet-token".into(), ..unsigned("n4") };
    let cases = [
        ("unsigned", carried(&unsigned("n1"), PHONE), "share.bad_signature"),
        ("another key", carried(&agent.sign(unsigned("n2")), PHONE), "share.bad_signature"),
        (
            "fields changed after signing",
            carried(&ShareApproval { nonce: "n3b".into(), ..phone.sign(unsigned("n3")) }, PHONE),
            "share.bad_signature",
        ),
        (
            "not an account device",
            carried(&agent.sign(fleet.clone()), "fleet-token"),
            "share.unknown_device",
        ),
        (
            "sent by another device",
            carried(&phone.sign(unsigned("n5")), MAC),
            "share.not_carried_by_asker",
        ),
        (
            "no sender",
            json!({"type": PUSH, "approval": phone.sign(unsigned("n6"))}),
            "share.not_carried_by_asker",
        ),
        (
            "another account",
            carried(
                &phone.sign(ShareApproval { confirmed_by: "user_other".into(), ..unsigned("n7") }),
                PHONE,
            ),
            "share.other_account",
        ),
        (
            "stale",
            carried(
                &phone.sign(ShareApproval { confirmed_at: NOW - 3600, ..unsigned("n8") }),
                PHONE,
            ),
            "share.stale",
        ),
        (
            "another Mac",
            carried(
                &phone.sign(ShareApproval { target: "other-mac".into(), ..unsigned("n9") }),
                PHONE,
            ),
            "share.wrong_target",
        ),
    ];
    for (name, push, code) in cases {
        let (result, entry) = run(&hub, &push, &mut HashSet::new());
        assert_eq!(result.map_err(|r| r.code), Err(code), "{name}");
        assert_eq!(entry["event"], "remote_host.share_refused", "{name}");
        assert_eq!(entry["code"], code, "{name}");
    }
    assert_eq!(hub.shared.get(), 0, "nothing turned sharing on");
}

#[test]
fn an_unreadable_push_or_a_mac_not_signed_in_admits_nothing() {
    let phone = DeviceKey::new();
    let hub = FakeHub::with_phone(&phone);
    for push in [json!({"type": PUSH}), json!({"type": PUSH, "from": PHONE, "approval": {"v": 1}})]
    {
        let (result, entry) = run(&hub, &push, &mut HashSet::new());
        assert_eq!(result.unwrap_err().code, "share.unreadable");
        assert_eq!(entry["event"], "remote_host.share_refused");
    }
    let signed_out = FakeHub { account: None, ..FakeHub::with_phone(&phone) };
    let (result, _) =
        run(&signed_out, &carried(&phone.sign(unsigned("n1")), PHONE), &mut HashSet::new());
    assert_eq!(result.unwrap_err().code, "share.not_signed_in");
    assert_eq!(hub.shared.get() + signed_out.shared.get(), 0);
}

#[test]
fn the_keys_are_the_hubs_listed_devices() {
    let keys = HubDeviceKeys::from_devices(&json!({"devices": [
        {"id": "a", "signingKey": "KA"}, {"id": "b"}, {"id": "c", "signingKey": ""}, {"signingKey": "K"},
    ]}));
    assert_eq!(keys.signing_key("a").as_deref(), Some("KA"));
    assert_eq!(keys.signing_key("b"), None);
    assert_eq!(keys.signing_key("c"), None);
    assert_eq!(HubDeviceKeys::from_devices(&json!({})).signing_key("a"), None);
}

#[test]
fn audit_lines_are_appended_with_a_time() {
    let dir = tempfile::tempdir().unwrap();
    append_audit(dir.path(), &json!({"event": "remote_host.share_admitted"}));
    append_audit(dir.path(), &json!({"event": "remote_host.share_refused"}));
    let text = std::fs::read_to_string(dir.path().join(AUDIT_FILE)).unwrap();
    let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[1]["event"], "remote_host.share_refused");
    assert!(lines[0]["ts"].as_str().is_some_and(|ts| ts.ends_with('Z')));
}
