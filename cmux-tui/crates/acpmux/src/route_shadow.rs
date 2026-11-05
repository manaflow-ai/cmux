//! A shadow account home: a second Codex login that keeps its own `auth.json`
//! and shares everything else with the CLI's own `CODEX_HOME` (Leo,
//! 2026-11-05, pointing at T3 Code's "Shadow home path: Account-specific Codex
//! home. Keeps auth.json separate while sharing state from CODEX_HOME").
//!
//! The shadow folder holds `auth.json` and a link to every other entry of the
//! base folder (`config.toml`, `sessions/`, `AGENTS.md`, ...). Codex signs in
//! there with `CODEX_HOME=<shadow> codex login`, and its conversations land in
//! the shared `sessions/`, so a chat may move between the base login and its
//! shadows and resume the same conversation: the routing that moves a chat off
//! an account that hit its limit relies on that ([`shares_conversations`]).
//! Links are made when the route is written and refreshed at every spawn, for
//! entries the base gained since; an entry the shadow already has is kept.
use std::path::{Path, PathBuf};

/// The entries a shadow keeps of its own: its login.
const OWN: &[&str] = &["auth.json"];

/// The folder conversations live in: shared, so a chat can move.
const CONVERSATIONS: &str = "sessions";

/// The Codex CLI's own home: `$CODEX_HOME` when absolute, else `~/.codex`.
pub fn codex_base() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| dirs::home_dir().map(|h| h.join(".codex")))
}

/// Links every entry of `base` but the login into `home`, creating both
/// folders (and the shared conversation folder) when missing. The shadow is
/// owner-only like every account home, a folder that was there before too: it
/// holds a login. Entries `home` already has stay as they are.
#[cfg(unix)]
pub fn link(home: &Path, base: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let mut dirs = std::fs::DirBuilder::new();
    dirs.recursive(true).mode(0o700);
    dirs.create(base.join(CONVERSATIONS))?;
    dirs.create(home)?;
    std::fs::set_permissions(home, std::fs::Permissions::from_mode(0o700))?;
    for entry in std::fs::read_dir(base)? {
        let name = entry?.file_name();
        if OWN.iter().any(|own| name == *own) {
            continue;
        }
        let at = home.join(&name);
        if at.symlink_metadata().is_ok() {
            continue;
        }
        std::os::unix::fs::symlink(base.join(&name), &at)?;
    }
    Ok(())
}

/// Without symlinks a shadow would share nothing: it is refused, never made empty.
#[cfg(not(unix))]
pub fn link(_home: &Path, _base: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "a shadow account home needs symlinks (macOS or Linux)",
    ))
}

/// Whether a conversation started in `a` resumes in `b`: both resolve their
/// conversation folder to the same place (the base and its shadows).
pub fn shares_conversations(a: &Path, b: &Path) -> bool {
    match (a.join(CONVERSATIONS).canonicalize(), b.join(CONVERSATIONS).canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shadow_keeps_its_login_and_shares_the_rest() {
        let root = std::env::temp_dir().join(format!("acpmux-shadow-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (base, shadow, other) = (root.join("base"), root.join("shadow"), root.join("other"));
        std::fs::create_dir_all(&base).unwrap();
        // A folder already there, open to others, is closed when it becomes a shadow.
        std::fs::create_dir_all(&shadow).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&shadow, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(base.join("auth.json"), "base login").unwrap();
        std::fs::write(base.join("config.toml"), "model = 'x'").unwrap();
        link(&shadow, &base).unwrap();
        assert!(!shadow.join("auth.json").exists(), "the login stays the base's");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&shadow).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0, "a shadow home is owner-only");
        }
        assert_eq!(std::fs::read_to_string(shadow.join("config.toml")).unwrap(), "model = 'x'");
        assert!(shares_conversations(&base, &shadow));
        // An entry the base gains later is linked at the next refresh; the shadow's own stay.
        std::fs::write(shadow.join("auth.json"), "shadow login").unwrap();
        std::fs::write(base.join("AGENTS.md"), "shared").unwrap();
        link(&shadow, &base).unwrap();
        assert_eq!(std::fs::read_to_string(shadow.join("AGENTS.md")).unwrap(), "shared");
        assert_eq!(std::fs::read_to_string(shadow.join("auth.json")).unwrap(), "shadow login");
        // A separate account home keeps its own conversations.
        std::fs::create_dir_all(other.join("sessions")).unwrap();
        assert!(!shares_conversations(&base, &other));
        let _ = std::fs::remove_dir_all(&root);
    }
}
