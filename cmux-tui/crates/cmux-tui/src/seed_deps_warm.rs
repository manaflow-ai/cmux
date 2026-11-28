//! Restoring a seeded folder's dependencies from the cache (moved from `main.rs`).

use std::path::{Path, PathBuf};

/// After a seed checks out a folder on this machine: restore its dependencies
/// from the cache in the background, never running its install
/// (`acpmux machine deps warm --if-joined --no-install`, which does nothing on
/// a machine that is not joined). `CMUX_DEPS_WARM=0` turns it off. Seeds and `acp` are
/// unix-only.
#[cfg(unix)]
pub(crate) fn warm_seeded_deps(folder: &Path) {
    if std::env::var_os("CMUX_DEPS_WARM").is_some_and(|v| v == "0") {
        return;
    }
    let Ok(exe) = std::env::current_exe() else { return };
    // After a self-update replaced the binary, Linux names the running one "<path> (deleted)".
    let exe = exe
        .to_str()
        .and_then(|path| path.strip_suffix(" (deleted)"))
        .map_or(exe.clone(), PathBuf::from);
    // The warm's stderr can hold private output: an owner-only log in this
    // build's acpmux state folder, never a shared temp folder, never through a link.
    let out = {
        use std::os::unix::fs::OpenOptionsExt;
        let dir = acpmux::config::home();
        std::fs::create_dir_all(&dir).ok().and_then(|()| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(dir.join("deps-warm.log"))
                .ok()
        })
    };
    let err = out.as_ref().and_then(|f| f.try_clone().ok());
    // A binary named `acpmux` (a symlink or a copy) runs acpmux directly; the
    // `cmux` binary takes it under `acp`.
    let standalone = exe.file_name().is_some_and(|name| name == "acpmux");
    let mut command = cmux_process::Command::new(&exe);
    if !standalone {
        command.arg("acp");
    }
    command
        // Restore only: a seed never runs a project's install, whose lifecycle
        // scripts would execute repository code without the owner's consent.
        .args(["machine", "deps", "warm", "--if-joined", "--if-missing", "--no-install", "--json"])
        .arg(folder)
        .current_dir(folder)
        .stdin(cmux_process::Stdio::null())
        .stdout(out.map_or_else(cmux_process::Stdio::null, Into::into))
        .stderr(err.map_or_else(cmux_process::Stdio::null, Into::into));
    // Reaped by a thread so it never lingers as a zombie of the daemon.
    if let Ok(mut child) = command.spawn() {
        let _ = std::thread::Builder::new().name("cmux-deps-warm".into()).spawn(move || {
            let _ = child.wait();
        });
    }
}
