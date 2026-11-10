//! The device's Noise static key for carrier sessions.
//!
//! On a Mac it lives in the login Keychain the way the other device keys do
//! (a generic password, not synchronized, accessible after first unlock on
//! this device only), so the device id a grant admits (`carrier:<user>:<key
//! fingerprint>`) stays the same across dials. It is never a file.
//!
//! Elsewhere (a Linux dial, tests) the key is made for this one dial and
//! never written down: each dial asks for a grant naming its own key.

use cmux_remote::crypto::StaticIdentity;

/// The Keychain service and account of the carrier key.
#[cfg(target_os = "macos")]
const SERVICE: &str = "com.cmuxterm.app.next.carrier-noise-key";
#[cfg(target_os = "macos")]
const ACCOUNT: &str = "device";

/// The device's lasting carrier identity, for `cmux carrier key --public`:
/// on a Mac the Keychain item dial and serve use, made the same way when it
/// does not exist yet. Elsewhere there is none (each dial makes its own), so
/// no key printed there could match a later dial's.
pub(super) fn lasting_identity() -> Result<StaticIdentity, String> {
    #[cfg(target_os = "macos")]
    {
        match keychain::load_or_create(SERVICE, ACCOUNT) {
            Ok(key) => Ok(StaticIdentity::from_private(key)),
            Err(keychain::Refused::NeedsUi) => {
                Err("the Keychain carrier key needs approval this process may not ask for".into())
            }
            Err(keychain::Refused::Other(why)) => Err(why),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("this platform keeps no device key: each dial makes its own".into())
    }
}

/// The device's carrier identity.
pub(super) fn device_identity() -> Result<StaticIdentity, String> {
    #[cfg(target_os = "macos")]
    {
        match keychain::load_or_create(SERVICE, ACCOUNT) {
            Ok(key) => Ok(StaticIdentity::from_private(key)),
            // The item exists but this binary may not read it without a
            // Keychain dialog (another build made it, or a new signature):
            // never show one. Dial with a key made for this one dial, as
            // elsewhere; the grant names that key.
            Err(keychain::Refused::NeedsUi) => {
                StaticIdentity::generate().map_err(|e| format!("no Noise key: {e}"))
            }
            Err(keychain::Refused::Other(why)) => Err(why),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        StaticIdentity::generate().map_err(|e| format!("no Noise key: {e}"))
    }
}

#[cfg(target_os = "macos")]
mod keychain {
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::passwords::generic_password;
    use security_framework::passwords_options::PasswordOptions;
    use security_framework_sys::access_control::kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    use security_framework_sys::base::{errSecDuplicateItem, errSecItemNotFound, errSecSuccess};
    use security_framework_sys::item::kSecValueData;
    use security_framework_sys::keychain::SecKeychainSetUserInteractionAllowed;
    use security_framework_sys::keychain_item::SecItemAdd;

    /// errSecInteractionNotAllowed: the item exists, but reading it would
    /// need the Keychain's approval dialog.
    const INTERACTION_NOT_ALLOWED: i32 = -25308;
    const AUTH_FAILED: i32 = -25293;

    /// Why the Keychain gave no key.
    pub(super) enum Refused {
        /// Only a Keychain dialog could give it (never shown).
        NeedsUi,
        Other(String),
    }

    fn refused(code: i32) -> Refused {
        if code == INTERACTION_NOT_ALLOWED || code == AUTH_FAILED {
            Refused::NeedsUi
        } else {
            Refused::Other(format!("the Keychain refused the carrier key ({code})"))
        }
    }

    /// Turns Keychain UI off for this process while held. A `cmux` process
    /// is a CLI or daemon: a login-Keychain approval dialog from it is
    /// never something the person asked for (an item made by
    /// another build's signature prompted on every dial).
    struct NoUi;
    impl NoUi {
        fn new() -> Self {
            // SAFETY: plain setter, no pointers.
            unsafe { SecKeychainSetUserInteractionAllowed(0) };
            NoUi
        }
    }
    impl Drop for NoUi {
        fn drop(&mut self) {
            // SAFETY: as above.
            unsafe { SecKeychainSetUserInteractionAllowed(1) };
        }
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecAttrAccessible: CFStringRef;
    }

    fn options(service: &str, account: &str) -> PasswordOptions {
        let mut options = PasswordOptions::new_generic_password(service, account);
        options.set_access_synchronized(Some(false));
        options
    }

    fn read(service: &str, account: &str) -> Result<Option<[u8; 32]>, Refused> {
        match generic_password(options(service, account)) {
            Ok(bytes) => bytes
                .try_into()
                .map(Some)
                .map_err(|_| Refused::Other("the Keychain carrier key is not 32 bytes".to_owned())),
            Err(e) if e.code() == errSecItemNotFound => Ok(None),
            Err(e) => Err(refused(e.code())),
        }
    }

    pub(super) fn load_or_create(service: &str, account: &str) -> Result<[u8; 32], Refused> {
        let _no_ui = NoUi::new();
        if let Some(key) = read(service, account)? {
            return Ok(key);
        }
        let identity = cmux_remote::crypto::StaticIdentity::generate()
            .map_err(|e| Refused::Other(format!("no Noise key: {e}")))?;
        let key = *identity.private_key();
        let mut add = options(service, account);
        // SAFETY: all three are static CFStrings the Security framework exports.
        let (accessible, after_first_unlock, value_data) = unsafe {
            (
                CFString::wrap_under_get_rule(kSecAttrAccessible),
                CFString::wrap_under_get_rule(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
                CFString::wrap_under_get_rule(kSecValueData),
            )
        };
        #[allow(deprecated)] // `query` is the only way to set kSecAttrAccessible.
        let query = &mut add.query;
        query.push((accessible, after_first_unlock.into_CFType()));
        query.push((value_data, CFData::from_buffer(&key).into_CFType()));
        let attributes = CFDictionary::from_CFType_pairs(query);
        // Add only, never update: when two first dials race, the one whose
        // add loses reads the key the other stored, so the device keeps one key.
        // SAFETY: `attributes` is a live dictionary; no result is asked for.
        let status = unsafe { SecItemAdd(attributes.as_concrete_TypeRef(), std::ptr::null_mut()) };
        if status == errSecDuplicateItem {
            return read(service, account)?.ok_or_else(|| {
                Refused::Other("the Keychain carrier key vanished while it was stored".to_owned())
            });
        }
        if status != errSecSuccess {
            return Err(refused(status));
        }
        Ok(key)
    }
}
