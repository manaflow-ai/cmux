//! An adopted session host of an older build (an update's flip restarted
//! only the agent, `KillMode=process`): telling it apart by its executable,
//! looking at its carrier sessions while the machine waits to replace it
//! (`crate::machine::ReplaceWhy`), and the updater's deferral mark
//! ([`HOST_DEFERRED_FILE`]) that holds the health deadline meanwhile.

use std::fs;
use std::io;
use std::time::{Duration, Instant};

use super::{LinuxPlatform, ensure_agent_dir, identity, procs};
use crate::agent::Platform;
use crate::config::HOST_DEFERRED_FILE;
use crate::machine::{HostLook, Input, ReplaceWhy};

/// The bound of one look at an old-build host's carrier sessions: it runs
/// on the agent's thread, every [`crate::machine::HOST_LOOK_MS`] while one
/// waits.
const HOST_LOOK_READ: Duration = Duration::from_secs(5);

impl LinuxPlatform {
    /// [`Platform::build_changed`]: whether the adopted host runs another
    /// executable than the session host link resolves to now (the updater's
    /// `healthy` compares the same two). Also removes a mark left by an
    /// earlier agent run when it does not.
    pub(super) fn adopted_build_changed(&mut self) -> bool {
        let Some(pid) = self.daemon_pid() else { return false };
        let Ok(bin) = self.layout().map(|layout| layout.bin.clone()) else { return false };
        if !procs::runs_other_build(pid, &bin) {
            self.clear_host_deferred();
            return false;
        }
        eprintln!(
            "cmux-host: the adopted session host {pid} runs {:?}, the installed build is {:?}",
            crate::updater::role::exe_of(&pid.to_string()),
            fs::canonicalize(&bin).ok()
        );
        // A mark from an earlier agent run for this same host keeps the
        // time the change was first found.
        let earlier = fs::read_to_string(self.cfg.paths.at(HOST_DEFERRED_FILE))
            .ok()
            .and_then(|text| changed_at_in(&text, pid))
            .map(|at| crate::updater::role::now().saturating_sub(at));
        let now = Instant::now();
        self.build_changed_at =
            Some(earlier.and_then(|s| now.checked_sub(Duration::from_secs(s))).unwrap_or(now));
        true
    }

    /// [`Platform::look_host`]: the attached carrier sessions and their
    /// least input idle time, from the session host's admin channel.
    pub(super) fn old_host_look(&mut self) -> HostLook {
        let since_changed_ms = self
            .build_changed_at
            .map_or(0, |at| at.elapsed().as_millis().min(u128::from(u64::MAX)) as u64);
        match crate::updater::role::carrier_input_idle_within(HOST_LOOK_READ) {
            Ok((attached, input_idle_ms)) => {
                HostLook { attached: Some(attached), input_idle_ms, since_changed_ms }
            }
            Err(why) => {
                eprintln!("cmux-host: the old-build host's carrier sessions are unknown: {why}");
                HostLook { attached: None, input_idle_ms: None, since_changed_ms }
            }
        }
    }

    /// `Action::ReplaceOldHost`: logs which cap fired and removes the mark;
    /// the machine's `TerminateDaemon` follows.
    pub(super) fn replace_old_host(&mut self, why: ReplaceWhy) -> io::Result<Option<Input>> {
        let after = self.build_changed_at.map_or(0, |at| at.elapsed().as_secs());
        eprintln!(
            "cmux-host: replacing the old-build session host ({}), {after} s after the build changed",
            why.name()
        );
        self.clear_host_deferred();
        Ok(None)
    }

    /// Removes the updater's deferral mark (none is fine).
    pub(super) fn clear_host_deferred(&mut self) {
        self.build_changed_at = None;
        let _ = self.host_look.disarm();
        match fs::remove_file(self.cfg.paths.at(HOST_DEFERRED_FILE)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => {
                eprintln!("cmux-host: removing the old-host deferral mark: {e}");
            }
            _ => {}
        }
    }

    /// Writes the updater's deferral mark: the session host it adopted runs
    /// an older build and a person's session keeps it. It carries when the
    /// build change was found (wall seconds), so an agent restart during the
    /// deferral keeps the 24 h cap's start ([`changed_at_in`]).
    pub(super) fn mark_host_deferred(&mut self) -> io::Result<Option<Input>> {
        ensure_agent_dir(&self.cfg.paths)?;
        let since = self.build_changed_at.map_or(0, |at| at.elapsed().as_secs());
        let changed_at = crate::updater::role::now().saturating_sub(since);
        let body =
            format!("{{\"pid\":{},\"changed_at\":{changed_at}}}\n", self.daemon_pid().unwrap_or(0));
        identity::write_atomic(&self.cfg.paths.at(HOST_DEFERRED_FILE), body.as_bytes(), 0o644)?;
        eprintln!(
            "cmux-host: the old-build session host serves an attached session: kept until it detaches, 10 min without input or 24 h"
        );
        Ok(None)
    }
}

/// The `changed_at` (wall seconds) of a deferral mark written for the host
/// `pid`; `None` for another host's mark or an unreadable one.
fn changed_at_in(text: &str, pid: u32) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_str(text.trim()).ok()?;
    (v.get("pid")?.as_u64()? == u64::from(pid)).then_some(())?;
    v.get("changed_at")?.as_u64()
}

#[cfg(test)]
#[path = "old_host_tests.rs"]
mod tests;
