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
//!   keep `modes.currentModeId` at an asking mode while its `mode` option says full access).
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
        let meta = session.meta();
        Self {
            mode: crate::web_modes::mode_of(&meta),
            undeclared_mode,
            options: config_options(&meta).cloned().collect(),
            argv: meta.harness_argv,
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

    /// MDM has just forced full access off (`apply_full_access_push`).
    pub(super) async fn full_access_turned_off(&self) {
        // Pooled agents started under the old bound (a profile pinning full access among them)
        // end; the pool starts again under the new one.
        self.drain_pool();
    }
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
