//! A local app's saved script is tried in a host of its own before its live
//! host restarts (`local_reload.rs`). A script that does not load (a syntax
//! error, a throw at the top level) leaves the live host, its mounts and
//! their last good scenes as they are: a sidebar section or chat widget keeps
//! its view, and the reload reports why the save was not taken. Only a clear
//! init failure keeps the old host; when the trial cannot tell (no host
//! binary, a spawn error, an exit or no answer by the deadline) the restart
//! goes ahead as before.

use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_app_host::{AppInfo, FromHost, ToHost};

use super::catalog::Package;
use super::grants::{Grant, ScopeTable};
use super::host::HostProcess;
use super::supervisor::Supervisor;

/// How long a trial waits for the script's answer. Init evaluates the
/// script's top level only; a script past this is left to the live restart.
const TRIAL_DEADLINE: Duration = Duration::from_secs(5);

/// The `Init` message that loads `main` for `package` under `grant`, the same
/// for a live host and a trial.
pub(super) fn init_message(package: &Package, main: String, grant: &Grant) -> ToHost {
    let table = ScopeTable::get();
    ToHost::Init {
        app: AppInfo { id: package.id.clone(), version: package.version.clone() },
        settings: package.default_settings(),
        api_version: "1.0.0".into(),
        ops: Some(table.allowed_ops(grant)),
        known_ops: Some(table.known_ops()),
        locale: Some("en".into()),
        strings: package.strings("en"),
        main,
        main_name: package.main_name(),
    }
}

impl Supervisor {
    /// Loads `package`'s saved script in a host of its own and returns its
    /// init error; None when it loaded or the trial could not tell.
    pub(super) fn load_trial(&self, package: &Package, grant: &Grant) -> Option<String> {
        let main = package.main_source()?;
        let binary = self.config.host_binary.as_ref()?;
        let (answer, answers) = channel();
        let exited = answer.clone();
        // The reader thread reports every message before the exit, so an
        // init failure is never lost to the exit that follows it.
        let process = HostProcess::spawn(
            binary,
            &self.config.host_args,
            &package.id,
            move |message| match message {
                FromHost::Ready { .. } => drop(answer.send(None)),
                FromHost::InitFailed { error } => drop(answer.send(Some(error))),
                _ => {}
            },
            move |_| drop(exited.send(None)),
        )
        .ok()?;
        self.host_spawns.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        process.send(&init_message(package, main, grant));
        // A bounded deadline, not a poll: a script that never answers must not hold the reload thread.
        let error = answers.recv_timeout(TRIAL_DEADLINE).ok().flatten();
        process.kill();
        error
    }
}
