//! Other local session daemons that mapped this NIGHTLY bundle.
use std::path::Path;
use std::time::Duration;

use cmux_process::{Command, Stdio};
use serde_json::{Value, json};

use super::live::{self, AppDaemon, Daemon};

pub(super) struct Session {
    daemon: AppDaemon,
    old: i32,
}

pub(super) fn discover(main: &AppDaemon) -> Result<Vec<Session>, String> {
    let mut sessions = Vec::new();
    for (_, socket) in crate::cli::federation::session_sockets() {
        if main.socket.as_ref().is_some_and(|s| live::same_file(s, &socket)) {
            continue;
        }
        let daemon = AppDaemon { cli: main.cli.clone(), socket: Some(socket) };
        if let Some((old, executable)) = daemon.owner()?
            && live::same_file(&executable, &main.cli)
        {
            sessions.push(Session { daemon, old });
        }
    }
    Ok(sessions)
}

impl Session {
    fn restart(&self, pid: i32, commit: Option<&str>) -> Result<Value, String> {
        let socket = self.daemon.socket.as_deref().ok_or("missing session socket")?;
        let current = self.daemon.owner()?;
        if !current.is_some_and(|(p, exe)| p == pid && live::same_file(&exe, &self.daemon.cli)) {
            return Err(format!("{} owner changed before restart", socket.display()));
        }
        let mut cmd = Command::new(&self.daemon.cli);
        cmd.arg("--socket").arg(socket).args(["--json", "server", "restart"]);
        let key = "CMUX_TUI_STATE_DIR";
        cmd.env_remove(key);
        if let Some(launch) = cmux_tui_core::platform::process_launch(pid as u32, &[key]) {
            cmd.envs(launch.env);
        }
        let mut child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        let status = match child.wait_timeout(Duration::from_secs(60)) {
            Ok(Some(status)) => status,
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{} restart timed out", socket.display()));
            }
        };
        let (new, exe) =
            self.daemon.owner()?.ok_or_else(|| format!("{} has no owner", socket.display()))?;
        if !live::same_file(&exe, &self.daemon.cli) {
            return Err(format!("{} owner changed executable", socket.display()));
        }
        if !status.success() && pid == new && commit.is_some() {
            return Ok(
                json!({"socket":socket,"old_pid":pid,"new_pid":new,"left":status.to_string()}),
            );
        }
        if !status.success()
            || new == pid
            || commit
                .is_some_and(|sha| !crate::cli::lifecycle::owner_reports_commit(socket, new, sha))
        {
            return Err(format!(
                "{} restart could not verify replacement of {pid}",
                socket.display()
            ));
        }
        Ok(json!({"socket":socket,"old_pid":pid,"new_pid":new}))
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn finish(
    sessions: Vec<Session>,
    mut applied: live::Applied,
    app: &Path,
    build: &str,
    commit: Option<&str>,
    store: &live::Store,
    main: &AppDaemon,
    phases: &mut live::Phases,
) -> Result<live::Applied, String> {
    if !applied.changed {
        return Ok(applied);
    }
    let mut steps = Vec::new();
    for (index, session) in sessions.iter().enumerate() {
        match session.restart(session.old, commit) {
            Ok(step) => steps.push(step),
            Err(error) => {
                let receipt = json!({"steps":applied.steps,"undo":{"files":applied.prior},"app_commit":build});
                let undo = live::undo_changes(app, &receipt)?;
                live::apply(app, &undo, store, main, phases)
                    .map_err(|why| format!("{error}; bundle rollback: {why}"))?;
                let mut failures = Vec::new();
                for touched in &sessions[..=index] {
                    match touched.daemon.owner() {
                        Ok(Some((pid, exe)))
                            if pid != touched.old && live::same_file(&exe, &main.cli) =>
                        {
                            if let Err(why) = touched.restart(pid, None) {
                                failures.push(why);
                            }
                        }
                        Ok(Some((pid, _))) if pid == touched.old => {}
                        other => failures.push(format!("unknown rollback owner: {other:?}")),
                    }
                }
                return Err(format!(
                    "{error}; restored bundle; session rollback errors: {failures:?}"
                ));
            }
        }
    }
    applied.steps["sessions"] = Value::Array(steps);
    Ok(applied)
}
