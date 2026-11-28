//! Subscription grants share the existing login Keychain service and account format.
//! The framework takes bytes directly, so grants never enter argv or the security shell.

use std::sync::Mutex;

use security_framework::item::{ItemClass, ItemSearchOptions, Limit};
use security_framework::os::macos::keychain::{KeychainUserInteractionLock, SecKeychain};
use security_framework::os::macos::passwords::find_generic_password;
use zeroize::Zeroizing;

use super::{OsStore, SERVICE, SecretStore, account, decode, encode};

const AUTH_FAILED: i32 = -25293;
const ITEM_NOT_FOUND: i32 = -25300;
const INTERACTION_NOT_ALLOWED: i32 = -25308;
const LOCKED: &str = "vault.keychain_locked";
pub(crate) const OTHER_BUILD: &str = "vault.keychain_other_build";

pub(crate) struct SubscriptionItems {
    keychain: SecKeychain,
    isolate_search: bool,
}

pub(crate) fn without_ui<T>(body: impl FnOnce() -> T) -> Result<T, &'static str> {
    // The interaction flag is process-wide. Keep these short calls serialized.
    static UI: Mutex<()> = Mutex::new(());
    let _guard = UI.lock().unwrap_or_else(|e| e.into_inner());
    let _no_ui: Option<KeychainUserInteractionLock> =
        if SecKeychain::user_interaction_allowed().map_err(|_| LOCKED)? {
            Some(SecKeychain::disable_user_interaction().map_err(|_| LOCKED)?)
        } else {
            None
        };
    Ok(body())
}

impl SubscriptionItems {
    #[cfg(not(test))]
    pub(crate) fn open() -> Result<Self, &'static str> {
        let keychain = without_ui(SecKeychain::default)?.map_err(|_| LOCKED)?;
        Ok(Self { keychain, isolate_search: false })
    }

    fn search_list(&self) -> Option<&[SecKeychain]> {
        // The earlier command searched the login Keychain list. The default
        // Keychain may have changed since an existing grant was written.
        self.isolate_search.then(|| std::slice::from_ref(&self.keychain))
    }

    pub(crate) fn read(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        let account = account(name);
        let result =
            without_ui(|| match find_generic_password(self.search_list(), SERVICE, &account) {
                Ok((password, _)) => std::str::from_utf8(&password)
                    .ok()
                    .and_then(decode)
                    .map(Some)
                    .ok_or("vault.secret_store_read_failed"),
                Err(error) if error.code() == ITEM_NOT_FOUND => Ok(None),
                Err(error) => Err(self.failure(error.code(), &account)),
            })?;
        if matches!(result, Err(OTHER_BUILD | LOCKED)) && self.legacy_item(name, &account) {
            // Older vault items were created by security and can trust its
            // signature alone. Only those items use the original reader.
            return OsStore.get(name);
        }
        result
    }

    pub(crate) fn write(&self, name: &str, value: &str) -> Result<bool, &'static str> {
        let account = account(name);
        let encoded = encode(value);
        let result =
            without_ui(|| match find_generic_password(self.search_list(), SERVICE, &account) {
                Ok((_, mut item)) => item
                    .set_password(encoded.as_bytes())
                    .map(|()| false)
                    .map_err(|error| self.failure(error.code(), &account)),
                Err(error) if error.code() == ITEM_NOT_FOUND => self
                    .keychain
                    .add_generic_password(SERVICE, &account, encoded.as_bytes())
                    .map(|()| true)
                    .map_err(|error| self.failure(error.code(), &account)),
                Err(error) => Err(self.failure(error.code(), &account)),
            })?;
        if result == Err(LOCKED)
            && self.legacy_item(name, &account)
            && OsStore.get(name).is_ok_and(|item| item.is_some())
        {
            // The legacy reader still has access. Rotate into a fresh account.
            return Err(OTHER_BUILD);
        }
        result
    }

    pub(crate) fn delete(&self, name: &str) -> Result<(), &'static str> {
        let account = account(name);
        let result =
            without_ui(|| match find_generic_password(self.search_list(), SERVICE, &account) {
                Ok((_, item)) => {
                    item.delete();
                    match find_generic_password(self.search_list(), SERVICE, &account) {
                        Err(error) if error.code() == ITEM_NOT_FOUND => Ok(()),
                        Err(error) => Err(self.failure(error.code(), &account)),
                        Ok(_) => Err(LOCKED),
                    }
                }
                Err(error) if error.code() == ITEM_NOT_FOUND => Ok(()),
                Err(error) => Err(self.failure(error.code(), &account)),
            })?;
        if matches!(result, Err(OTHER_BUILD | LOCKED)) && self.legacy_item(name, &account) {
            OsStore.delete(name)?;
            return if self.read(name)?.is_some() { Err(LOCKED) } else { Ok(()) };
        }
        result
    }

    pub(crate) fn subscription_accounts(&self, scope: &str) -> Result<Vec<String>, &'static str> {
        let prefix = account(&format!(".subscription/{scope}/"));
        without_ui(|| {
            let mut options = ItemSearchOptions::new();
            if let Some(keychains) = self.search_list() {
                options.keychains(keychains);
            }
            let results = options
                .class(ItemClass::generic_password())
                .service(SERVICE)
                .limit(Limit::All)
                .load_attributes(true)
                .search();
            let results = match results {
                Ok(results) => results,
                Err(error) if error.code() == ITEM_NOT_FOUND => return Ok(Vec::new()),
                Err(_) => return Err(LOCKED),
            };
            let mut accounts = Vec::new();
            for item in results {
                let attrs = item.simplify_dict().ok_or(LOCKED)?;
                if let Some(name) = attrs.get("acct").and_then(|name| name.strip_prefix(&prefix)) {
                    accounts.push(name.to_owned());
                }
            }
            Ok(accounts)
        })?
    }

    fn legacy_item(&self, name: &str, account: &str) -> bool {
        without_ui(|| has_item(self.search_list(), account, Some(&format!("cmux vault {name}"))))
            .unwrap_or(false)
    }

    // A locked Keychain and an item's access list may both refuse interaction.
    // A writable default says nothing about items in another Keychain.
    fn failure(&self, status: i32, account: &str) -> &'static str {
        let denied = matches!(status, AUTH_FAILED | INTERACTION_NOT_ALLOWED);
        if denied
            && has_item(Some(std::slice::from_ref(&self.keychain)), account, None)
            && self.probe()
        {
            OTHER_BUILD
        } else {
            LOCKED
        }
    }

    fn probe(&self) -> bool {
        let account = account(&format!("{}.subscription-access", super::probe_name()));
        if self.keychain.add_generic_password(SERVICE, &account, b"probe").is_err() {
            return false;
        }
        let Ok((_, item)) = self.keychain.find_generic_password(SERVICE, &account) else {
            return false;
        };
        item.delete();
        true
    }

    #[cfg(not(test))]
    pub(crate) fn usable(&self) -> bool {
        without_ui(|| self.probe()).unwrap_or(false)
    }

    #[cfg(test)]
    pub(crate) fn in_keychain(keychain: SecKeychain) -> Self {
        Self { keychain, isolate_search: true }
    }
}

fn has_item(keychains: Option<&[SecKeychain]>, account: &str, label: Option<&str>) -> bool {
    let mut options = ItemSearchOptions::new();
    if let Some(keychains) = keychains {
        options.keychains(keychains);
    }
    if let Some(label) = label {
        options.label(label);
    }
    options
        .class(ItemClass::generic_password())
        .service(SERVICE)
        .account(account)
        .load_attributes(true)
        .search()
        .is_ok_and(|items| !items.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use security_framework::os::macos::keychain::CreateOptions;

    #[test]
    fn an_item_refusal_in_a_writable_keychain_is_other_build() {
        let directory = tempfile::tempdir().unwrap();
        let keychain = CreateOptions::new()
            .password("fixture-password")
            .create(directory.path().join("access.keychain"))
            .unwrap();
        let items = SubscriptionItems::in_keychain(keychain);
        items.write("fixture", "value").unwrap();
        let account = account("fixture");
        assert_eq!(
            without_ui(|| items.failure(INTERACTION_NOT_ALLOWED, &account)),
            Ok(OTHER_BUILD)
        );
        assert_eq!(without_ui(|| items.failure(AUTH_FAILED, &account)), Ok(OTHER_BUILD));
        assert_eq!(without_ui(|| items.failure(INTERACTION_NOT_ALLOWED, "elsewhere")), Ok(LOCKED));
    }
}
