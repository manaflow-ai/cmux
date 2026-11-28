//! The runtime scope of an app's daemon: which socket directory its owner uses.
//!
//! cmux-tui derives an owner's socket from the session name and the runtime
//! base (`<base>/cmux-tui-<uid>/<session>.sock`), and the app fixes the base
//! to the user's Darwin temp directory. Both are the same for every app of
//! one user, so a second app that runs on another HOME (a fresh-HOME launch
//! check, an isolated profile) and so another state root, asked for the
//! same session, found the first app's owner and was refused
//! (`server.different_state`).
//!
//! An app whose HOME is not the account's own HOME gets a scope, one short
//! hex word of its HOME, that the owner's runtime directory carries
//! (`cmux-tui-<uid>-<scope>`, `CMUX_TUI_RUNTIME_SCOPE`). An app on the
//! account's HOME, the usual single-app case, has none, so its socket keeps
//! the path it always had and nothing migrates.

use crate::Env;

/// The variable that hands the scope to the owner and to cmux-tui clients.
pub const SCOPE_ENV: &str = "CMUX_TUI_RUNTIME_SCOPE";

/// The scope of an app whose HOME is `home` on an account whose own HOME is
/// `account_home`: none when they are the same directory or either is
/// unknown, else 8 hex digits of FNV-1a over `home` without a trailing `/`.
pub fn scope(home: Option<&str>, account_home: Option<&str>) -> Option<String> {
    let home = trimmed(home?)?;
    let account = trimmed(account_home?)?;
    if home == account || same_directory(home, account) {
        return None;
    }
    let mut hash: u32 = 0x811c_9dc5;
    for byte in home.as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    Some(format!("{hash:08x}"))
}

/// The scope for the HOME of `env` on this account.
pub fn scope_of(env: &Env) -> Option<String> {
    scope(env.get("HOME").map(String::as_str), account_home().as_deref())
}

/// The account's own HOME (the password database's, not `$HOME`).
#[cfg(unix)]
pub fn account_home() -> Option<String> {
    use std::ffi::CStr;
    let mut buffer = vec![0u8; 4096];
    loop {
        // SAFETY: the passwd record and buffer are valid for the call; the
        // record's strings point into the buffer, which outlives the read.
        let mut record: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        let code = unsafe {
            libc::getpwuid_r(
                libc::geteuid(),
                &mut record,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if code == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if code != 0 || found.is_null() || record.pw_dir.is_null() {
            return None;
        }
        let dir = unsafe { CStr::from_ptr(record.pw_dir) }.to_str().ok()?;
        return Some(dir.to_owned());
    }
}

#[cfg(not(unix))]
pub fn account_home() -> Option<String> {
    None
}

fn trimmed(path: &str) -> Option<&str> {
    let path = path.trim();
    if path.is_empty() {
        return None;
    }
    Some(if path.len() > 1 { path.trim_end_matches('/') } else { path })
}

/// Two spellings of one directory (a symlinked `/var`, say).
fn same_directory(a: &str, b: &str) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(test)]
#[path = "runtime_scope_tests.rs"]
mod tests;
