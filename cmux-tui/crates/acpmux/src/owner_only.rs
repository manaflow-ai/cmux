//! Owner-only files and folders on Windows: what modes 0600 and 0700 and
//! the uid and mode checks do on Unix.
//!
//! - Written files and made folders get a protected DACL that grants only
//!   our token user (`D:P(A;;FA;;;<user>)`, folders `OICI` so new children
//!   inherit it), with our user as owner. Files are created that way
//!   (CreateFileW with the descriptor), never narrowed after the bytes are
//!   in them.
//! - A file another user can change is one whose owner, or a DACL entry
//!   that grants write, delete or ACL rights, is a SID other than our user,
//!   SYSTEM, BUILTIN\Administrators or OWNER RIGHTS (the last three can
//!   change any file anyway; Unix allows root the same way). A missing DACL
//!   grants everyone everything. Deny entries and inherit-only entries grant
//!   nothing to the file itself.

use std::fs::File;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::FromRawHandle;
use std::path::Path;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::{
    ERROR_SUCCESS, GENERIC_WRITE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT, SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GetAce, GetSecurityDescriptorDacl,
    GetSecurityDescriptorOwner, OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES,
};
use windows_sys::Win32::Storage::FileSystem::{
    CREATE_NEW, CreateDirectoryW, CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT,
    FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_ALWAYS,
};

/// SIDs whose rights do not make a file shared: SYSTEM, Administrators and
/// OWNER RIGHTS (it names the owner, checked on its own).
const ALWAYS_ALLOWED: [&str; 3] = ["S-1-5-18", "S-1-5-32-544", "S-1-3-4"];
/// ACE types that grant (allowed, allowed-object, allowed-callback and
/// allowed-callback-object); deny, audit and label entries grant nothing.
const ALLOW_TYPES: [u8; 4] = [0x0, 0x5, 0x9, 0xB];
/// `INHERIT_ONLY_ACE`: applies to children only.
const INHERIT_ONLY: u8 = 0x08;
/// Rights that change a file or its access: write and append data, write
/// extended attributes, delete, write DACL, write owner, generic write and
/// generic all.
const CHANGE_RIGHTS: u32 =
    0x2 | 0x4 | 0x10 | 0x1_0000 | 0x4_0000 | 0x8_0000 | 0x4000_0000 | 0x1000_0000;

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

/// Frees a `LocalAlloc` block on drop.
struct Local(*mut core::ffi::c_void);

impl Drop for Local {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: a block the system allocated for us.
            unsafe { LocalFree(self.0) };
        }
    }
}

fn user_sid() -> io::Result<String> {
    Ok(cmux::local_socket::win::current_identity()?.user_sid)
}

fn sid_string(sid: PSID) -> io::Result<String> {
    let mut text: *mut u16 = null_mut();
    // SAFETY: a valid SID; `text` is freed below.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _free = Local(text.cast());
    // SAFETY: a NUL-terminated string from the call.
    let len = (0..).take_while(|&i| unsafe { *text.add(i) } != 0).count();
    // SAFETY: `len` units were just read.
    Ok(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) }))
}

/// An owner-only security descriptor for a file (`inherit` false) or a
/// folder whose children inherit it.
fn descriptor(user: &str, inherit: bool) -> io::Result<Local> {
    let flags = if inherit { "OICI" } else { "" };
    let sddl: Vec<u16> =
        format!("O:{user}D:P(A;{flags};FA;;;{user})").encode_utf16().chain([0]).collect();
    let mut sd: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: a NUL-terminated SDDL string; `sd` is freed by `Local`.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(Local(sd))
}

fn attributes(sd: &Local) -> SECURITY_ATTRIBUTES {
    SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd.0,
        bInheritHandle: 0,
    }
}

/// Creates `path` (which must not exist) owner-only for writing, never
/// through a link (O_EXCL | O_NOFOLLOW, mode 0600 on Unix).
pub(crate) fn create_new(path: &Path) -> io::Result<File> {
    open_owner_only(path, CREATE_NEW, GENERIC_WRITE, FILE_SHARE_READ)
}

/// Opens `path` for appending, creating it owner-only when missing; an
/// existing file that is wider is narrowed (the daemon log; 0600 on Unix).
pub(crate) fn open_append(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::MetadataExt;
    // FILE_APPEND_DATA | SYNCHRONIZE, plus read attributes for metadata.
    // Shared like std's opens: a running daemon holds the log as its stdout
    // and stderr, and a second start must still open it (it then loses the
    // start lock and exits).
    let file = open_owner_only(
        path,
        OPEN_ALWAYS,
        0x4 | 0x10_0000 | 0x80,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    // The checks below go by path, so the path must be the file itself.
    if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is a link, not a log file", path.display()),
        ));
    }
    if !only_owner_reads(path)? {
        restrict(path)?;
    }
    Ok(file)
}

fn open_owner_only(path: &Path, disposition: u32, access: u32, share: u32) -> io::Result<File> {
    let sd = descriptor(&user_sid()?, false)?;
    let attrs = attributes(&sd);
    let name = wide(path);
    // SAFETY: a NUL-terminated name and valid attributes.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            access,
            share,
            &attrs,
            disposition,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a handle CreateFileW returned; `File` owns it.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// Makes `dir` and missing parents; `dir` itself, when made here, is
/// owner-only (mode 0700 on create on Unix). An existing folder is left as
/// it is.
pub(crate) fn create_dir_all(dir: &Path) -> io::Result<()> {
    if dir.is_dir() {
        return Ok(());
    }
    if let Some(parent) = dir.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let sd = descriptor(&user_sid()?, true)?;
    let attrs = attributes(&sd);
    let name = wide(dir);
    // SAFETY: a NUL-terminated name and valid attributes.
    if unsafe { CreateDirectoryW(name.as_ptr(), &attrs) } == 0 {
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::AlreadyExists {
            return Err(e);
        }
    }
    Ok(())
}

/// Makes `dir` owner-only, or checks an existing one: a wider folder is
/// refused (mode 0700 and the uid check on Unix).
pub(crate) fn private_dir(dir: &Path) -> io::Result<()> {
    create_dir_all(dir)?;
    if !only_owner_reads(dir)? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private directory", dir.display()),
        ));
    }
    Ok(())
}

/// Replaces `path`'s access list with the owner-only one (and its owner
/// with our user).
pub(crate) fn restrict(path: &Path) -> io::Result<()> {
    let user = user_sid()?;
    let sd = descriptor(&user, path.is_dir())?;
    let (mut owner, mut dacl): (PSID, *mut ACL) = (null_mut(), null_mut());
    let (mut defaulted, mut present) = (0, 0);
    // SAFETY: a valid descriptor; the out-pointers point into it.
    unsafe {
        GetSecurityDescriptorOwner(sd.0, &mut owner, &mut defaulted);
        GetSecurityDescriptorDacl(sd.0, &mut present, &mut dacl, &mut defaulted);
    }
    let mut name = wide(path);
    // SAFETY: a NUL-terminated name; SID and ACL from the descriptor.
    let status = unsafe {
        SetNamedSecurityInfoW(
            name.as_mut_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION
                | DACL_SECURITY_INFORMATION
                | PROTECTED_DACL_SECURITY_INFORMATION,
            owner,
            null_mut(),
            dacl,
            null_mut(),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}

/// The other SID that can change `path`: its owner, or one granted change
/// rights; None when only our user (and the always-allowed SIDs) can.
pub(crate) fn changer_other_than_us(path: &Path) -> io::Result<Option<String>> {
    wider(path, CHANGE_RIGHTS)
}

/// True when only our user (and the always-allowed SIDs) can read or
/// change `path`.
pub(crate) fn only_owner_reads(path: &Path) -> io::Result<bool> {
    // Every right counts: read data, read attributes and the change rights.
    Ok(wider(path, u32::MAX)?.is_none())
}

fn wider(path: &Path, rights: u32) -> io::Result<Option<String>> {
    let user = user_sid()?;
    let allowed = |sid: &str| {
        sid.eq_ignore_ascii_case(&user)
            || ALWAYS_ALLOWED.iter().any(|a| sid.eq_ignore_ascii_case(a))
    };
    let name = wide(path);
    let (mut owner, mut dacl): (PSID, *mut ACL) = (null_mut(), null_mut());
    let mut sd: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: out-pointers valid; `sd` is freed by `Local`.
    let status = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut sd,
        )
    };
    let _free = Local(sd);
    if status != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    let owner = sid_string(owner)?;
    if !allowed(&owner) {
        return Ok(Some(owner));
    }
    if dacl.is_null() {
        return Ok(Some("Everyone (no access list)".into()));
    }
    // SAFETY: a valid ACL from the descriptor.
    let count = unsafe { (*dacl).AceCount };
    for index in 0..u32::from(count) {
        let mut ace: *mut core::ffi::c_void = null_mut();
        // SAFETY: index below AceCount.
        if unsafe { GetAce(dacl, index, &mut ace) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: every ACE starts with an ACE_HEADER.
        let header = unsafe { &*(ace as *const ACE_HEADER) };
        if !ALLOW_TYPES.contains(&header.AceType) || header.AceFlags & INHERIT_ONLY != 0 {
            continue;
        }
        // Every allow type starts header, mask, then (for the plain and
        // callback types) the SID; the object types have flags and GUIDs
        // first, so their SID is found by the flags.
        // SAFETY: the mask follows the 4-byte header.
        let mask = unsafe { *(ace.cast::<u8>().add(4) as *const u32) };
        if mask & rights == 0 {
            continue;
        }
        let sid_offset = match header.AceType {
            0x5 | 0xB => {
                // SAFETY: the object ACE's flags follow the mask.
                let flags = unsafe { *(ace.cast::<u8>().add(8) as *const u32) };
                12 + if flags & 1 != 0 { 16 } else { 0 } + if flags & 2 != 0 { 16 } else { 0 }
            }
            _ => 8,
        };
        // SAFETY: the SID starts at that offset inside the ACE.
        let sid = sid_string(unsafe { ace.cast::<u8>().add(sid_offset) }.cast())?;
        if !allowed(&sid) {
            return Ok(Some(sid));
        }
    }
    Ok(None)
}
