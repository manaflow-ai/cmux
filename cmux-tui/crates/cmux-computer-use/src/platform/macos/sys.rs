//! The C surface of CoreFoundation, CoreGraphics and the Accessibility API
//! that the macOS desktop uses, and a retained CoreFoundation reference.
//!
//! Declared by hand (the functions are stable C ABI since macOS 10.x) so the
//! crate needs no framework binding crates' feature sets. Every pointer
//! handed out by a safe helper here is owned by a [`Cf`] or borrowed from one
//! that outlives it.
#![allow(non_upper_case_globals, non_snake_case, dead_code)]

use std::ffi::{CStr, c_char, c_void};

pub type CFTypeRef = *const c_void;
pub type CFIndex = isize;
pub type CFTypeID = usize;
pub type AXError = i32;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CGSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

/// An opaque C struct whose address is all we need (CF callback tables).
#[repr(C)]
pub struct Opaque {
    _private: [u8; 0],
}

pub const UTF8: u32 = 0x0800_0100;
const NUMBER_SINT64: CFIndex = 4;
const NUMBER_FLOAT64: CFIndex = 6;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    pub fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    pub fn CFRelease(cf: CFTypeRef);
    pub fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
    pub fn CFStringGetTypeID() -> CFTypeID;
    pub fn CFNumberGetTypeID() -> CFTypeID;
    pub fn CFBooleanGetTypeID() -> CFTypeID;
    pub fn CFArrayGetTypeID() -> CFTypeID;
    pub fn CFDictionaryGetTypeID() -> CFTypeID;
    pub fn CFStringCreateWithBytes(
        alloc: CFTypeRef,
        bytes: *const u8,
        len: CFIndex,
        encoding: u32,
        external: u8,
    ) -> CFTypeRef;
    pub fn CFStringGetLength(s: CFTypeRef) -> CFIndex;
    pub fn CFStringGetMaximumSizeForEncoding(len: CFIndex, encoding: u32) -> CFIndex;
    pub fn CFStringGetCString(s: CFTypeRef, buf: *mut c_char, size: CFIndex, encoding: u32) -> u8;
    pub fn CFArrayGetCount(a: CFTypeRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(a: CFTypeRef, i: CFIndex) -> CFTypeRef;
    pub fn CFArrayCreate(
        alloc: CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        callbacks: *const Opaque,
    ) -> CFTypeRef;
    pub fn CFDictionaryGetValue(d: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    pub fn CFDictionaryCreate(
        alloc: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        key_callbacks: *const Opaque,
        value_callbacks: *const Opaque,
    ) -> CFTypeRef;
    pub fn CFNumberGetValue(n: CFTypeRef, ty: CFIndex, out: *mut c_void) -> u8;
    pub fn CFNumberCreate(alloc: CFTypeRef, ty: CFIndex, value: *const c_void) -> CFTypeRef;
    pub fn CFBooleanGetValue(b: CFTypeRef) -> u8;
    pub fn CFDictionaryGetCount(d: CFTypeRef) -> CFIndex;
    pub fn CFDictionaryGetKeysAndValues(d: CFTypeRef, keys: *mut CFTypeRef, values: *mut CFTypeRef);
    pub fn CFPreferencesCopyAppValue(key: CFTypeRef, app: CFTypeRef) -> CFTypeRef;
    pub fn CFPreferencesAppSynchronize(app: CFTypeRef) -> u8;
    pub static kCFBooleanTrue: CFTypeRef;
    pub static kCFBooleanFalse: CFTypeRef;
    pub static kCFTypeArrayCallBacks: Opaque;
    pub static kCFTypeDictionaryKeyCallBacks: Opaque;
    pub static kCFTypeDictionaryValueCallBacks: Opaque;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    pub fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> CFTypeRef;
    pub fn CGMainDisplayID() -> u32;
    pub fn CGDisplayBounds(display: u32) -> CGRect;
    pub fn CGPreflightScreenCaptureAccess() -> bool;
    pub fn CGRequestScreenCaptureAccess() -> bool;
    pub fn CGPreflightPostEventAccess() -> bool;
    pub fn CGRequestPostEventAccess() -> bool;
    pub fn CGEventSourceCreate(state: i32) -> CFTypeRef;
    pub fn CGEventCreateMouseEvent(
        source: CFTypeRef,
        ty: u32,
        at: CGPoint,
        button: u32,
    ) -> CFTypeRef;
    pub fn CGEventCreateKeyboardEvent(source: CFTypeRef, keycode: u16, down: bool) -> CFTypeRef;
    pub fn CGEventCreateScrollWheelEvent2(
        source: CFTypeRef,
        units: u32,
        wheels: u32,
        wheel1: i32,
        wheel2: i32,
        wheel3: i32,
    ) -> CFTypeRef;
    pub fn CGEventKeyboardSetUnicodeString(event: CFTypeRef, len: usize, chars: *const u16);
    pub fn CGEventSetFlags(event: CFTypeRef, flags: u64);
    pub fn CGEventSetIntegerValueField(event: CFTypeRef, field: u32, value: i64);
    pub fn CGEventSetLocation(event: CFTypeRef, at: CGPoint);
    pub fn CGEventCreate(source: CFTypeRef) -> CFTypeRef;
    pub fn CGEventGetLocation(event: CFTypeRef) -> CGPoint;
    pub fn CGEventPostToPid(pid: i32, event: CFTypeRef);
    pub fn CGEventPost(tap: u32, event: CFTypeRef);
    pub fn CGImageGetWidth(image: CFTypeRef) -> usize;
    pub fn CGImageGetHeight(image: CFTypeRef) -> usize;
    pub fn CGColorSpaceCreateDeviceRGB() -> CFTypeRef;
    pub fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: CFTypeRef,
        info: u32,
    ) -> CFTypeRef;
    pub fn CGContextDrawImage(ctx: CFTypeRef, rect: CGRect, image: CFTypeRef);
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    pub fn AXIsProcessTrusted() -> u8;
    pub fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> u8;
    pub static kAXTrustedCheckOptionPrompt: CFTypeRef;
    pub fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    pub fn AXUIElementCreateSystemWide() -> CFTypeRef;
    pub fn AXUIElementCopyAttributeValue(
        e: CFTypeRef,
        attr: CFTypeRef,
        out: *mut CFTypeRef,
    ) -> AXError;
    pub fn AXUIElementCopyMultipleAttributeValues(
        e: CFTypeRef,
        attrs: CFTypeRef,
        options: u32,
        out: *mut CFTypeRef,
    ) -> AXError;
    pub fn AXUIElementSetAttributeValue(e: CFTypeRef, attr: CFTypeRef, value: CFTypeRef)
    -> AXError;
    pub fn AXUIElementIsAttributeSettable(e: CFTypeRef, attr: CFTypeRef, out: *mut u8) -> AXError;
    pub fn AXUIElementPerformAction(e: CFTypeRef, action: CFTypeRef) -> AXError;
    pub fn AXUIElementCopyActionNames(e: CFTypeRef, out: *mut CFTypeRef) -> AXError;
    pub fn AXUIElementSetMessagingTimeout(e: CFTypeRef, seconds: f32) -> AXError;
    pub fn AXUIElementGetPid(e: CFTypeRef, out: *mut i32) -> AXError;
    pub fn AXUIElementCopyElementAtPosition(
        app: CFTypeRef,
        x: f32,
        y: f32,
        out: *mut CFTypeRef,
    ) -> AXError;
    pub fn AXUIElementGetTypeID() -> CFTypeID;
    pub fn AXValueGetTypeID() -> CFTypeID;
    pub fn AXValueGetType(v: CFTypeRef) -> u32;
    pub fn AXValueGetValue(v: CFTypeRef, ty: u32, out: *mut c_void) -> u8;
}

// AppKit holds NSWorkspace; linking it makes the class available to the
// Objective-C runtime lookups in `workspace.rs`.
#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}

pub const AX_OK: AXError = 0;
pub const AX_INVALID_ELEMENT: AXError = -25202;
pub const AX_CANNOT_COMPLETE: AXError = -25204;
pub const AX_ATTRIBUTE_UNSUPPORTED: AXError = -25205;
pub const AX_ACTION_UNSUPPORTED: AXError = -25206;
pub const AX_API_DISABLED: AXError = -25211;
pub const AX_NO_VALUE: AXError = -25212;

pub const AX_VALUE_CGPOINT: u32 = 1;
pub const AX_VALUE_CGSIZE: u32 = 2;
pub const AX_VALUE_ERROR: u32 = 5;

/// A retained CoreFoundation object (+1), released on drop.
pub struct Cf(CFTypeRef);

// SAFETY: CoreFoundation objects (CFString, CFArray, CGEvent, AXUIElement and
// the rest used here) are immutable or internally synchronized, and
// CFRetain/CFRelease are thread-safe.
unsafe impl Send for Cf {}
unsafe impl Sync for Cf {}

impl Cf {
    /// Takes ownership of a reference returned by a Create/Copy function.
    pub fn created(p: CFTypeRef) -> Option<Self> {
        (!p.is_null()).then_some(Cf(p))
    }

    /// Retains a borrowed (Get rule) reference.
    pub fn retained(p: CFTypeRef) -> Option<Self> {
        if p.is_null() {
            return None;
        }
        // SAFETY: p is a live CF object borrowed from a container the caller holds.
        unsafe { CFRetain(p) };
        Some(Cf(p))
    }

    pub fn ptr(&self) -> CFTypeRef {
        self.0
    }

    pub fn type_id(&self) -> CFTypeID {
        // SAFETY: self.0 is a live CF object.
        unsafe { CFGetTypeID(self.0) }
    }

    pub fn string(s: &str) -> Option<Self> {
        // SAFETY: the bytes are valid UTF-8 for the given length.
        Cf::created(unsafe {
            CFStringCreateWithBytes(std::ptr::null(), s.as_ptr(), s.len() as CFIndex, UTF8, 0)
        })
    }

    pub fn number_f64(v: f64) -> Option<Self> {
        // SAFETY: v outlives the call; CFNumberCreate copies it.
        Cf::created(unsafe {
            CFNumberCreate(std::ptr::null(), NUMBER_FLOAT64, (&raw const v).cast())
        })
    }

    pub fn boolean(v: bool) -> Option<Self> {
        // SAFETY: the CFBoolean singletons are immortal.
        Cf::retained(unsafe { if v { kCFBooleanTrue } else { kCFBooleanFalse } })
    }

    /// A CFArray of CF objects (retained by the array).
    pub fn array(items: &[CFTypeRef]) -> Option<Self> {
        // SAFETY: items are live CF objects; the callbacks retain them.
        Cf::created(unsafe {
            CFArrayCreate(
                std::ptr::null(),
                items.as_ptr(),
                items.len() as CFIndex,
                &raw const kCFTypeArrayCallBacks,
            )
        })
    }

    /// A one-entry CFDictionary.
    pub fn dictionary(key: &Cf, value: &Cf) -> Option<Self> {
        let keys = [key.0];
        let values = [value.0];
        // SAFETY: key and value are live; the callbacks retain them.
        Cf::created(unsafe {
            CFDictionaryCreate(
                std::ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                &raw const kCFTypeDictionaryKeyCallBacks,
                &raw const kCFTypeDictionaryValueCallBacks,
            )
        })
    }

    pub fn as_string(&self) -> Option<String> {
        string_of(self.0)
    }

    /// The items of a CFArray, retained.
    pub fn items(&self) -> Vec<Cf> {
        // SAFETY: checked to be a CFArray before indexing.
        unsafe {
            if self.type_id() != CFArrayGetTypeID() {
                return Vec::new();
            }
            let n = CFArrayGetCount(self.0);
            (0..n).filter_map(|i| Cf::retained(CFArrayGetValueAtIndex(self.0, i))).collect()
        }
    }

    /// The values of a CFDictionary, retained (empty for anything else).
    pub fn dict_values(&self) -> Vec<Cf> {
        // SAFETY: checked to be a CFDictionary; the out arrays hold count entries.
        unsafe {
            if self.type_id() != CFDictionaryGetTypeID() {
                return Vec::new();
            }
            let n = CFDictionaryGetCount(self.0).max(0) as usize;
            let mut keys = vec![std::ptr::null(); n];
            let mut values = vec![std::ptr::null(); n];
            CFDictionaryGetKeysAndValues(self.0, keys.as_mut_ptr(), values.as_mut_ptr());
            values.into_iter().filter_map(Cf::retained).collect()
        }
    }

    /// Drops this process's cached copy of another app's preferences, so the
    /// next read sees what that app (or the system) wrote since.
    pub fn synchronize_preferences(app: &str) {
        if let Some(a) = Cf::string(app) {
            // SAFETY: a is live for the call.
            unsafe { CFPreferencesAppSynchronize(a.0) };
        }
    }

    /// A user default of another app (`CFPreferencesCopyAppValue`), or None.
    pub fn preference(key: &str, app: &str) -> Option<Cf> {
        let k = Cf::string(key)?;
        let a = Cf::string(app)?;
        // SAFETY: both live; the result is +1 or null.
        Cf::created(unsafe { CFPreferencesCopyAppValue(k.0, a.0) })
    }

    /// A value of a CFDictionary by string key, retained.
    pub fn get(&self, key: &str) -> Option<Cf> {
        let k = Cf::string(key)?;
        // SAFETY: checked to be a CFDictionary; k is live for the call.
        unsafe {
            if self.type_id() != CFDictionaryGetTypeID() {
                return None;
            }
            Cf::retained(CFDictionaryGetValue(self.0, k.0))
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        // SAFETY: checked to be a CFNumber or CFBoolean before reading.
        unsafe {
            let t = self.type_id();
            if t == CFNumberGetTypeID() {
                let mut v = 0f64;
                (CFNumberGetValue(self.0, NUMBER_FLOAT64, (&raw mut v).cast()) != 0).then_some(v)
            } else if t == CFBooleanGetTypeID() {
                Some(if CFBooleanGetValue(self.0) != 0 { 1.0 } else { 0.0 })
            } else {
                None
            }
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        // SAFETY: checked to be a CFNumber before reading.
        unsafe {
            if self.type_id() != CFNumberGetTypeID() {
                return None;
            }
            let mut v = 0i64;
            (CFNumberGetValue(self.0, NUMBER_SINT64, (&raw mut v).cast()) != 0).then_some(v)
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        self.as_f64().map(|v| v != 0.0)
    }

    pub fn is_number(&self) -> bool {
        // SAFETY: plain type id read.
        unsafe { self.type_id() == CFNumberGetTypeID() || self.type_id() == CFBooleanGetTypeID() }
    }
}

impl Clone for Cf {
    fn clone(&self) -> Self {
        // SAFETY: self.0 is live; the clone owns its own +1.
        unsafe { CFRetain(self.0) };
        Cf(self.0)
    }
}

impl Drop for Cf {
    fn drop(&mut self) {
        // SAFETY: we own one reference.
        unsafe { CFRelease(self.0) }
    }
}

/// A CFString (or bridged NSString) as a Rust string.
fn string_of(p: CFTypeRef) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // SAFETY: p is a live CF object; the buffer is sized by CF for UTF-8.
    unsafe {
        if CFGetTypeID(p) != CFStringGetTypeID() {
            return None;
        }
        let len = CFStringGetLength(p);
        let max = CFStringGetMaximumSizeForEncoding(len, UTF8) + 1;
        let mut buf = vec![0 as c_char; max.max(1) as usize];
        if CFStringGetCString(p, buf.as_mut_ptr(), max, UTF8) == 0 {
            return None;
        }
        Some(CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned())
    }
}

/// A C string from a `sysctlbyname` key (`kern.osproductversion`).
pub fn sysctl_string(name: &CStr) -> Option<String> {
    let mut len: libc::size_t = 0;
    // SAFETY: sizing call, then a buffer of that size.
    unsafe {
        if libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
            || len == 0
        {
            return None;
        }
        let mut buf = vec![0u8; len];
        if libc::sysctlbyname(
            name.as_ptr(),
            buf.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        let s = CStr::from_bytes_until_nul(&buf).ok()?;
        Some(s.to_string_lossy().into_owned())
    }
}

/// A symbol looked up at run time (private or obsoleted API).
pub fn symbol(name: &CStr) -> Option<*mut c_void> {
    // SAFETY: dlsym with RTLD_DEFAULT and a NUL-terminated name.
    let p = unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()) };
    (!p.is_null()).then_some(p)
}
