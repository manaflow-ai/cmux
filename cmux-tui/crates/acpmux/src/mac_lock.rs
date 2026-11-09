//! This Mac's screen lock, as the window server reports it, and the one idle-sleep
//! assertion the lock bridge holds (`hub/lock_bridge.rs`, design/lock-bridge.md).
//!
//! The lock is read from `CGSessionCopyCurrentDictionary`: `CGSSessionScreenIsLocked`
//! is true while this login's screen is locked (the same key the app's
//! `NotificationPreviews.screenIsLocked` reads). The daemon runs in the Aqua
//! session (`daemon/login_session.rs`), so the dictionary is there; outside a GUI
//! session it is nil, and the state is [`Lock::Unknown`]. One call reads it, in
//! process: no subprocess and no notification observer.
//!
//! The assertion is IOKit's `PreventUserIdleSystemSleep`, the same one the app's
//! Keep Mac Awake (`KeepAwakeService`, a `ProcessInfo` activity with
//! `.idleSystemSleepDisabled`) takes. It stops only idle sleep: the display still
//! sleeps, a closed lid on battery still sleeps the Mac, and low battery still
//! sleeps it. Off macOS there is no screen to lock: [`Lock::None`], and no
//! assertion is taken.

/// The screen lock state of this login.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lock {
    /// The screen is unlocked.
    Unlocked,
    /// The screen is locked: nobody can see or answer this Mac's screen.
    Locked,
    /// The window server did not say (no GUI session, or the read failed).
    Unknown,
    /// Not a Mac: nothing here has a screen lock.
    None,
}

impl Lock {
    /// The wire name (`mac_locked` waits, status views).
    pub fn as_str(self) -> &'static str {
        match self {
            Lock::Unlocked => "unlocked",
            Lock::Locked => "locked",
            Lock::Unknown => "unknown",
            Lock::None => "none",
        }
    }
}

/// The typed reason a screen- or person-gated step answers while the screen is
/// locked: the Computer Use gates (`cua_v2.rs`, `cua_lock_gate.rs`) and the
/// permission wait (`_acpmux/permission_pending`'s `macLocked`).
pub const MAC_LOCKED: &str = "mac_locked";

/// The text a gated step answers with while the screen is locked.
pub const MAC_LOCKED_TEXT: &str = "mac_locked: this Mac's screen is locked, so nothing can see or \
    use its screen. The step was not run. Continue with work that does not need the screen, or \
    wait until the person unlocks the Mac.";

/// This login's screen lock now.
pub fn lock() -> Lock {
    imp::lock()
}

/// Whether the screen is locked now ([`Lock::Locked`] only: an unknown state gates nothing).
pub fn locked() -> bool {
    lock() == Lock::Locked
}

/// Whether Computer Use waits in `lock`: unless the screen is known to be unlocked. An unknown
/// state (no session dictionary, a failed read) waits like a lock, since a screenshot or a click
/// then might land on the lock screen; off a Mac there is no screen to lock.
pub fn holds_computer_use(lock: Lock) -> bool {
    matches!(lock, Lock::Locked | Lock::Unknown)
}

/// Whether Computer Use waits now ([`holds_computer_use`] of [`lock`]).
pub fn computer_use_held() -> bool {
    holds_computer_use(lock())
}

/// `CGSSessionScreenIsLocked` in a session dictionary that was read: absent (`None`), a
/// Boolean (`Some(Some(b))`), or some other type (`Some(None)`). The window server sets the key
/// only while locked, so absent is unlocked; a value of another type is unknown.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn classify(value: Option<Option<bool>>) -> Lock {
    match value {
        None | Some(Some(false)) => Lock::Unlocked,
        Some(Some(true)) => Lock::Locked,
        Some(None) => Lock::Unknown,
    }
}

/// One held `PreventUserIdleSystemSleep` assertion, released on drop. `None` when it
/// could not be taken (off macOS, or IOKit refused).
pub struct IdleSleepHold(#[allow(dead_code)] imp::Hold);

impl IdleSleepHold {
    /// Takes the assertion, named `reason` (what `pmset -g assertions` shows).
    pub fn take(reason: &str) -> Option<Self> {
        imp::Hold::take(reason).map(Self)
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Lock;
    use std::ffi::{CString, c_char, c_void};

    type CFTypeRef = *const c_void;
    type CFStringRef = *const c_void;
    type CFDictionaryRef = *const c_void;
    /// `kCFStringEncodingUTF8`.
    const UTF8: u32 = 0x0800_0100;
    /// `kIOPMAssertionLevelOn`.
    const LEVEL_ON: u32 = 255;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(
            alloc: CFTypeRef,
            text: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFDictionaryGetValue(dict: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
        fn CFGetTypeID(value: CFTypeRef) -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFBooleanGetValue(value: CFTypeRef) -> u8;
        fn CFRelease(value: CFTypeRef);
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGSessionCopyCurrentDictionary() -> CFDictionaryRef;
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPMAssertionCreateWithName(
            kind: CFStringRef,
            level: u32,
            name: CFStringRef,
            id: *mut u32,
        ) -> i32;
        fn IOPMAssertionRelease(id: u32) -> i32;
    }

    /// An owned CFString, released on drop. None for text with a NUL or a failed create.
    struct CfString(CFStringRef);

    impl CfString {
        fn new(text: &str) -> Option<Self> {
            let text = CString::new(text).ok()?;
            // SAFETY: `text` is a valid NUL-terminated UTF-8 string for the call; a null
            // allocator is the default allocator.
            let made = unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), UTF8) };
            (!made.is_null()).then(|| Self(made))
        }
    }

    impl Drop for CfString {
        fn drop(&mut self) {
            // SAFETY: `self.0` came from a Create call (owned, non-null) and is released once.
            unsafe { CFRelease(self.0) };
        }
    }

    pub(super) fn lock() -> Lock {
        let Some(key) = CfString::new("CGSSessionScreenIsLocked") else { return Lock::Unknown };
        // SAFETY: no arguments; the result is owned (Copy rule) or null.
        let session = unsafe { CGSessionCopyCurrentDictionary() };
        if session.is_null() {
            return Lock::Unknown;
        }
        // SAFETY: `session` is a valid CFDictionary and `key` a valid CFString; the value
        // is borrowed from the dictionary, read before the dictionary is released.
        let value = unsafe {
            let value = CFDictionaryGetValue(session, key.0);
            let read = (!value.is_null()).then(|| {
                (CFGetTypeID(value) == CFBooleanGetTypeID()).then(|| CFBooleanGetValue(value) != 0)
            });
            CFRelease(session);
            read
        };
        super::classify(value)
    }

    pub(crate) struct Hold(u32);

    impl Hold {
        pub(super) fn take(reason: &str) -> Option<Self> {
            let kind = CfString::new("PreventUserIdleSystemSleep")?;
            let name = CfString::new(reason)?;
            let mut id = 0u32;
            // SAFETY: both strings are valid CFStrings for the call and `id` is a valid
            // out pointer.
            let status = unsafe { IOPMAssertionCreateWithName(kind.0, LEVEL_ON, name.0, &mut id) };
            (status == 0).then(|| Self(id))
        }
    }

    impl Drop for Hold {
        fn drop(&mut self) {
            // SAFETY: `self.0` is an assertion this process created and releases once.
            unsafe { IOPMAssertionRelease(self.0) };
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::Lock;

    pub(super) fn lock() -> Lock {
        Lock::None
    }

    pub(crate) struct Hold;

    impl Hold {
        pub(super) fn take(_reason: &str) -> Option<Self> {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Review of #37239 at fda360ba, F1: Computer Use runs only on a screen known to be unlocked.
    /// An unknown state (no session dictionary, a failed read) waits like a lock; off a Mac there
    /// is no screen to lock.
    #[test]
    fn computer_use_waits_unless_the_screen_is_confirmed_unlocked() {
        assert!(holds_computer_use(Lock::Locked));
        assert!(holds_computer_use(Lock::Unknown));
        assert!(!holds_computer_use(Lock::Unlocked));
        assert!(!holds_computer_use(Lock::None));
    }

    /// The window server sets the key only while locked: absent is unlocked, a Boolean says
    /// which, and a value of any other type is unknown, never unlocked.
    #[test]
    fn a_lock_flag_that_is_not_a_boolean_is_unknown() {
        assert_eq!(classify(None), Lock::Unlocked);
        assert_eq!(classify(Some(Some(true))), Lock::Locked);
        assert_eq!(classify(Some(Some(false))), Lock::Unlocked);
        assert_eq!(classify(Some(None)), Lock::Unknown);
    }
}
