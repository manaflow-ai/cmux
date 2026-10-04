//! The macOS half of [`super::verify`]: the caller's code signature, named by
//! the socket peer's audit token.

use std::ffi::{c_char, c_void};
use std::os::fd::RawFd;
use std::ptr;

type CFTypeRef = *const c_void;
type CFIndex = isize;
type OSStatus = i32;

#[repr(C)]
struct Opaque {
    _private: [u8; 0],
}

const UTF8: u32 = 0x0800_0100;
/// `kSecCSSigningInformation`.
const SIGNING_INFORMATION: u32 = 1 << 1;
/// `SOL_LOCAL` and `LOCAL_PEERTOKEN` from `<sys/un.h>`.
const SOL_LOCAL: libc::c_int = 0;
const LOCAL_PEERTOKEN: libc::c_int = 0x006;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: Opaque;
    static kCFTypeDictionaryValueCallBacks: Opaque;
    fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: CFIndex) -> CFTypeRef;
    fn CFDataGetLength(data: CFTypeRef) -> CFIndex;
    fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
    fn CFDataGetTypeID() -> usize;
    fn CFDictionaryCreate(
        allocator: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        key_callbacks: *const Opaque,
        value_callbacks: *const Opaque,
    ) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFStringCreateWithBytes(
        allocator: CFTypeRef,
        bytes: *const u8,
        length: CFIndex,
        encoding: u32,
        external: u8,
    ) -> CFTypeRef;
    fn CFStringGetCString(
        string: CFTypeRef,
        buffer: *mut c_char,
        size: CFIndex,
        encoding: u32,
    ) -> u8;
    fn CFStringGetTypeID() -> usize;
    fn CFGetTypeID(object: CFTypeRef) -> usize;
    fn CFRelease(object: CFTypeRef);
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: CFTypeRef,
        buffer: *const u8,
        length: CFIndex,
        is_directory: u8,
    ) -> CFTypeRef;
    fn CFBundleCreate(allocator: CFTypeRef, url: CFTypeRef) -> CFTypeRef;
    fn CFBundleGetIdentifier(bundle: CFTypeRef) -> CFTypeRef;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecGuestAttributeAudit: CFTypeRef;
    static kSecCodeInfoTeamIdentifier: CFTypeRef;
    static kSecCodeInfoUnique: CFTypeRef;
    fn SecCodeCopySelf(flags: u32, code: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopyGuestWithAttributes(
        host: CFTypeRef,
        attributes: CFTypeRef,
        flags: u32,
        guest: *mut CFTypeRef,
    ) -> OSStatus;
    fn SecCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> OSStatus;
    fn SecCodeCopyStaticCode(code: CFTypeRef, flags: u32, out: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopySigningInformation(
        code: CFTypeRef,
        flags: u32,
        information: *mut CFTypeRef,
    ) -> OSStatus;
    fn SecRequirementCreateWithString(
        text: CFTypeRef,
        flags: u32,
        requirement: *mut CFTypeRef,
    ) -> OSStatus;
}

/// An owned Core Foundation reference, released on drop.
struct Owned(CFTypeRef);

impl Owned {
    fn new(object: CFTypeRef, what: &str) -> Result<Self, String> {
        if object.is_null() { Err(format!("{what} failed")) } else { Ok(Self(object)) }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: `self.0` is a non-null object this wrapper owns once.
        unsafe { CFRelease(self.0) };
    }
}

fn status(result: OSStatus, what: &str) -> Result<(), String> {
    if result == 0 { Ok(()) } else { Err(format!("{what} returned {result}")) }
}

/// Signature facts about one piece of code.
struct Signing {
    team: Option<String>,
    unique: Option<Vec<u8>>,
}

pub(super) fn verify_signature(fd: RawFd) -> Result<(), String> {
    let guest = guest_code(&peer_audit_token(fd)?)?;
    let own = signing(&own_code()?)?;
    match own.team {
        Some(team) => {
            // A Team ID is ten upper-case letters or digits; anything else
            // never goes into the requirement text.
            if team.len() != 10
                || !team.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
            {
                return Err(format!("unexpected Team ID {team:?}"));
            }
            let requirement = requirement(&format!(
                "anchor apple generic and certificate leaf[subject.OU] = \"{team}\""
            ))?;
            // SAFETY: both references are live owned objects.
            status(unsafe { SecCodeCheckValidity(guest.0, 0, requirement.0) }, "team check")
        }
        None => {
            // SAFETY: `guest.0` is a live owned code object; no requirement.
            status(unsafe { SecCodeCheckValidity(guest.0, 0, ptr::null()) }, "validity")?;
            let own_unique = own.unique.ok_or("this process has no code identity")?;
            let guest_unique = signing(&guest)?.unique.ok_or("caller has no code identity")?;
            if guest_unique == own_unique {
                Ok(())
            } else {
                Err("caller is different code than this unsigned build".to_string())
            }
        }
    }
}

/// Prover A of `verified_app` (`crate::app_caller`): the peer named by
/// `token` (never by pid) is the signed app that contains this binary.
pub(crate) fn verify_app_token(token: &[u32; 8]) -> Result<(), crate::app_caller::NotTheApp> {
    use crate::app_caller::NotTheApp;
    let own =
        signing(&own_code().map_err(NotTheApp::Unavailable)?).map_err(NotTheApp::Unavailable)?;
    let team =
        own.team.ok_or_else(|| NotTheApp::Unavailable("this build has no Team ID".into()))?;
    if team.len() != 10
        || !team.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
    {
        return Err(NotTheApp::Unavailable(format!("unexpected Team ID {team:?}")));
    }
    let identifier = containing_app_identifier().map_err(NotTheApp::Unavailable)?;
    let requirement = requirement(&format!(
        "anchor apple generic and certificate leaf[subject.OU] = \"{team}\" and identifier \"{identifier}\""
    ))
    .map_err(NotTheApp::Unavailable)?;
    let guest = guest_code(token).map_err(NotTheApp::Signature)?;
    // SAFETY: both references are live owned objects.
    status(unsafe { SecCodeCheckValidity(guest.0, 0, requirement.0) }, "app check")
        .map_err(NotTheApp::Signature)
}

/// Resolves `token` to running code (tests: a pid-reused token must fail).
#[cfg(test)]
pub(crate) fn guest_for_test(token: &[u32; 8]) -> Result<(), String> {
    guest_code(token).map(|_| ())
}

/// `CFBundleIdentifier` of the app bundle that contains this executable.
fn containing_app_identifier() -> Result<String, String> {
    let executable = std::env::current_exe().map_err(|error| format!("current_exe: {error}"))?;
    let bundle = crate::app_caller::containing_bundle(&executable)
        .ok_or("this binary is not inside an app bundle")?;
    let path = bundle.as_os_str().as_encoded_bytes();
    // SAFETY: the bytes are live for the call; CFURL copies them.
    let url = Owned::new(
        unsafe {
            CFURLCreateFromFileSystemRepresentation(
                ptr::null(),
                path.as_ptr(),
                path.len() as CFIndex,
                1,
            )
        },
        "CFURLCreateFromFileSystemRepresentation",
    )?;
    // SAFETY: `url.0` is a live CFURL.
    let bundle = Owned::new(unsafe { CFBundleCreate(ptr::null(), url.0) }, "CFBundleCreate")?;
    // SAFETY: `bundle.0` is live; the identifier is borrowed (Get rule) and
    // copied before `bundle` drops.
    let identifier = unsafe { string(CFBundleGetIdentifier(bundle.0)) }
        .ok_or("the containing app has no CFBundleIdentifier")?;
    if !crate::app_caller::plain_bundle_identifier(&identifier) {
        return Err(format!("unexpected bundle identifier {identifier:?}"));
    }
    Ok(identifier)
}

pub(crate) fn peer_audit_token(fd: RawFd) -> Result<[u32; 8], String> {
    let mut token = [0u32; 8];
    let mut length = size_of_val(&token) as libc::socklen_t;
    // SAFETY: the out-buffer is valid for `length` bytes.
    let result = unsafe {
        libc::getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &raw mut length)
    };
    if result != 0 || length as usize != size_of_val(&token) {
        return Err(format!("LOCAL_PEERTOKEN: {}", std::io::Error::last_os_error()));
    }
    Ok(token)
}

fn guest_code(token: &[u32; 8]) -> Result<Owned, String> {
    // SAFETY: the token buffer is live for the call; CFDataCreate copies it.
    let data = Owned::new(
        unsafe { CFDataCreate(ptr::null(), token.as_ptr().cast(), size_of_val(token) as CFIndex) },
        "CFDataCreate",
    )?;
    // SAFETY: reading an immutable framework constant.
    let key = unsafe { kSecGuestAttributeAudit };
    let keys = [key];
    let values = [data.0];
    // SAFETY: one key and one value, both live; the standard callbacks retain them.
    let attributes = Owned::new(
        unsafe {
            CFDictionaryCreate(
                ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                &raw const kCFTypeDictionaryKeyCallBacks,
                &raw const kCFTypeDictionaryValueCallBacks,
            )
        },
        "CFDictionaryCreate",
    )?;
    let mut guest: CFTypeRef = ptr::null();
    // SAFETY: a null host means the system; the out-pointer is valid.
    status(
        unsafe { SecCodeCopyGuestWithAttributes(ptr::null(), attributes.0, 0, &raw mut guest) },
        "SecCodeCopyGuestWithAttributes",
    )?;
    Owned::new(guest, "SecCodeCopyGuestWithAttributes")
}

fn own_code() -> Result<Owned, String> {
    let mut code: CFTypeRef = ptr::null();
    // SAFETY: the out-pointer is valid.
    status(unsafe { SecCodeCopySelf(0, &raw mut code) }, "SecCodeCopySelf")?;
    Owned::new(code, "SecCodeCopySelf")
}

fn signing(code: &Owned) -> Result<Signing, String> {
    let mut static_code: CFTypeRef = ptr::null();
    // SAFETY: `code.0` is live; the out-pointer is valid.
    status(
        unsafe { SecCodeCopyStaticCode(code.0, 0, &raw mut static_code) },
        "SecCodeCopyStaticCode",
    )?;
    let static_code = Owned::new(static_code, "SecCodeCopyStaticCode")?;
    let mut information: CFTypeRef = ptr::null();
    // SAFETY: `static_code.0` is live; the out-pointer is valid.
    status(
        unsafe {
            SecCodeCopySigningInformation(static_code.0, SIGNING_INFORMATION, &raw mut information)
        },
        "SecCodeCopySigningInformation",
    )?;
    let information = Owned::new(information, "SecCodeCopySigningInformation")?;
    // SAFETY: the dictionary is live; the keys are framework constants; the
    // values are borrowed (Get rule) and read before `information` drops.
    unsafe {
        let team = CFDictionaryGetValue(information.0, kSecCodeInfoTeamIdentifier);
        let unique = CFDictionaryGetValue(information.0, kSecCodeInfoUnique);
        Ok(Signing { team: string(team), unique: data(unique) })
    }
}

/// # Safety
/// `object` is null or a live Core Foundation object.
unsafe fn string(object: CFTypeRef) -> Option<String> {
    // SAFETY: the caller passes null or a live object.
    if object.is_null() || unsafe { CFGetTypeID(object) != CFStringGetTypeID() } {
        return None;
    }
    let mut buffer = [0 as c_char; 256];
    // SAFETY: the buffer is valid for its length.
    let copied =
        unsafe { CFStringGetCString(object, buffer.as_mut_ptr(), buffer.len() as CFIndex, UTF8) };
    if copied == 0 {
        return None;
    }
    // SAFETY: CFStringGetCString wrote a NUL-terminated string.
    let text = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) };
    text.to_str().ok().map(str::to_string)
}

/// # Safety
/// `object` is null or a live Core Foundation object.
unsafe fn data(object: CFTypeRef) -> Option<Vec<u8>> {
    // SAFETY: the caller passes null or a live object.
    if object.is_null() || unsafe { CFGetTypeID(object) != CFDataGetTypeID() } {
        return None;
    }
    // SAFETY: a live CFData has `length` readable bytes at its byte pointer.
    unsafe {
        let length = usize::try_from(CFDataGetLength(object)).ok()?;
        Some(std::slice::from_raw_parts(CFDataGetBytePtr(object), length).to_vec())
    }
}

fn requirement(text: &str) -> Result<Owned, String> {
    // SAFETY: the bytes are live for the call; CFString copies them.
    let string = Owned::new(
        unsafe {
            CFStringCreateWithBytes(ptr::null(), text.as_ptr(), text.len() as CFIndex, UTF8, 0)
        },
        "CFStringCreateWithBytes",
    )?;
    let mut requirement: CFTypeRef = ptr::null();
    // SAFETY: `string.0` is live; the out-pointer is valid.
    status(
        unsafe { SecRequirementCreateWithString(string.0, 0, &raw mut requirement) },
        "SecRequirementCreateWithString",
    )?;
    Owned::new(requirement, "SecRequirementCreateWithString")
}
