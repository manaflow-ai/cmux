//! macOS headless LaunchAgent (server.md 4.3 column "macOS (headless)").
//! The plist text comes from `cmux_server_core::units::launch_agent_plist`;
//! it is loaded with `launchctl bootstrap gui/<uid>`. The app path
//! (`SMAppService.agent`) and the LaunchDaemon variant are server.md step 7.

use std::path::{Path, PathBuf};

use cmux_server_core::layout::LAUNCHD_LABEL;
use cmux_server_core::units::{launch_agent_plist, session_launch_agent_plist};

use super::{ServiceReport, ServiceState, Services};
use crate::error::{Error, Result};
use crate::fsx;
use crate::process::Cmd;

fn domain(s: &Services<'_>) -> String {
    format!("gui/{}", s.uid)
}

fn target(s: &Services<'_>) -> String {
    format!("gui/{}/{LAUNCHD_LABEL}", s.uid)
}

fn launchctl() -> Cmd {
    Cmd::new("launchctl")
}

fn loaded(s: &Services<'_>) -> bool {
    s.runner.run(&launchctl().args(["print", &target(s)])).is_ok_and(|o| o.ok())
}

pub fn plist(s: &Services<'_>) -> Result<String> {
    match &s.session {
        Some(host) => session_launch_agent_plist(s.layout, &host.binary, &host.session),
        None => launch_agent_plist(s.layout),
    }
    .map_err(|e| Error::rejected(format!("cannot render the plist: {e:?}")))
}

pub fn install(s: &Services<'_>, restart: bool) -> Result<ServiceReport> {
    let plist = s.unit_path()?;
    let text = self::plist(s)?;
    if let Some(dir) = plist.parent() {
        fsx::ensure_dir(dir, 0o755)?;
    }
    // launchd writes the server log there before the server can create it:
    // only this account may read or replace it (preflight checked the
    // folder is this account's and not a symlink).
    let logs = fsx::local(&s.layout.logs());
    fsx::ensure_dir(&logs, 0o700)?;
    private_log(&logs)?;
    let changed = fsx::write_if_changed(&plist, text.as_bytes(), 0o644)?;
    s.wrote(&[(plist.clone(), text)])?;
    let mut report = ServiceReport { unit: plist.clone(), changed, ..ServiceReport::default() };
    let was_loaded = loaded(s);
    if was_loaded && changed {
        // A changed plist is read only at bootstrap.
        let _ = s.runner.run(&launchctl().args(["bootout", &target(s)]));
        report.restarted = true;
    }
    if !was_loaded || changed {
        // A `server down` override would refuse the bootstrap; installing starts the server.
        let _ = s.runner.run(&launchctl().args(["enable", &target(s)]));
        s.runner.check(&launchctl().args(["bootstrap", &domain(s)]).arg(&plist))?;
    } else if restart {
        s.runner.check(&launchctl().args(["kickstart", "-k", &target(s)]))?;
        report.restarted = true;
    }
    Ok(report)
}

/// Refuses a service log launchd would write into another file through: a
/// symlink, a file of another account, or a second name (hard link) of
/// another file.
pub fn check_log(log: &Path) -> Result<()> {
    let Ok(meta) = std::fs::symlink_metadata(log) else { return Ok(()) };
    let owner = crate::sys::owner_uid(&meta);
    #[cfg(unix)]
    let links = std::os::unix::fs::MetadataExt::nlink(&meta);
    #[cfg(not(unix))]
    let links = 1;
    if !meta.is_file() || owner != crate::sys::euid() || links != 1 {
        return Err(Error::rejected(format!(
            "{} is not a plain file of yours (a symlink, a second name of another file, or owned by uid {owner}); launchd would write the service log into it. Remove it, then run `cmux server install` again",
            log.display()
        )));
    }
    super::check_no_acl_grants(log, "the service log")
}

/// Makes the service log folder 0700 and creates `server.log` in it, or
/// keeps the one there, as 0600. The folder is opened once without
/// following a symlink and the log is opened through it (`openat`), so a
/// folder or log swapped for a symlink after the checks is refused, not
/// written through.
#[cfg(unix)]
fn private_log(logs: &Path) -> Result<()> {
    use std::ffi::CString;
    use std::os::fd::{FromRawFd as _, OwnedFd};
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
    let changed = |what: &Path| {
        Error::rejected(format!(
            "{} changed while cmux set it up (a symlink, a second name of another file, or not yours); run `cmux server install` again",
            what.display()
        ))
    };
    let dir_name = CString::new(logs.as_os_str().as_bytes()).map_err(|_| changed(logs))?;
    // SAFETY: a valid C string; the result is checked before use.
    let dir_fd = unsafe {
        libc::open(
            dir_name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if dir_fd < 0 {
        return Err(Error::io(logs.display(), std::io::Error::last_os_error()));
    }
    // SAFETY: dir_fd is a new descriptor this function owns.
    let dir = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(dir_fd) });
    let meta = dir.metadata().map_err(|e| Error::io(logs.display(), e))?;
    if !meta.is_dir() || meta.uid() != crate::sys::euid() {
        return Err(changed(logs));
    }
    dir.set_permissions(std::fs::Permissions::from_mode(0o700))
        .map_err(|e| Error::io(logs.display(), e))?;
    // The mode does not reach macOS ACL entries: drop any that allow
    // another account to write here (crate::acl).
    crate::acl::strip_write_grants(&dir).map_err(|e| Error::io(logs.display(), e))?;
    let log = logs.join("server.log");
    // SAFETY: a valid descriptor and a constant C string.
    let log_fd = unsafe {
        libc::openat(
            dir_fd,
            c"server.log".as_ptr(),
            libc::O_WRONLY
                | libc::O_APPEND
                | libc::O_CREAT
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK,
            0o600 as libc::c_uint,
        )
    };
    if log_fd < 0 {
        return Err(Error::io(log.display(), std::io::Error::last_os_error()));
    }
    // SAFETY: log_fd is a new descriptor this function owns.
    let file = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(log_fd) });
    let meta = file.metadata().map_err(|e| Error::io(log.display(), e))?;
    if !meta.is_file() || meta.uid() != crate::sys::euid() || meta.nlink() != 1 {
        return Err(changed(&log));
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))
        .map_err(|e| Error::io(log.display(), e))?;
    crate::acl::strip_write_grants(&file).map_err(|e| Error::io(log.display(), e))?;
    Ok(())
}

#[cfg(not(unix))]
fn private_log(_logs: &Path) -> Result<()> {
    Ok(())
}

/// `launchctl print`'s exit code for a job launchd has not loaded.
const NOT_LOADED: i32 = 113;

/// Refuses a `com.cmux.server` job launchd runs from another plist than
/// the one cmux writes (or from none it names): install would replace it
/// and uninstall would boot it out. Not loaded (`launchctl print` exits
/// 113): fine. Any other failure: refused, since it is no answer.
pub fn check_source(s: &Services<'_>) -> Result<()> {
    let ours = s.unit_path()?;
    let cmd = launchctl().args(["print", &target(s)]);
    let out = s.runner.run(&cmd).map_err(|e| Error::io(cmd.display(), e))?;
    // 113: launchd has no such job. Any other failure is no answer.
    if out.code == Some(NOT_LOADED) {
        return Ok(());
    }
    if !out.ok() {
        return Err(Error::rejected(format!(
            "cmux cannot tell whether launchd runs {LAUNCHD_LABEL} (`{}` failed with {}), so it changes nothing; run the command again",
            cmd.display(),
            out.code.map_or_else(|| "a signal".to_owned(), |c| format!("exit {c}"))
        )));
    }
    let text = out.stdout_text();
    let path = text.lines().find_map(|l| l.trim().strip_prefix("path = ")).map(str::trim);
    if path.map(Path::new) == Some(ours.as_path()) {
        return Ok(());
    }
    Err(Error::rejected(format!(
        "launchd runs {LAUNCHD_LABEL} from {}, not from {} (the plist cmux writes), so cmux leaves it, and everything it may use, alone. Remove that job yourself (launchctl bootout {}), then run the command again",
        path.unwrap_or("a plist it does not name"),
        ours.display(),
        target(s)
    )))
}

pub fn restart(s: &Services<'_>) -> Result<()> {
    s.runner.check(&launchctl().args(["kickstart", "-k", &target(s)])).map(|_| ())
}

/// Clears a `down` override, then loads the plist when it is not loaded.
pub fn start(s: &Services<'_>) -> Result<()> {
    s.runner.check(&launchctl().args(["enable", &target(s)]))?;
    if !loaded(s) {
        s.runner.check(&launchctl().args(["bootstrap", &domain(s)]).arg(s.unit_path()?))?;
    }
    Ok(())
}

/// Records a disabled override (kept across logins), then unloads the job.
pub fn stop(s: &Services<'_>) -> Result<()> {
    s.runner.check(&launchctl().args(["disable", &target(s)]))?;
    if loaded(s) {
        s.runner.check(&launchctl().args(["bootout", &target(s)]))?;
    }
    Ok(())
}

pub fn uninstall(s: &Services<'_>) -> Result<Vec<PathBuf>> {
    // launchd has no bootout bound to a plist (`bootout DOMAIN PATH` reads
    // the label from the file and unloads by label): check the job's source
    // right before the bootout by label, so the gap is that one command
    // (Codex R-005), which only root or this same account can use.
    check_source(s).map_err(|e| super::outcome(e, "nothing was changed"))?;
    let _ = s.runner.run(&launchctl().args(["bootout", &target(s)]));
    // A bootout that failed must not let uninstall remove what the job
    // still uses: launchd must say it has no such job now.
    let print = launchctl().args(["print", &target(s)]);
    let out = s.runner.run(&print).map_err(|e| Error::io(print.display(), e))?;
    if out.code != Some(NOT_LOADED) {
        return Err(Error::rejected(format!(
            "launchd still has {LAUNCHD_LABEL} after cmux booted it out (`{}` exited {}), so cmux removed nothing it may still use. Boot it out (`launchctl bootout {}`), then run the command again",
            print.display(),
            out.code.map_or_else(|| "by a signal".to_owned(), |c| c.to_string()),
            target(s)
        )));
    }
    s.remove_unit_files()
}

pub fn state(s: &Services<'_>) -> ServiceState {
    let installed = s.unit_path().is_ok_and(|p| p.is_file());
    let is_loaded = loaded(s);
    ServiceState { installed, active: Some(is_loaded), enabled: Some(installed) }
}
