//! Part of `Hub`; see `hub/mod.rs`. `sessions.allowFullAccess` as MDM or the team policy forces
//! it (#23322). claude-sr2, 2026-10-25: "an MDM-managed value is an upper bound the user can't
//! override. If MDM sets allowFullAccess=false, Full access is unavailable and the mode menu says
//! "Managed by your organization". If MDM is unset, nothing changes."
//!
//! The app pushes the forced value (`_acpmux/chat_settings`), which acpmux keeps in
//! start-mode.json (`start_mode_state.rs`). Only a forced off acts: `full_access_allowed` is the
//! settings file's answer under it, and every check that asks whether full access may run reads it.
//!
//! Whether an agent runs in full access is decided in one place, `runs_full_access`, over a
//! `FullAccessView` of everything acpmux knows that can put it there:
//! - argv: its profile pins full access (`subsession_guard::argv_full_access`, the one parse of
//!   those flags);
//! - mode: its current mode is a full-access one;
//! - undeclared mode: a mode its harness reported without declaring modes
//!   (`RemoteFloor::undeclared_mode`); for a host a restart left, read back from its log first;
//! - option: any config option holds a full-access value, the `mode` one included (a harness can
//!   keep `modes.currentModeId` at an asking mode while its `mode` option says full access);
//! - reported: its harness reported full access while nothing watched it (`StartReports`), or in
//!   a report the inbound loop has not applied yet (`FloorState::unapplied_full_access`).
//!
//! Each form is judged by the shared rule (`start_mode::is_full_access`). A start whose profile
//! pins full access is refused (`refuse_pinned_full_access`), and so is one that comes up in it
//! (`cap_full_access`). An agent that already runs in it ends (below, `end_if_runs_full_access`).

use super::*;

/// The form in which an agent runs in full access (`runs_full_access`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FullAccessForm {
    /// Its profile's argv pins it (`--yolo`, `--permission-mode bypassPermissions`, ...).
    Argv,
    /// Its current mode is a full-access one.
    Mode,
    /// Its harness, declaring no modes, reported a full-access mode.
    UndeclaredMode,
    /// A config option holds a full-access value.
    Option,
    /// Its harness reported full access while nothing watched it (`StartReports`).
    Reported,
}

/// What acpmux knows of one agent that can put it in full access.
#[derive(Default)]
pub(crate) struct FullAccessView {
    pub argv: Vec<String>,
    pub mode: Option<String>,
    pub undeclared_mode: Option<String>,
    /// Its config options, the `mode` one included.
    pub options: Vec<Value>,
    /// Whether its harness reported full access while nothing watched it (`StartReports`).
    pub reported: bool,
}

impl FullAccessView {
    /// A profile before its agent starts: its argv only.
    pub(crate) fn of_argv(argv: &[String]) -> Self {
        Self { argv: argv.to_vec(), ..Self::default() }
    }

    /// An agent from `argv` whose harness answered `session/new` with `res`: the mode and config
    /// options its session came up in, beside its argv.
    pub(crate) fn of_session_new(argv: &[String], res: Option<&Value>) -> Self {
        Self {
            argv: argv.to_vec(),
            mode: res.and_then(|r| r["modes"]["currentModeId"].as_str()).map(str::to_owned),
            undeclared_mode: None,
            options: res.and_then(|r| r["configOptions"].as_array()).cloned().unwrap_or_default(),
            reported: false,
        }
    }

    /// A session's agent as acpmux records it.
    pub(crate) fn of_session(session: &Session) -> Self {
        // One snapshot, under the meta lock: the tap counts a report under it (`session_tap`),
        // and `write_mode_state` applies the report and takes its count back under it, so the
        // view sees a report counted, applied, or not yet come (reviews 3 to 5 of #26052).
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        #[cfg(test)]
        between_view_reads(session);
        let reported = session.floor.unapplied_full_access.load(Ordering::SeqCst) > 0;
        let undeclared_mode =
            session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let asked = session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let meta = m.clone();
        drop(m);
        Self {
            mode: crate::web_modes::mode_of(&meta),
            undeclared_mode,
            // With the values a bare `set_config_option` answer took (`FloorState::asked_options`).
            options: config_options(&meta).cloned().chain(asked).collect(),
            // The argv its agent started with; before any start, the creation's.
            argv: meta.spawn_argv.unwrap_or(meta.harness_argv),
            reported,
        }
    }
}

/// A harness or report session id as the full-access bound matches it: an empty or all-whitespace
/// id names no session (reviews 70 and 74 of #23322). Every id that enters `StartReports` passes
/// here: a report's (`note`), and the harness session a `session/new` answer names (`of`,
/// `of_answer`), for a probe and a pooled agent alike.
pub(crate) fn known_id(id: Option<&str>) -> Option<&str> {
    id.filter(|s| !s.trim().is_empty())
}

/// The sessions whose mode or a config option a harness reported in full access while nothing
/// watched it: a probe, or a pooled agent no chat took yet (reviews 32, 41 and 46 of #23322). Any
/// such report counts, whatever the harness reported after it or answered `session/new` with, in
/// either order. Bounded: past `CAP` sessions, or for a report that names none (no id, or a
/// blank one), every session counts.
#[derive(Default)]
pub(crate) struct StartReports {
    sessions: Vec<String>,
    all: bool,
}

impl StartReports {
    const CAP: usize = 16;

    /// Whether one `session/update` notification's `params` reports full access: a mode, declared
    /// or not, or a config option.
    pub(crate) fn reports_full_access(params: &Value) -> bool {
        use super::start_mode::is_full_access;
        let update = &params["update"];
        match update["sessionUpdate"].as_str() {
            Some("current_mode_update") => {
                update["currentModeId"].as_str().is_some_and(is_full_access)
            }
            Some("config_option_update") => update["configOptions"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|o| o["currentValue"].as_str().is_some_and(is_full_access)),
            _ => false,
        }
    }

    /// Notes one `session/update` notification's `params`.
    pub(crate) fn note(&mut self, params: &Value) {
        if self.all || !Self::reports_full_access(params) {
            return;
        }
        // A blank id names no session (`known_id`): it counts for all, as a missing one does.
        let Some(sid) = known_id(params["sessionId"].as_str()) else {
            self.all = true;
            return;
        };
        if !self.sessions.iter().any(|s| s == sid) {
            if self.sessions.len() == Self::CAP {
                self.all = true;
            } else {
                self.sessions.push(sid.to_owned());
            }
        }
    }

    /// Whether the harness reported full access for its session `harness_session` (a subagent's
    /// are not its own, `on_update`); for any session when it is not known (none, or a blank id).
    pub(crate) fn of(&self, harness_session: Option<&str>) -> bool {
        // A blank id names no session (`known_id`): any report counts for it.
        self.all
            || known_id(harness_session)
                .map_or(!self.sessions.is_empty(), |sid| self.sessions.iter().any(|s| s == sid))
    }

    /// `of` for the harness session the `session/new` answer `new` names (none: not known).
    pub(crate) fn of_answer(&self, new: Option<&Value>) -> bool {
        self.of(new.and_then(|r| r["sessionId"].as_str()))
    }
}

/// Whether an agent runs in full access, and in which form. The one predicate: every check of
/// #23322 reads it.
pub(crate) fn runs_full_access(view: &FullAccessView) -> Option<FullAccessForm> {
    use super::start_mode::is_full_access;
    if super::subsession_guard::argv_full_access(&view.argv).is_some() {
        Some(FullAccessForm::Argv)
    } else if view.mode.as_deref().is_some_and(is_full_access) {
        Some(FullAccessForm::Mode)
    } else if view.undeclared_mode.as_deref().is_some_and(is_full_access) {
        Some(FullAccessForm::UndeclaredMode)
    } else if view.options.iter().any(|o| o["currentValue"].as_str().is_some_and(is_full_access)) {
        Some(FullAccessForm::Option)
    } else if view.reported {
        Some(FullAccessForm::Reported)
    } else {
        None
    }
}

/// Session `meta`'s config options, the `mode` one included.
fn config_options(meta: &crate::store::SessionMeta) -> impl Iterator<Item = &Value> {
    meta.config_options.as_deref().and_then(Value::as_array).into_iter().flatten()
}

/// The effective `sessions.allowFullAccess`: off when MDM or the team policy forces it off
/// (`managed`), else the settings file's answer (`file_allows`). A forced on adds nothing: the
/// person's own off still holds.
pub(crate) fn full_access_allowed_by(managed: Option<bool>, file_allows: bool) -> bool {
    managed != Some(false) && file_allows
}

/// Whether a permission policy auto-approves every request (`approve-all`, also spelled `yolo`):
/// the policy form of full access, refused or capped while the setting is off.
pub(crate) fn policy_is_full_access(policy: PermissionPolicy) -> bool {
    policy == PermissionPolicy::ApproveAll
}

/// Tests only: a pause right before a family message is written to its agent, so a test can
/// push MDM's off while one waits there: `arrived` fires there, the write waits for `release`.
/// Empty: no pause.
#[cfg(test)]
pub(super) type WriteSeam = std::sync::Mutex<
    Option<(tokio::sync::oneshot::Sender<()>, tokio::sync::oneshot::Receiver<()>)>,
>;

/// How long an MDM off push waits for the family messages and answers checked under the old
/// bound to be written before it cuts them (`hold_until_written`).
#[cfg(not(test))]
pub(super) const FAMILY_WRITE_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);
/// Tests: short, so a test sees a push cut and try again in a few seconds.
#[cfg(test)]
pub(super) const FAMILY_WRITE_BUDGET: std::time::Duration = std::time::Duration::from_secs(1);

/// MDM's bound as one operation reads it, once, at its entry (`Hub::mdm_snapshot`): every check
/// of that operation ranks under it, so no two of them read different pushes (review 86 of
/// #23322). `generation` counts the offs pushed (`full_access_off_now`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct MdmSnapshot {
    pub(super) off: bool,
    pub(super) generation: u64,
}

/// The family gate held for one message or answer (`Hub::family_gate`), the bound read once it
/// was taken, and the off pushes' cuts since.
pub(super) struct FamilyHold {
    pub(super) gate: tokio::sync::OwnedRwLockReadGuard<()>,
    pub(super) bound: MdmSnapshot,
    pub(super) cut: tokio::sync::watch::Receiver<u64>,
}

impl Hub {
    /// Tests only: waits at the pause a test set (`WriteSeam`), once.
    #[cfg(test)]
    pub(super) async fn pause_at_family_write(&self) {
        let seam = self.family_write_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some((arrived, release)) = seam {
            let _ = arrived.send(());
            let _ = release.await;
        }
    }

    /// A family message about to reach `session`'s agent (`provenance` a family prompt's, a
    /// sub-session's retry, or a continuation of either; any other prompt: Ok(None), no gate):
    /// checked again (`family_dispatch_check`) under the family gate, which the caller holds
    /// until the message is written (`hold_until_written`). An MDM off push waits on the gate
    /// (`full_access_turned_off`), so a message checked under the old bound is written, or cut,
    /// before the push returns, and one checked after it is checked under the off.
    pub(super) async fn family_gate(
        &self,
        session: &Session,
        provenance: Option<&Value>,
    ) -> Result<Option<FamilyHold>, RpcError> {
        if !super::subsession_guard::is_family(provenance) {
            return Ok(None);
        }
        let hold = self.family_hold().await;
        self.family_dispatch_check(session, provenance, hold.bound).await?;
        Ok(Some(hold))
    }

    /// MDM's bound now, read once for one operation (`MdmSnapshot`).
    pub(super) fn mdm_snapshot(&self) -> MdmSnapshot {
        let (_, generation, off) = self.full_access_off_now();
        MdmSnapshot { off, generation }
    }

    /// Takes the family gate (`family_gate`), for a family message or an ancestor's answer, and
    /// reads the bound under it.
    pub(super) async fn family_hold(&self) -> FamilyHold {
        let gate = self.family_gate.clone().read_owned().await;
        let mut cut = self.family_cut.subscribe();
        cut.borrow_and_update();
        FamilyHold { gate, bound: self.mdm_snapshot(), cut }
    }

    /// Holds `hold` until the message about to go to `session`'s agent under the returned fence
    /// is written. An off push that waited `FAMILY_WRITE_BUDGET` cuts it: a message still queued
    /// is then never written, and the agent whose writer has it already ends first, by an
    /// identity the cut proves (`Fence::cut_or_end`, reviews 81 and 82 of #23322), so nothing
    /// the push waited for reaches the agent after it. A cut that can not prove that in time
    /// tries again, holding the gate (review 84).
    pub(super) fn hold_until_written(
        self: &Arc<Self>,
        session: &Arc<Session>,
        hold: FamilyHold,
    ) -> crate::agent::Fence {
        let fence = crate::agent::Fence::default();
        Self::hold_fences(&session.id, hold, vec![fence.clone()]);
        fence
    }

    /// Whether a mode or policy that skips every approval may run now: the settings file under
    /// the value MDM or the team policy forces (`full_access_allowed_by`).
    pub fn full_access_allowed(&self) -> bool {
        full_access_allowed_by(
            self.full_access_managed(),
            super::start_mode::file_allows_full_access(),
        )
    }

    /// Whether approve-all (the policy form of full access) may answer requests itself: always,
    /// unless MDM or the team policy forces `sessions.allowFullAccess` off. The person's own off
    /// never capped a policy before #23322, and with MDM unset nothing changes. One read: an
    /// operation that reads the off more than once takes an `OffLatch` instead.
    pub(crate) fn approve_all_allowed(&self) -> bool {
        !self.full_access_managed_off()
    }

    /// Whether MDM or the team policy forces `sessions.allowFullAccess` off: the pane's mode menu
    /// then says "Managed by your organization" (`_acpmux/start_mode` `fullAccess`).
    pub(crate) fn full_access_managed_off(&self) -> bool {
        self.full_access_managed() == Some(false)
    }

    /// Whether MDM forces full access off, as the operation that took `off` sees it, while
    /// `session`'s agent runs in it (`runs_full_access`) or its end is pending
    /// (`full_access_end_pending`): `child_for` then hands it out only through `ensure_child`,
    /// which ends it first (review 2 of #26034).
    pub(super) fn managed_off_runs_full_access(&self, off: &OffLatch, session: &Session) -> bool {
        off.off()
            && (session.floor.full_access_end_pending.load(Ordering::SeqCst)
                || runs_full_access(&FullAccessView::of_session(session)).is_some())
    }

    /// Refuses to start an agent from a profile that pins full access in its argv while MDM
    /// forces it off, as the start that took `off` sees it: an upper bound the person's own
    /// profile does not override. Without MDM a pinned profile runs as it always has.
    pub(super) fn refuse_pinned_full_access(
        &self,
        off: &OffLatch,
        profile: &HarnessProfile,
    ) -> Result<(), RpcError> {
        if off.off() && runs_full_access(&FullAccessView::of_argv(&profile.argv)).is_some() {
            return Err(super::start_mode::full_access_off());
        }
        Ok(())
    }

    /// A start that passed `refuse_pinned_full_access` and then awaited (a cold Claude start, which
    /// never reaches `cap_full_access`): MDM may have forced full access off meanwhile, which the
    /// start's `off` counts. When the started agent runs in it by `view`, the agent stops and the
    /// chat stays open and idle. Without MDM's off nothing changes.
    pub(super) async fn refuse_started_in_full_access(
        &self,
        session: &Arc<Session>,
        off: &OffLatch,
        view: &FullAccessView,
    ) -> Result<(), RpcError> {
        if off.off() && runs_full_access(view).is_some() {
            self.stop_full_access_agent(session, true).await;
            return Err(super::start_mode::full_access_off());
        }
        Ok(())
    }

    /// For an agent started outside any session (a model probe) from `argv`, under the off it
    /// read as it began (`latch`): refused while MDM forces full access off for it and `argv` pins
    /// it, else what `full_access_forced_off` waits on
    /// (none when `argv` does not pin it). Review 25 of #23322: the probe holds it from before its
    /// start, so an off that lands while it starts or runs ends it, an unset after it too (review
    /// 46).
    pub(super) fn probe_bound(
        &self,
        latch: &OffLatch,
        argv: &[String],
    ) -> anyhow::Result<Option<OffWatch>> {
        if runs_full_access(&FullAccessView::of_argv(argv)).is_none() {
            return Ok(None);
        }
        // The probe's one read of the off (`latch`, review 77): an off that held as it began, or
        // came and went since, refuses it; one counted after is the probe's to end on.
        if latch.off() {
            anyhow::bail!("its profile pins full access, which MDM forces off");
        }
        Ok(Some(OffWatch { offs: latch.offs.clone(), seen: latch.seen }))
    }

    /// MDM's off as an operation that begins now sees it (`OffLatch`): its one read. A start, a
    /// pooled start, a pooled agent's report, a mode switch and an ask each take one at their
    /// entry and pass it down (reviews 73, 75 and 77 of #23322).
    pub(super) fn off_latch(&self) -> OffLatch {
        // The count and the state, read together (review 75): an off counted after this changes
        // the count.
        let (offs, seen, was_off) = self.full_access_off_now();
        #[cfg(test)]
        after_off_count(self);
        OffLatch { offs, seen, was_off }
    }

    /// MDM has just forced full access off (`apply_full_access_push`): an ask that read the
    /// policy before the push (`policy_for` reads the bound under the prompt's lock, where it
    /// decides) finishes first, and so does a family message or answer checked under the old
    /// bound (`family_gate`), written or, past `FAMILY_WRITE_BUDGET`, cut
    /// (`hold_until_written`), so no approve-all decision made after the push returns uses the
    /// old bound.
    /// It runs at every push of the off, as one may follow an agent that entered full access
    /// since. `changed`: this push turned it off; the pool drains only then.
    pub(super) async fn full_access_turned_off(&self, changed: bool) {
        // A restart's adoption holds again the fenced lines its hosts may not have written
        // (`hosts.rs` `hold_unwritten`): the push waits until it ran, so it waits for those too.
        let _ = self.adoption_ready.subscribe().wait_for(|ready| *ready).await;
        while tokio::time::timeout(FAMILY_WRITE_BUDGET, self.family_gate.write()).await.is_err() {
            self.family_cut.send_modify(|n| *n += 1);
        }
        for session in self.sessions() {
            drop(session.permissions.lock().unwrap_or_else(|e| e.into_inner()));
        }
        // Pooled agents started under the old bound (a profile pinning full access among them)
        // end; the pool starts again under the new one.
        if changed {
            self.drain_pool();
        }
        // Unavailable now, not only for the next start: an agent still in full access ends.
        self.end_every_managed_full_access(true).await;
    }
}

/// Ending what already runs (#23322): under the managed off, an agent that runs in full access
/// ends (`end_if_runs_full_access`) wherever `runs_full_access` turns true for it:
/// - the push that turns it off (`full_access_turned_off`, every session);
/// - a mode or option write, the harness's own included: `write_mode_state` wakes the hub's
///   background task (`idle.rs`), which checks every session;
/// - a mode switch that raced the push, checked again after it writes its mode (`Hub::forward`);
/// - a host a restart left, at adoption (`adopt_agent_hosts`) or at the next start
///   (`ensure_child`), with the mode it reported read back from the log first;
/// - the next start (`ensure_child`); `child_for` never hands such an agent out.
impl Hub {
    /// Under the managed off, ends `session`'s agent when it runs in full access
    /// (`counts_as_full_access`), and says what it did: its live child, and any host a restart
    /// left. Called under the session's spawn lock, with `off` the caller's one read of MDM's off
    /// (`full_access_managed_off`), taken where its operation begins: nothing here reads it again.
    pub(super) async fn end_if_runs_full_access(
        &self,
        session: &Session,
        off: bool,
    ) -> FullAccessEnd {
        if !off || !self.counts_as_full_access(session).await {
            return FullAccessEnd::NotInFullAccess;
        }
        self.end_managed_full_access(session).await
    }

    /// Whether `session`'s agent counts as in full access under MDM's off: by what acpmux keeps
    /// of it or its left host reported (`runs_full_access_by_records`), because an end of it
    /// failed and its host may still run (`FloorState::full_access_end_pending`, review 51 of
    /// #23322), because its reattached host's replay is not all in the log yet (`host_replaying`),
    /// because the host records cannot be read while this daemon hears no agent of it
    /// (`host_unknown`), because its left host cannot speak to this build (`unjudged_host`,
    /// #26337), or because this daemon no longer hears its host (`host_unheard`, review
    /// 64).
    async fn counts_as_full_access(&self, session: &Session) -> bool {
        if session.floor.full_access_end_pending.load(Ordering::SeqCst) {
            return true;
        }
        let unjudged = session.floor.unjudged_host.load(Ordering::SeqCst);
        if unjudged && !Self::host_record_gone(&session.id) {
            return true;
        }
        if Self::host_replaying(session).await {
            return true;
        }
        let records = Self::read_host_records();
        Self::host_unknown(session, records.as_ref()).await
            || self.runs_full_access_by_records(session, records.as_ref())
            || Self::host_unheard(session).await
    }

    /// Whether the host records could not be read (`records`) while `session` has no agent this
    /// daemon hears: a host a restart left may run unadopted, and what it kept in its buffer is in
    /// no log, so under MDM's off it counts as full access until the records can be read and the
    /// host ended (review 3 of #26055). An agent this daemon hears is judged by what it reported.
    async fn host_unknown(session: &Session, records: Option<&super::hosts::HostRecords>) -> bool {
        if records.is_some() {
            return false;
        }
        let child = session.child.lock().await.clone();
        match child {
            Some(child) => !child.is_alive().await,
            None => true,
        }
    }

    /// Whether `session`'s agent host may hold reports this daemon has not seen: its link broke
    /// (an entry could not be logged), its reader stopped (`ChildAgent::is_stopped`), or the link
    /// closed while the host still runs. What it reported since
    /// is unknown, so under MDM's off it counts as full access (review 64 of #23322); a request
    /// would reattach it, but the push does not wait for one. Host records that cannot be read
    /// do not prove the host gone (`host_record_gone`, review 67). A slot held past its bound
    /// counts too, as for `host_replaying`.
    async fn host_unheard(session: &Session) -> bool {
        let wait = super::shutdown::SHUTDOWN_GRACE;
        let Ok(slot) = tokio::time::timeout(wait, session.child.lock()).await else { return true };
        let child = (*slot).clone();
        drop(slot);
        let Some(child) = child.filter(|c| c.host_record().is_some()) else { return false };
        child.is_broken()
            || child.is_stopped()
            || (!child.is_alive().await && !Self::host_record_gone(&session.id))
    }

    /// Whether `session`'s agent host was reattached and its replay is not all in the log yet:
    /// what it kept while its link was down is unknown until then, so under MDM's off it counts as
    /// full access, and its log is not read back (nor `left_host_read` kept) before the replay is
    /// in it (review 1 of #26057).
    ///
    /// The wait for the agent slot is bounded, as an end's is (review 81 of #23322): a slot held
    /// past it (a stop waiting on its host) keeps no push waiting. The replay is then not known,
    /// so the agent counts as in full access; the end that follows marks itself pending while the
    /// slot stays held (`end_managed_full_access`).
    async fn host_replaying(session: &Session) -> bool {
        let wait = super::shutdown::SHUTDOWN_GRACE;
        match tokio::time::timeout(wait, session.child.lock()).await {
            Ok(slot) => slot.as_ref().is_some_and(|c| c.replay_pending()),
            Err(_) => true,
        }
    }

    /// Whether `session`'s agent runs in full access by what acpmux keeps of it, or, for a host a
    /// restart left, by what that host reported since it started (`reported_by_left_host`);
    /// `records`, the host records as read (`read_host_records`), None when they could not be.
    /// Once that read finds no full access, what this daemon keeps is complete (every later report
    /// reaches it live), so the log is read once per host, not at each check
    /// (`FloorState::left_host_read`, cleared at each `host_started`), kept and trusted only while
    /// the host records can be read (review 69): records that cannot may leave a live host
    /// unproven, so its log is read again at each check meanwhile. A host whose own record this
    /// build cannot read is never adopted, so its log does not hear what it did since: under MDM's
    /// off it counts as in full access (review 2 of #26055). A log that cannot be read says nothing
    /// either way: under MDM's off the host counts as in full access (review 61). Host records
    /// that cannot be read do not prove the host gone, so its log is read back then too
    /// (`host_record_gone`, review 67).
    fn runs_full_access_by_records(
        &self,
        session: &Session,
        records: Option<&super::hosts::HostRecords>,
    ) -> bool {
        if runs_full_access(&FullAccessView::of_session(session)).is_some() {
            return true;
        }
        if records.is_some_and(|r| !r.live.contains(&session.id)) {
            return false;
        }
        if records.is_some_and(|r| r.unreadable.contains(&session.id)) {
            return true;
        }
        // A kept read holds only while the records can be read (review 2 of #26055).
        if records.is_some() && session.floor.left_host_read.load(Ordering::SeqCst) {
            return false;
        }
        let reported = self
            .reported_by_left_host(session)
            .is_none_or(|view| runs_full_access(&view).is_some());
        if !reported && records.is_some() {
            session.floor.left_host_read.store(true, Ordering::SeqCst);
        }
        reported
    }

    /// What the host a restart left last reported of its modes and options, read back from the
    /// log since its `host_started`: the answers to the session's own start (`session/new`,
    /// `load`, `resume`, `fork`), its `set_mode` and `set_config_option` answers, and its own
    /// `current_mode_update` and `config_option_update` records. Saved meta is written only at
    /// some points, so after a crash or a reload it can be older than these (review 51 of #23322).
    /// A mode reported with or without declared modes counts the same (`mode`). A subagent's
    /// update is not the session's own: the tap marks it
    /// (`SubagentTree::annotate`) only for a thread that is not the session's own, as `on_update`
    /// skips it live. An update a load replays (`.replay`) counts, as `on_update` writes it too; a
    /// fork's answer describes the new chat, so it does not (review 62).
    ///
    /// The read is strict (review 62): it starts at the newest `host_started` and needs every
    /// record from there, one `seq` after another (`Hub::append` numbers them so), each one whole
    /// (`Store::scan_strict`, review 63: a torn last record leaves no gap). None when the log
    /// could not be read, has no `host_started`, or lost a record since (a torn or malformed line,
    /// a failed append): what the host reported is then unknown.
    fn reported_by_left_host(&self, session: &Session) -> Option<FullAccessView> {
        use crate::rpc::method;
        let own = session.meta().agent_session_id;
        let own = known_id(own.as_deref());
        let mut modes: Option<Value> = None;
        let mut mode: Option<String> = None;
        let mut options: Option<Value> = None;
        // The session's own requests that change modes, by id, until their answer.
        let mut asked: HashMap<String, (String, Value)> = HashMap::new();
        let requests = [
            method::SESSION_NEW,
            method::SESSION_LOAD,
            method::SESSION_RESUME,
            method::SESSION_SET_MODE,
            method::SESSION_SET_CONFIG_OPTION,
        ];
        let mut start = None;
        let found = self.store.scan_kinds(&session.id, &["host_started"], &mut |e| {
            if e.dir == "mux" {
                start = Some(e.seq);
            }
            true
        });
        let Some(start) = start.filter(|_| found.is_ok()) else {
            tracing::warn!(session = %session.id, "its left host's start is not in its log");
            return None;
        };
        // Debug builds only: `ACPMUX_TEST_LEFT_HOST_SCAN_FAILS` makes this read fail before it reads
        // anything, as an unreadable log does, so the daemon's integration tests can drive that
        // path. Release builds have no seam.
        // `ACPMUX_TEST_LEFT_HOST_SCAN_EMPTY` makes it read no record, as a log whose segments
        // could not be listed this time does.
        #[cfg(debug_assertions)]
        let (fails, empty) = (
            std::env::var_os("ACPMUX_TEST_LEFT_HOST_SCAN_FAILS").is_some(),
            std::env::var_os("ACPMUX_TEST_LEFT_HOST_SCAN_EMPTY").is_some(),
        );
        #[cfg(not(debug_assertions))]
        let (fails, empty) = (false, false);
        let scan = |visit: &mut dyn FnMut(crate::store::EventRecord) -> bool| {
            if fails {
                return Err(anyhow::anyhow!("the log could not be read"));
            }
            if empty {
                return Ok(());
            }
            self.store.scan_strict(&session.id, start.saturating_sub(1), visit)
        };
        let mut next = start;
        let mut lost = false;
        let scanned = scan(&mut |e: crate::store::EventRecord| {
            if e.seq != next {
                lost = true;
                return false;
            }
            next += 1;
            let its_own = || {
                e.msg.pointer("/params/_meta/acpmux/subagent").is_none()
                    || own.is_some_and(|own| {
                        known_id(e.msg.pointer("/params/sessionId").and_then(Value::as_str))
                            == Some(own)
                    })
            };
            let text = |v: Option<&Value>| v.and_then(Value::as_str).map(str::to_owned);
            let kind = match e.kind.as_str() {
                "current_mode_update.replay" => "current_mode_update",
                "config_option_update.replay" => "config_option_update",
                kind => kind,
            };
            match (e.dir.as_str(), kind) {
                ("mux", "host_started") => {
                    (modes, mode, options) = (None, None, None);
                    asked.clear();
                }
                ("in", "current_mode_update") if its_own() => {
                    mode = text(e.msg.pointer("/params/update/currentModeId")).or(mode.take());
                }
                ("in", "config_option_update") if its_own() => {
                    if let Some(o) =
                        e.msg.pointer("/params/update/configOptions").filter(|o| !o.is_null())
                    {
                        options = Some(o.clone());
                    }
                }
                ("out", m) if requests.contains(&m) => {
                    if let Some(id) = e.msg.get("id") {
                        let params = e.msg.get("params").cloned().unwrap_or(Value::Null);
                        asked.insert(id.to_string(), (m.to_owned(), params));
                    }
                }
                ("in", "response") => {
                    let Some((m, params)) =
                        e.msg.get("id").and_then(|id| asked.remove(&id.to_string()))
                    else {
                        return true;
                    };
                    let Some(res) = e.msg.get("result") else { return true };
                    match m.as_str() {
                        method::SESSION_SET_MODE => {
                            mode = text(res.get("currentModeId"))
                                .or_else(|| text(res.get("modeId")))
                                .or_else(|| text(params.get("modeId")))
                                .or(mode.take());
                        }
                        method::SESSION_SET_CONFIG_OPTION => {
                            // An answer without its options took the value asked (review 60).
                            match res.get("configOptions").filter(|o| !o.is_null()) {
                                Some(o) => options = Some(o.clone()),
                                None => {
                                    if let Some(asked) = asked_option(&params) {
                                        let mut all = options
                                            .as_ref()
                                            .and_then(Value::as_array)
                                            .cloned()
                                            .unwrap_or_default();
                                        merge_asked_option(&mut all, asked);
                                        options = Some(Value::Array(all));
                                    }
                                }
                            }
                            if params.get("configId").and_then(Value::as_str) == Some("mode") {
                                mode = text(res.get("currentModeId")).or(mode.take());
                            }
                        }
                        _ => {
                            if let Some(m) = res.get("modes").filter(|m| m.is_object()) {
                                modes = Some(m.clone());
                                mode = None;
                            }
                            if let Some(o) = res.get("configOptions").filter(|o| !o.is_null()) {
                                options = Some(o.clone());
                            }
                        }
                    }
                }
                _ => {}
            }
            true
        });
        if let Err(e) = scanned {
            tracing::warn!(session = %session.id, "its left host's log could not be read back: {e:#}");
            return None;
        }
        if lost {
            tracing::warn!(session = %session.id, seq = next, "its left host's log lost a record");
            return None;
        }
        // The read starts at the host's start: one that did not reach it read nothing of the
        // host (review 2 of #26054).
        if next == start {
            tracing::warn!(session = %session.id, "its left host's log read back no record");
            return None;
        }
        Some(FullAccessView {
            argv: Vec::new(),
            mode: mode.or_else(|| text_at(modes.as_ref(), "currentModeId")),
            undeclared_mode: None,
            options: options.as_ref().and_then(Value::as_array).cloned().unwrap_or_default(),
            reported: false,
        })
    }

    /// Every agent still running in full access under the managed off ends now (a turn in
    /// progress ends with it), each under its session's spawn lock, checked again there. `off`:
    /// the caller's one read of MDM's off (`end_if_runs_full_access`).
    ///
    /// The wait for each spawn lock is bounded (review 1 of #26034): an operation that holds it
    /// longer (a start ending an agent that does not end) keeps no push or background check from
    /// the other sessions. That session's end stays pending (`full_access_end_pending`): its next
    /// start ends the agent first, and the background check tries again once woken here; it
    /// stops trying once it holds the lock.
    pub(super) async fn end_every_managed_full_access(&self, off: bool) {
        if !off {
            return;
        }
        let wait = super::shutdown::SHUTDOWN_GRACE * 2;
        for session in self.sessions() {
            if !self.counts_as_full_access(&session).await {
                continue;
            }
            // What waits on an agent this daemon no longer hears is answered first: a start
            // waiting on its `initialize` holds the spawn lock below, and its link may have broken
            // while MDM was unset, when nothing failed it (review 3 of #26059). The agent slot is
            // waited on only so long, as the end's is: a slot held elsewhere keeps no push
            // waiting, and the end below marks itself pending.
            let held = tokio::time::timeout(super::shutdown::SHUTDOWN_GRACE, session.child.lock());
            let child = held.await.ok().and_then(|slot| (*slot).clone());
            if let Some(child) = child.filter(|c| c.host_record().is_some()) {
                child.fail_pending_if_unheard().await;
            }
            let Ok(_spawning) = tokio::time::timeout(wait, session.spawn_lock.lock()).await else {
                tracing::warn!(session = %session.id, "MDM forces full access off: its agent is busy starting or stopping; its end is tried again");
                session.floor.full_access_end_pending.store(true, Ordering::SeqCst);
                self.idle_wake.notify_one();
                continue;
            };
            self.end_if_runs_full_access(&session, off).await;
        }
    }

    /// Ends the agent of a session that runs in full access while MDM forces it off: the live
    /// child and any host a restart left. The start that follows runs in a mode that asks, or
    /// refuses a profile that pins full access (`refuse_pinned_full_access`). A host whose end its
    /// nonce does not prove may still run in full access: what says so stays, so the next check
    /// (a start, a push, the background check) tries again, and nothing reaches it meanwhile
    /// (`FullAccessEnd::StillRunning`, review 51 of #23322). So does one whose host records
    /// cannot be read (`host_record_gone`, review 66).
    pub(super) async fn end_managed_full_access(&self, session: &Session) -> FullAccessEnd {
        // Bounded, as the spawn lock's wait is (review 2 of #26034): a stop that holds the agent
        // slot while its agent ends keeps no push waiting. The end stays pending, tried again.
        let wait = super::shutdown::SHUTDOWN_GRACE * 2;
        let Ok(mut slot) = tokio::time::timeout(wait, session.child.lock()).await else {
            tracing::warn!(session = %session.id, "MDM forces full access off: its agent is busy stopping; its end is tried again");
            session.floor.full_access_end_pending.store(true, Ordering::SeqCst);
            self.idle_wake.notify_one();
            return FullAccessEnd::StillRunning;
        };
        let child = slot.take();
        // Under the slot's lock the inbound loop checks a mode or option report under: one it
        // checked before this is applied before this, and one after is dropped, not applied to
        // the agent after it (`permissions.rs`, reviews 3, 5 and 6 of #26052).
        if let Some(child) = &child {
            session.floor.retired_through.fetch_max(child.generation, Ordering::SeqCst);
        }
        drop(slot);
        let ended = child.is_some() || !Self::host_record_gone(&session.id);
        if let Some(child) = &child {
            // Ended on purpose, as a stop is (reviews 1 to 3 of #26034): its turn gets no
            // continuation and no failover, nothing it asked stays asking, and its exit and its
            // turn's end leave the chat idle, not disconnected. Marked under the lock a turn's end
            // reads it under (`finish_turn`): an end either sees it or is followed by the idle
            // below. The next prompt starts an agent under the bound.
            {
                let _held = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
                child.end_on_purpose();
            }
            self.stop_auto_resume(session);
            self.cancel_pending_permissions(session);
            self.idle_unless_closed(session);
        }
        if let Some(child) = child {
            // Bounded: a host whose link stopped reading never answers the terminate; it is then
            // ended by its nonce below (review 27 of #23322).
            let grace = super::shutdown::SHUTDOWN_GRACE;
            if tokio::time::timeout(grace * 2, child.terminate(grace)).await.is_err() {
                tracing::warn!(session = %session.id, "its full-access agent did not end in time; its host is ended");
            }
            // What waited on it is answered now: a reader that stopped reads no exit for it
            // (review 65 of #23322).
            child.fail_pending().await;
            self.cancel_pending_permissions(session);
        }
        if !Self::host_record_gone(&session.id) {
            self.end_unadopted_host(session).await;
            if !Self::host_record_gone(&session.id) {
                tracing::warn!(session = %session.id, "MDM forces full access off: its full-access agent host did not end; it is not reached until it does");
                self.append(session, "mux", "full_access_end_failed", json!({"reason": "managed"}));
                session.floor.full_access_end_pending.store(true, Ordering::SeqCst);
                return FullAccessEnd::StillRunning;
            }
        }
        session.floor.full_access_end_pending.store(false, Ordering::SeqCst);
        session.floor.unjudged_host.store(false, Ordering::SeqCst);
        // What its agent reported and nothing applied goes with it; a report it still sends is
        // not counted (its tap's epoch is gone, review 4 of #26052).
        {
            let _m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            session.floor.report_epoch.fetch_add(1, Ordering::SeqCst);
            session.floor.unapplied_full_access.store(0, Ordering::SeqCst);
        }
        // What only the ended agent said goes with it: the mode it reported without declaring
        // modes, the values bare answers took, and a full-access value of any option (the next
        // agent reports its own, and `replay_config` skips a null).
        *session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()) = None;
        session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner()).clear();
        let scrubbed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.config_options.as_mut().is_some_and(|options| {
                options.update_matching(
                    |o| o["currentValue"].as_str().is_some_and(super::start_mode::is_full_access),
                    |o| o["currentValue"] = Value::Null,
                )
            })
        };
        if scrubbed {
            self.save_meta(session);
        }
        if ended {
            // Its turn's end may have set another state meanwhile.
            self.idle_unless_closed(session);
            tracing::info!(session = %session.id, "MDM forces full access off: its full-access agent ended");
            self.append(session, "mux", "full_access_ended", json!({"reason": "managed"}));
        }
        FullAccessEnd::Ended
    }
}

/// The option a `set_config_option` request asks for, as an option record:
/// `{"id": configId, "currentValue": value}`.
pub(super) fn asked_option(params: &Value) -> Option<Value> {
    let id = params.get("configId").and_then(Value::as_str)?;
    let value = params.get("value").filter(|v| !v.is_null())?;
    Some(json!({"id": id, "currentValue": value}))
}

/// Puts `asked` (`asked_option`) into `options`: the option of its id takes its value, or it is
/// added.
pub(super) fn merge_asked_option(options: &mut Vec<Value>, asked: Value) {
    match options.iter_mut().find(|o| o.get("id") == asked.get("id")) {
        Some(o) => o["currentValue"] = asked["currentValue"].clone(),
        None => options.push(asked),
    }
}

/// Records a `set_config_option` answer `res` to the request that asked `asked`
/// (`asked_option`), from a client's switch (`turns.rs`) or the replay of a chat's options on a
/// new agent (`replay_config`). A bare answer (no options, or null ones) took the value asked:
/// the full-access bound reads it (reviews 60 and 61 of #23322). An answer with its options says
/// what each holds now. Kept in answer order: the harness's own option reports never clear it, as
/// one sent before this answer may be applied after it (review 1 of #26058).
pub(super) fn record_option_answer(session: &Session, res: &Value, asked: Option<Value>) {
    let mut kept = session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner());
    match res.get("configOptions").and_then(Value::as_array) {
        Some(reported) => kept.retain(|o| !reported.iter().any(|r| r.get("id") == o.get("id"))),
        None => {
            if let Some(asked) = asked {
                merge_asked_option(&mut kept, asked);
            }
        }
    }
}

impl Hub {
    /// `session` is idle unless it was closed.
    fn idle_unless_closed(&self, session: &Session) {
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
    }
}

/// The string at `key` of an object, if any.
fn text_at(v: Option<&Value>, key: &str) -> Option<String> {
    v.and_then(|v| v.get(key)).and_then(Value::as_str).map(str::to_owned)
}

/// Whether `params` of a `session/update` the session's harness sent reports full access for the
/// session itself, not one of its subagents (`on_update` skips those): counted by the tap as it
/// is logged and taken back once the inbound loop applied it (`FloorState::unapplied_full_access`).
pub(super) fn own_full_access_report(session: &Session, params: &Value) -> bool {
    StartReports::reports_full_access(params)
        && !params["sessionId"].as_str().is_some_and(|sid| {
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).owns(sid)
        })
}

/// What `end_if_runs_full_access` did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum FullAccessEnd {
    /// The agent does not run in full access (or MDM does not force it off).
    NotInFullAccess,
    /// It ran in full access and has ended.
    Ended,
    /// It ran in full access and its host may still run: its end by nonce failed. Nothing may
    /// reach it; the next check tries again.
    StillRunning,
}

#[cfg(test)]
thread_local! {
    /// Test seam (review 75): runs right after a start read MDM's off.
    pub(super) static AFTER_OFF_COUNT: std::cell::Cell<Option<fn(&Hub)>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
thread_local! {
    /// Test seam (review 3 of #26052): runs between `FullAccessView::of_session`'s reads.
    pub(super) static BETWEEN_VIEW_READS: std::cell::Cell<Option<fn(&Session)>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn between_view_reads(session: &Session) {
    if let Some(f) = BETWEEN_VIEW_READS.take() {
        f(session);
    }
}

#[cfg(test)]
fn after_off_count(hub: &Hub) {
    if let Some(f) = AFTER_OFF_COUNT.take() {
        f(hub);
    }
}

#[cfg(test)]
thread_local! {
    /// Test seam (review 123): runs as a start (`ensure_child`) or an ask (`handle_permission_for`)
    /// is entered, before it waits on anything.
    pub(super) static AT_OPERATION_ENTRY: std::cell::Cell<Option<fn(&Hub)>> = const { std::cell::Cell::new(None) };
}

/// Runs the `AT_OPERATION_ENTRY` seam, once.
#[cfg(test)]
pub(super) fn operation_entry(hub: &Hub) {
    if let Some(f) = AT_OPERATION_ENTRY.take() {
        f(hub);
    }
}

/// Test seam (debug builds): the pooled starts begun (`pool_want`), for `Hub::claim_blip_seam`.
#[cfg(debug_assertions)]
pub(super) static POOL_STARTS: std::sync::LazyLock<tokio::sync::watch::Sender<u64>> =
    std::sync::LazyLock::new(|| tokio::sync::watch::channel(0).0);

impl Hub {
    /// Test seam (debug builds) at a pool claim, right after its read of MDM's off: when the file
    /// `ACPMUX_TEST_OFF_BLIP_FILE` names exists, the off comes and goes once; a file that says
    /// "then-start" then waits (at most 10 s) for a pooled start to begin, so the start reads the
    /// off after the claim did and the claim waits on it (reviews 121, 122 and 124 of #23322).
    #[cfg(debug_assertions)]
    pub(super) async fn claim_blip_seam(&self) {
        let Some(file) = std::env::var_os("ACPMUX_TEST_OFF_BLIP_FILE") else { return };
        let Ok(what) = std::fs::read_to_string(&file) else { return };
        let mut starts = POOL_STARTS.subscribe();
        let seen = *starts.borrow_and_update();
        if std::fs::remove_file(file).is_err() {
            return;
        }
        self.update_start_mode_state(None, |s| s.full_access_managed = Some(false));
        self.update_start_mode_state(None, |s| s.full_access_managed = None);
        if what.trim() == "then-start" {
            let begun = starts.wait_for(|n| *n > seen);
            let _ = tokio::time::timeout(std::time::Duration::from_secs(10), begun).await;
        }
    }

    /// Test seam (debug builds): when the file `ACPMUX_TEST_OFF_BLIP_FILE` names exists, MDM's off
    /// comes and goes once, at the next pooled start, after it read the off (reviews 73, 75 and 77
    /// of #23322). A pool claim has its own (`claim_blip_seam`).
    #[cfg(debug_assertions)]
    pub(super) fn off_blip_seam(&self) {
        let Some(file) = std::env::var_os("ACPMUX_TEST_OFF_BLIP_FILE") else { return };
        if std::fs::remove_file(file).is_ok() {
            self.update_start_mode_state(None, |s| s.full_access_managed = Some(false));
            self.update_start_mode_state(None, |s| s.full_access_managed = None);
        }
    }
}

/// MDM's off as one operation (a start, a probe, a pooled agent, a switch, an ask) saw it: on
/// when it was off as the operation began, or began while it ran, though an unset followed
/// (reviews 71, 73, 75 and 77 of #23322). The operation's only read of MDM's off. A pooled
/// entry keeps its start's (`Pooled::started`), so an off it lived through counts at its take.
#[derive(Clone)]
pub(super) struct OffLatch {
    offs: tokio::sync::watch::Receiver<u64>,
    seen: u64,
    was_off: bool,
}

impl OffLatch {
    /// Whether MDM's off holds for this start. Takes no lock of the start-mode state, so it may
    /// be read under the pool lock (review 76).
    pub(super) fn off(&self) -> bool {
        self.was_off || self.began()
    }

    /// Whether an off began since this start read it, though an unset may have followed. Takes no
    /// lock of the start-mode state either.
    pub(super) fn began(&self) -> bool {
        *self.offs.borrow() != self.seen
    }

    /// The earlier of two reads (`self` and `other`, of one daemon): on whenever either is. The
    /// off count only grows, so the read with the lower count saw every off the later one saw. A
    /// pooled entry's start and claim reads join the chat's that takes it (review 122 of #23322).
    pub(super) fn merge(&self, other: &OffLatch) -> OffLatch {
        let seen = self.seen.min(other.seen);
        let was_off = (self.seen == seen && self.was_off) || (other.seen == seen && other.was_off);
        OffLatch { offs: self.offs.clone(), seen, was_off }
    }

    /// Whether a full-access mode may run for this operation: the settings file under MDM's off
    /// as the operation saw it (`Hub::full_access_allowed`).
    pub(super) fn allows_full_access(&self) -> bool {
        full_access_allowed_by(
            self.off().then_some(false),
            super::start_mode::file_allows_full_access(),
        )
    }

    /// Resolves once the start's harness reported full access (`any`; `reported` is notified on
    /// each such report) while MDM's off holds for it (`off`). Never otherwise: the start's own
    /// timeout bounds it.
    pub(super) async fn reported_under_off(
        &self,
        reported: &tokio::sync::Notify,
        any: impl Fn() -> bool,
    ) {
        let mut offs = self.offs.clone();
        loop {
            let began = *offs.borrow_and_update() != self.seen;
            if (self.was_off || began) && any() {
                return;
            }
            tokio::select! {
                changed = offs.changed() => if changed.is_err() { break },
                () = reported.notified() => {}
            }
        }
        std::future::pending().await
    }
}

/// The times MDM forced full access off (`Hub::full_access_off_now`), and the count a probe
/// started under (`probe_bound`).
pub(super) struct OffWatch {
    offs: tokio::sync::watch::Receiver<u64>,
    seen: u64,
}

/// Resolves once MDM forces full access off, for a probe that holds `bound` (`probe_bound`); never
/// for one that does not pin full access. An off that came before this call counts too, though
/// an unset followed it.
pub(super) async fn full_access_forced_off(bound: Option<&mut OffWatch>) {
    if let Some(OffWatch { offs, seen }) = bound
        && offs.wait_for(|n| *n != *seen).await.is_ok()
    {
        return;
    }
    std::future::pending().await
}

#[cfg(test)]
#[path = "full_access_bound_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "one_read_tests.rs"]
mod one_read_tests;
