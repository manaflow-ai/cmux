//! The share approval: the target admits only a granted same-account asker
//! whose device signed it after the click, and audits each decision.

use std::collections::HashSet;

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::Value;

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

/// Cut 1's grant, faked: the machines the target's owner granted.
struct Granted(Vec<(&'static str, &'static str)>);

impl SameAccountGrant for Granted {
    fn covers(&self, asker: &Asker<'_>) -> bool {
        self.0.iter().any(|(device, account)| *device == asker.device && *account == asker.account)
    }
}

/// The device hub's key list for the target's account, faked.
struct Keys(Vec<(&'static str, String)>);

impl AskerKeys for Keys {
    fn signing_key(&self, device: &str) -> Option<String> {
        self.0.iter().find(|(id, _)| *id == device).map(|(_, key)| key.clone())
    }
}

fn target() -> Target<'static> {
    Target { device: TARGET, account: ACCOUNT, now: NOW }
}

fn granted() -> Granted {
    Granted(vec![(ASKER, ACCOUNT)])
}

#[test]
fn canonical_matches_the_shared_vectors() {
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("share_approval_vectors.json")).unwrap();
    assert!(!vectors.is_empty());
    for vector in vectors {
        let approval: ShareApproval = serde_json::from_value(vector["approval"].clone()).unwrap();
        assert_eq!(approval.canonical(), vector["canonical"].as_str().unwrap());
    }
}

#[test]
fn target_accepts_a_granted_same_account_asker() {
    let key = DeviceKey::new();
    let approval = key.sign(unsigned());
    let keys = Keys(vec![(ASKER, key.public())]);
    let mut seen = HashSet::new();
    assert_eq!(admit(&approval, &target(), &granted(), &keys, &mut seen), Ok(()));
    // The same click admits once.
    let again = admit(&approval, &target(), &granted(), &keys, &mut seen).unwrap_err();
    assert_eq!(again.code, "share.replayed");
}

#[test]
fn target_refuses_an_asker_its_owner_did_not_grant() {
    let key = DeviceKey::new();
    let approval = key.sign(unsigned());
    let keys = Keys(vec![(ASKER, key.public())]);
    for grant in [Granted(vec![]), Granted(vec![("another-mac", ACCOUNT)])] {
        let refused = admit(&approval, &target(), &grant, &keys, &mut HashSet::new()).unwrap_err();
        assert_eq!(refused.code, "share.not_granted", "{refused:?}");
        assert!(refused.message.contains("Laptop"), "{refused:?}");
    }
}

#[test]
fn target_refuses_another_account_even_when_its_device_is_granted() {
    let key = DeviceKey::new();
    let approval = key.sign(ShareApproval { confirmed_by: "user_other".into(), ..unsigned() });
    let keys = Keys(vec![(ASKER, key.public())]);
    let grant = Granted(vec![(ASKER, ACCOUNT), (ASKER, "user_other")]);
    let refused = admit(&approval, &target(), &grant, &keys, &mut HashSet::new()).unwrap_err();
    assert_eq!(refused.code, "share.other_account");
}

/// An agent alone can never complete it: without the click the app signs
/// nothing, and no other signature, nor one over different fields, passes.
#[test]
fn target_refuses_an_approval_nobody_clicked() {
    let asker = DeviceKey::new();
    let keys = Keys(vec![(ASKER, asker.public())]);
    let agent = DeviceKey::new();
    let cases = [
        ("unsigned", unsigned()),
        ("signed by another key", agent.sign(unsigned())),
        (
            "fields changed after signing",
            ShareApproval { nonce: "nonce-2".into(), ..asker.sign(unsigned()) },
        ),
        ("garbage signature", ShareApproval { signature: "AAAA".into(), ..unsigned() }),
    ];
    for (name, approval) in cases {
        let refused =
            admit(&approval, &target(), &granted(), &keys, &mut HashSet::new()).unwrap_err();
        assert_eq!(refused.code, "share.bad_signature", "{name}: {refused:?}");
    }
    let unknown =
        admit(&asker.sign(unsigned()), &target(), &granted(), &Keys(vec![]), &mut HashSet::new())
            .unwrap_err();
    assert_eq!(unknown.code, "share.unknown_device");
}

#[test]
fn target_refuses_another_mac_old_clicks_and_other_formats() {
    let key = DeviceKey::new();
    let keys = Keys(vec![(ASKER, key.public())]);
    let check = |approval: ShareApproval| {
        admit(&key.sign(approval), &target(), &granted(), &keys, &mut HashSet::new())
            .unwrap_err()
            .code
    };
    assert_eq!(
        check(ShareApproval { target: "other-mac".into(), ..unsigned() }),
        "share.wrong_target"
    );
    assert_eq!(
        check(ShareApproval { confirmed_at: NOW - MAX_AGE_SECS - 1, ..unsigned() }),
        "share.stale"
    );
    assert_eq!(
        check(ShareApproval { confirmed_at: NOW + MAX_SKEW_SECS + 1, ..unsigned() }),
        "share.stale"
    );
    assert_eq!(
        check(ShareApproval { v: "cmux.share-approval.v0".into(), ..unsigned() }),
        "share.bad_version"
    );
}

#[test]
fn target_audit_names_who_confirmed_where_and_when() {
    let approval = unsigned();
    let admitted = target_entry(&approval, &Ok(()));
    assert_eq!(admitted["event"], "remote_host.share_admitted");
    assert_eq!(admitted["confirmed_by"], ACCOUNT);
    assert_eq!(admitted["confirmed_on"], ASKER);
    assert_eq!(admitted["asker_name"], "Laptop");
    assert_eq!(admitted["confirmed_at"], rfc3339(NOW - 5));
    assert!(admitted.get("code").is_none());
    let refused =
        target_entry(&approval, &Err(Refused { code: "share.not_granted", message: "no".into() }));
    assert_eq!(refused["event"], "remote_host.share_refused");
    assert_eq!(refused["code"], "share.not_granted");
}

/// The target's real grant is its owner's `signedInMachines` consent, held for the account this
/// Mac is joined as: only `granted`, for that same account, admits; off, unanswered, declined,
/// another account's grant, an unjoined Mac and an unreadable record admit nothing.
#[test]
fn target_admits_only_with_its_owners_signed_in_machines_consent() {
    let key = DeviceKey::new();
    let approval = key.sign(unsigned());
    let keys = Keys(vec![(ASKER, key.public())]);
    let consent = |state: &str, user: &str| serde_json::json!({"consent": {"signedInMachines": state, "signedInMachinesUser": user}});
    let granted = SignedInMachinesConsent::from_status(&consent("granted", ACCOUNT), Some(ACCOUNT));
    assert_eq!(admit(&approval, &target(), &granted, &keys, &mut HashSet::new()), Ok(()));
    let refusing = [
        ("off", SignedInMachinesConsent::from_status(&consent("off", ACCOUNT), Some(ACCOUNT))),
        (
            "unanswered",
            SignedInMachinesConsent::from_status(
                &serde_json::json!({"consent": {}}),
                Some(ACCOUNT),
            ),
        ),
        (
            "declined",
            SignedInMachinesConsent::from_status(&consent("denied", ACCOUNT), Some(ACCOUNT)),
        ),
        (
            "granted for another account",
            SignedInMachinesConsent::from_status(&consent("granted", "user_other"), Some(ACCOUNT)),
        ),
        ("not joined", SignedInMachinesConsent::from_status(&consent("granted", ACCOUNT), None)),
        ("unreadable", SignedInMachinesConsent::from_status(&Value::Null, Some(ACCOUNT))),
    ];
    for (name, grant) in refusing {
        let refused = admit(&approval, &target(), &grant, &keys, &mut HashSet::new()).unwrap_err();
        assert_eq!(refused.code, "share.not_granted", "{name}: {refused:?}");
    }
    // The grant is for this account's machines only, never an asker of another account.
    assert!(!granted.covers(&Asker { device: ASKER, account: "user_other" }));
    assert!(!granted.covers(&Asker { device: ASKER, account: "" }));
}
