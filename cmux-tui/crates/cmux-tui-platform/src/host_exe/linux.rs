//! Linux: terminal hosts run from the slim `cmux-tui-host` beside the
//! daemon when it is this daemon's build, else from `/proc/self/exe` (see
//! `host_exe.rs`).
//!
//! Why: a host re-exec'd from the daemon's own executable maps the whole
//! multi-call binary, and the loader's relocations dirty its relocated data
//! (vtables, the GOT, `.data.rel.ro`) in every host: about 4.3 MB of private
//! memory per idle terminal at 1,000 terminals in the infinite-items run
//! (CMUX-571), most of what a terminal costs. The slim binary links only the
//! terminal-host runtime, so it has far less to relocate.
//!
//! Which build runs: `/proc/self/exe` always named the running daemon's own
//! file, even after an upgrade replaced it on disk. The sibling keeps that
//! promise this way: when the daemon first needs it, it records the file's
//! identity (device, inode, size, times, mode, owner, link count), runs it
//! once with `--version`, and uses it only when it answers `cmux-tui-host
//! <identity>` with the daemon's own build identity. Before every spawn the
//! file's identity must still equal the recorded one; an upgrade that
//! replaced it (a new inode) or rewrote it (new times) sends this daemon back
//! to `/proc/self/exe` for good. A missing sibling, another answer or a
//! failed spawn does the same.

use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Once, OnceLock};

/// The slim host binary beside the daemon.
const SIBLING_NAME: &str = "cmux-tui-host";

/// The identity of the sibling file that answered with this build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileKey {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    mode: u32,
    uid: u32,
    nlink: u64,
}

impl FileKey {
    fn of(path: &Path) -> io::Result<Self> {
        let meta = fs::symlink_metadata(path)?;
        if !meta.file_type().is_file() {
            return Err(io::Error::other("not a regular file"));
        }
        Ok(Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.size(),
            mtime: (meta.mtime(), meta.mtime_nsec()),
            ctime: (meta.ctime(), meta.ctime_nsec()),
            mode: meta.mode(),
            uid: meta.uid(),
            nlink: meta.nlink(),
        })
    }
}

#[derive(Debug)]
struct Sibling {
    path: PathBuf,
    key: FileKey,
}

/// The build identity the sibling must report (`use_sibling_host`).
static SIBLING_IDENTITY: OnceLock<&'static str> = OnceLock::new();
/// The sibling, checked once; `None`: there is none, or it is another build.
static SIBLING: OnceLock<Option<Sibling>> = OnceLock::new();
/// The sibling changed on disk or failed to spawn: `/proc/self/exe` from now on.
static SIBLING_REFUSED: AtomicBool = AtomicBool::new(false);

pub(super) fn use_sibling_host(identity: &'static str) {
    let _ = SIBLING_IDENTITY.set(identity);
}

pub(super) fn terminal_host_executable() -> io::Result<PathBuf> {
    let own = crate::platform::self_exe_for_spawn()?;
    if SIBLING_REFUSED.load(Ordering::Acquire) {
        return Ok(own);
    }
    let Some(sibling) = SIBLING.get_or_init(find_sibling) else { return Ok(own) };
    if FileKey::of(&sibling.path).ok() != Some(sibling.key) {
        refuse(&sibling.path, "it changed on disk since it answered with this build");
        return Ok(own);
    }
    Ok(sibling.path.clone())
}

/// The sibling beside the daemon's own file, when it answers with this build.
fn find_sibling() -> Option<Sibling> {
    let identity = *SIBLING_IDENTITY.get()?;
    // The daemon's own file: `/proc/self/exe` reads "<path> (deleted)" once an
    // upgrade replaced it, and then no sibling can be this build's.
    let own = fs::read_link("/proc/self/exe").ok()?;
    if own.to_string_lossy().ends_with(" (deleted)") {
        return None;
    }
    let path = own.parent()?.join(SIBLING_NAME);
    let key = FileKey::of(&path).ok()?;
    if let Err(error) = check_identity(&path, identity) {
        eprintln!(
            "cmux-tui: terminal hosts run from the daemon's own executable; {} is not usable: \
             {error}",
            path.display()
        );
        return None;
    }
    // The file that answered is the file that runs: a change meanwhile refuses it.
    (FileKey::of(&path).ok() == Some(key)).then_some(Sibling { path, key })
}

/// Run the sibling with `--version`: it must be this daemon's build.
fn check_identity(path: &Path, identity: &str) -> io::Result<()> {
    let output = cmux_process::Command::new(path)
        .arg("--version")
        .stdin(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .output()?;
    let answer = String::from_utf8_lossy(&output.stdout);
    let expected = format!("{SIBLING_NAME} {identity}");
    if !output.status.success() || answer.trim_end() != expected {
        return Err(io::Error::other(format!(
            "it reports {:?}, not this daemon's build {expected:?}",
            answer.trim_end()
        )));
    }
    Ok(())
}

fn refuse(path: &Path, why: &str) {
    SIBLING_REFUSED.store(true, Ordering::Release);
    static REPORTED: Once = Once::new();
    REPORTED.call_once(|| {
        eprintln!(
            "cmux-tui: terminal hosts run from the daemon's own executable from now on; {} {why}",
            path.display()
        );
    });
}

/// The holder runs as it is: a running binary cannot be written on Linux.
pub(super) fn holder_copy(source: &Path, accepts: &dyn Fn(&str) -> bool) -> Option<PathBuf> {
    super::holder_answers(source, accepts).then(|| source.to_path_buf())
}

pub(super) fn hold_in_use_lock() {}

/// Checks the sibling on a background thread when the daemon starts serving,
/// so the first terminal does not wait for its `--version`.
pub(super) fn prepare_in_background() {
    static STARTED: Once = Once::new();
    STARTED.call_once(|| {
        if SIBLING_IDENTITY.get().is_none() {
            return;
        }
        let _ = std::thread::Builder::new().name("cmux-host-exe".into()).spawn(|| {
            let _ = SIBLING.get_or_init(find_sibling);
        });
    });
}

/// A spawn from `path` failed: the daemon's own executable from now on.
pub(super) fn copy_failed(path: &Path) {
    if SIBLING.get().and_then(Option::as_ref).is_some_and(|sibling| sibling.path == path) {
        refuse(path, "did not start");
    }
}

/// The sibling this daemon runs its hosts from, when it does: a host's
/// `/proc/<pid>/exe` names it (`process_resources`).
pub(crate) fn sibling_in_use() -> Option<PathBuf> {
    if SIBLING_REFUSED.load(Ordering::Acquire) {
        return None;
    }
    SIBLING.get().and_then(Option::as_ref).map(|sibling| sibling.path.clone())
}

#[cfg(test)]
#[path = "linux_tests.rs"]
mod tests;
