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
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecGuestAttributeAudit: CFTypeRef;
    static kSecCodeInfoTeamIdentifier: CFTypeRef;
    static kSecCodeInfoUnique: CFTypeRef;
    static kSecCodeInfoIdentifier: CFTypeRef;
    fn SecStaticCodeCreateWithPath(path: CFTypeRef, flags: u32, code: *mut CFTypeRef) -> OSStatus;
    fn SecStaticCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> OSStatus;
    fn SecCodeCopySelf(flags: u32, code: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopyGuestWithAttributes(
        host: CFTypeRef,
        attributes: CFTypeRef,
        flags: u32,
        guest: *mut CFTypeRef,
    ) -> OSStatus;
    fn SecCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> OSStatus;
    fn SecCodeCopyStaticCode(code: CFTypeRef, flags: u32, out: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopyDesignatedRequirement(
        code: CFTypeRef,
        flags: u32,
        out: *mut CFTypeRef,
    ) -> OSStatus;
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
#[derive(Clone)]
struct Signing {
    team: Option<String>,
    unique: Option<Vec<u8>>,
}

pub(super) fn verify_signature(fd: RawFd) -> Result<(), String> {
    let guest = guest_code(&peer_audit_token(fd)?)?;
    let own = own_signing()?;
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
    let own = own_signing().map_err(NotTheApp::Unavailable)?;
    let team =
        own.team.ok_or_else(|| NotTheApp::Unavailable("this build has no Team ID".into()))?;
    if team.len() != 10
        || !team.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
    {
        return Err(NotTheApp::Unavailable(format!("unexpected Team ID {team:?}")));
    }
    let identifier = own_app_identifier(&team).map_err(NotTheApp::Unavailable)?;
    let requirement = requirement(&format!(
        "anchor apple generic and certificate leaf[subject.OU] = \"{team}\" and identifier \"{identifier}\""
    ))
    .map_err(NotTheApp::Unavailable)?;
    let guest = guest_code(token).map_err(NotTheApp::Signature)?;
    // SAFETY: both references are live owned objects.
    status(unsafe { SecCodeCheckValidity(guest.0, 0, requirement.0) }, "app check")
        .map_err(NotTheApp::Signature)
}

/// Whether this binary is Team-signed. Fails closed: when the signing
/// information cannot be read the binary counts as signed, so the
/// install-key proof is refused and only prover A could pass.
pub(crate) fn team_signed() -> bool {
    match own_signing() {
        Ok(own) => {
            // Read the containing app's identifier now too (the daemon asks at
            // start), while the bundle it was started from is still on disk.
            if let Some(team) = own.team.as_deref().filter(|team| plain_team(team)) {
                let _ = own_app_identifier(team);
            }
            own.team.is_some()
        }
        Err(_) => true,
    }
}

/// This process's own signature facts, read once. A running daemon outlives
/// its bundle: a Sparkle update replaces or deletes the app it was started
/// from, after which its static code (`SecCodeCopyStaticCode`) is gone
/// ("No such file or directory") and every later read failed, so no app
/// connection was ever verified again and the app's cloud lease was refused
/// (Home group chats "Not Delivered", 2026-10-28). The facts cannot change
/// while the process runs. An error is kept too (fail closed).
fn own_signing() -> Result<Signing, String> {
    static OWN: std::sync::OnceLock<Result<Signing, String>> = std::sync::OnceLock::new();
    OWN.get_or_init(|| own_code().and_then(|code| signing(&code))).clone()
}

/// The signed identifier of the app that contains this binary, read once per
/// process (`team_signed` reads it at start): a later swap of the bundle on
/// disk cannot move the identifier the daemon expects, nor make it unreadable.
fn own_app_identifier(team: &str) -> Result<String, String> {
    static IDENTIFIER: std::sync::OnceLock<Result<String, String>> = std::sync::OnceLock::new();
    IDENTIFIER.get_or_init(|| containing_app_identifier(team)).clone()
}

/// Resolves `token` to running code (tests: a pid-reused token must fail).
#[cfg(test)]
pub(crate) fn guest_for_test(token: &[u32; 8]) -> Result<(), String> {
    guest_code(token).map(|_| ())
}

/// `kSecCSBasicValidateOnly`: the signature and its code directory (which
/// binds the Info.plist and the identifier), without hashing every page and
/// resource of a large app bundle.
const BASIC_VALIDATE_ONLY: u32 = (1 << 1) | (1 << 2);

/// The signed identifier of the app bundle that contains this executable.
/// It comes from the bundle's code directory after the bundle's signature is
/// checked against this build's team, never from an unsigned Info.plist.
fn containing_app_identifier(team: &str) -> Result<String, String> {
    let executable = std::env::current_exe().map_err(|error| format!("current_exe: {error}"))?;
    let bundle = crate::app_caller::containing_bundle(&executable)
        .ok_or("this binary is not inside an app bundle")?;
    let code =
        static_code_signed_by(&bundle, team, BASIC_VALIDATE_ONLY, "containing app signature")?;
    static_identifier(&code)
}

fn static_identifier(code: &Owned) -> Result<String, String> {
    let mut information: CFTypeRef = ptr::null();
    // SAFETY: `code.0` is live; the out-pointer is valid.
    status(
        unsafe { SecCodeCopySigningInformation(code.0, 0, &raw mut information) },
        "SecCodeCopySigningInformation",
    )?;
    let information = Owned::new(information, "SecCodeCopySigningInformation")?;
    // SAFETY: the dictionary is live and the key is a framework constant; the
    // value is borrowed (Get rule) and copied before `information` drops.
    let identifier = unsafe { string(CFDictionaryGetValue(information.0, kSecCodeInfoIdentifier)) }
        .ok_or("the containing app has no signed identifier")?;
    if !crate::app_caller::plain_bundle_identifier(&identifier) {
        return Err(format!("unexpected bundle identifier {identifier:?}"));
    }
    Ok(identifier)
}

/// The static code at `path` after its signature is checked against `team`
/// (a Team ID already checked by [`plain_team`]).
fn static_code_signed_by(
    path: &std::path::Path,
    team: &str,
    flags: u32,
    what: &str,
) -> Result<Owned, String> {
    let code = static_code(path)?;
    let team_requirement = requirement(&format!(
        "anchor apple generic and certificate leaf[subject.OU] = \"{team}\""
    ))?;
    // SAFETY: both references are live owned objects.
    status(unsafe { SecStaticCodeCheckValidity(code.0, flags, team_requirement.0) }, what)?;
    Ok(code)
}

fn static_code(path: &std::path::Path) -> Result<Owned, String> {
    let bytes = path.as_os_str().as_encoded_bytes();
    // SAFETY: the bytes are live for the call; CFURL copies them.
    let url = Owned::new(
        unsafe {
            CFURLCreateFromFileSystemRepresentation(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len() as CFIndex,
                u8::from(path.is_dir()),
            )
        },
        "CFURLCreateFromFileSystemRepresentation",
    )?;
    let mut code: CFTypeRef = ptr::null();
    // SAFETY: `url.0` is a live CFURL; the out-pointer is valid.
    status(
        unsafe { SecStaticCodeCreateWithPath(url.0, 0, &raw mut code) },
        "SecStaticCodeCreateWithPath",
    )?;
    Owned::new(code, "SecStaticCodeCreateWithPath")
}

/// A Team ID is ten upper-case letters or digits; anything else never goes
/// into a requirement text.
fn plain_team(team: &str) -> bool {
    team.len() == 10 && team.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

/// Whether the executable at `path` is signed by this build's Team ID.
/// `Ok(false)` when this build has no Team ID (unsigned or ad hoc): there is
/// no team to compare. A mismatch, or a signature that does not validate, is
/// an error.
pub(crate) fn path_has_own_team(path: &std::path::Path) -> Result<bool, String> {
    let own = own_signing()?;
    let Some(team) = own.team else {
        return Ok(false);
    };
    if !plain_team(&team) {
        return Err(format!("unexpected Team ID {team:?}"));
    }
    static_code_signed_by(path, &team, 0, "team signature")?;
    Ok(true)
}

/// Full validation, including a nested executable, before a clone path can
/// stand for an installed app. The own Team ID is the existing trust anchor.
fn clone_signature(path: &std::path::Path) -> Option<crate::sign_clone::Identity> {
    let team = own_signing().ok()?.team.filter(|team| plain_team(team))?;
    let code = static_code_signed_by(path, &team, 0, "update clone signature").ok()?;
    Some(crate::sign_clone::Identity { team, identifier: static_identifier(&code).ok()? })
}

fn check_running_clone(code: &Owned, installed: &std::path::Path) -> Result<(), String> {
    let team = own_signing()?.team.filter(|team| plain_team(team)).ok_or("no signing team")?;
    let installed = static_code_signed_by(installed, &team, 0, "installed clone executable")?;
    check_running_requirement(code, &installed)
}

/// `installed` must already have passed the caller's static signature policy.
fn check_running_requirement(code: &Owned, installed: &Owned) -> Result<(), String> {
    let requirement = designated_requirement(installed)?;
    // SAFETY: both owned references are live. Dynamic code was obtained from
    // this process or the connection's audit token, never from a bare PID.
    status(unsafe { SecCodeCheckValidity(code.0, 0, requirement.0) }, "running clone signature")
}

fn designated_requirement(installed: &Owned) -> Result<Owned, String> {
    let mut requirement: CFTypeRef = ptr::null();
    // SAFETY: the static code is live and the out-pointer is valid.
    status(
        unsafe { SecCodeCopyDesignatedRequirement(installed.0, 0, &raw mut requirement) },
        "installed executable requirement",
    )?;
    Owned::new(requirement, "installed executable requirement")
}

pub(crate) fn verified_clone_executable(path: &std::path::Path) -> Option<std::path::PathBuf> {
    let installed = crate::sign_clone::resolve(path, clone_signature)?;
    if std::env::current_exe().ok().as_deref() == Some(path) {
        check_running_clone(&own_code().ok()?, &installed).ok()?;
    }
    Some(installed)
}

pub(crate) fn verified_clone_peer(token: &[u32; 8]) -> Option<std::path::PathBuf> {
    // UID is also checked by the socket's caller gate; preserve it here for
    // callers using this public verifier without that gate.
    // SAFETY: geteuid has no preconditions.
    if token[1] != unsafe { libc::geteuid() } {
        return None;
    }
    let path = executable_path(token)?;
    let installed = crate::sign_clone::resolve(&path, clone_signature)?;
    check_running_clone(&guest_code(token).ok()?, &installed).ok()?;
    Some(installed)
}

unsafe extern "C" {
    /// libproc: the path of the process `token` names, failing (`<= 0`) when
    /// its pid no longer carries the token's pid version.
    fn proc_pidpath_audittoken(token: *mut [u32; 8], buffer: *mut c_void, size: u32)
    -> libc::c_int;
}

/// `app_caller::executable_path`.
pub(crate) fn executable_path(token: &[u32; 8]) -> Option<std::path::PathBuf> {
    let mut token = *token;
    let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: both pointers are valid; the call writes at most `path.len()`
    // bytes and returns the count written (`<= 0` on failure).
    let written = unsafe {
        proc_pidpath_audittoken(&raw mut token, path.as_mut_ptr().cast(), path.len() as u32)
    };
    let written = usize::try_from(written).ok().filter(|written| *written > 0)?;
    let path = std::str::from_utf8(&path[..written]).ok()?;
    Some(std::path::PathBuf::from(path))
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

#[cfg(test)]
#[path = "caller_macos_sign_clone_tests.rs"]
mod sign_clone_tests;
