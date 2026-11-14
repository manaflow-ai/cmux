//! One spelling for each file a tool call names, so a client can tell that
//! two spellings are the same file: `./notes.txt` and its absolute path, a
//! folder link and the real folder, `Notes.txt` and `notes.txt` on a volume
//! that ignores case. For a file that exists in a git repository it is
//! `$(git rev-parse --show-toplevel)/<path>`, the path a turn checkpoint names
//! the file by, up to Unicode normalization: this path is NFC, and git may
//! print a folder stored decomposed as it is stored, so a client normalizes
//! the checkpoint side to NFC before comparing. The hub records it beside
//! each tool call path (`hub/tool_paths.rs`); clients compare only these.

use std::path::{Path, PathBuf};

/// The canonical form of `path`, a tool call's path as the agent wrote it, in
/// a session working in `cwd`: absolute (a leading `~` is the home folder),
/// with `.`, `..`, doubled slashes and symlinks resolved the way the OS opens
/// it (`hand::policy::resolve`), and on macOS each existing component spelled
/// as the volume stores it, NFC (`realpath` already returns the stored letter
/// case; reading each stored name keeps that true when the realpath fallback
/// runs). A component that is not there yet keeps the spelling given, so a
/// call before the file exists and one after it names it the same way: the
/// file is stored as it was spelled. None for an empty or non-UTF-8 path, a
/// relative one with no `cwd`, or one a dangling link breaks. None on
/// Windows, where the resolved form `\\?\C:\...` never matches git's `C:/...`.
pub fn canonical_path(path: &str, cwd: Option<&Path>) -> Option<String> {
    if cfg!(windows) {
        return None;
    }
    let path = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            dirs::home_dir()?.join(rest.trim_start_matches('/'))
        }
        _ => PathBuf::from(path),
    };
    if path.as_os_str().is_empty() || (path.is_relative() && cwd.is_none()) {
        return None;
    }
    let joined = cwd.map_or_else(|| path.clone(), |cwd| cwd.join(&path));
    // Most paths name a file that is there: one realpath for all of it.
    let resolved = match std::fs::canonicalize(&joined) {
        Ok(real) => real,
        Err(_) => crate::hand::policy::resolve(joined.to_str()?, None).ok()?,
    };
    if !resolved.is_absolute() {
        return None;
    }
    #[cfg(target_os = "macos")]
    let resolved = stored_spelling(&resolved);
    let text = resolved.into_os_string().into_string().ok()?;
    // As git shows names on macOS (core.precomposeunicode).
    #[cfg(target_os = "macos")]
    let text: String = unicode_normalization::UnicodeNormalization::nfc(text.as_str()).collect();
    Some(text)
}

/// `path` (resolved: no links, `.` or `..`) with each component that exists
/// as the volume stores its name, and the rest as given.
#[cfg(target_os = "macos")]
fn stored_spelling(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    let mut there = true;
    for part in path.components() {
        match part {
            Component::Normal(name) if there => match stored_name(&out.join(name)) {
                Some(stored) => out.push(stored),
                None => {
                    there = false;
                    out.push(name);
                }
            },
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// The name the volume stores for the last component of `path`
/// (`getattrlist` `ATTR_CMN_NAME`, not following a final link), or None when
/// it is not there.
#[cfg(target_os = "macos")]
fn stored_name(path: &Path) -> Option<std::ffi::OsString> {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: attrlist is plain old data; all-zero is a valid empty request.
    let mut request: libc::attrlist = unsafe { std::mem::zeroed() };
    request.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    request.commonattr = libc::ATTR_CMN_NAME;
    // The reply's u32 length, an attrreference_t, then the name (NAME_MAX
    // UTF-8 characters and its NUL).
    let mut reply = [0u8; 4 + 8 + 255 * 3 + 1];
    // SAFETY: c_path is NUL-terminated, request and reply live through the
    // call, and the reply's size is passed with it.
    let status = unsafe {
        libc::getattrlist(
            c_path.as_ptr(),
            (&mut request as *mut libc::attrlist).cast(),
            reply.as_mut_ptr().cast(),
            reply.len(),
            libc::FSOPT_NOFOLLOW,
        )
    };
    if status != 0 {
        return None;
    }
    // attrreference_t: the name's offset from the reference itself, and its
    // length with the NUL.
    let offset = i32::from_ne_bytes(reply[4..8].try_into().ok()?);
    let length = u32::from_ne_bytes(reply[8..12].try_into().ok()?) as usize;
    let start = usize::try_from(4 + i64::from(offset)).ok()?;
    let name = reply.get(start..start.checked_add(length)?.checked_sub(1)?)?;
    (!name.is_empty()).then(|| std::ffi::OsString::from_vec(name.to_vec()))
}

// canonical_path is None on Windows.
#[cfg(all(test, unix))]
mod tests;
