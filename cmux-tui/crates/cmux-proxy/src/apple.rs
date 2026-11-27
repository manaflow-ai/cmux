//! The system's proxy settings on iOS and macOS, from CFNetwork: the list
//! URLSession would use for a URL (a manual HTTP, HTTPS or SOCKS proxy, a
//! PAC file or script, WPAD, an MDM global proxy), with PAC run by CFNetwork
//! itself (`CFNetworkExecuteProxyAutoConfigurationURL`) on this thread's run
//! loop. The caller is a blocking thread ([`super::proxy::hops`]).

use std::ffi::c_void;
use std::ptr;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use core_foundation::base::TCFType;
use core_foundation::string::CFString;
use core_foundation::url::CFURL;
use core_foundation_sys::array::{
    CFArrayGetCount, CFArrayGetTypeID, CFArrayGetValueAtIndex, CFArrayRef,
};
use core_foundation_sys::base::{CFGetTypeID, CFIndex, CFRelease, CFTypeRef, kCFAllocatorDefault};
use core_foundation_sys::dictionary::{
    CFDictionaryGetTypeID, CFDictionaryGetValue, CFDictionaryRef,
};
use core_foundation_sys::error::CFErrorRef;
use core_foundation_sys::number::{
    CFNumberGetTypeID, CFNumberGetValue, CFNumberRef, kCFNumberSInt64Type,
};
use core_foundation_sys::runloop::{
    CFRunLoopAddSource, CFRunLoopGetCurrent, CFRunLoopRemoveSource, CFRunLoopRunInMode,
    CFRunLoopSourceInvalidate, CFRunLoopSourceRef, CFRunLoopStop,
};
use core_foundation_sys::string::{CFStringGetTypeID, CFStringRef};
use core_foundation_sys::url::{CFURLCreateWithString, CFURLGetString, CFURLGetTypeID, CFURLRef};

use super::proxy::{Hop, ProxyServer, SystemEntry, hops_from_entries};

/// `CFProxyAutoConfigurationResultCallback`.
type PacCallback = extern "C" fn(client: *mut c_void, proxy_list: CFArrayRef, error: CFErrorRef);

/// `CFStreamClientContext`.
#[repr(C)]
struct StreamClientContext {
    version: CFIndex,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

#[link(name = "CFNetwork", kind = "framework")]
unsafe extern "C" {
    fn CFNetworkCopySystemProxySettings() -> CFDictionaryRef;
    fn CFNetworkCopyProxiesForURL(url: CFURLRef, proxy_settings: CFDictionaryRef) -> CFArrayRef;
    fn CFNetworkExecuteProxyAutoConfigurationURL(
        proxy_auto_config_url: CFURLRef,
        target_url: CFURLRef,
        callback: PacCallback,
        client_context: *mut StreamClientContext,
    ) -> CFRunLoopSourceRef;
    fn CFNetworkExecuteProxyAutoConfigurationScript(
        proxy_auto_configuration_script: CFStringRef,
        target_url: CFURLRef,
        callback: PacCallback,
        client_context: *mut StreamClientContext,
    ) -> CFRunLoopSourceRef;
    static kCFProxyTypeKey: CFStringRef;
    static kCFProxyHostNameKey: CFStringRef;
    static kCFProxyPortNumberKey: CFStringRef;
    static kCFProxyUsernameKey: CFStringRef;
    static kCFProxyPasswordKey: CFStringRef;
    static kCFProxyAutoConfigurationURLKey: CFStringRef;
    static kCFProxyAutoConfigurationJavaScriptKey: CFStringRef;
    static kCFProxyTypeNone: CFStringRef;
    static kCFProxyTypeHTTP: CFStringRef;
    static kCFProxyTypeHTTPS: CFStringRef;
    static kCFProxyTypeSOCKS: CFStringRef;
    static kCFProxyTypeAutoConfigurationURL: CFStringRef;
    static kCFProxyTypeAutoConfigurationJavaScript: CFStringRef;
}

/// A CF object this code owns (create rule), released on drop.
struct Owned(CFTypeRef);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: an object from a Create or Copy function, released once.
            unsafe { CFRelease(self.0) };
        }
    }
}

/// Bound on fetching and running one PAC file.
const PAC_WAIT: Duration = Duration::from_secs(4);

/// CFNetwork's PAC runner is not to be run on two threads at once
/// (Chromium's ProxyResolverMac serializes it the same way).
static PAC_LOCK: Mutex<()> = Mutex::new(());

/// The text of a CF string constant.
fn constant(value: CFStringRef) -> String {
    if value.is_null() {
        return String::new();
    }
    // SAFETY: a CFNetwork string constant, alive for the process.
    unsafe { CFString::wrap_under_get_rule(value) }.to_string()
}

/// The string at `key` of `dict`, if it is a string (or a URL, as text).
///
/// # Safety
/// `dict` is a live CFDictionary.
unsafe fn string_at(dict: CFDictionaryRef, key: CFStringRef) -> Option<String> {
    if key.is_null() {
        return None;
    }
    // SAFETY: the caller's dictionary; the key is a CF string.
    let value = unsafe { CFDictionaryGetValue(dict, key.cast()) };
    if value.is_null() {
        return None;
    }
    // SAFETY: `value` is a CF object owned by `dict` (get rule).
    let type_id = unsafe { CFGetTypeID(value) };
    // SAFETY: type ids of CF classes.
    let (string_type, url_type) = unsafe { (CFStringGetTypeID(), CFURLGetTypeID()) };
    if type_id == string_type {
        // SAFETY: checked to be a CFString above; retained by the wrapper.
        return Some(unsafe { CFString::wrap_under_get_rule(value.cast()) }.to_string());
    }
    if type_id == url_type {
        // SAFETY: checked to be a CFURL; its string follows the get rule.
        let text = unsafe { CFURLGetString(value.cast()) };
        return (!text.is_null()).then(|| constant(text));
    }
    None
}

/// The integer at `key` of `dict`, if it is a number.
///
/// # Safety
/// `dict` is a live CFDictionary.
unsafe fn number_at(dict: CFDictionaryRef, key: CFStringRef) -> Option<i64> {
    if key.is_null() {
        return None;
    }
    // SAFETY: the caller's dictionary; the key is a CF string.
    let value = unsafe { CFDictionaryGetValue(dict, key.cast()) };
    // SAFETY: a CF object owned by `dict`, and the CFNumber class id.
    if value.is_null() || unsafe { CFGetTypeID(value) != CFNumberGetTypeID() } {
        return None;
    }
    let mut out: i64 = 0;
    // SAFETY: a CFNumber; `out` is an i64 for kCFNumberSInt64Type.
    let ok = unsafe {
        CFNumberGetValue(value as CFNumberRef, kCFNumberSInt64Type, (&raw mut out).cast())
    };
    ok.then_some(out)
}

/// One entry of CFNetwork's proxy list.
///
/// # Safety
/// `dict` is a live CFDictionary from that list.
unsafe fn entry(dict: CFDictionaryRef) -> SystemEntry {
    // SAFETY: CFNetwork's key constants; the caller's dictionary.
    let (type_key, host_key, port_key, user_key, password_key, pac_url_key, pac_script_key) = unsafe {
        (
            kCFProxyTypeKey,
            kCFProxyHostNameKey,
            kCFProxyPortNumberKey,
            kCFProxyUsernameKey,
            kCFProxyPasswordKey,
            kCFProxyAutoConfigurationURLKey,
            kCFProxyAutoConfigurationJavaScriptKey,
        )
    };
    // SAFETY: the caller's dictionary.
    let kind = unsafe { string_at(dict, type_key) }.unwrap_or_default();
    let server = || {
        // SAFETY: the caller's dictionary.
        let host = unsafe { string_at(dict, host_key) }.filter(|host| !host.is_empty())?;
        // SAFETY: the caller's dictionary.
        let port =
            unsafe { number_at(dict, port_key) }.and_then(|port| u16::try_from(port).ok())?;
        let mut server = ProxyServer::new(host, port);
        // SAFETY: the caller's dictionary.
        if let Some(user) = unsafe { string_at(dict, user_key) }.filter(|user| !user.is_empty()) {
            // SAFETY: the caller's dictionary.
            // A user name without its password (kept in the Keychain, out of
            // reach here) is no sign-in: sending an empty password would read
            // as "refused the user name and password" to the person.
            if let Some(password) =
                unsafe { string_at(dict, password_key) }.filter(|p| !p.is_empty())
            {
                server = server.with_credentials(&user, &password);
            }
        }
        Some(server)
    };
    // SAFETY: CFNetwork's proxy type constants.
    let (none, http, https, socks, pac_url, pac_script) = unsafe {
        (
            constant(kCFProxyTypeNone),
            constant(kCFProxyTypeHTTP),
            constant(kCFProxyTypeHTTPS),
            constant(kCFProxyTypeSOCKS),
            constant(kCFProxyTypeAutoConfigurationURL),
            constant(kCFProxyTypeAutoConfigurationJavaScript),
        )
    };
    if kind == none {
        SystemEntry::Direct
    } else if kind == http || kind == https {
        server().map_or(SystemEntry::Other(kind), SystemEntry::Http)
    } else if kind == socks {
        server().map_or(SystemEntry::Other(kind), SystemEntry::Socks)
    } else if kind == pac_url {
        // SAFETY: the caller's dictionary.
        unsafe { string_at(dict, pac_url_key) }
            .map_or(SystemEntry::Other(kind), SystemEntry::PacUrl)
    } else if kind == pac_script {
        // SAFETY: the caller's dictionary.
        unsafe { string_at(dict, pac_script_key) }
            .map_or(SystemEntry::Other(kind), SystemEntry::PacScript)
    } else {
        SystemEntry::Other(kind)
    }
}

/// The entries of a CFNetwork proxy list.
///
/// # Safety
/// `list` is null or a live CF object.
unsafe fn entries(list: CFArrayRef) -> Vec<SystemEntry> {
    // SAFETY: a live CF object; the CFArray class id.
    if list.is_null() || unsafe { CFGetTypeID(list.cast()) != CFArrayGetTypeID() } {
        return Vec::new();
    }
    // SAFETY: checked to be a CFArray.
    let count = unsafe { CFArrayGetCount(list) };
    let mut out = Vec::new();
    for index in 0..count {
        // SAFETY: an index below the count; the item follows the get rule.
        let item = unsafe { CFArrayGetValueAtIndex(list, index) };
        // SAFETY: a CF object in the array; the CFDictionary class id.
        if item.is_null() || unsafe { CFGetTypeID(item) != CFDictionaryGetTypeID() } {
            continue;
        }
        // SAFETY: checked to be a CFDictionary.
        out.push(unsafe { entry(item.cast()) });
    }
    out
}

fn cf_url(text: &str) -> Option<CFURL> {
    let string = CFString::new(text);
    // SAFETY: a valid CF string; the result follows the create rule.
    let url = unsafe {
        CFURLCreateWithString(kCFAllocatorDefault, string.as_concrete_TypeRef(), ptr::null())
    };
    // SAFETY: owned (create rule), wrapped once.
    (!url.is_null()).then(|| unsafe { CFURL::wrap_under_create_rule(url) })
}

/// What one PAC run answered, filled in by [`pac_done`].
struct PacRun {
    done: bool,
    entries: Option<Vec<SystemEntry>>,
}

extern "C" fn pac_done(client: *mut c_void, proxy_list: CFArrayRef, error: CFErrorRef) {
    if client.is_null() {
        return;
    }
    // SAFETY: `client` is the PacRun `run_pac` boxed and passed as the
    // context's info; it is freed only after its source was invalidated.
    let run = unsafe { &mut *client.cast::<PacRun>() };
    run.done = true;
    if error.is_null() {
        // SAFETY: CFNetwork's answer, alive during this callback.
        run.entries = Some(unsafe { entries(proxy_list) });
    }
    // SAFETY: this thread's run loop, running in `run_pac`.
    unsafe { CFRunLoopStop(CFRunLoopGetCurrent()) };
}

/// Run a PAC entry for `target` on this thread's run loop; `None` when it
/// could not be fetched or run in [`PAC_WAIT`].
fn run_pac(entry: &SystemEntry, target: &CFURL) -> Option<Vec<SystemEntry>> {
    let _one_at_a_time = PAC_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let run = Box::into_raw(Box::new(PacRun { done: false, entries: None }));
    let mut context = StreamClientContext {
        version: 0,
        info: run.cast(),
        retain: ptr::null(),
        release: ptr::null(),
        copy_description: ptr::null(),
    };
    let source = match entry {
        SystemEntry::PacUrl(url) => match cf_url(url) {
            // SAFETY: live CF URLs; the context outlives the run below.
            Some(pac) => unsafe {
                CFNetworkExecuteProxyAutoConfigurationURL(
                    pac.as_concrete_TypeRef(),
                    target.as_concrete_TypeRef(),
                    pac_done,
                    &raw mut context,
                )
            },
            None => ptr::null_mut(),
        },
        SystemEntry::PacScript(script) => {
            let script = CFString::new(script);
            // SAFETY: a live CF string and URL; the context outlives the run.
            unsafe {
                CFNetworkExecuteProxyAutoConfigurationScript(
                    script.as_concrete_TypeRef(),
                    target.as_concrete_TypeRef(),
                    pac_done,
                    &raw mut context,
                )
            }
        }
        _ => ptr::null_mut(),
    };
    if source.is_null() {
        // SAFETY: boxed above and never handed out.
        drop(unsafe { Box::from_raw(run) });
        return None;
    }
    let mode = CFString::from_static_string("dev.cmux.mobile.egress.pac");
    // SAFETY: this thread's run loop and the source CFNetwork returned.
    let run_loop = unsafe { CFRunLoopGetCurrent() };
    // SAFETY: as above.
    unsafe { CFRunLoopAddSource(run_loop, source, mode.as_concrete_TypeRef()) };
    let deadline = Instant::now() + PAC_WAIT;
    loop {
        // SAFETY: only this thread touches `run`; the callback runs inside
        // CFRunLoopRunInMode below, on this thread.
        if unsafe { (*run).done } {
            break;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            tracing::warn!("the PAC file did not answer in time; connecting directly");
            break;
        }
        // SAFETY: running this thread's own run loop in a private mode.
        unsafe { CFRunLoopRunInMode(mode.as_concrete_TypeRef(), left.as_secs_f64(), 1) };
    }
    // SAFETY: the source added above; invalidated so its callback can no
    // longer run, then released (create rule).
    unsafe {
        CFRunLoopRemoveSource(run_loop, source, mode.as_concrete_TypeRef());
        CFRunLoopSourceInvalidate(source);
        CFRelease(source.cast_const().cast());
    }
    // SAFETY: boxed above; the callback can no longer reach it.
    let run = unsafe { Box::from_raw(run) };
    run.entries
}

/// The hops the system's settings give for `url` (`https://host:port/`).
pub(super) fn hops_for_url(url: &str) -> Vec<Hop> {
    let Some(target) = cf_url(url) else { return vec![Hop::Direct] };
    // SAFETY: a Copy function (create rule), released by `Owned`.
    let settings = Owned(unsafe { CFNetworkCopySystemProxySettings() }.cast());
    if settings.0.is_null() {
        return vec![Hop::Direct];
    }
    // SAFETY: a live URL and settings dictionary; the list follows the create rule.
    let list = Owned(
        unsafe { CFNetworkCopyProxiesForURL(target.as_concrete_TypeRef(), settings.0.cast()) }
            .cast(),
    );
    // SAFETY: null or the live list above.
    let entries = unsafe { entries(list.0.cast()) };
    hops_from_entries(entries, |entry| run_pac(entry, &target))
}

#[cfg(test)]
#[path = "apple_tests.rs"]
mod tests;
