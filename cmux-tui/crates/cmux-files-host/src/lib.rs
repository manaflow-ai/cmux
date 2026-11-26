//! cmux Files (dev): one stable macOS privacy identity for the terminals and agents of every
//! DEV build of cmux NEXT (docs/cmux-files-host.md).
//!
//! macOS keys a Files and Folders answer (Desktop, Documents, Downloads, ...) to the
//! *responsible process* of the code that touched the folder. A shell in a DEV build's terminal
//! answers to that build's app (`com.cmuxterm.app.debug.<tag>`), so every tag asked again. This
//! helper is a pinned, team-signed bundle every DEV build embeds unchanged. It runs from a
//! verified copy outside the app ([`cmux_signed_bundle`]), is spawned with responsibility
//! disclaimed, and starts the daemon as its own child, so the daemon, its shells and its agents
//! answer to `com.cmuxterm.files.dev` in every DEV build.
//!
//! One executable, two roles:
//! - `run -- PROGRAM ARGS...` (the launcher, from the app's embedded copy): stages the bundle,
//!   spawns the staged copy as `host` with responsibility disclaimed and waits for it. When it
//!   cannot, it `exec`s PROGRAM in place, as cmux ran it before.
//! - `host -- PROGRAM ARGS...` (the staged copy): runs PROGRAM as its child and waits for it.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// The helper's bundle id (never a main app's, never another helper's).
pub const BUNDLE_ID: &str = "com.cmuxterm.files.dev";
/// The bundle's directory name, where an app embeds it (`Contents/Library/<name>`).
pub const BUNDLE_NAME: &str = "cmux Files (dev).app";
/// The bundle's executable (`Contents/MacOS/<name>`).
pub const EXECUTABLE: &str = "cmux-files-host";
/// cmux's Apple team, whose certificate signs the pinned bundle.
pub const TEAM: &str = "7WLXT3NR37";
/// The executable of the embedded copy, relative to the app that embeds it.
pub const EMBEDDED_EXECUTABLE: &str =
    "Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host";
/// The signals the launcher and the host pass on to their child.
pub const FORWARDED_SIGNALS: [i32; 6] =
    [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGQUIT, libc::SIGUSR1, libc::SIGUSR2];
/// The exit status of a host that refuses its program.
pub const REFUSED_STATUS: i32 = 126;

/// What one start of the executable was asked to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Invocation {
    /// `run -- PROGRAM ARGS...`: the launcher.
    Run(Vec<OsString>),
    /// `host -- PROGRAM ARGS...`: the staged host.
    Host(Vec<OsString>),
    /// Launch Services opened the bundle (no arguments, or only `-psn_*`): nothing to do.
    LaunchServicesOpen,
    /// Anything else.
    Usage,
}

/// Reads the arguments after the executable's own name.
pub fn parse(args: &[OsString]) -> Invocation {
    if args.iter().all(|arg| arg.to_string_lossy().starts_with("-psn_")) {
        return Invocation::LaunchServicesOpen;
    }
    let Some((role, rest)) = args.split_first() else {
        return Invocation::LaunchServicesOpen;
    };
    let Some(program) = rest
        .split_first()
        .filter(|(separator, program)| separator.as_os_str() == "--" && !program.is_empty())
        .map(|(_, program)| program.to_vec())
    else {
        return Invocation::Usage;
    };
    match role.to_str() {
        Some("run") => Invocation::Run(program),
        Some("host") => Invocation::Host(program),
        _ => Invocation::Usage,
    }
}

/// The outermost `.app` directory among `path` and its ancestors: the app a nested helper, or a
/// binary in `Contents/Resources/bin`, belongs to.
pub fn outermost_app(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .filter(|ancestor| ancestor.extension().is_some_and(|extension| extension == "app"))
        .last()
        .map(Path::to_path_buf)
}

/// The bundle whose main executable `executable` is (`X.app/Contents/MacOS/<executable>`).
pub fn own_bundle(executable: &Path) -> Option<PathBuf> {
    let macos = executable.parent().filter(|dir| dir.ends_with("Contents/MacOS"))?;
    let app = macos.parent()?.parent()?;
    app.extension().is_some_and(|extension| extension == "app").then(|| app.to_path_buf())
}

/// Whether `bundle` sits inside another app. macOS checks code that runs from inside an app
/// bundle as that outer app, so such a copy is never the host.
pub fn nested_in_app(bundle: &Path) -> bool {
    bundle.parent().is_some_and(|parent| outermost_app(parent).is_some())
}

/// The copy of an app's embedded helper bundle that the launcher stages.
pub fn staging_root(home: &Path) -> PathBuf {
    home.join("Library/Application Support/cmux/files-host/app")
}

/// The code requirement every staged copy satisfies: the helper's bundle id, signed by an
/// Apple-issued certificate of cmux's team. An ad-hoc copy never satisfies it, so a person is
/// never asked to grant one.
pub fn requirement() -> String {
    cmux_signed_bundle::team_requirement(BUNDLE_ID, TEAM)
}

/// The program as the host runs it: its canonical path (no `..`, no symlink), when it belongs
/// to an app that embeds a helper whose executable has the bytes of `own` (this process's
/// executable), that is a DEV build of the same pin. Anything else is refused.
///
/// This stops `cmux-files-host host -- /bin/cat ...`. It is not a boundary against code that
/// already runs as this user (docs/cmux-files-host.md, "Security").
pub fn allowed_program(program: &OsStr, own: &Path) -> Option<PathBuf> {
    let program = Path::new(program);
    if !program.is_absolute() {
        return None;
    }
    let canonical = std::fs::canonicalize(program).ok()?;
    let app = outermost_app(&canonical)?;
    same_bytes(&app.join(EMBEDDED_EXECUTABLE), own).then_some(canonical)
}

fn same_bytes(left: &Path, right: &Path) -> bool {
    matches!((std::fs::read(left), std::fs::read(right)), (Ok(a), Ok(b)) if a == b)
}

/// A verified copy of `bundle` under `root` (one per content digest, checked by `check`), and
/// the path of its executable.
pub fn stage(
    bundle: &Path,
    root: &Path,
    check: impl Fn(&Path) -> Result<(), String>,
) -> Result<PathBuf, String> {
    let parts = cmux_signed_bundle::digest_parts(EXECUTABLE);
    let staged = cmux_signed_bundle::stage(bundle, root, &parts, check)?;
    Ok(staged.executable(EXECUTABLE))
}

/// Replaces this process with `program` (its path, then its arguments), keeping every descriptor
/// without close-on-exec, as `exec` does. Returns only the error when it cannot.
pub fn exec_in_place(program: &[OsString]) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    let Some((first, rest)) = program.split_first() else {
        return std::io::Error::new(std::io::ErrorKind::InvalidInput, "no program");
    };
    std::process::Command::new(first).args(rest).exec()
}

/// The descriptors above 2 that this process holds without close-on-exec: what its parent gave
/// it to pass on (a readiness pipe, an install key, a person key).
pub fn inherited_descriptors() -> Vec<i32> {
    let Ok(entries) = std::fs::read_dir("/dev/fd") else {
        return Vec::new();
    };
    let listed: Vec<i32> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
        .filter(|fd| *fd > 2)
        .collect();
    // The listing's own descriptor is closed by now; F_GETFD fails on it.
    listed
        .into_iter()
        .filter(|fd| {
            // SAFETY: F_GETFD only reads the descriptor's flags.
            let flags = unsafe { libc::fcntl(*fd, libc::F_GETFD) };
            flags >= 0 && flags & libc::FD_CLOEXEC == 0
        })
        .collect()
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
