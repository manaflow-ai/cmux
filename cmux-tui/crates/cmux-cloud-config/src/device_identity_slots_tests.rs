//! The app's call site over the rules, against a Keychain where every build reads every item but
//! only the build that made one deletes it (the app's own: CmuxNextDevicesTests
//! `DeviceIdentityAcrossBuildsTests`).

use std::collections::BTreeMap;

use super::*;

/// errSecInvalidOwnerEdit: another build's item.
const OWNER_EDIT: i32 = -25244;

#[derive(Default)]
struct Keychain {
    /// account -> (value, the build that made it)
    items: BTreeMap<String, (String, &'static str)>,
}

impl Keychain {
    fn accounts(&self) -> Vec<String> {
        self.items.keys().cloned().collect()
    }

    /// The identity a load reads: the three items of the newest generation, all or nothing.
    fn read(&self) -> Option<[String; 3]> {
        let current = slots(&self.accounts()).current?;
        let get = |account: &String| self.items.get(account).map(|item| item.0.clone());
        Some([get(&current.id)?, get(&current.signing_key)?, get(&current.agreement_key)?])
    }

    /// `load`: the current identity, else a renewal.
    fn load(&mut self, identity: &str, build: &'static str) -> [String; 3] {
        if let Some(read) = self.read() {
            return read;
        }
        self.renew(identity, build)
    }

    /// `renew`: delete every item it can, add the new identity where Rust says.
    fn renew(&mut self, identity: &str, build: &'static str) -> [String; 3] {
        let deletes: Vec<Delete> = slots(&self.accounts())
            .accounts
            .into_iter()
            .map(|account| {
                let status = match self.items.get(&account) {
                    None => STATUS_NOT_FOUND,
                    Some((_, owner)) if *owner != build => OWNER_EDIT,
                    Some(_) => {
                        self.items.remove(&account);
                        STATUS_SUCCESS
                    }
                };
                Delete { account, status }
            })
            .collect();
        let at = replacement(&deletes);
        let made =
            [format!("{identity}-id"), format!("{identity}-sign"), format!("{identity}-agree")];
        for (account, value) in [at.id, at.signing_key, at.agreement_key].into_iter().zip(&made) {
            assert!(self.items.insert(account, (value.clone(), build)).is_none(), "add-only");
        }
        made
    }
}

#[test]
fn a_device_renewed_on_another_build_gets_a_new_identity_its_later_loads_read() {
    let mut keychain = Keychain::default();
    let first = keychain.load("a", "A");
    assert_eq!(keychain.accounts(), ["device-agreement-key", "device-id", "device-signing-key"]);
    // The updated build reads build A's identity.
    assert_eq!(keychain.load("unused", "B"), first);

    // The hub refused it: build B may not delete A's items, so the new identity goes above them.
    let renewed = keychain.renew("b", "B");
    assert_ne!(renewed, first);
    assert_eq!(keychain.load("unused", "B"), renewed);
    assert_eq!(keychain.load("unused", "A"), renewed);
    assert_eq!(slots(&keychain.accounts()).current, Some(names(2)));

    // Again on B: its own generation goes, A's stays below, the new one takes generation 2 again.
    let again = keychain.renew("c", "B");
    assert_eq!(keychain.load("unused", "B"), again);
    assert_eq!(keychain.accounts().len(), 6);
    assert_eq!(slots(&keychain.accounts()).current, Some(names(2)));
}

#[test]
fn installed_identities_keep_their_names_and_a_sole_build_stays_at_generation_one() {
    assert_eq!(
        names(1),
        Generation {
            id: "device-id".into(),
            signing_key: "device-signing-key".into(),
            agreement_key: "device-agreement-key".into(),
        }
    );
    assert_eq!(replacement(&[]), names(1));
    let mut keychain = Keychain::default();
    let first = keychain.load("a", "A");
    let renewed = keychain.renew("b", "A");
    assert_ne!(renewed, first);
    assert_eq!(slots(&keychain.accounts()).current, Some(names(1)));
    assert_eq!(keychain.accounts().len(), 3);
}

#[test]
fn a_generation_missing_an_item_is_never_mixed_with_an_older_one() {
    let mut keychain = Keychain::default();
    let first = keychain.load("a", "A");
    // A renewal on B that stopped after one add: generation 2 holds only an id.
    keychain.items.insert(names(2).id, ("half".into(), "B"));
    assert_eq!(keychain.read(), None);
    // The next load renews: B deletes its half, keeps A's, and writes a whole generation 2.
    let fresh = keychain.load("b", "B");
    assert_ne!(fresh, first);
    assert_eq!(keychain.read(), Some(fresh));
    assert_eq!(slots(&keychain.accounts()).current, Some(names(2)));
}

#[test]
fn the_newest_generation_is_the_identity_whatever_order_the_keychain_lists() {
    let listed: Vec<String> =
        ["device-id.10", "capture-lease", "device-agreement-key", "device-id.2", "device-id"]
            .map(str::to_owned)
            .into();
    let found = slots(&listed);
    assert_eq!(
        found.accounts,
        ["device-agreement-key", "device-id", "device-id.2", "device-id.10"].map(str::to_owned)
    );
    assert_eq!(found.current, Some(names(10)));
    assert_eq!(names(10).signing_key, "device-signing-key.10");
    assert_eq!(slots(&[]), Slots { accounts: vec![], current: None });
}

#[test]
fn other_items_and_look_alikes_are_never_a_generation() {
    for other in [
        "capture-lease",
        "relay-r1",
        "device-id.x",
        "device-id.02",
        "device-id.1",
        "device-id.0",
        "device-id.-3",
        "device-id.+3",
        "device-id2",
        "device-id.",
        "device-signing-key.2.3",
        "device",
    ] {
        assert_eq!(generation(other), None, "{other}");
    }
    assert_eq!(generation("device-signing-key.7"), Some(7));
    assert_eq!(generation("device-agreement-key"), Some(1));
}

#[test]
fn only_a_refused_delete_keeps_a_generation() {
    let delete = |account: &str, status: i32| Delete { account: account.into(), status };
    assert_eq!(
        replacement(&[
            delete("device-id", STATUS_SUCCESS),
            delete("device-id.2", STATUS_NOT_FOUND)
        ]),
        names(1)
    );
    assert_eq!(
        replacement(&[
            delete("device-id", OWNER_EDIT),
            delete("device-signing-key.2", STATUS_SUCCESS)
        ]),
        names(2)
    );
    // Any other refusal (a locked Keychain, -25308) keeps the item too.
    assert_eq!(
        replacement(&[
            delete("device-id", STATUS_SUCCESS),
            delete("device-agreement-key.3", -25308)
        ]),
        names(4)
    );
    // A refused delete of something that is not the identity's never moves it.
    assert_eq!(replacement(&[delete("capture-lease", OWNER_EDIT)]), names(1));
}
