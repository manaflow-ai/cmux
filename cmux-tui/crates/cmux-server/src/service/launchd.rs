//! macOS headless LaunchAgent (server.md 4.3 column "macOS (headless)").
//! The plist text comes from `cmux_server_core::units::launch_agent_plist`;
//! it is loaded with `launchctl bootstrap gui/<uid>`. The app path
//! (`SMAppService.agent`) and the LaunchDaemon variant are server.md step 7.

use std::path::PathBuf;

use cmux_server_core::layout::LAUNCHD_LABEL;
use cmux_server_core::units::launch_agent_plist;

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
    launch_agent_plist(s.layout)
        .map_err(|e| Error::rejected(format!("cannot render the plist: {e:?}")))
}

pub fn install(s: &Services<'_>, restart: bool) -> Result<ServiceReport> {
    let plist = s.unit_path()?;
    let text = self::plist(s)?;
    if let Some(dir) = plist.parent() {
        fsx::ensure_dir(dir, 0o755)?;
    }
    // launchd writes the server log there before the server can create it.
    fsx::ensure_dir(&fsx::local(&s.layout.logs()), 0o700)?;
    let changed = fsx::write_if_changed(&plist, text.as_bytes(), 0o644)?;
    let mut report = ServiceReport { unit: plist.clone(), changed, ..ServiceReport::default() };
    let was_loaded = loaded(s);
    if was_loaded && changed {
        // A changed plist is read only at bootstrap.
        let _ = s.runner.run(&launchctl().args(["bootout", &target(s)]));
    }
    if !was_loaded || changed {
        s.runner.check(&launchctl().args(["bootstrap", &domain(s)]).arg(&plist))?;
    } else if restart {
        s.runner.check(&launchctl().args(["kickstart", "-k", &target(s)]))?;
        report.restarted = true;
    }
    Ok(report)
}

pub fn restart(s: &Services<'_>) -> Result<()> {
    s.runner.check(&launchctl().args(["kickstart", "-k", &target(s)])).map(|_| ())
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
