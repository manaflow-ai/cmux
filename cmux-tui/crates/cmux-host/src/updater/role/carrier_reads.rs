//! The updater's read of what a restart would cut: the attached carrier sessions and their
//! bounded reads, the child output reader, and the busy list built from them.

use super::*;

/// What a restart would cut: the attached carrier sessions ([`carrier_busy`],
/// bounded), then [`acpmux_busy_sessions`]. Empty only when both are idle.
pub(super) fn busy_sessions(paths: &Paths) -> Result<Vec<String>, String> {
    let carrier = carrier_busy(paths);
    let mut busy = acpmux_busy_sessions()?;
    busy.extend(carrier);
    Ok(busy)
}

/// The carrier hold between looks ([`super::carrier`]).
pub(super) static CARRIER: Mutex<Option<CarrierHold>> = Mutex::new(None);

/// One look at the session host's carrier sessions: why they hold the
/// update, if they do. A new session starts the connect hold, so a claimed
/// spare's first link is never cut, also past the carrier hold's bound.
pub(super) fn carrier_busy(paths: &Paths) -> Option<String> {
    carrier_busy_from(paths, carrier_sessions())
}

/// [`carrier_busy`] for a rollback's wait: only sessions the list shows hold
/// it, under the same bound. A list that can't be read holds nothing here:
/// the session host that would answer is the build being rolled back, and
/// keeping a broken build is worse than a restart (#37280).
///
/// Each wait has its own hold, started when the wait begins: the forward
/// update's hold ([`CARRIER`]) may have passed its bound, and a session that
/// reconnected since would get no hold at all.
#[derive(Default)]
pub(in crate::updater) struct RollbackCarrier {
    hold: CarrierHold,
}

impl RollbackCarrier {
    /// One look at `now` at the sessions read.
    pub(in crate::updater) fn look(
        &mut self,
        paths: &Paths,
        now: Instant,
        sessions: Result<Vec<String>, String>,
    ) -> Option<String> {
        let ids = sessions.ok()?;
        act_on_look(self.hold.look(now, Ok(ids)), || {
            hold_connects(paths, HoldKind::Connect);
        })
    }
}

/// [`carrier_busy`] for the sessions one look read.
pub(in crate::updater) fn carrier_busy_from(
    paths: &Paths,
    sessions: Result<Vec<String>, String>,
) -> Option<String> {
    carrier_busy_at(paths, Instant::now(), sessions)
}

/// [`carrier_busy_from`] at `now`.
pub(in crate::updater) fn carrier_busy_at(
    paths: &Paths,
    now: Instant,
    sessions: Result<Vec<String>, String>,
) -> Option<String> {
    carrier_look_at(now, sessions, || {
        hold_connects(paths, HoldKind::Connect);
    })
}

/// One look at the carrier sessions through the hold between looks
/// ([`CARRIER`]); a new session calls `start_hold`.
pub(super) fn carrier_look(
    sessions: Result<Vec<String>, String>,
    start_hold: impl FnOnce(),
) -> Option<String> {
    carrier_look_at(Instant::now(), sessions, start_hold)
}

/// [`carrier_look`] at `now`.
pub(super) fn carrier_look_at(
    now: Instant,
    sessions: Result<Vec<String>, String>,
    start_hold: impl FnOnce(),
) -> Option<String> {
    let mut hold = CARRIER.lock().unwrap_or_else(|e| e.into_inner());
    let look = hold.get_or_insert_with(CarrierHold::default).look(now, sessions);
    drop(hold);
    act_on_look(look, start_hold)
}

/// What one carrier look does: a new session starts the connect hold
/// (`start_hold`), the bound is logged once, and the answer is why the
/// update waits, if it does.
pub(in crate::updater) fn act_on_look(
    look: CarrierLook,
    start_hold: impl FnOnce(),
) -> Option<String> {
    if look.new_session {
        start_hold();
        log("a new carrier session: no flip during the connect hold");
    }
    if look.bound_passed {
        log(&format!(
            "carrier sessions held this update for {} min; it goes at the next idle gap",
            CARRIER_MAX_HOLD.as_secs() / 60
        ));
    }
    look.busy
}

/// The bound of a carrier read outside the gate.
pub(super) const CARRIER_READ: Duration = Duration::from_secs(20);

/// The bound of the flip's carrier read inside the gate ([`flip_in_gate`]):
/// the gate's flock is held meanwhile, so every bind and hold on the machine
/// waits on it. A read that runs past it holds the flip as busy
/// ([`Unread::TimedOut`]), never as no sessions.
pub(in crate::updater) const CARRIER_READ_IN_GATE: Duration = Duration::from_secs(4);

/// Why one read of the carrier sessions has no list.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::updater) enum Unread {
    /// The query ran past its bound (`timeout`'s exit status 124).
    TimedOut(Duration),
    /// Any other failure.
    Failed(String),
}

impl Unread {
    /// The failure an exited query's `status` shows, run under `limit`.
    pub(in crate::updater) fn of(status: std::process::ExitStatus, limit: Duration) -> Unread {
        if status.code() == Some(124) {
            Unread::TimedOut(limit)
        } else {
            Unread::Failed(format!("its admin channel answered {status}"))
        }
    }

    pub(super) fn why(self) -> String {
        match self {
            Unread::TimedOut(limit) => {
                format!("its admin channel did not answer within {} s", limit.as_secs())
            }
            Unread::Failed(why) => why,
        }
    }
}

/// [`carrier_sessions_within`] the bound outside the gate.
pub(super) fn carrier_sessions() -> Result<Vec<String>, String> {
    carrier_sessions_within(CARRIER_READ).map_err(Unread::why)
}

/// The attached carrier sessions, from the session host's admin channel
/// (`cmux-tui remote enroll connections --json`, at most `limit`), run as the
/// user and home the session host runs with (the layout marker), since the
/// channel answers only its own user.
pub(super) fn carrier_sessions_within(limit: Duration) -> Result<Vec<String>, Unread> {
    let stdout = connections_json_within(limit)?;
    super::super::carrier::attached_sessions_in(&stdout)
        .ok_or_else(|| Unread::Failed("its connection list is unreadable".to_owned()))
}

/// The attached carrier sessions and the least input idle time among them
/// ([`super::super::carrier::attached_input_idle_in`]), read within `limit`: the
/// supervisor's look at an old-build session host it waits to replace
/// (`crate::machine::HostLook`).
pub(crate) fn carrier_input_idle_within(limit: Duration) -> Result<(usize, Option<u64>), String> {
    let stdout = connections_json_within(limit).map_err(Unread::why)?;
    super::super::carrier::attached_input_idle_in(&stdout)
        .ok_or_else(|| "its connection list is unreadable".to_owned())
}

/// The session host's `remote enroll connections --json` reply, at most `limit`.
pub(super) fn connections_json_within(limit: Duration) -> Result<String, Unread> {
    let marker = fs::read_to_string(Paths::new("/").at(crate::config::LAYOUT_MARKER_FILE)).ok();
    let home =
        crate::cloud::daemon_noise_key::session_home(marker.as_deref()).ok_or_else(|| {
            Unread::Failed("the session host's layout is not recorded yet".to_owned())
        })?;
    let mut cmd = Command::new("timeout");
    cmd.arg(limit.as_secs().max(1).to_string());
    if home != Path::new(crate::daemon_spec::ROOT_HOME) {
        cmd.args(["runuser", "-u", WORK_USER, "--"]);
    }
    cmd.arg("env")
        .arg(format!("HOME={}", home.display()))
        .arg(super::super::CURRENT_CMUX_TUI)
        .args(["remote", "enroll", "connections", "--session", crate::daemon_spec::SESSION])
        .arg("--json");
    let stdout = output_within(cmd, limit)?;
    Ok(String::from_utf8_lossy(&stdout).into_owned())
}

/// How long past its `timeout` bound a read may run before [`output_within`]
/// kills its process group: `timeout` only sends SIGTERM and waits, so a
/// child that ignores it (or a grandchild under `runuser` that keeps stdout
/// open) would hold the caller, and the gate's flock with it, past the bound
/// (review F1 on #39366 at 6ac5a558).
pub(in crate::updater) const READ_KILL_AFTER: Duration = Duration::from_secs(1);
