//! Untracked files a seed leaves out because they likely hold secrets.
//! Tracked files are never left out: the remote already has them. One rule
//! everywhere: the Mac's seed plan leaves these out of its WORK commit, the
//! machine's export (cmux-tui-core `git_seed::export`) leaves out the same, so
//! an `.env` the machine made never comes back to the Mac, and
//! `acpmux session move --carry-changes` leaves them out of what it carries.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt as _;
use std::path::Path;

/// Why the untracked file at `relative` (under `top`, git's raw bytes)
/// stays where it is, or None when it goes. The raw path is what is read: a
/// name that is not UTF-8 is never looked up by a lossy spelling.
pub fn reason(top: &Path, relative: &[u8]) -> Option<&'static str> {
    let raw_name = relative.rsplit(|byte| *byte == b'/').next().unwrap_or(relative);
    let name = String::from_utf8_lossy(raw_name);
    let name = name.as_ref();
    if name.starts_with(".env") {
        return Some(".env file: it may hold secrets, so it is shared only on purpose");
    }
    let lower = name.to_ascii_lowercase();
    if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].iter().any(|key| lower.starts_with(key))
        && !lower.ends_with(".pub")
    {
        return Some("SSH private key");
    }
    if [".pem", ".p12", ".pfx", ".key"].iter().any(|ext| lower.ends_with(ext)) {
        return Some("key or certificate file");
    }
    if name == ".netrc" {
        return Some("credentials file (.netrc)");
    }
    let token_markers: &[&str] = match name {
        ".npmrc" => &["_authToken", "_auth", "_password"],
        ".pypirc" => &["password"],
        _ => &[],
    };
    if !token_markers.is_empty() {
        // A registry file that can't be read counts as holding a token.
        let Ok(text) = std::fs::read(top.join(OsStr::from_bytes(relative))) else {
            return Some("package registry credentials file that could not be read");
        };
        let text = String::from_utf8_lossy(&text);
        if token_markers.iter().any(|marker| text.contains(marker)) {
            return Some("package registry credentials file with a token");
        }
    }
    None
}

#[cfg(test)]
mod tests;
