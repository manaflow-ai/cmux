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
    fsx::set_mode(&logs, 0o700).map_err(|e| Error::io(logs.display(), e))?;
    private_log(&logs.join("server.log"))?;
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
    Ok(())
}

/// Creates the service log, or keeps the one there, readable only by this
/// account, without following a symlink put there since the check.
fn private_log(log: &Path) -> Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(log).map_err(|e| Error::io(log.display(), e))?;
    let meta = file.metadata().map_err(|e| Error::io(log.display(), e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        if !meta.is_file() || meta.uid() != crate::sys::euid() || meta.nlink() != 1 {
            return Err(Error::rejected(format!(
                "{} changed while cmux set it up; run `cmux server install` again",
                log.display()
            )));
        }
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|e| Error::io(log.display(), e))?;
    }
    #[cfg(not(unix))]
    let _ = meta;
    Ok(())
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
    let _ = s.runner.run(&launchctl().args(["bootout", &target(s)]));
    let plist = s.unit_path()?;
    if fsx::exists_no_follow(&plist) {
        fsx::remove_tree(&plist)?;
        return Ok(vec![plist]);
    }
    Ok(Vec::new())
}

pub fn state(s: &Services<'_>) -> ServiceState {
    let installed = s.unit_path().is_ok_and(|p| p.is_file());
    let is_loaded = loaded(s);
    ServiceState { installed, active: Some(is_loaded), enabled: Some(installed) }
}
