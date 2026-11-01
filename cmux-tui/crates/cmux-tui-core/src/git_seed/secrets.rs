//! Untracked files a seed leaves out because they likely hold secrets.
//! Tracked files are never left out: the remote already has them. One rule
//! on both sides: the Mac's seed plan leaves these out of its WORK commit,
//! and the machine's export ([`super::export`]) leaves out the same, so an
//! `.env` the machine made never comes back to the Mac.

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
mod tests {
    use super::*;

    #[test]
    fn secrets_are_named() {
        let top = Path::new("/nonexistent");
        for path in [
            ".env",
            ".env.local",
            ".envrc",
            "app/.env.production",
            "id_rsa",
            "keys/id_ed25519",
            "id_ecdsa_work",
            "cert.pem",
            "deploy/server.KEY",
            "bundle.p12",
            ".netrc",
        ] {
            assert!(reason(top, path.as_bytes()).is_some(), "{path}");
        }
        for path in ["README.md", "id_rsa.pub", "src/env.rs", ".envrc-notes/x", "keyboard.rs"] {
            assert_eq!(reason(top, path.as_bytes()), None, "{path}");
        }
    }

    #[test]
    fn registry_files_with_tokens_are_secrets() {
        let dir = std::env::temp_dir().join(format!("cmux-seed-secrets-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".npmrc"), "//registry.npmjs.org/:_authToken=abc\n").unwrap();
        std::fs::write(dir.join(".pypirc"), "[pypi]\nusername = x\n").unwrap();
        assert!(reason(&dir, b".npmrc").is_some());
        assert_eq!(reason(&dir, b".pypirc"), None);
        std::fs::create_dir_all(dir.join(OsStr::from_bytes(b"bad-\xff"))).unwrap();
        std::fs::write(
            dir.join(OsStr::from_bytes(b"bad-\xff/.npmrc")),
            "//registry.npmjs.org/:_authToken=abc\n",
        )
        .unwrap();
        assert!(reason(&dir, b"bad-\xff/.npmrc").is_some(), "read by its raw path");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
