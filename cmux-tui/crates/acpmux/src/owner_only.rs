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
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::Path;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::{
    ERROR_SUCCESS, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
    SDDL_REVISION_1, SE_FILE_OBJECT, SetSecurityInfo,
};
use windows_sys::Win32::Security::{
    ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GetAce, GetSecurityDescriptorDacl,
    OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    SECURITY_ATTRIBUTES,
};
use windows_sys::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, CREATE_NEW, CreateDirectoryW, CreateFileW,
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, GetFileInformationByHandle, OPEN_ALWAYS, OPEN_EXISTING,
};

/// SIDs whose rights do not make a file shared: SYSTEM, Administrators and
/// OWNER RIGHTS (it names the owner, checked on its own).
const ALWAYS_ALLOWED: [&str; 4] = [
    "S-1-5-18",
    "S-1-5-32-544",
    "S-1-3-4",
    // Windows Modules Installer (TrustedInstaller), the owner of protected
    // filesystem roots on standard Windows installations.
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
];
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
/// `FILE_DELETE_CHILD` matters on directories in addition to the file
/// mutation rights above.
const DIRECTORY_CHANGE_RIGHTS: u32 = CHANGE_RIGHTS | 0x40;
/// Rights that let another identity replace an existing namespace component.
/// Adding a sibling is harmless once every missing component is opened and
/// authenticated after creation. `FILE_WRITE_DATA` (`FILE_ADD_FILE` for a
/// directory) is included because `FSCTL_SET_REPARSE_POINT` requires it.
const ANCESTOR_REPLACE_RIGHTS: u32 =
    0x2 | 0x40 | 0x1_0000 | 0x4_0000 | 0x8_0000 | 0x4000_0000 | 0x1000_0000;
const READ_CONTROL_ACCESS: u32 = 0x0002_0000;
const WRITE_DAC_ACCESS: u32 = 0x0004_0000;
const WRITE_SECURITY_ACCESS: u32 = READ_CONTROL_ACCESS | WRITE_DAC_ACCESS;

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
        0x4 | 0x10_0000 | 0x80 | WRITE_SECURITY_ACCESS,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is a link, not a log file", path.display()),
        ));
    }
    ensure_opened_owner(&file)?;
    ensure_no_other_changer(&file, false)?;
    if !only_owner_reads_opened(&file)? {
        restrict_opened(&file, false)?;
    }
    ensure_owner_only(&file)?;
    Ok(file)
}

/// Open an existing state file for reading without following a reparse point,
/// narrowing a wider DACL before its contents are consumed.
pub(crate) fn open_read(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::MetadataExt;

    let file = open_owner_only(
        path,
        OPEN_EXISTING,
        GENERIC_READ | 0x80 | WRITE_SECURITY_ACCESS,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is a link, not a state file", path.display()),
        ));
    }
    ensure_opened_owner(&file)?;
    ensure_no_other_changer(&file, false)?;
    if !only_owner_reads_opened(&file)? {
        restrict_opened(&file, false)?;
    }
    ensure_owner_only(&file)?;
    Ok(file)
}

/// Open or create a state file for read/write without following a reparse
/// point, narrowing a wider DACL before it can be used as daemon.lock.
pub(crate) fn open_rw(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::MetadataExt;

    let file = open_owner_only(
        path,
        OPEN_ALWAYS,
        GENERIC_READ | GENERIC_WRITE | 0x80 | WRITE_SECURITY_ACCESS,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is a link, not a state file", path.display()),
        ));
    }
    ensure_opened_owner(&file)?;
    ensure_no_other_changer(&file, false)?;
    if !only_owner_reads_opened(&file)? {
        restrict_opened(&file, false)?;
    }
    ensure_owner_only(&file)?;
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

/// Open a directory itself, never the target of a junction or other reparse point.
fn open_directory(path: &Path) -> io::Result<File> {
    let name = wide(path);
    // SAFETY: a NUL-terminated name; no security attributes are needed for an
    // existing directory, and the returned handle is owned below.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ | WRITE_SECURITY_ACCESS,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
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
    crate::config::refuse_lost_home(dir).map_err(io::Error::other)?;
    create_missing_directories(&missing_directories(dir))
}

fn missing_directories(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut missing = Vec::new();
    let mut current = dir;
    while !current.is_dir() {
        missing.push(current.to_path_buf());
        let Some(parent) =
            current.parent().filter(|parent| !parent.as_os_str().is_empty() && *parent != current)
        else {
            break;
        };
        current = parent;
    }
    missing
}

fn create_missing_directories(missing: &[std::path::PathBuf]) -> io::Result<()> {
    let sd = descriptor(&user_sid()?, true)?;
    let attrs = attributes(&sd);
    for dir in missing.iter().rev() {
        let name = wide(dir);
        // SAFETY: a NUL-terminated name and valid attributes.
        if unsafe { CreateDirectoryW(name.as_ptr(), &attrs) } == 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        // A concurrent creator may have won after the existence check. Never
        // accept its wide directory or reparse point as a trusted parent.
        let opened = open_directory(dir)?;
        ensure_opened_private_directory(dir, &opened)?;
    }
    Ok(())
}

/// Makes `dir` owner-only, or checks an existing one: a wider folder is
/// refused (mode 0700 and the uid check on Unix).
pub(crate) fn private_dir(dir: &Path) -> io::Result<()> {
    // Capture every absent component before validating the existing chain.
    // A component planted during validation still gets CreateDirectoryW's
    // AlreadyExists path and the full object check below.
    let missing = missing_directories(dir);
    ensure_safe_parent(dir)?;
    create_missing_directories(&missing)?;
    let opened = open_directory(dir)?;
    finish_private_dir(dir, &opened)
}

fn finish_private_dir(dir: &Path, opened: &File) -> io::Result<()> {
    ensure_opened_private_directory(dir, opened)?;
    // Normalize even an owner-only but read-only legacy DACL: state
    // directories must let this user create, replace and delete children.
    restrict_opened(opened, true)?;
    if !only_owner_reads_opened(opened)? {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "directory is not owner-only"));
    }
    let reopened = open_directory(dir)?;
    if !same_opened_object(opened, &reopened)? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "state directory path changed while its permissions were checked",
        ));
    }
    Ok(())
}

fn ensure_opened_private_directory(dir: &Path, opened: &File) -> io::Result<()> {
    use std::os::windows::fs::MetadataExt;

    let attributes = opened.metadata()?.file_attributes();
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 || attributes & FILE_ATTRIBUTE_DIRECTORY == 0
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a private directory", dir.display()),
        ));
    }
    ensure_opened_owner(opened)?;
    ensure_no_other_changer(opened, true)
}

fn ensure_safe_parent(path: &Path) -> io::Result<()> {
    let mut saw_existing = false;
    for candidate in path.ancestors().skip(1) {
        match open_for_security(candidate, false) {
            Ok(opened) => {
                saw_existing = true;
                ensure_opened_owner(&opened)?;
                ensure_no_other_replacer(&opened)?;
            }
            Err(error) if !saw_existing && error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn same_opened_object(left: &File, right: &File) -> io::Result<bool> {
    let identity = |file: &File| -> io::Result<(u32, u64)> {
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let index = (u64::from(info.nFileIndexHigh) << 32) | u64::from(info.nFileIndexLow);
        Ok((info.dwVolumeSerialNumber, index))
    };
    Ok(identity(left)? == identity(right)?)
}

/// `daemon.rs` `narrow_to_owner`: an existing file or folder that is not
/// owner-only already gets the owner-only access list; a failure is logged.
pub(crate) fn narrow(path: &Path) {
    let result = (|| {
        let opened = open_for_security(path, true)?;
        ensure_opened_owner(&opened)?;
        if !only_owner_reads_opened(&opened)? {
            let is_dir = opened_is_dir(&opened)?;
            restrict_opened(&opened, is_dir)?;
            ensure_owner_only(&opened)?;
        }
        Ok::<_, io::Error>(())
    })();
    if let Err(e) = result
        && e.kind() != io::ErrorKind::NotFound
    {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}

/// Replaces `path`'s access list with the owner-only one (and its owner
/// with our user).
pub(crate) fn restrict(path: &Path) -> io::Result<()> {
    let opened = open_for_security(path, true)?;
    ensure_opened_owner(&opened)?;
    let is_dir = opened_is_dir(&opened)?;
    restrict_opened(&opened, is_dir)?;
    ensure_owner_only(&opened)
}

fn restrict_opened(opened: &File, is_dir: bool) -> io::Result<()> {
    let user = user_sid()?;
    let sd = descriptor(&user, is_dir)?;
    let mut dacl: *mut ACL = null_mut();
    let (mut defaulted, mut present) = (0, 0);
    // SAFETY: a valid descriptor; the DACL out-pointer points into it.
    unsafe {
        GetSecurityDescriptorDacl(sd.0, &mut present, &mut dacl, &mut defaulted);
    }
    // SAFETY: a live file/directory handle and ACL from the descriptor. The
    // opened object must already be ours; never take ownership of another's.
    let status = unsafe {
        SetSecurityInfo(
            opened.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            null_mut(),
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
    let opened = open_for_security(path, false)?;
    wider_opened(&opened, CHANGE_RIGHTS)
}

/// True when only our user (and the always-allowed SIDs) can read or
/// change `path`.
pub(crate) fn only_owner_reads(path: &Path) -> io::Result<bool> {
    let opened = open_for_security(path, false)?;
    only_owner_reads_opened(&opened)
}

fn only_owner_reads_opened(opened: &File) -> io::Result<bool> {
    // Every right counts: read data, read attributes and the change rights.
    Ok(wider_opened(opened, u32::MAX)?.is_none())
}

fn ensure_opened_owner(opened: &File) -> io::Result<()> {
    if wider_opened(opened, 0)?.is_some() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "state object is not owned by this user",
        ));
    }
    Ok(())
}

fn ensure_no_other_changer(opened: &File, directory: bool) -> io::Result<()> {
    let rights = if directory { DIRECTORY_CHANGE_RIGHTS } else { CHANGE_RIGHTS };
    if let Some(sid) = wider_opened(opened, rights)? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("state object is writable by another identity ({sid})"),
        ));
    }
    Ok(())
}

fn ensure_no_other_replacer(opened: &File) -> io::Result<()> {
    if let Some(sid) = wider_opened(opened, ANCESTOR_REPLACE_RIGHTS)? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("state path can be replaced by another identity ({sid})"),
        ));
    }
    Ok(())
}

fn ensure_owner_only(opened: &File) -> io::Result<()> {
    if !only_owner_reads_opened(opened)? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "state object is not owner-only",
        ));
    }
    Ok(())
}

fn wider_opened(opened: &File, rights: u32) -> io::Result<Option<String>> {
    let user = user_sid()?;
    let allowed = |sid: &str| {
        sid.eq_ignore_ascii_case(&user)
            || ALWAYS_ALLOWED.iter().any(|a| sid.eq_ignore_ascii_case(a))
    };
    let (mut owner, mut dacl): (PSID, *mut ACL) = (null_mut(), null_mut());
    let mut sd: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: out-pointers valid; `sd` is freed by `Local`.
    let status = unsafe {
        GetSecurityInfo(
            opened.as_raw_handle(),
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

fn open_for_security(path: &Path, write: bool) -> io::Result<File> {
    use std::os::windows::fs::MetadataExt;

    let mut access = READ_CONTROL_ACCESS | 0x80;
    if write {
        access |= WRITE_DAC_ACCESS;
    }
    let name = wide(path);
    // SAFETY: a NUL-terminated path; the handle is owned by File below.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            access,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: CreateFileW returned one owned handle.
    let opened = unsafe { File::from_raw_handle(handle) };
    if opened.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is a link, not a state object", path.display()),
        ));
    }
    Ok(opened)
}

fn opened_is_dir(opened: &File) -> io::Result<bool> {
    use std::os::windows::fs::MetadataExt;
    Ok(opened.metadata()?.file_attributes() & FILE_ATTRIBUTE_DIRECTORY != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grant_everyone(path: &Path) {
        let output = std::process::Command::new("icacls")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)F"])
            .output()
            .unwrap();
        assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn grant_everyone_read(path: &Path) {
        let output = std::process::Command::new("icacls")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(OI)(CI)R"])
            .output()
            .unwrap();
        assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn grant_everyone_add_subdirectory(path: &Path) {
        let output = std::process::Command::new("icacls")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(AD)"])
            .output()
            .unwrap();
        assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn grant_everyone_add_file(path: &Path) {
        let output = std::process::Command::new("icacls")
            .arg(path)
            .args(["/grant", "*S-1-1-0:(WD)"])
            .output()
            .unwrap();
        assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
    }

    #[test]
    fn private_dir_refuses_an_existing_directory_another_sid_can_change() {
        let root = std::env::temp_dir().join(format!(
            "acpmux-owner-writable-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let checked = root.join("checked");
        std::fs::create_dir_all(&checked).unwrap();
        grant_everyone(&checked);
        private_dir(&checked).expect_err("a directory writable by Everyone was trusted");
        assert!(!only_owner_reads(&checked).unwrap(), "the unsafe DACL was silently erased");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn private_dir_allows_an_ancestor_that_can_only_add_a_sibling() {
        let root = std::env::temp_dir().join(format!(
            "acpmux-owner-add-only-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let checked = root.join("checked");
        private_dir(&root).unwrap();
        private_dir(&checked).unwrap();
        grant_everyone_add_subdirectory(&root);

        private_dir(&checked).expect("add-subdirectory alone could replace an existing child");
        assert!(only_owner_reads(&checked).unwrap());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn private_dir_refuses_an_ancestor_that_can_be_made_a_reparse_point() {
        let root = std::env::temp_dir().join(format!(
            "acpmux-owner-add-file-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        private_dir(&root).unwrap();
        grant_everyone_add_file(&root);

        private_dir(&root.join("checked"))
            .expect_err("FILE_WRITE_DATA can turn the ancestor into a reparse point");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn private_dir_normalizes_the_opened_directory_not_a_replacement_path() {
        let root = std::env::temp_dir().join(format!(
            "acpmux-owner-handle-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let checked = root.join("checked");
        let moved = root.join("moved");
        std::fs::create_dir_all(&checked).unwrap();
        grant_everyone_read(&checked);

        ensure_safe_parent(&checked).unwrap();
        let opened = open_directory(&checked).unwrap();
        std::fs::rename(&checked, &moved).unwrap();
        std::fs::create_dir(&checked).unwrap();
        grant_everyone(&checked);
        finish_private_dir(&checked, &opened).expect_err("a replacement pathname was accepted");

        assert!(only_owner_reads(&moved).unwrap(), "the checked object stayed wide");
        assert!(!only_owner_reads(&checked).unwrap(), "the replacement path was changed");
        let _ = std::fs::remove_dir_all(&root);
    }
}
