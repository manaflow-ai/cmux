//! The app's install key on its way to the owner daemon this process
//! spawns (P8 3b-2; Windows cx-jdb.8): never in argv or the environment,
//! only on a pipe the owner alone holds, read once and kept in memory only.

#[cfg(unix)]
use cmux_process::Command;
#[cfg(any(unix, windows))]
use std::io::{self, Write};

/// Private startup option (P8 3b-2): the app's install key arrives on this
/// inherited pipe (`cmuxik1 <install_id> <hex key>`), never in argv or the
/// environment. The owner reads it once, closes the descriptor and keeps
/// the key in memory only.
pub(crate) const OWNER_INSTALL_KEY_FD_ARG: &str = "--owner-install-key-fd";

/// Private startup option, Windows (cx-jdb.8): the app's install key
/// arrives on the owner's standard input, a pipe only this owner holds
/// (`std` makes the child's end inheritable for that one spawn only), never
/// in argv or the environment. The owner takes its stdin out of every
/// process it starts (`claim_install_key_stdin`), reads it to end of file
/// once and keeps the key in memory only.
#[cfg(windows)]
pub(crate) const OWNER_INSTALL_KEY_STDIN_ARG: &str = "--owner-install-key-stdin";

/// Whether `arg` is `OWNER_INSTALL_KEY_STDIN_ARG` (never outside Windows).
pub(super) fn is_stdin_arg(arg: &str) -> bool {
    #[cfg(windows)]
    {
        arg == OWNER_INSTALL_KEY_STDIN_ARG
    }
    #[cfg(not(windows))]
    {
        let _ = arg;
        false
    }
}

#[cfg(not(windows))]
pub(super) fn claim_install_key_stdin() -> Result<(), String> {
    Err("the stdin install key handoff is Windows only".to_string())
}

/// The install key this owner read from its stdin at startup (Windows),
/// until `install_key_from_launcher` gives it to the session.
#[cfg(windows)]
static STDIN_CLAIMED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
static STDIN_INSTALL_KEY: std::sync::Mutex<Option<cmux_tui_core::server::FrontendKey>> =
    std::sync::Mutex::new(None);

/// Parses `OWNER_INSTALL_KEY_STDIN_ARG` (once) and reads the key at once,
/// before this owner can start any process: its stdin must be a pipe; the
/// handle loses its inherit flag first (as `claim_inherited_fd` sets
/// close-on-exec), and is read to end of file through an unbuffered
/// duplicate, so no `std` buffer keeps a copy. Afterwards the standard
/// handle stays open at end of file (the launcher closed its end), so a
/// child that is given it (`Stdio::inherit`) reads nothing. A bad payload
/// leaves the owner without a key, as on Unix.
#[cfg(windows)]
pub(super) fn claim_install_key_stdin() -> Result<(), String> {
    use std::os::windows::io::{AsHandle, AsRawHandle};
    use windows_sys::Win32::Foundation::{HANDLE_FLAG_INHERIT, SetHandleInformation};
    use windows_sys::Win32::Storage::FileSystem::{FILE_TYPE_PIPE, GetFileType};
    if STDIN_CLAIMED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return Err(format!("{OWNER_INSTALL_KEY_STDIN_ARG} may be supplied only once"));
    }
    let stdin = io::stdin();
    let handle = stdin.as_raw_handle();
    // SAFETY: GetFileType only queries this process's standard input
    // handle; a null or invalid handle reports FILE_TYPE_UNKNOWN.
    if handle.is_null() || unsafe { GetFileType(handle) } != FILE_TYPE_PIPE {
        return Err(format!("{OWNER_INSTALL_KEY_STDIN_ARG} needs a standard input pipe"));
    }
    // SAFETY: SetHandleInformation only changes the flags of this process's
    // own standard input handle; an invalid handle reports an error.
    if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(format!("{OWNER_INSTALL_KEY_STDIN_ARG}: {}", io::Error::last_os_error()));
    }
    let pipe = stdin
        .as_handle()
        .try_clone_to_owned()
        .map_err(|e| format!("{OWNER_INSTALL_KEY_STDIN_ARG}: {e}"))?;
    let key = cmux_tui_core::server::read_frontend_key(std::fs::File::from(pipe)).ok();
    *STDIN_INSTALL_KEY.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = key;
    Ok(())
}

/// Gives the app's install key from the launcher's pipe to the session
/// (`client-hello`): on Unix read now from the inherited descriptor `fd`
/// (`OWNER_INSTALL_KEY_FD_ARG`), which then closes; on Windows the key
/// `claim_install_key_stdin` read at startup. A bad or missing payload
/// leaves the daemon without a key: no connection proves itself with one.
pub(crate) fn install_key_from_launcher(mux: &cmux_tui_core::Mux, fd: Option<i32>) {
    if let Some(key) = launcher_key(fd) {
        cmux_tui_core::server::install_frontend_key(mux, key);
    }
}

#[cfg(unix)]
fn launcher_key(fd: Option<i32>) -> Option<cmux_tui_core::server::FrontendKey> {
    use std::os::fd::FromRawFd;
    let fd = fd?;
    // SAFETY: `claim_inherited_fd` validated this inherited descriptor, and
    // this is its only use; the File closes it on drop.
    let pipe = unsafe { std::fs::File::from_raw_fd(fd) };
    cmux_tui_core::server::read_frontend_key(pipe).ok()
}

#[cfg(windows)]
fn launcher_key(_fd: Option<i32>) -> Option<cmux_tui_core::server::FrontendKey> {
    STDIN_INSTALL_KEY.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

#[cfg(not(any(unix, windows)))]
fn launcher_key(_fd: Option<i32>) -> Option<cmux_tui_core::server::FrontendKey> {
    None
}

/// The descriptor number the owner gets the install key pipe's read end at
/// (the readiness pipe is 3).
#[cfg(unix)]
const OWNER_INSTALL_KEY_FD: std::os::fd::RawFd = 4;

/// The install key pipe: the whole payload is written now (it fits the
/// pipe buffer) and the write end closes, so the owner reads to end of
/// file. Only the owner gets the read end, as `OWNER_INSTALL_KEY_FD`
/// (`Command::inherit_fd`); the returned reader closes in this process
/// after spawn.
#[cfg(unix)]
pub(super) fn install_key_pipe(
    command: &mut Command,
    key: &cmux_tui_core::server::FrontendKey,
) -> io::Result<io::PipeReader> {
    use std::os::fd::AsFd;
    let (reader, mut writer) = io::pipe()?;
    writer.write_all(key.to_payload().as_bytes())?;
    drop(writer);
    command.arg(OWNER_INSTALL_KEY_FD_ARG).arg(OWNER_INSTALL_KEY_FD.to_string());
    command.inherit_fd(reader.as_fd(), OWNER_INSTALL_KEY_FD)?;
    Ok(reader)
}

/// Writes the whole payload to the owner's stdin and closes this end, so
/// the owner reads to end of file. A failed write (the owner already
/// exited) leaves it without a key, as a bad payload does.
#[cfg(windows)]
pub(super) fn send_over_stdin(
    child: &mut cmux_process::Child,
    key: Option<&cmux_tui_core::server::FrontendKey>,
) {
    if let (Some(key), Some(mut stdin)) = (key, child.stdin.take()) {
        let _ = stdin.write_all(key.to_payload().as_bytes());
    }
}

/// Windows `std` spawns with `bInheritHandles`, so every inheritable handle
/// of this process reaches the owner even when its stdio is null: this
/// process's own stdin (on `server ensure --install-key-stdin`, the app's
/// key pipe) and the stdout/stderr pipes of whoever runs it, which the
/// detached owner would then hold open (a caller reading this command's
/// output to end of file never sees it end). Clearing the inherit flag of
/// the three standard handles keeps them here; a later `Stdio::inherit`
/// spawn still works (`std` duplicates the handle for that child).
#[cfg(windows)]
pub(super) fn keep_std_handles_from_children() {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{HANDLE_FLAG_INHERIT, SetHandleInformation};
    for handle in
        [io::stdin().as_raw_handle(), io::stdout().as_raw_handle(), io::stderr().as_raw_handle()]
    {
        if !handle.is_null() {
            // SAFETY: SetHandleInformation only changes the flags of this
            // process's own standard handle; an invalid one reports an error,
            // which leaves the handle as it was.
            unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) };
        }
    }
}
