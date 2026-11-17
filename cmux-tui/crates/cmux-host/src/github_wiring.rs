//! git and `gh` with the cmux GitHub App on a Cloud machine whose image predates that wiring
//! (web/scripts/cmux-vm-image/github-auth.ts, bake.ts): `cmux host run` (root, the store
//! layout) makes the image's managed files again at each start, so a machine updated in place
//! gets them without a new image.
//!
//! - `/etc/cmux/gitconfig`, the system credential helper for https://github.com, and its
//!   `include.path` in `/etc/gitconfig` (appended once; nothing else there is touched).
//! - `/opt/cmux/github/bin/gh`, the `gh` shim, and the login profile's PATH entry for it
//!   (`/etc/profile.d/00-cmux-store.sh`).
//!
//! A managed file is written when it is missing or is an older managed copy (its first lines
//! are the image's managed header); a file someone wrote themselves is left as it is. Nothing
//! is written unless the store's `cmux` and `gh` are there, since both files run them: an
//! image without the store layout keeps what it has. The texts are the bake's, byte for byte
//! (web/tests/vm-image-cmux-vm-github-auth.test.ts reads them from here).

use std::io;
use std::path::Path;

use crate::config::Paths;

pub const GH_SHIM: &str = "/opt/cmux/github/bin/gh";
const SHIM_ROOT: &str = "/opt/cmux/github";
const SHIM_DIR: &str = "/opt/cmux/github/bin";
pub const GITHUB_GITCONFIG: &str = "/etc/cmux/gitconfig";
pub const SYSTEM_GITCONFIG: &str = "/etc/gitconfig";
pub const STORE_PROFILE: &str = "/etc/profile.d/00-cmux-store.sh";
/// What both managed files run.
const STORE_CMUX: &str = "/opt/cmux/current/bin/cmux";
const STORE_GH: &str = "/opt/cmux/current/bin/gh";

/// github-auth.ts `ghShimScript()`.
pub const GH_SHIM_TEXT: &str = r#"#!/bin/sh
# cmux (images/cmux-vm, managed, do not edit): gh with a short-lived GitHub App token for one
# repo from this machine's Cloud agent, unless you have your own GH_TOKEN or gh login.
if [ -S '/run/cmux-vm-agent/agent.sock' ] && [ -x '/opt/cmux/current/bin/cmux' ]; then
  CMUX_GITHUB_GH_REAL='/opt/cmux/current/bin/gh' exec '/opt/cmux/current/bin/cmux' github gh --auto -- "$@"
fi
exec '/opt/cmux/current/bin/gh' "$@"
"#;

/// github-auth.ts `githubGitconfig()`.
pub const GITCONFIG_TEXT: &str = r#"# cmux (images/cmux-vm, managed, do not edit): git gets a short-lived GitHub App token per repo
# from this machine's Cloud agent. Your own --global helper for github.com replaces this one.
[credential "https://github.com"]
	helper = !/opt/cmux/current/bin/cmux github credential
	useHttpPath = true
"#;

/// bake.ts `storeProfileScript()`.
pub const STORE_PROFILE_TEXT: &str = r#"# cmux store: user-space programs (images/cmux-vm). Managed, do not edit.
case ":$PATH:" in *:/opt/cmux/current/bin:*) ;; *) PATH=/opt/cmux/current/bin:$PATH ;; esac
case ":$PATH:" in *:/opt/cmux/github/bin:*) ;; *) PATH=/opt/cmux/github/bin:$PATH ;; esac
export PATH
"#;

/// The managed header of each file: an existing file without it is someone's own.
const SHIM_HEADER: &str = "#!/bin/sh\n# cmux (images/cmux-vm, managed, do not edit)";
const GITCONFIG_HEADER: &str = "# cmux (images/cmux-vm, managed, do not edit)";
const PROFILE_HEADER: &str =
    "# cmux store: user-space programs (images/cmux-vm). Managed, do not edit.";

/// One file to write: its absolute path, whole text and mode.
#[derive(Debug, PartialEq, Eq)]
pub struct Write {
    pub path: &'static str,
    pub text: String,
    pub mode: u32,
}

/// Whether a gitconfig text includes `/etc/cmux/gitconfig` (any spacing, any section line).
fn includes_ours(text: &str) -> bool {
    text.lines().any(|line| {
        let compact: String = line.chars().filter(|c| !c.is_whitespace()).collect();
        compact == format!("path={GITHUB_GITCONFIG}")
    })
}

/// The writes that bring a machine to the image's wiring (sans I/O): `read` answers a file's
/// text, `exists` whether a path is there.
pub fn plan(read: impl Fn(&str) -> Option<String>, exists: impl Fn(&str) -> bool) -> Vec<Write> {
    if !(exists(STORE_CMUX) && exists(STORE_GH)) {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (path, text, header, mode) in [
        (GH_SHIM, GH_SHIM_TEXT, SHIM_HEADER, 0o755),
        (GITHUB_GITCONFIG, GITCONFIG_TEXT, GITCONFIG_HEADER, 0o644),
        (STORE_PROFILE, STORE_PROFILE_TEXT, PROFILE_HEADER, 0o644),
    ] {
        let stale = match read(path) {
            None => !exists(path),
            Some(now) => now != text && now.starts_with(header),
        };
        if stale {
            out.push(Write { path, text: text.to_owned(), mode });
        }
    }
    let system = read(SYSTEM_GITCONFIG);
    if system.is_some() || !exists(SYSTEM_GITCONFIG) {
        let now = system.unwrap_or_default();
        if !includes_ours(&now) {
            let sep = if now.is_empty() || now.ends_with('\n') { "" } else { "\n" };
            let text = format!("{now}{sep}[include]\n\tpath = {GITHUB_GITCONFIG}\n");
            out.push(Write { path: SYSTEM_GITCONFIG, text, mode: 0o644 });
        }
    }
    out
}

/// Writes `w` under `paths`: its directories (0755; the shim's own two root-owned first, as
/// the bake leaves them, so no other user can swap what root writes there), then the text
/// through a new file beside it, renamed into place, so a reader sees the old text or the new.
fn write(paths: &Paths, w: &Write) -> io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
    let target = paths.at(w.path);
    let dir = target.parent().unwrap_or(Path::new("/"));
    std::fs::DirBuilder::new().recursive(true).mode(0o755).create(dir)?;
    if w.path == GH_SHIM {
        for own in [SHIM_ROOT, SHIM_DIR] {
            let own = paths.at(own);
            if std::fs::symlink_metadata(&own)?.file_type().is_symlink() {
                return Err(io::Error::other(format!("{} is a symlink", own.display())));
            }
            if paths.is_system_root() {
                std::os::unix::fs::chown(&own, Some(0), Some(0))?;
            }
            std::fs::set_permissions(&own, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
        }
    }
    let name = target.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let part = dir.join(format!(".{name}.cmux-part"));
    // A leftover (or planted) part goes first; the new one is made here, never followed.
    match std::fs::remove_file(&part) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(w.mode).open(&part)?;
    file.write_all(w.text.as_bytes())?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&part, &target)
}

/// [`plan`] on the files under `paths`, then each write; one stderr line per file written or
/// failed. Never fatal: git and gh keep whatever the machine had.
pub fn ensure(paths: &Paths) {
    let read = |p: &str| std::fs::read_to_string(paths.at(p)).ok();
    let exists = |p: &str| paths.at(p).exists();
    for w in plan(read, exists) {
        match write(paths, &w) {
            Ok(()) => {
                eprintln!("cmux host: wrote {} (git and gh with the cmux GitHub App)", w.path)
            }
            Err(e) => eprintln!("cmux host: could not write {}: {e}", w.path),
        }
    }
}

#[cfg(test)]
#[path = "github_wiring_tests.rs"]
mod tests;
