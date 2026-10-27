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
//! - reported: its harness reported full access while nothing watched it (`StartReports`).
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
        let undeclared_mode =
            session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let meta = session.meta();
        Self {
            mode: crate::web_modes::mode_of(&meta),
            undeclared_mode,
            options: config_options(&meta).cloned().collect(),
            // The argv its agent started with; before any start, the creation's.
            argv: meta.spawn_argv.unwrap_or(meta.harness_argv),
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
    /// checked again
    /// (`family_dispatch_check`) under the family gate, which the caller holds until the
    /// message is written. An MDM off push waits on the gate (`full_access_turned_off`), so a
    /// message checked under the old bound is written before the push returns, and one checked
    /// after it is checked under the off.
    pub(super) async fn family_gate(
        &self,
        session: &Session,
        provenance: Option<&Value>,
    ) -> Result<Option<tokio::sync::RwLockReadGuard<'_, ()>>, RpcError> {
        if !super::subsession_guard::is_family(provenance) {
            return Ok(None);
        }
        let gate = self.family_gate.read().await;
        self.family_dispatch_check(session, provenance).await?;
        Ok(Some(gate))
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
    /// bound (`family_gate`), so no approve-all decision made after the push returns uses the
    /// old bound.
    /// It runs at every push of the off, as one may follow an agent that entered full access
    /// since. `changed`: this push turned it off; the pool drains only then.
    pub(super) async fn full_access_turned_off(&self, changed: bool) {
        drop(self.family_gate.write().await);
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
    /// of it or its left host reported (`runs_full_access_by_any_record`), or because an end of it failed and its host may still run
    /// (`FloorState::full_access_end_pending`, review 51 of #23322).
    async fn counts_as_full_access(&self, session: &Session) -> bool {
        session.floor.full_access_end_pending.load(Ordering::SeqCst)
            || self.runs_full_access_by_any_record(session)
    }

    /// Whether `session`'s agent runs in full access by what acpmux keeps of it, or, for a host a
    /// restart left, by what that host reported since it started (`reported_by_left_host`). Once
    /// that read finds no full access, what this daemon keeps is complete (every later report
    /// reaches it live), so the log is read once per host, not at each check
    /// (`FloorState::left_host_read`, cleared at each `host_started`), and only when the host
    /// records could be read (review 69): records that could not may leave a live host unproven, so
    /// its log is read again at the next check. A host whose own record this build cannot read is
    /// never adopted, so its log does not hear what it did since: under MDM's off it counts as in
    /// full access (review 2 of #26055). A log that cannot be read
    /// says nothing either way: under MDM's off the host counts as in full access (review 61).
    /// Host records that cannot be read do not prove the host gone, so its log is read back then
    /// too (`host_record_gone`, review 67).
    fn runs_full_access_by_any_record(&self, session: &Session) -> bool {
        self.runs_full_access_by_records(session, Self::read_host_records().as_ref())
    }

    /// `runs_full_access_by_any_record` with the host records as read (`read_host_records`):
    /// None when they could not be read.
    fn runs_full_access_by_records(
        &self,
        session: &Session,
        records: Option<&super::hosts::HostRecords>,
    ) -> bool {
        if runs_full_access(&FullAccessView::of_session(session)).is_some() {
            return true;
        }
        if records.is_some_and(|r| !r.live.contains(&session.id))
            || session.floor.left_host_read.load(Ordering::SeqCst)
        {
            return false;
        }
        if records.is_some_and(|r| r.unreadable.contains(&session.id)) {
            return true;
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
        let own = own.as_deref().filter(|s| !s.trim().is_empty());
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
        #[cfg(debug_assertions)]
        let fails = std::env::var_os("ACPMUX_TEST_LEFT_HOST_SCAN_FAILS").is_some();
        #[cfg(not(debug_assertions))]
        let fails = false;
        let scan = |visit: &mut dyn FnMut(crate::store::EventRecord) -> bool| {
            if fails {
                return Err(anyhow::anyhow!("the log could not be read"));
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
                        e.msg.pointer("/params/sessionId").and_then(Value::as_str) == Some(own)
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
                            if let Some(o) = res.get("configOptions").filter(|o| !o.is_null()) {
                                options = Some(o.clone());
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
    pub(super) async fn end_every_managed_full_access(&self, off: bool) {
        if !off {
            return;
        }
        for session in self.sessions() {
            if self.counts_as_full_access(&session).await {
                let _spawning = session.spawn_lock.lock().await;
                self.end_if_runs_full_access(&session, off).await;
            }
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
        let child = session.child.lock().await.take();
        let ended = child.is_some() || !Self::host_record_gone(&session.id);
        if let Some(child) = child {
            // Bounded: a host whose link stopped reading never answers the terminate; it is then
            // ended by its nonce below (review 27 of #23322).
            let grace = super::shutdown::SHUTDOWN_GRACE;
            if tokio::time::timeout(grace * 2, child.terminate(grace)).await.is_err() {
                tracing::warn!(session = %session.id, "its full-access agent did not end in time; its host is ended");
            }
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
        // What only the ended agent said goes with it: the mode it reported without declaring
        // modes, and a full-access value of any option (the next agent reports its own, and
        // `replay_config` skips a null).
        *session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let scrubbed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let mut scrubbed = false;
            for o in m.config_options.as_mut().and_then(Value::as_array_mut).into_iter().flatten() {
                if o["currentValue"].as_str().is_some_and(super::start_mode::is_full_access) {
                    o["currentValue"] = Value::Null;
                    scrubbed = true;
                }
            }
            scrubbed
        };
        if scrubbed {
            self.save_meta(session);
        }
        if ended {
            tracing::info!(session = %session.id, "MDM forces full access off: its full-access agent ended");
            self.append(session, "mux", "full_access_ended", json!({"reason": "managed"}));
        }
        FullAccessEnd::Ended
    }
}

/// The string at `key` of an object, if any.
fn text_at(v: Option<&Value>, key: &str) -> Option<String> {
    v.and_then(|v| v.get(key)).and_then(Value::as_str).map(str::to_owned)
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

    /// Review 69 of #23322: a left host's log read back while the host records could not be read
    /// is not kept as the last word: a later check reads the log again and finds what the host
    /// reported since.
    #[tokio::test]
    async fn a_left_host_read_while_its_records_were_unreadable_is_read_again() {
        let (hub, chat, _) = two_chats_on(&[], false).await;
        hub.append(&chat, "mux", "host_started", json!({}));
        assert!(
            !hub.runs_full_access_by_records(&chat, None),
            "a log that asks read as full access"
        );
        let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": chat.meta().agent_session_id,
            "update": {"sessionUpdate": "current_mode_update", "currentModeId": "full-access"}}});
        hub.append(&chat, "in", "current_mode_update", update);
        assert!(
            hub.runs_full_access_by_records(&chat, None),
            "a read while the host records could not be read hid the host's later full access"
        );
    }

    /// Review 2 of #26055: a host whose own record this build cannot read may run on unproven, and
    /// it is never adopted, so its log never hears what it did since: under MDM's off it counts as
    /// full access, whatever its log says.
    #[tokio::test]
    async fn a_host_whose_record_cannot_be_read_counts_as_full_access() {
        let (hub, chat, _) = two_chats_on(&[], false).await;
        hub.append(&chat, "mux", "host_started", json!({}));
        let ids = std::collections::HashSet::from([chat.id.clone()]);
        let records = super::super::hosts::HostRecords { live: ids.clone(), unreadable: ids };
        assert!(
            hub.runs_full_access_by_records(&chat, Some(&records)),
            "a host whose record cannot be read was judged by its log"
        );
    }

    /// Review 2 of #26055, round 2: a log read kept while the host records could be read
    /// (`left_host_read`) does not outlast them. Once the host's own record cannot be read, the
    /// host counts as full access; while the records cannot be read at all, its log is read again.
    #[tokio::test]
    async fn a_kept_left_host_read_does_not_outlast_readable_records() {
        use super::super::hosts::HostRecords;
        let (hub, chat, _) = two_chats_on(&[], false).await;
        hub.append(&chat, "mux", "host_started", json!({}));
        let ids = std::collections::HashSet::from([chat.id.clone()]);
        let readable = HostRecords { live: ids.clone(), unreadable: Default::default() };
        assert!(
            !hub.runs_full_access_by_records(&chat, Some(&readable)),
            "a log that asks read as full access"
        );
        let unreadable = HostRecords { live: ids.clone(), unreadable: ids };
        assert!(
            hub.runs_full_access_by_records(&chat, Some(&unreadable)),
            "a kept read hid a host whose record cannot be read now"
        );
        let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": chat.meta().agent_session_id,
            "update": {"sessionUpdate": "current_mode_update", "currentModeId": "full-access"}}});
        hub.append(&chat, "in", "current_mode_update", update);
        assert!(
            hub.runs_full_access_by_records(&chat, None),
            "a kept read hid the host's later full access while the records could not be read"
        );
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
