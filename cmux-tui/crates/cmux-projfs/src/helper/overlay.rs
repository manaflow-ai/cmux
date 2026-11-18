//! The host's side of mounting: what the machine offers (FUSE, `sudo -n`), the overlay mount in
//! the machine's root mount namespace, and unmounting both layers.
//!
//! Every command runs with an argument vector, never a shell, with stdin closed so `sudo -n`
//! can never wait for a password.

use std::path::Path;
use std::process::{Command, Stdio};

use super::Failure;
use super::state::{LOWER_FSTYPE, Paths, mount_at};

/// Whether this host can mount FUSE as this user, and why not.
pub(super) fn check_fuse() -> Result<(), Failure> {
    if !Path::new("/dev/fuse").exists() {
        return Err(Failure::new("no_fuse", "this machine has no /dev/fuse"));
    }
    if on_path("fusermount3").is_none() {
        return Err(Failure::new("no_fuse", "this machine has no fusermount3"));
    }
    Ok(())
}

/// Whether `sudo -n` works for this user.
pub(super) fn check_sudo() -> Result<(), Failure> {
    match run("sudo", &["-n", "true"]) {
        Ok(()) => Ok(()),
        Err(why) => Err(Failure::new("no_sudo", format!("sudo -n is not allowed here: {why}"))),
    }
}

fn on_path(name: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file())
}

/// Runs `program args…` to the end; the error names its exit and its stderr.
fn run(program: &str, args: &[&str]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("cannot run {program}: {e}"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(format!("{program} exited with {}: {}", output.status, stderr.trim()))
}

/// The overlay's `-o` value for `paths`.
pub(super) fn overlay_options(paths: &Paths) -> String {
    format!(
        "lowerdir={},upperdir={},workdir={},redirect_dir=on,metacopy=on",
        paths.lower.display(),
        paths.upper.display(),
        paths.work.display()
    )
}

/// Mounts the overlay over `paths.lower` at `at`, as root, in the machine's own namespace.
pub(super) fn mount_overlay(paths: &Paths, at: &Path) -> Result<(), Failure> {
    let at = at.to_str().ok_or_else(|| Failure::new("bad_path", "--at is not UTF-8"))?;
    let options = overlay_options(paths);
    run("sudo", &["-n", "mount", "-t", "overlay", "overlay", "-o", &options, at])
        .map_err(|why| Failure::new("overlay_refused", why))
}

/// Whether the mount at `at` is this state's overlay.
pub(super) fn is_our_overlay(paths: &Paths, at: &Path) -> Option<bool> {
    let m = mount_at(at)?;
    let lowerdir = format!("lowerdir={}", paths.lower.display());
    Some(m.fstype == "overlay" && m.super_options.split(',').any(|o| o == lowerdir))
}

/// What unmounting one layer did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Undone {
    /// Nothing was mounted there.
    NotMounted,
    /// Unmounted.
    Unmounted,
    /// Files were open on it, so it was detached: gone from the namespace, freed when they close.
    Detached,
    /// Something else is mounted there; left alone.
    NotOurs,
}

impl Undone {
    pub(super) fn word(self) -> &'static str {
        match self {
            Undone::NotMounted => "not_mounted",
            Undone::Unmounted => "unmounted",
            Undone::Detached => "detached",
            Undone::NotOurs => "not_ours",
        }
    }
}

/// Unmounts this state's overlay at `at`; detaches it when it is busy.
pub(super) fn unmount_overlay(paths: &Paths, at: &Path) -> Result<Undone, Failure> {
    match is_our_overlay(paths, at) {
        None => return Ok(Undone::NotMounted),
        Some(false) => return Ok(Undone::NotOurs),
        Some(true) => {}
    }
    let at_text = at.to_str().ok_or_else(|| Failure::new("bad_path", "--at is not UTF-8"))?;
    if run("sudo", &["-n", "umount", at_text]).is_ok() {
        return Ok(Undone::Unmounted);
    }
    run("sudo", &["-n", "umount", "-l", at_text])
        .map(|()| Undone::Detached)
        .map_err(|why| Failure::new("unmount_failed", why))
}

/// Unmounts (lazily) the lower FUSE layer at `paths.lower`, when one is mounted there.
pub(super) fn unmount_lower(paths: &Paths) -> Result<Undone, Failure> {
    match mount_at(&paths.lower) {
        None => return Ok(Undone::NotMounted),
        Some(m) if m.fstype != LOWER_FSTYPE => return Ok(Undone::NotOurs),
        Some(_) => {}
    }
    let lower = paths.lower.to_str().ok_or_else(|| Failure::new("bad_path", "not UTF-8"))?;
    run("fusermount3", &["-u", "-z", "--", lower])
        .map(|()| Undone::Unmounted)
        .map_err(|why| Failure::new("unmount_failed", why))
}
