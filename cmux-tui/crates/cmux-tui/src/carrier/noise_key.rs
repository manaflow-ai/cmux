//! The device's Noise static key for carrier sessions.
//!
//! On a Mac it lives in the login Keychain the way the other device keys do
//! (a generic password, not synchronized, accessible after first unlock on
//! this device only; `NativeDeviceSecret.swift` stores the native mesh key
//! the same way), so the device id a grant admits (`carrier:<user>:<key
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

/// The device's carrier identity.
pub(super) fn device_identity() -> Result<StaticIdentity, String> {
    #[cfg(target_os = "macos")]
    {
        keychain::load_or_create(SERVICE, ACCOUNT).map(StaticIdentity::from_private)
    }
    #[cfg(not(target_os = "macos"))]
    {
        StaticIdentity::generate().map_err(|e| format!("no Noise key: {e}"))
    }
}

#[cfg(target_os = "macos")]
mod keychain {
    use core_foundation::base::TCFType;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::passwords::{generic_password, set_generic_password_options};
    use security_framework::passwords_options::PasswordOptions;
    use security_framework_sys::access_control::kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    use security_framework_sys::base::errSecItemNotFound;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecAttrAccessible: CFStringRef;
    }

    fn options(service: &str, account: &str) -> PasswordOptions {
        let mut options = PasswordOptions::new_generic_password(service, account);
        options.set_access_synchronized(Some(false));
        options
    }

    fn read(service: &str, account: &str) -> Result<Option<[u8; 32]>, String> {
        match generic_password(options(service, account)) {
            Ok(bytes) => bytes
                .try_into()
                .map(Some)
                .map_err(|_| "the Keychain carrier key is not 32 bytes".to_owned()),
            Err(e) if e.code() == errSecItemNotFound => Ok(None),
            Err(e) => Err(format!("the Keychain refused the carrier key ({})", e.code())),
        }
    }

    pub(super) fn load_or_create(service: &str, account: &str) -> Result<[u8; 32], String> {
        if let Some(key) = read(service, account)? {
            return Ok(key);
        }
        let identity = cmux_remote::crypto::StaticIdentity::generate()
            .map_err(|e| format!("no Noise key: {e}"))?;
        let key = *identity.private_key();
        let mut add = options(service, account);
        // SAFETY: both are static CFStrings the Security framework exports.
        let (attribute, value) = unsafe {
            (
                CFString::wrap_under_get_rule(kSecAttrAccessible),
                CFString::wrap_under_get_rule(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            )
        };
        #[allow(deprecated)] // `query` is the only way to set kSecAttrAccessible.
        add.query.push((attribute, value.into_CFType()));
        // Two first dials at once may each store a key; the later one stays.
        // Each dial's grant names the key it holds, so both still connect.
        set_generic_password_options(&key, add)
            .map_err(|e| format!("the Keychain refused the carrier key ({})", e.code()))?;
        Ok(key)
    }
}
