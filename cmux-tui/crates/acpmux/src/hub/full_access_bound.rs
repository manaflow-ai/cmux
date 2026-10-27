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
//!   keep `modes.currentModeId` at an asking mode while its `mode` option says full access).
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
}

/// What acpmux knows of one agent that can put it in full access.
#[derive(Default)]
pub(crate) struct FullAccessView {
    pub argv: Vec<String>,
    pub mode: Option<String>,
    pub undeclared_mode: Option<String>,
    /// Its config options, the `mode` one included.
    pub options: Vec<Value>,
}

impl FullAccessView {
    /// A profile before its agent starts: its argv only.
    pub(crate) fn of_argv(argv: &[String]) -> Self {
        Self { argv: argv.to_vec(), ..Self::default() }
    }

    /// A session's agent as acpmux records it.
    pub(crate) fn of_session(session: &Session) -> Self {
        let undeclared_mode =
            session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let asked = session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let meta = session.meta();
        Self {
            mode: crate::web_modes::mode_of(&meta),
            undeclared_mode,
            // With the values a bare `set_config_option` answer took (`FloorState::asked_options`).
            options: config_options(&meta).cloned().chain(asked).collect(),
            // The argv its agent started with; before any start, the creation's.
            argv: meta.spawn_argv.unwrap_or(meta.harness_argv),
        }
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

impl Hub {
    /// Whether a mode that skips every approval may run now: the settings file under
    /// the value MDM or the team policy forces (`full_access_allowed_by`).
    pub fn full_access_allowed(&self) -> bool {
        full_access_allowed_by(
            self.full_access_managed(),
            super::start_mode::file_allows_full_access(),
        )
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

    /// MDM forces full access off (`apply_full_access_push`, every push of the off: one may
    /// follow an agent that entered full access since). `changed`: this push turned it off; the
    /// pool drains only then.
    pub(super) async fn full_access_turned_off(&self, changed: bool) {
        // Pooled agents started under the old bound (a profile pinning full access among them)
        // end; the pool starts again under the new one.
        if changed {
            self.drain_pool();
        }
        // Unavailable now, not only for the next start: an agent still in full access ends.
        self.end_every_managed_full_access().await;
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
    /// (`runs_full_access`), and says what it did: its live child, and any host a restart left.
    /// For such a host what it reported is read back from the log too (`reported_by_left_host`):
    /// the saved chat can be older. Called under the session's spawn lock.
    pub(super) async fn end_if_runs_full_access(&self, session: &Session) -> FullAccessEnd {
        if !self.full_access_managed_off() || !self.runs_full_access_by_any_record(session) {
            return FullAccessEnd::NotInFullAccess;
        }
        self.end_managed_full_access(session).await
    }

    /// Whether `session`'s agent runs in full access by what acpmux keeps of it, or, for a host a
    /// restart left, by what that host reported since it started (`reported_by_left_host`). Once
    /// that read finds no full access, what this daemon keeps is complete (every later report
    /// reaches it live), so the log is read once per host, not at each check
    /// (`FloorState::left_host_read`, cleared at each `host_started`). A log that cannot be read
    /// says nothing either way: under MDM's off the host counts as in full access (review 61).
    fn runs_full_access_by_any_record(&self, session: &Session) -> bool {
        if runs_full_access(&FullAccessView::of_session(session)).is_some() {
            return true;
        }
        if !Self::host_record_live(&session.id)
            || session.floor.left_host_read.load(Ordering::SeqCst)
        {
            return false;
        }
        let reported = self
            .reported_by_left_host(session)
            .is_none_or(|view| runs_full_access(&view).is_some());
        if !reported {
            session.floor.left_host_read.store(true, Ordering::SeqCst);
        }
        reported
    }

    /// Every agent still running in full access under the managed off ends now (a turn in
    /// progress ends with it), each under its session's spawn lock, checked again there.
    pub(super) async fn end_every_managed_full_access(&self) {
        for session in self.sessions() {
            if self.full_access_managed_off() && self.runs_full_access_by_any_record(&session) {
                let _spawning = session.spawn_lock.lock().await;
                self.end_if_runs_full_access(&session).await;
            }
        }
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
                    || e.msg.pointer("/params/sessionId").and_then(Value::as_str) == own.as_deref()
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
        Some(FullAccessView {
            argv: Vec::new(),
            mode: mode.or_else(|| text_at(modes.as_ref(), "currentModeId")),
            undeclared_mode: None,
            options: options.as_ref().and_then(Value::as_array).cloned().unwrap_or_default(),
        })
    }

    /// Ends the agent of a session that runs in full access while MDM forces it off: the live
    /// child and any host a restart left. The start that follows runs in a mode that asks, or
    /// refuses a profile that pins full access (`refuse_pinned_full_access`). A host whose end its
    /// nonce does not prove may still run in full access: what says so stays, so the next check
    /// (a start, a push, the background check) tries again, and nothing reaches it meanwhile
    /// (`FullAccessEnd::StillRunning`, review 51 of #23322).
    pub(super) async fn end_managed_full_access(&self, session: &Session) -> FullAccessEnd {
        let child = session.child.lock().await.take();
        let ended = child.is_some() || Self::host_record_live(&session.id);
        if let Some(child) = child {
            // Bounded: a host whose link stopped reading never answers the terminate; it is then
            // ended by its nonce below (review 27 of #23322).
            let grace = super::shutdown::SHUTDOWN_GRACE;
            if tokio::time::timeout(grace * 2, child.terminate(grace)).await.is_err() {
                tracing::warn!(session = %session.id, "its full-access agent did not end in time; its host is ended");
            }
        }
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
            if Self::host_record_live(&session.id) {
                tracing::warn!(session = %session.id, "MDM forces full access off: its full-access agent host did not end; it is not reached until it does");
                self.append(session, "mux", "full_access_end_failed", json!({"reason": "managed"}));
                return FullAccessEnd::StillRunning;
            }
        }
        // What only the ended agent said goes with it: the mode it reported without declaring
        // modes, the values bare answers took, and a full-access value of any option (the next
        // agent reports its own, and `replay_config` skips a null).
        *session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()) = None;
        session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner()).clear();
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
}
