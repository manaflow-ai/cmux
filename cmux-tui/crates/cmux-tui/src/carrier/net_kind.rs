//! The `net=` tag of a `carrier.phases` line (RFD 0223 row 1: Mac-side connect "by region and
//! network (Wi-Fi, cell)"): the kind of this machine's primary network interface.
//!
//! Read once per process, lazily, when the first phases line is written (after the attempt it
//! counts), never before or during a connect. On macOS the primary interface is
//! `State:/Network/Global/IPv4`'s `PrimaryInterface` in the SystemConfiguration dynamic store, and
//! it is Wi-Fi when the store has `State:/Network/Interface/<name>/AirPort`. Anything we cannot
//! tell for sure is `unknown`, never a guess.

use std::sync::OnceLock;

/// `wifi`, `wired`, `cell`, `other` (a VPN or tunnel is primary) or `unknown`.
pub(super) fn current() -> &'static str {
    static KIND: OnceLock<&'static str> = OnceLock::new();
    KIND.get_or_init(read)
}

/// The kind of interface `name`, given whether the store has an AirPort entry for it.
pub(super) fn classify(name: Option<&str>, airport: bool) -> &'static str {
    let Some(name) = name.filter(|n| !n.is_empty()) else { return "unknown" };
    if airport {
        return "wifi";
    }
    if name.starts_with("pdp_ip") {
        return "cell";
    }
    if ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].iter().any(|p| name.starts_with(p)) {
        return "other";
    }
    if name.starts_with("en") || name.starts_with("bridge") {
        // An en* with no AirPort entry: Ethernet, a USB or Thunderbolt adapter, or an iPhone
        // tethered by cable (its hotspot over Wi-Fi is wifi here).
        return "wired";
    }
    "unknown"
}

#[cfg(target_os = "macos")]
fn read() -> &'static str {
    let name = macos::primary_interface();
    let airport = name.as_deref().is_some_and(macos::has_airport);
    classify(name.as_deref(), airport)
}

#[cfg(not(target_os = "macos"))]
fn read() -> &'static str {
    "unknown"
}

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use std::ffi::c_void;

    type SCDynamicStoreRef = *const c_void;
    type CFPropertyListRef = *const c_void;

    #[link(name = "SystemConfiguration", kind = "framework")]
    unsafe extern "C" {
        fn SCDynamicStoreCreate(
            allocator: *const c_void,
            name: CFStringRef,
            callout: *const c_void,
            context: *const c_void,
        ) -> SCDynamicStoreRef;
        fn SCDynamicStoreCopyValue(store: SCDynamicStoreRef, key: CFStringRef)
        -> CFPropertyListRef;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(cf: *const c_void);
    }

    struct Store(SCDynamicStoreRef);

    impl Drop for Store {
        fn drop(&mut self) {
            // SAFETY: a non-null store from SCDynamicStoreCreate, released once.
            unsafe { CFRelease(self.0) }
        }
    }

    fn store() -> Option<Store> {
        let name = CFString::new("cmux-carrier-net");
        // SAFETY: a plain create with no callout; null on failure.
        let store = unsafe {
            SCDynamicStoreCreate(
                std::ptr::null(),
                name.as_concrete_TypeRef(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        (!store.is_null()).then_some(Store(store))
    }

    /// The store's value at `key`, owned, or None.
    fn value(store: &Store, key: &str) -> Option<CFType> {
        let key = CFString::new(key);
        // SAFETY: a valid store and key; the result follows the Copy rule (owned) or is null.
        let value = unsafe { SCDynamicStoreCopyValue(store.0, key.as_concrete_TypeRef()) };
        // SAFETY: an owned, non-null CF object.
        (!value.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(value) })
    }

    pub(super) fn primary_interface() -> Option<String> {
        let store = store()?;
        let global = value(&store, "State:/Network/Global/IPv4")?;
        let dict = global.downcast_into::<CFDictionary>()?;
        let key = CFString::new("PrimaryInterface");
        let raw = dict.find(key.as_concrete_TypeRef().cast())?;
        // SAFETY: a value borrowed from `dict`, which outlives this use; retained by the wrap.
        let name = unsafe { CFType::wrap_under_get_rule(*raw) };
        name.downcast_into::<CFString>().map(|s| s.to_string())
    }

    pub(super) fn has_airport(name: &str) -> bool {
        store().is_some_and(|store| {
            value(&store, &format!("State:/Network/Interface/{name}/AirPort")).is_some()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::classify;

    #[test]
    fn kinds() {
        assert_eq!(classify(Some("en0"), true), "wifi");
        assert_eq!(classify(Some("en5"), false), "wired");
        assert_eq!(classify(Some("pdp_ip0"), false), "cell");
        assert_eq!(classify(Some("utun3"), false), "other");
        assert_eq!(classify(Some("awdl0"), false), "unknown");
        assert_eq!(classify(None, false), "unknown");
        assert_eq!(classify(Some(""), true), "unknown");
    }

    #[test]
    fn current_is_one_of_the_tags() {
        assert!(["wifi", "wired", "cell", "other", "unknown"].contains(&super::current()));
    }
}
