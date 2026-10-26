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

    /// MDM has just forced full access off (`apply_full_access_push`): an ask that read the
    /// policy before the push (`policy_for` reads the bound under the prompt's lock, where it
    /// decides) finishes first, so no approve-all decision made after the push returns uses the
    /// old bound.
    /// `changed`: this push turned it off; the pool drains only then.
    pub(super) async fn full_access_turned_off(&self, changed: bool) {
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

    /// A hub with two open chats on a stand-in agent.
    async fn two_chats() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
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

    /// Review 26 of #23322: a second push of the same off waits, as the first does, for an ask
    /// deciding under the old bound (it holds the session's permission lock), so no push returns
    /// before that decision is made.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    // The test stands in for an ask deciding under the permission lock across the pushes.
    #[allow(clippy::await_holding_lock)]
    async fn every_off_push_waits_for_an_ask_deciding_under_the_old_bound() {
        let (hub, session, _) = two_chats().await;
        let deciding = session.permissions.lock().unwrap();
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
        let (_, _) = (first.await, second.await);
        assert!(!returned, "a second off push returned while an ask decided under the old bound");
    }
}
