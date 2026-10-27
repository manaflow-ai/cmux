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
//!   (`RemoteFloor::undeclared_mode`);
//! - option: any config option holds a full-access value, the `mode` one included (a harness can
//!   keep `modes.currentModeId` at an asking mode while its `mode` option says full access);
//! - reported: its harness reported full access while nothing watched it (`StartReports`).
//!
//! Each form is judged by the shared rule (`start_mode::is_full_access`). A start whose profile
//! pins full access is refused (`refuse_pinned_full_access`), and so is one that comes up in it
//! (`cap_full_access`).

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
        let undeclared_mode =
            session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let meta = session.meta();
        Self {
            mode: crate::web_modes::mode_of(&meta),
            undeclared_mode,
            options: config_options(&meta).cloned().collect(),
            argv: meta.harness_argv,
            reported: false,
        }
    }
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
        // A blank id names no session (review 70): it counts for all, as a missing one does.
        let Some(sid) = params["sessionId"].as_str().filter(|s| !s.trim().is_empty()) else {
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
        // A blank id names no session (review 74): any report counts for it.
        let harness_session = harness_session.filter(|s| !s.trim().is_empty());
        self.all
            || harness_session
                .map_or(!self.sessions.is_empty(), |sid| self.sessions.iter().any(|s| s == sid))
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
    meta.config_options.as_ref().and_then(Value::as_array).into_iter().flatten()
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
const FAMILY_WRITE_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);
/// Tests: short, so a test sees a push cut and try again in a few seconds.
#[cfg(test)]
const FAMILY_WRITE_BUDGET: std::time::Duration = std::time::Duration::from_secs(1);

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
    gate: tokio::sync::OwnedRwLockReadGuard<()>,
    pub(super) bound: MdmSnapshot,
    cut: tokio::sync::watch::Receiver<u64>,
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
        let FamilyHold { gate, bound, mut cut } = hold;
        let (held, id) = (fence.clone(), session.id.clone());
        // task-owner: ends once the message settles (every carrier settles it) or is cut; each
        // try to end its writer below is bounded.
        tokio::spawn(async move {
            tokio::select! {
                biased;
                () = held.settled() => {}
                _ = cut.changed() => {
                    while !held.cut_or_end(FAMILY_WRITE_BUDGET).await {
                        tracing::warn!(session = %id, checked_at = bound.generation, "an MDM off push cut a family message whose agent did not end in time; trying again");
                        tokio::time::sleep(FAMILY_WRITE_BUDGET).await;
                    }
                }
            }
            drop(gate);
        });
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
    /// never capped a policy before #23322, and with MDM unset nothing changes.
    pub(crate) fn approve_all_allowed(&self) -> bool {
        !self.full_access_managed_off()
    }

    /// Whether MDM or the team policy forces `sessions.allowFullAccess` off: the pane's mode menu
    /// then says "Managed by your organization" (`_acpmux/start_mode` `fullAccess`).
    pub(crate) fn full_access_managed_off(&self) -> bool {
        self.full_access_managed() == Some(false)
    }

    /// Whether MDM forces full access off while `session`'s agent runs in it (`runs_full_access`).
    pub(super) fn managed_off_runs_full_access(&self, session: &Session) -> bool {
        self.full_access_managed_off()
            && runs_full_access(&FullAccessView::of_session(session)).is_some()
    }

    /// Refuses to start an agent from a profile that pins full access in its argv while MDM
    /// forces it off: an upper bound the person's own profile does not override. Without MDM a
    /// pinned profile runs as it always has.
    pub(super) fn refuse_pinned_full_access(
        &self,
        profile: &HarnessProfile,
    ) -> Result<(), RpcError> {
        if self.full_access_managed_off()
            && runs_full_access(&FullAccessView::of_argv(&profile.argv)).is_some()
        {
            return Err(super::start_mode::full_access_off());
        }
        Ok(())
    }

    /// A start that passed `refuse_pinned_full_access` and then awaited (a cold Claude start, which
    /// never reaches `cap_full_access`): MDM may have forced full access off meanwhile. When the
    /// started agent runs in it by `view`, the agent stops and the chat stays open and idle. Without
    /// MDM's off nothing changes.
    pub(super) async fn refuse_started_in_full_access(
        &self,
        session: &Arc<Session>,
        view: &FullAccessView,
    ) -> Result<(), RpcError> {
        if self.full_access_managed_off() && runs_full_access(view).is_some() {
            self.stop_full_access_agent(session).await;
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

    /// MDM's off as a start that begins now sees it (`OffLatch`).
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
    /// `changed`: this push turned it off; the pool drains only then.
    pub(super) async fn full_access_turned_off(&self, changed: bool) {
        while tokio::time::timeout(FAMILY_WRITE_BUDGET, self.family_gate.write()).await.is_err() {
            self.family_cut.send_modify(|n| *n += 1);
        }
        for session in self.sessions() {
            drop(session.permissions.lock().unwrap_or_else(|e| e.into_inner()));
        }
        if !changed {
            return;
        }
        // Pooled agents started under the old bound (a profile pinning full access among them)
        // end; the pool starts again under the new one.
        self.drain_pool();
    }
}

#[cfg(test)]
thread_local! {
    /// Test seam (review 75): runs right after a start read MDM's off.
    pub(super) static AFTER_OFF_COUNT: std::cell::Cell<Option<fn(&Hub)>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn after_off_count(hub: &Hub) {
    if let Some(f) = AFTER_OFF_COUNT.take() {
        f(hub);
    }
}

/// MDM's off as one start (a probe, a pooled agent) saw it: on when it was off as the start
/// began, or began while it ran, though an unset followed (reviews 71 and 73 of #23322).
pub(super) struct OffLatch {
    offs: tokio::sync::watch::Receiver<u64>,
    seen: u64,
    was_off: bool,
}

impl OffLatch {
    /// Whether MDM's off holds for this start. Takes no lock of the start-mode state, so it may
    /// be read under the pool lock (review 76).
    pub(super) fn off(&self) -> bool {
        self.was_off || *self.offs.borrow() != self.seen
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
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> FullAccessView {
        let mut argv = vec!["agent".to_owned()];
        argv.extend(args.iter().map(|a| (*a).to_owned()));
        FullAccessView::of_argv(&argv)
    }

    /// Every form the reviews of #23322 found, and what is not full access.
    #[test]
    fn each_form_of_full_access_is_found() {
        use FullAccessForm::*;
        for (pinned, why) in [
            (&["--yolo"][..], "round 1: --yolo"),
            (&["--permission-mode=bypassPermissions"], "round 1: bypass, one word"),
            (&["--permission-mode", "bypassPermissions"], "round 1: bypass, two words"),
            (&["-sdanger-full-access", "-a", "never"], "round 2: -s joined"),
            (&["--sandbox", "danger-full-access"], "round 2: --sandbox"),
            (&["-csandbox_mode=danger-full-access"], "round 2: -c joined"),
            (&["-c", "sandbox_mode=\"danger-full-access\""], "round 2: -c quoted"),
            (&["-y"], "round 2: -y"),
            (&["--approval-mode", "yolo"], "round 2: --approval-mode yolo"),
            (&["--dangerously-skip-permissions"], "skip permissions"),
        ] {
            assert_eq!(runs_full_access(&argv(pinned)), Some(Argv), "{why}");
        }
        for (asks, why) in [
            (&["--permission-mode", "default"][..], "an asking pinned mode"),
            (&["-s", "workspace-write"], "a narrower sandbox"),
            (&[], "nothing pinned"),
        ] {
            assert_eq!(runs_full_access(&argv(asks)), None, "{why}");
        }
        let mode = |m: &str| FullAccessView { mode: Some(m.to_owned()), ..Default::default() };
        assert_eq!(runs_full_access(&mode("agent-full-access")), Some(Mode));
        assert_eq!(runs_full_access(&mode("bypassPermissions")), Some(Mode));
        assert_eq!(runs_full_access(&mode("agent")), None);
        // Round 5: a harness that declares no modes reports one.
        let undeclared =
            |m: &str| FullAccessView { undeclared_mode: Some(m.to_owned()), ..Default::default() };
        assert_eq!(runs_full_access(&undeclared("bypassPermissions")), Some(UndeclaredMode));
        assert_eq!(runs_full_access(&undeclared("default")), None);
        // Round 5: a config option other than `mode`.
        let option = |id: &str, v: &str| FullAccessView {
            options: vec![json!({"id": id, "currentValue": v})],
            ..Default::default()
        };
        assert_eq!(runs_full_access(&option("sandbox", "danger-full-access")), Some(Option));
        assert_eq!(runs_full_access(&option("sandbox", "workspace-write")), None);
        // Round 8: the `mode` option says full access while `modes.currentModeId` asks.
        let split = FullAccessView {
            mode: Some("normal".to_owned()),
            options: vec![json!({"id": "mode", "currentValue": "full-access"})],
            ..Default::default()
        };
        assert_eq!(runs_full_access(&split), Some(Option));
    }

    /// Review 46: an off a probe started before ends it, though an unset follows it before the
    /// probe looks.
    #[tokio::test]
    async fn an_off_ends_a_probe_though_an_unset_follows_it() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config =
            serde_json::from_value(json!({"harnesses": {"fake": {"argv": ["python3", fake]}}}))
                .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let latch = hub.off_latch();
        let mut bound =
            hub.probe_bound(&latch, &["agent".to_owned(), "--yolo".to_owned()]).unwrap();
        hub.apply_full_access_push(Some(false)).await;
        hub.apply_full_access_push(None).await;
        let ended = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            full_access_forced_off(bound.as_mut()),
        )
        .await;
        assert!(ended.is_ok(), "the unset after the off hid it from the probe");
    }

    /// Review 70: a full-access report under an empty or blank session id names no session, so it
    /// counts for every one, as a report with no id does.
    #[test]
    fn a_report_under_a_blank_session_id_counts_for_every_session() {
        let full = |sid: Value| {
            json!({"sessionId": sid, "update": {"sessionUpdate": "current_mode_update",
                                                 "currentModeId": "bypassPermissions"}})
        };
        for sid in [json!(""), json!("  "), json!(null), json!(7)] {
            let mut reports = StartReports::default();
            reports.note(&full(sid.clone()));
            assert!(reports.of(Some("fake-1")), "a report under {sid} was not counted");
        }
        let mut reports = StartReports::default();
        reports.note(&full(json!("fake-2")));
        assert!(!reports.of(Some("fake-1")), "another session's report counted for this one");
        assert!(reports.of(Some("fake-2")));
        // Review 74: a harness session with a blank id is not known, so any report counts.
        for blank in ["", "  "] {
            assert!(reports.of(Some(blank)), "a report did not count for the blank id {blank:?}");
        }
    }

    /// Review 75: an unset that lands while a start reads MDM's off does not erase an off that
    /// held as the start began, for a probe or pooled start (`off_latch`) or a pinned probe
    /// (`probe_bound`).
    #[tokio::test]
    async fn an_unset_racing_a_start_does_not_erase_the_off_it_began_under() {
        let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let unset: fn(&Hub) = |hub| {
            hub.update_start_mode_state(None, |s| s.full_access_managed = None);
        };
        hub.apply_full_access_push(Some(false)).await;
        AFTER_OFF_COUNT.set(Some(unset));
        assert!(hub.off_latch().off(), "an unset during the latch's read erased the off");
        hub.apply_full_access_push(Some(false)).await;
        AFTER_OFF_COUNT.set(Some(unset));
        let pinned = hub.probe_bound(&hub.off_latch(), &["agent".to_owned(), "--yolo".to_owned()]);
        assert!(pinned.is_err(), "an unset during the read let a pinned probe start");
    }

    /// claude-sr2's bound: a forced off wins over the person's on; a forced on, or nothing
    /// forced, leaves the person's own answer.
    #[test]
    fn a_forced_off_is_an_upper_bound_and_nothing_else_changes() {
        assert!(!full_access_allowed_by(Some(false), true));
        assert!(!full_access_allowed_by(Some(false), false));
        assert!(full_access_allowed_by(None, true));
        assert!(!full_access_allowed_by(None, false));
        assert!(full_access_allowed_by(Some(true), true));
        assert!(!full_access_allowed_by(Some(true), false), "a forced on raises nothing");
    }

    /// A hub with two open chats on a stand-in agent that fails over to itself with
    /// `FAKE_FALLBACK=1`; a cut turn goes on after 1 s.
    async fn two_chats() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
        two_chats_on(&[], true).await
    }

    /// `two_chats`, the agent run with `env` (`FAKE_CLAUDE_STEER=1`: it steers as Claude Code),
    /// and `fails_over` or not.
    async fn two_chats_on(
        env: &[&str],
        fails_over: bool,
    ) -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut argv = vec!["/usr/bin/env"];
        argv.extend(env);
        argv.extend(["python3", fake]);
        let mut cfg = json!({
            "harnesses": {"fake": {"argv": argv}},
            "defaultHarness": "fake",
        });
        if fails_over {
            cfg["harnesses"]["fake"]["fallback"] = json!("fake-fallback");
            let fallback = ["/usr/bin/env", "FAKE_FALLBACK=1", "python3", fake];
            cfg["harnesses"]["fake-fallback"] = json!({"argv": fallback});
            cfg["autoResumeDelaysMs"] = json!([1000]);
        }
        let mut cfg: Config = serde_json::from_value(cfg).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let a = hub.new_session(req()).await.unwrap();
        let b = hub.new_session(req()).await.unwrap();
        (hub, a, b)
    }

    /// Review 26 of #23322: under MDM's off a stored approve-all runs as ask, and sub-session
    /// checks rank it so. A parent in approve-all may message an approve-edits child before the
    /// push, never after it: the child would approve edits the parent must ask about.
    #[tokio::test]
    async fn under_an_mdm_off_approve_all_ranks_as_ask_between_sessions() {
        let (hub, parent, child) = two_chats().await;
        hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
        hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
        assert!(hub.receiver_check(&parent, &child).await.is_ok(), "before the push");
        hub.apply_full_access_push(Some(false)).await;
        let r = hub.receiver_check(&parent, &child).await;
        assert!(r.is_err(), "an approve-all parent messaged an approve-edits child under the off");
        assert_eq!(hub.effective_policy(&parent.meta()).await, PermissionPolicy::Ask);
    }

    /// Review 33 of #23322: a family message checked under the old bound (an approve-all
    /// parent to an approve-edits child) and not yet written to its agent holds an off push
    /// until it is written: no message the old bound let through reaches an agent after the
    /// push returns. A message checked after the push is refused (the test above).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_waits_for_a_family_message_checked_under_the_old_bound() {
        let (hub, parent, child) = two_chats().await;
        hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
        hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
        let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        *hub.family_write_seam.lock().unwrap() = Some((arrived_tx, release_rx));
        let send = {
            let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
            tokio::spawn(async move {
                let text = vec![json!({"type": "text", "text": "hello"})];
                hub.send_family_prompt(&parent, &child, text, None, false, false, None, None).await
            })
        };
        let wait = std::time::Duration::from_secs(10);
        tokio::time::timeout(wait, arrived)
            .await
            .expect("the message reaches its write")
            .expect("the seam fires");
        let push = {
            let hub = hub.clone();
            tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
        };
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let returned = push.is_finished();
        let _ = release.send(());
        tokio::time::timeout(wait, push).await.expect("the push returns").unwrap();
        let _ = tokio::time::timeout(wait, send).await;
        assert!(
            !returned,
            "an off push returned while a message checked under the old bound was still unwritten"
        );
    }

    /// Review 33 of #23322: a family message checked before MDM's off (`receiver_check`, an
    /// approve-all parent to an approve-edits child) that steers into the child's running turn
    /// after the push is checked again at the steer, and refused: the parent now asks.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_family_steer_after_an_off_push_is_checked_again() {
        let (hub, parent, child) = two_chats_on(&["FAKE_CLAUDE_STEER=1"], false).await;
        hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
        hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
        assert!(hub.receiver_check(&parent, &child).await.is_ok(), "checked before the push");
        let running = {
            let (hub, child) = (hub.clone(), child.clone());
            let text = vec![json!({"type": "text", "text": "until-cancel"})];
            tokio::spawn(async move {
                hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await
            })
        };
        let started = async {
            while child.meta().status != SessionStatus::Running {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        let wait = std::time::Duration::from_secs(20);
        tokio::time::timeout(wait, started).await.expect("the child's turn runs");
        hub.apply_full_access_push(Some(false)).await;
        let text = vec![json!({"type": "text", "text": "hello"})];
        let sent = tokio::time::timeout(
            wait,
            hub.send_family_prompt(&parent, &child, text, None, true, false, None, None),
        )
        .await
        .expect("the steer answers");
        running.abort();
        assert!(
            sent.is_err(),
            "a family steer checked under the old bound ran after the push: {sent:?}"
        );
    }

    /// Review 26 of #23322: a second push of the same off waits, as the first does, for an ask
    /// deciding under the old bound (it holds the session's permission lock), so no push returns
    /// before that decision is made.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn every_off_push_waits_for_an_ask_deciding_under_the_old_bound() {
        let (hub, session, _) = two_chats().await;
        // An ask deciding under the permission lock across the pushes: held on its own thread,
        // never across this task's awaits.
        let (locked_tx, locked) = std::sync::mpsc::channel();
        let (deciding, release) = std::sync::mpsc::channel::<()>();
        let holder = {
            let session = session.clone();
            std::thread::spawn(move || {
                let held = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
                let _ = locked_tx.send(());
                let _ = release.recv();
                drop(held);
            })
        };
        locked.recv().expect("the ask holds the permission lock");
        let push = || {
            let hub = hub.clone();
            tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
        };
        let first = push();
        let stored = async {
            while !hub.full_access_managed_off() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(10), stored)
            .await
            .expect("the off is stored");
        let second = push();
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let returned = second.is_finished();
        drop(deciding);
        holder.join().expect("the ask's thread ends");
        let (_, _) = (first.await, second.await);
        assert!(!returned, "a second off push returned while an ask decided under the old bound");
    }

    const WAIT: std::time::Duration = std::time::Duration::from_secs(20);

    /// `two_chats`, the first an approve-all parent of the second, an approve-edits child: the
    /// parent's message passes under the old bound and is refused under MDM's off.
    async fn approve_all_parent() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
        let (hub, parent, child) = two_chats().await;
        hub.set_policy(&parent, PermissionPolicy::ApproveAll).await;
        hub.set_policy(&child, PermissionPolicy::ApproveEdits).await;
        (hub, parent, child)
    }

    fn send(hub: &Arc<Hub>, from: &Arc<Session>, to: &Arc<Session>, text: &str) {
        let (hub, from, to) = (hub.clone(), from.clone(), to.clone());
        let text = vec![json!({"type": "text", "text": text})];
        tokio::spawn(async move {
            hub.send_family_prompt(&from, &to, text, None, false, false, None, None).await
        });
    }

    fn push_off(hub: &Arc<Hub>) -> tokio::task::JoinHandle<()> {
        let hub = hub.clone();
        tokio::spawn(async move { hub.apply_full_access_push(Some(false)).await })
    }

    /// Waits for the first entry of `session`'s log whose kind is one of `kinds`: its kind.
    async fn logged(hub: &Hub, session: &Session, kinds: &[&str]) -> String {
        let found = async {
            loop {
                let events = hub.events(&session.id, 0, 10_000).unwrap();
                if let Some(e) = events.iter().find(|e| kinds.contains(&e.kind.as_str())) {
                    return e.kind.clone();
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        tokio::time::timeout(WAIT, found).await.unwrap_or_else(|_| panic!("no {kinds:?} logged"))
    }

    /// Pauses `session`'s agent's input before the first line holding `pattern`
    /// (`agent::InputSeam`): the line is queued, its transport takes nothing more.
    async fn pause_input(
        hub: &Arc<Hub>,
        session: &Arc<Session>,
        pattern: &str,
    ) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
        pause_input_at(hub, session, pattern, false).await
    }

    /// `pause_input`, or (`writing`) once the writer took the line and is writing it.
    async fn pause_input_at(
        hub: &Arc<Hub>,
        session: &Arc<Session>,
        pattern: &str,
        writing: bool,
    ) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
        let agent = hub.child_for(session).await.expect("a running agent");
        let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        *agent.input_seam.lock().unwrap() =
            Some((pattern.to_owned(), writing, arrived_tx, release_rx));
        (arrived, release)
    }

    /// A family message checked under the old bound, queued for its agent while its transport
    /// takes nothing, then MDM's off pushed. Its input moves again 300 ms into the push, or,
    /// `stuck`, only once the push returned. Whether the push had returned at 300 ms, and how
    /// the message's turn ended.
    async fn off_push_over_a_held_write(stuck: bool) -> (bool, String) {
        let (hub, parent, child) = approve_all_parent().await;
        let (arrived, release) = pause_input(&hub, &child, "session/prompt").await;
        send(&hub, &parent, &child, "hello");
        tokio::time::timeout(WAIT, arrived).await.expect("the message is queued").unwrap();
        let push = push_off(&hub);
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let returned = push.is_finished();
        let mut release = Some(release);
        if !stuck {
            let _ = release.take().map(|r| r.send(()));
        }
        tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
        let _ = release.map(|r| r.send(()));
        (returned, logged(&hub, &child, &["turn_end", "turn_error"]).await)
    }

    /// Review 40 of #23322: a family message queued for its agent, not yet written, holds an
    /// off push until its transport writes it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_waits_for_a_queued_family_message_until_it_is_written() {
        let (returned, end) = off_push_over_a_held_write(false).await;
        assert!(
            !returned,
            "an off push returned while a message checked under the old bound was queued"
        );
        assert_eq!(end, "turn_end", "the message was written once its transport took it");
    }

    /// Review 40 of #23322: a transport that never takes the message holds the push only for a
    /// bounded time, and the message it cut is never written after the push returns.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_cuts_a_family_message_its_transport_never_takes() {
        let (_, end) = off_push_over_a_held_write(true).await;
        assert_eq!(end, "turn_error", "a message the off push cut was written after it returned");
    }

    /// Review 40 of #23322: an ancestor's answer checked under the old bound holds an off push
    /// until the answer is written to the asking agent, not only handed to the ask.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_waits_for_an_ancestors_answer_until_it_is_written() {
        let (hub, parent, child) = approve_all_parent().await;
        let asking = {
            let (hub, child) = (hub.clone(), child.clone());
            let text = vec![json!({"type": "text", "text": "question: Pick?"})];
            tokio::spawn(async move {
                hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await
            })
        };
        let pending = async {
            loop {
                if let Some(id) = child.permissions.lock().unwrap().pending.keys().next() {
                    return id.clone();
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        let id = tokio::time::timeout(WAIT, pending).await.expect("the child asks");
        let (arrived, release) = pause_input(&hub, &child, "outcome").await;
        let answer = {
            let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
            })
        };
        tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
        let push = push_off(&hub);
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let returned = push.is_finished();
        let _ = release.send(());
        tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
        let answered = answer.await.unwrap();
        asking.abort();
        assert!(answered.is_ok(), "{answered:?}");
        assert!(
            !returned,
            "an off push returned while an answer checked under the old bound was queued"
        );
    }

    /// Starts a turn on `child` that asks the question "Pick?": the ask's permission id.
    async fn ask_pick(
        hub: &Arc<Hub>,
        child: &Arc<Session>,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let asking = {
            let (hub, child) = (hub.clone(), child.clone());
            let text = vec![json!({"type": "text", "text": "question: Pick?"})];
            tokio::spawn(async move {
                let _ =
                    hub.prompt_with(&child, text, "test", false, PromptOptions::default()).await;
            })
        };
        let pending = async {
            loop {
                if let Some(id) = child.permissions.lock().unwrap().pending.keys().next() {
                    return id.clone();
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        (tokio::time::timeout(WAIT, pending).await.expect("the child asks"), asking)
    }

    /// Review 81 of #23322: two ancestors answer one question at once. The answer that lost
    /// never takes away the fence of the one that won, so an off push still waits for the
    /// winning answer until it is written.
    #[tokio::test]
    async fn a_losing_ancestor_answer_leaves_the_winners_answer_fenced() {
        let (hub, parent, child) = approve_all_parent().await;
        let (id, asking) = ask_pick(&hub, &child).await;
        let (arrived, release) = pause_input(&hub, &child, "outcome").await;
        // The later answer is checked first and pauses right before it answers.
        let (at_tx, at) = tokio::sync::oneshot::channel();
        let (go, go_rx) = tokio::sync::oneshot::channel();
        *hub.family_write_seam.lock().unwrap() = Some((at_tx, go_rx));
        let late = {
            let (hub, parent, child, id) = (hub.clone(), parent.clone(), child.clone(), id.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "B"})).await
            })
        };
        tokio::time::timeout(WAIT, at).await.expect("the later answer is checked").unwrap();
        // It goes on only once this thread waits: the first answer wins, then the later one
        // loses, before the asking task writes the winner.
        let _ = go.send(());
        let first = hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await;
        let late = late.await.unwrap();
        assert!(first.is_ok() != late.is_ok(), "one answer wins: {first:?}, {late:?}");
        tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
        let push = push_off(&hub);
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let returned = push.is_finished();
        let _ = release.send(());
        tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
        asking.abort();
        assert!(
            !returned,
            "an off push returned while the winning answer, checked under the old bound, was queued"
        );
    }

    /// Review 81 of #23322: a message its agent's writer already took when the transport stops
    /// taking input is cut by ending that agent at once. The push returns in bounded time even
    /// while the chat's agent slot is held elsewhere (a stop waiting on its host), and the
    /// message never reaches the agent.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_returns_in_time_while_a_cut_message_is_being_written() {
        let (hub, parent, child) = approve_all_parent().await;
        let (arrived, release) = pause_input_at(&hub, &child, "session/prompt", true).await;
        send(&hub, &parent, &child, "hello");
        tokio::time::timeout(WAIT, arrived).await.expect("the writer takes the message").unwrap();
        let slot = child.child.lock().await;
        let push = push_off(&hub);
        let returned = tokio::time::timeout(std::time::Duration::from_secs(15), push).await;
        drop(slot);
        let _ = release.send(());
        assert!(returned.is_ok(), "an off push waited on a held agent slot past its bound");
        let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
        assert_eq!(end, "turn_error", "a message the off push cut reached its agent");
    }

    /// Review 84 of #23322: a cut that can not prove its message's agent ended in time (its
    /// reaper holds its slot) tries again, and the push never returns while the message may
    /// still reach the agent.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_off_push_waits_until_a_cut_messages_agent_is_ended() {
        let (hub, parent, child) = approve_all_parent().await;
        let (arrived, release) = pause_input_at(&hub, &child, "session/prompt", true).await;
        send(&hub, &parent, &child, "hello");
        tokio::time::timeout(WAIT, arrived).await.expect("the writer takes the message").unwrap();
        let slot = hub.child_for(&child).await.expect("a running agent").child_slot();
        let reaping = slot.lock().await;
        let push = push_off(&hub);
        // The cut gives up on the slot after about 3 s (the budget, then twice it on the lock).
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        let returned = push.is_finished();
        drop(reaping);
        tokio::time::timeout(WAIT, push).await.expect("the push returns").unwrap();
        let _ = release.send(());
        assert!(!returned, "an off push returned while a cut message's agent could still read it");
        let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
        assert_eq!(end, "turn_error", "a message the off push cut reached its agent");
    }

    /// Review 84 of #23322: an answer that lost to another settles its fence, so the next off
    /// push does not wait on it.
    #[tokio::test]
    async fn a_losing_ancestor_answer_holds_no_later_push() {
        let (hub, parent, child) = approve_all_parent().await;
        let (id, asking) = ask_pick(&hub, &child).await;
        // The later answer is checked first and pauses right before it answers.
        let (at_tx, at) = tokio::sync::oneshot::channel();
        let (go, go_rx) = tokio::sync::oneshot::channel();
        *hub.family_write_seam.lock().unwrap() = Some((at_tx, go_rx));
        let late = {
            let (hub, parent, child, id) = (hub.clone(), parent.clone(), child.clone(), id.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "B"})).await
            })
        };
        tokio::time::timeout(WAIT, at).await.expect("the later answer is checked").unwrap();
        let first = hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await;
        let _ = go.send(());
        let late = late.await.unwrap();
        assert!(first.is_ok() && late.is_err(), "the first answer wins: {first:?}, {late:?}");
        // The winner is written.
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let started = std::time::Instant::now();
        tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
        asking.abort();
        let took = started.elapsed();
        assert!(
            took < std::time::Duration::from_millis(500),
            "an off push waited {took:?} on an answer that lost"
        );
    }

    /// Review 84 of #23322: an answer the off push cut while queued never reaches the agent,
    /// which still waits for one: the question is asked again, under the bound now.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_cut_ancestor_answer_is_asked_again() {
        let (hub, parent, child) = approve_all_parent().await;
        let (id, asking) = ask_pick(&hub, &child).await;
        let (arrived, release) = pause_input(&hub, &child, "outcome").await;
        let answer = {
            let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
            })
        };
        tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
        tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
        let _ = release.send(());
        let answered = answer.await.unwrap();
        let again = async {
            while child.permissions.lock().unwrap().pending.is_empty() {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        let asked = tokio::time::timeout(std::time::Duration::from_secs(5), again).await;
        asking.abort();
        assert!(answered.is_ok(), "{answered:?}");
        assert!(asked.is_ok(), "a cut answer left its agent waiting on a question nobody is asked");
    }

    /// Review 88 of #23322: a cut answer is asked again only of the agent that asked it: once
    /// another agent took the session (a failover), whose request ids start over, its request
    /// is not answered on that agent's ids.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_cut_answer_is_not_asked_again_once_another_agent_took_the_session() {
        let (hub, parent, child) = approve_all_parent().await;
        let (id, asking) = ask_pick(&hub, &child).await;
        let (arrived, release) = pause_input(&hub, &child, "outcome").await;
        let answer = {
            let (hub, parent, child) = (hub.clone(), parent.clone(), child.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &id, json!({"Pick?": "A"})).await
            })
        };
        tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
        // Another live agent takes the session while the one that asked still runs.
        let other = hub.child_for(&parent).await.expect("the parent's agent");
        let asked_of = child.child.lock().await.replace(other);
        tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
        let _ = release.send(());
        let answered = answer.await.unwrap();
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        let again = child.permissions.lock().unwrap().pending.len();
        *child.child.lock().await = asked_of;
        asking.abort();
        assert!(answered.is_ok(), "{answered:?}");
        assert_eq!(again, 0, "a cut answer was asked again for an agent that did not ask it");
    }

    /// Review 86 of #23322: a family prompt that fails before its write (its PDF attachment has
    /// no folder to go to) settles its fence, so the next off push does not wait on it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_family_prompt_that_fails_before_its_write_holds_no_push() {
        let (hub, parent, child) = approve_all_parent().await;
        let dir = std::env::temp_dir().join(format!("hbf-pdf-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A file where the attachment folder goes.
        std::fs::write(dir.join(".cmux"), "").unwrap();
        child.meta.lock().unwrap().cwd = dir.clone();
        let pdf = vec![json!({"type": "document", "name": "a.pdf", "data": "JVBERi0="})];
        let sent = hub.send_family_prompt(&parent, &child, pdf, None, false, false, None, None);
        tokio::time::timeout(WAIT, sent).await.expect("the send answers").unwrap();
        // The turn fails at its prompt's attachment, before anything is written.
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        let started = std::time::Instant::now();
        tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
        let took = started.elapsed();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            took < std::time::Duration::from_millis(500),
            "an off push waited {took:?} on a prompt that failed before its write"
        );
    }

    /// Review 86 of #23322: a question asked again after a restart (`reregister_permission`)
    /// whose ancestor's answer an off push cut is not asked again once a stop cancelled it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_cut_answer_to_a_cancelled_question_is_not_asked_again() {
        let (hub, parent, child) = approve_all_parent().await;
        let (id, asking) = ask_pick(&hub, &child).await;
        let request = child.permissions.lock().unwrap().pending[&id].request.clone();
        let agent = hub.child_for(&child).await.expect("a running agent");
        let again = "asked-again".to_owned();
        hub.reregister_permission(&child, &agent, json!(9999), again.clone(), request, None);
        let (arrived, release) = pause_input(&hub, &child, "\"id\":9999").await;
        let answer = {
            let (hub, parent, child, again) =
                (hub.clone(), parent.clone(), child.clone(), again.clone());
            tokio::spawn(async move {
                hub.ancestor_answer(&parent, &child, &again, json!({"Pick?": "A"})).await
            })
        };
        tokio::time::timeout(WAIT, arrived).await.expect("the answer is queued").unwrap();
        hub.cancel_pending_permissions(&child);
        tokio::time::timeout(WAIT, push_off(&hub)).await.expect("the push returns").unwrap();
        let _ = release.send(());
        let _ = answer.await;
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let reasked = child.permissions.lock().unwrap().pending.contains_key(&again);
        asking.abort();
        assert!(!reasked, "a question a stop cancelled was asked again");
    }

    /// Review 86 of #23322: a family check ranks both sessions under the one bound its operation
    /// read at its entry, never a newer push in between.
    #[tokio::test]
    async fn a_family_check_ranks_both_sessions_under_the_bound_it_read_once() {
        let (hub, parent, child) = approve_all_parent().await;
        let before = hub.mdm_snapshot();
        hub.apply_full_access_push(Some(false)).await;
        let after = hub.mdm_snapshot();
        assert!(!before.off && after.off && after.generation > before.generation);
        let checked = hub.receiver_check_under(&parent, &child, before).await;
        assert!(checked.is_ok(), "under the bound read before the push: {checked:?}");
        let checked = hub.receiver_check_under(&parent, &child, after).await;
        assert!(checked.is_err(), "under the off the approve-all parent asks");
    }

    /// Review 40 of #23322: a family message whose agent hit its limit after the off push is
    /// checked again before it is resent to the fallback, and refused.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_family_message_that_fails_over_is_checked_again_before_its_resend() {
        let (hub, parent, child) = approve_all_parent().await;
        send(&hub, &parent, &child, "slow-limit");
        logged(&hub, &child, &["turn_started"]).await;
        hub.apply_full_access_push(Some(false)).await;
        let end = logged(&hub, &child, &["turn_end", "turn_error"]).await;
        assert_eq!(end, "turn_error", "the fallback ran a family message the off push refuses");
    }

    /// Review 40 of #23322: the automatic continuation of a family message's cut turn speaks
    /// for its sender: after an off push it is checked again, and refused.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_continuation_of_a_family_message_is_checked_again() {
        let (hub, parent, child) = approve_all_parent().await;
        send(&hub, &parent, &child, "net-fail-once: x");
        logged(&hub, &child, &["auto_resume_scheduled"]).await;
        hub.apply_full_access_push(Some(false)).await;
        let end = logged(&hub, &child, &["turn_end", "auto_resume_skipped"]).await;
        assert_eq!(end, "auto_resume_skipped", "a family turn was continued after the off push");
    }
}
