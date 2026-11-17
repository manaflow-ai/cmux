//! Ported from the app's InstallKeyAcrossBuildsTests (`aRotationMovesAboveEveryItemItCouldNotDelete`).

use std::collections::BTreeMap;

use super::*;

const ACCOUNT: &str = "install-key-0123456789abcdef";
/// errSecInvalidOwnerEdit: another build's item.
const OWNER_EDIT: i32 = -25244;

/// The login Keychain as builds see it: every build reads every item; only the build that made one
/// deletes it. The app's call site over it: list, ask, then read, add or delete what the answer names.
#[derive(Default)]
struct Keychain {
    items: BTreeMap<String, (String, &'static str)>,
}

impl Keychain {
    fn accounts(&self) -> Vec<String> {
        self.items.keys().cloned().collect()
    }

    fn current(&self) -> Option<String> {
        slots(ACCOUNT, &self.accounts())
            .current
            .and_then(|at| self.items.get(&at).map(|i| i.0.clone()))
    }

    fn store(&mut self, blob: &str, build: &'static str) {
        let at = slots(ACCOUNT, &self.accounts()).next;
        assert!(self.items.insert(at, (blob.to_owned(), build)).is_none());
    }

    fn rotate(&mut self, fresh: &str, build: &'static str) {
        let deletes: Vec<Delete> = slots(ACCOUNT, &self.accounts())
            .slots
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
        if let Some(at) = replacement(ACCOUNT, &deletes) {
            assert!(self.items.insert(at, (fresh.to_owned(), build)).is_none());
        }
    }
}

#[test]
fn a_rotation_moves_above_every_item_it_could_not_delete() {
    let mut keychain = Keychain::default();
    keychain.store("first", "old");
    assert_eq!(keychain.current().as_deref(), Some("first"));

    // The update's build may not delete the old build's key: the fresh one goes above it.
    keychain.rotate("second", "new");
    assert_eq!(keychain.current().as_deref(), Some("second"));
    assert_eq!(keychain.accounts(), [ACCOUNT.to_owned(), format!("{ACCOUNT}.2")]);

    // Its own generation goes; the kept one stays below the new key.
    keychain.rotate("third", "new");
    assert_eq!(keychain.current().as_deref(), Some("third"));
    assert_eq!(keychain.accounts(), [ACCOUNT.to_owned(), format!("{ACCOUNT}.2")]);
}

#[test]
fn a_build_that_deletes_everything_leaves_no_key() {
    let mut keychain = Keychain::default();
    keychain.store("solo", "solo");
    keychain.rotate("unused", "solo");
    assert_eq!(keychain.current(), None);
    assert!(keychain.accounts().is_empty());
    // The next use makes one at the account itself, so installed keys keep their name.
    assert_eq!(slots(ACCOUNT, &[]).next, ACCOUNT);
}

#[test]
fn the_newest_generation_is_the_key_whatever_order_the_keychain_lists() {
    let listed = [format!("{ACCOUNT}.10"), ACCOUNT.to_owned(), format!("{ACCOUNT}.2")];
    let found = slots(ACCOUNT, &listed);
    assert_eq!(found.slots, [ACCOUNT.to_owned(), format!("{ACCOUNT}.2"), format!("{ACCOUNT}.10")]);
    assert_eq!(found.current, Some(format!("{ACCOUNT}.10")));
    assert_eq!(found.next, format!("{ACCOUNT}.11"));
    assert_eq!(slots(ACCOUNT, &[ACCOUNT.to_owned()]).next, format!("{ACCOUNT}.2"));
}

#[test]
fn another_users_key_and_look_alikes_are_never_a_generation() {
    for other in [
        "install-key-ffffffffffffffff".to_owned(),
        format!("{ACCOUNT}.x"),
        format!("{ACCOUNT}.02"),
        format!("{ACCOUNT}.1"),
        format!("{ACCOUNT}.0"),
        format!("{ACCOUNT}.-3"),
        format!("{ACCOUNT}.+3"),
        format!("{ACCOUNT}2"),
        format!("{ACCOUNT}."),
    ] {
        assert_eq!(generation(ACCOUNT, &other), None, "{other}");
    }
    let found =
        slots(ACCOUNT, &["install-key-ffffffffffffffff".to_owned(), format!("{ACCOUNT}.02")]);
    assert_eq!(found, Slots { slots: vec![], current: None, next: ACCOUNT.to_owned() });
}

#[test]
fn only_a_refused_delete_keeps_a_generation() {
    let deletes = |statuses: &[(u64, i32)]| -> Vec<Delete> {
        statuses
            .iter()
            .map(|(g, status)| Delete { account: name(ACCOUNT, *g), status: *status })
            .collect()
    };
    assert_eq!(replacement(ACCOUNT, &deletes(&[(1, STATUS_SUCCESS), (2, STATUS_NOT_FOUND)])), None);
    assert_eq!(
        replacement(ACCOUNT, &deletes(&[(1, OWNER_EDIT), (2, STATUS_SUCCESS)])),
        Some(format!("{ACCOUNT}.2"))
    );
    // Any other refusal (a locked Keychain, -25308) keeps the item too.
    assert_eq!(
        replacement(ACCOUNT, &deletes(&[(1, STATUS_SUCCESS), (3, -25308)])),
        Some(format!("{ACCOUNT}.4"))
    );
    // A delete of something that is not this key's never moves it.
    let foreign =
        [Delete { account: "install-key-ffffffffffffffff".to_owned(), status: OWNER_EDIT }];
    assert_eq!(replacement(ACCOUNT, &foreign), None);
}
