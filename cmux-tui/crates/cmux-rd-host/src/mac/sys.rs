//! The Apple frameworks a macOS host session uses, bound at run time (cmux_encode::dynlib): the
//! host ships inside the `cmux` CLI binary, which must not load CoreGraphics, CoreMedia,
//! CoreVideo or ScreenCaptureKit at every launch, and whose macOS build on Linux has no link
//! stubs for them. ScreenCaptureKit is an Objective-C API: its classes are looked up and
//! messaged through the Objective-C runtime (`msg`), and its completion handlers are blocks
//! built here (`Block`).

use cmux_encode::framework;
use std::ffi::{c_char, c_int, c_long, c_void, CStr};

pub type Id = *mut c_void;
pub type Sel = *const c_void;
pub type Class = *mut c_void;
pub type CFTypeRef = *const c_void;
pub type CFStringRef = *const c_void;
pub type CFArrayRef = *const c_void;
pub type CFDictionaryRef = *const c_void;
pub type CFNumberRef = *const c_void;
pub type CGEventRef = *mut c_void;
pub type CGEventSourceRef = *mut c_void;
pub type CGDisplayModeRef = *mut c_void;
pub type CMSampleBufferRef = *mut c_void;
pub type CVPixelBufferRef = *mut c_void;
pub type IOSurfaceRef = *mut c_void;
pub type DispatchQueue = *mut c_void;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

impl CGPoint {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CMTime {
    pub value: i64,
    pub timescale: i32,
    pub flags: u32,
    pub epoch: i64,
}

/// A macOS virtual key code (Carbon kVK_*).
pub type CGKeyCode = u16;

/// CGEventFlags: the modifier bits an event carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CGEventFlags(pub u64);

#[allow(non_upper_case_globals)]
impl CGEventFlags {
    pub const CGEventFlagShift: Self = Self(0x0002_0000);
    pub const CGEventFlagControl: Self = Self(0x0004_0000);
    pub const CGEventFlagAlternate: Self = Self(0x0008_0000);
    pub const CGEventFlagCommand: Self = Self(0x0010_0000);

    pub fn empty() -> Self {
        Self(0)
    }
}

impl std::ops::BitOr for CGEventFlags {
    type Output = Self;
    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// CGEventType values the injector posts.
pub mod event_type {
    pub const LEFT_MOUSE_DOWN: u32 = 1;
    pub const LEFT_MOUSE_UP: u32 = 2;
    pub const RIGHT_MOUSE_DOWN: u32 = 3;
    pub const RIGHT_MOUSE_UP: u32 = 4;
    pub const MOUSE_MOVED: u32 = 5;
    pub const LEFT_MOUSE_DRAGGED: u32 = 6;
    pub const RIGHT_MOUSE_DRAGGED: u32 = 7;
    pub const OTHER_MOUSE_DOWN: u32 = 25;
    pub const OTHER_MOUSE_UP: u32 = 26;
    pub const OTHER_MOUSE_DRAGGED: u32 = 27;
}

/// CGMouseButton, CGEventField, CGScrollEventUnit, CGEventTapLocation and
/// CGEventSourceStateID values the injector uses.
pub const MOUSE_BUTTON_LEFT: u32 = 0;
pub const MOUSE_BUTTON_RIGHT: u32 = 1;
pub const MOUSE_BUTTON_CENTER: u32 = 2;
pub const FIELD_MOUSE_EVENT_CLICK_STATE: u32 = 1;
pub const FIELD_MOUSE_EVENT_BUTTON_NUMBER: u32 = 3;
pub const SCROLL_UNIT_PIXEL: u32 = 0;
pub const SCROLL_UNIT_LINE: u32 = 1;
pub const TAP_HID: u32 = 0;
pub const SOURCE_STATE_HID_SYSTEM: i32 = 1;

/// kCMTimeFlags_Valid.
pub const CM_TIME_VALID: u32 = 1;
/// kCFNumberSInt64Type.
pub const CF_NUMBER_SINT64: c_long = 4;

framework! {
    pub mod cf = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" {
        fn CFRetain(value: CFTypeRef) -> CFTypeRef;
        fn CFRelease(value: CFTypeRef);
        fn CFArrayGetCount(array: CFArrayRef) -> c_long;
        fn CFArrayGetValueAtIndex(array: CFArrayRef, index: c_long) -> CFTypeRef;
        fn CFDictionaryGetValue(dictionary: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
        fn CFNumberGetValue(number: CFNumberRef, kind: c_long, out: *mut c_void) -> u8;
    }
}

framework! {
    pub mod cg = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
        static kCGColorSpaceSRGB: CFStringRef;
        fn CGMainDisplayID() -> u32;
        fn CGDisplayBounds(display: u32) -> CGRect;
        fn CGDisplayCopyDisplayMode(display: u32) -> CGDisplayModeRef;
        fn CGDisplayModeGetPixelWidth(mode: CGDisplayModeRef) -> usize;
        fn CGDisplayModeGetPixelHeight(mode: CGDisplayModeRef) -> usize;
        fn CGDisplayModeRelease(mode: CGDisplayModeRef);
        fn CGRectMakeWithDictionaryRepresentation(dictionary: CFDictionaryRef, rect: *mut CGRect) -> u8;
        fn CGEventSourceCreate(state: i32) -> CGEventSourceRef;
        fn CGEventCreateMouseEvent(source: CGEventSourceRef, kind: u32, point: CGPoint, button: u32) -> CGEventRef;
        fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, code: u16, down: bool) -> CGEventRef;
        fn CGEventCreateScrollWheelEvent2(source: CGEventSourceRef, units: u32, count: u32, wheel1: i32, wheel2: i32, wheel3: i32) -> CGEventRef;
        fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
        fn CGEventSetFlags(event: CGEventRef, flags: u64);
        fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: usize, units: *const u16);
        fn CGEventPost(tap: u32, event: CGEventRef);
    }
}

framework! {
    pub mod cm = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia" {
        fn CMSampleBufferGetImageBuffer(sample: CMSampleBufferRef) -> CVPixelBufferRef;
        fn CMSampleBufferGetSampleAttachmentsArray(sample: CMSampleBufferRef, create: u8) -> CFArrayRef;
    }
}

framework! {
    pub mod cv = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo" {
        fn CVPixelBufferGetIOSurface(buffer: CVPixelBufferRef) -> IOSurfaceRef;
    }
}

framework! {
    pub mod sck = "/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit" {
        static SCStreamFrameInfoStatus: CFStringRef;
        static SCStreamFrameInfoDirtyRects: CFStringRef;
    }
}

framework! {
    // NSObject, NSArray and NSString are registered once Foundation loaded.
    pub mod foundation = "/System/Library/Frameworks/Foundation.framework/Foundation" {
        ref NSFoundationVersionNumber: f64;
    }
}

framework! {
    pub mod objc = "/usr/lib/libobjc.A.dylib" {
        ref objc_msgSend: u8;
        fn objc_getClass(name: *const c_char) -> Class;
        fn objc_getProtocol(name: *const c_char) -> *mut c_void;
        fn sel_registerName(name: *const c_char) -> Sel;
        fn objc_allocateClassPair(superclass: Class, name: *const c_char, extra: usize) -> Class;
        fn objc_registerClassPair(class: Class);
        fn class_addMethod(class: Class, sel: Sel, imp: *const c_void, types: *const c_char) -> u8;
        fn class_addProtocol(class: Class, protocol: *mut c_void) -> u8;
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }
}

framework! {
    pub mod system = "/usr/lib/libSystem.B.dylib" {
        ref _NSConcreteGlobalBlock: u8;
        fn dispatch_queue_create(label: *const c_char, attributes: *const c_void) -> DispatchQueue;
        fn dispatch_release(object: *mut c_void);
    }
}

/// Every framework a host session binds, loaded once; the error names what is missing.
pub fn load() -> Result<(), String> {
    cf::available()?;
    cg::available()?;
    cm::available()?;
    cv::available()?;
    foundation::available()?;
    objc::available()?;
    system::available()?;
    sck::available().map_err(|e| format!("ScreenCaptureKit (macOS 12.3 or later): {e}"))
}

/// An Objective-C class by name (nil when not registered).
pub fn class(name: &CStr) -> Class {
    // SAFETY: a NUL-terminated name.
    unsafe { objc::objc_getClass(name.as_ptr()) }
}

pub fn sel(name: &CStr) -> Sel {
    // SAFETY: a NUL-terminated name.
    unsafe { objc::sel_registerName(name.as_ptr()) }
}

/// `objc_msgSend` as a function of type `F` (an `unsafe extern "C" fn(Id, Sel, ...) -> R`
/// matching the method's real signature, which the caller states). On arm64 and x86_64 alike
/// a method returning an object, an integer, a BOOL or nothing goes through objc_msgSend.
///
/// # Safety
/// `F` must be the method's C signature, receiver and selector first.
pub unsafe fn msg<F: Copy>() -> F {
    const { assert!(size_of::<F>() == size_of::<*const u8>()) };
    // `load()` ran first: libobjc is loaded, so the address is never NULL here.
    debug_assert!(!objc::objc_msgSend().is_null());
    // SAFETY: objc_msgSend's address, reinterpreted as the caller's stated signature.
    unsafe { std::mem::transmute_copy::<*const u8, F>(&objc::objc_msgSend()) }
}

/// `[receiver sel]` returning an object (or nil).
pub fn send_id(receiver: Id, name: &CStr) -> Id {
    // SAFETY: a no-argument method returning an object.
    unsafe { msg::<unsafe extern "C" fn(Id, Sel) -> Id>()(receiver, sel(name)) }
}

/// `[receiver release]`.
pub fn release(object: Id) {
    if !object.is_null() {
        // SAFETY: a no-argument method returning nothing, on an object this code owns.
        unsafe { msg::<unsafe extern "C" fn(Id, Sel)>()(object, sel(c"release")) }
    }
}

/// An NSString's text.
pub fn string(object: Id) -> String {
    if object.is_null() {
        return String::new();
    }
    // SAFETY: -UTF8String returns a NUL-terminated buffer the string owns (copied at once).
    let text = unsafe {
        msg::<unsafe extern "C" fn(Id, Sel) -> *const c_char>()(object, sel(c"UTF8String"))
    };
    if text.is_null() {
        return String::new();
    }
    // SAFETY: non-NULL, NUL-terminated.
    unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
}

/// An NSError's localized description.
pub fn error_text(error: Id) -> String {
    string(send_id(error, c"localizedDescription"))
}

/// Objects created between push and drop are released when the pool drops.
pub struct AutoreleasePool(*mut c_void);

impl AutoreleasePool {
    pub fn new() -> Self {
        // SAFETY: pushes a pool on this thread; popped on drop, on the same thread.
        Self(unsafe { objc::objc_autoreleasePoolPush() })
    }
}

impl Drop for AutoreleasePool {
    fn drop(&mut self) {
        // SAFETY: the pool this value pushed.
        unsafe { objc::objc_autoreleasePoolPop(self.0) }
    }
}

#[repr(C)]
struct BlockDescriptor {
    reserved: c_long,
    size: c_long,
    /// The block's type encoding (BLOCK_HAS_SIGNATURE), for runtimes that ask a block for it.
    signature: *const c_char,
}

/// A block literal (the Blocks ABI) whose invoke function reads `context`. It is marked global
/// (BLOCK_IS_GLOBAL), so the frameworks' Block_copy and Block_release never copy or free it;
/// each one is leaked (a few per session), since a framework may keep a pointer to it.
#[repr(C)]
pub struct Block<C> {
    isa: *const u8,
    flags: c_int,
    reserved: c_int,
    invoke: *const c_void,
    descriptor: *const BlockDescriptor,
    pub context: C,
}

const BLOCK_IS_GLOBAL: c_int = 1 << 28;
const BLOCK_HAS_SIGNATURE: c_int = 1 << 30;

/// A leaked block that calls `invoke` with itself first, then the block's arguments.
/// `signature` is its type encoding (`v@?@` for a handler taking one object).
pub fn block<C>(invoke: *const c_void, signature: &'static CStr, context: C) -> *mut Block<C> {
    let descriptor = Box::leak(Box::new(BlockDescriptor {
        reserved: 0,
        size: size_of::<Block<C>>() as c_long,
        signature: signature.as_ptr(),
    }));
    Box::leak(Box::new(Block {
        isa: system::_NSConcreteGlobalBlock(),
        flags: BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE,
        reserved: 0,
        invoke,
        descriptor,
        context,
    }))
}

/// A retained CoreFoundation object, released on drop.
pub struct Retained(CFTypeRef);

// SAFETY: CoreFoundation's retain and release are thread-safe, and the objects held here (pixel
// buffers) are only read after the capture queue handed them over.
unsafe impl Send for Retained {}

impl Retained {
    /// Retains `object` (non-NULL).
    pub fn retain(object: CFTypeRef) -> Self {
        // SAFETY: a live CoreFoundation object.
        Self(unsafe { cf::CFRetain(object) })
    }

    pub fn as_ptr(&self) -> CFTypeRef {
        self.0
    }
}

impl Clone for Retained {
    fn clone(&self) -> Self {
        Self::retain(self.0)
    }
}

impl Drop for Retained {
    fn drop(&mut self) {
        // SAFETY: the reference this value holds.
        unsafe { cf::CFRelease(self.0) }
    }
}
