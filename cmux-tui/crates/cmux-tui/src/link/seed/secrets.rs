//! Untracked files the seed leaves out because they likely hold secrets.
//! Tracked files are never left out: the remote already has them.

use std::path::Path;

/// Why the untracked file at `relative` (under `top`) stays on this Mac,
/// or None when it goes.
pub(super) fn reason(top: &Path, relative: &str) -> Option<&'static str> {
    let name = relative.rsplit('/').next().unwrap_or(relative);
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
        let text = std::fs::read(top.join(relative)).unwrap_or_default();
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
            assert!(reason(top, path).is_some(), "{path}");
        }
        for path in
            ["README.md", "id_rsa.pub", "src/env.rs", ".envrc-notes/x", "keyboard.rs", ".npmrc"]
        {
            assert_eq!(reason(top, path), None, "{path}");
        }
    }

    #[test]
    fn registry_files_with_tokens_are_secrets() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".npmrc"), "//registry.npmjs.org/:_authToken=abc\n")
            .unwrap();
        std::fs::write(dir.path().join(".pypirc"), "[pypi]\nusername = x\n").unwrap();
        assert!(reason(dir.path(), ".npmrc").is_some());
        assert_eq!(reason(dir.path(), ".pypirc"), None);
    }
}
