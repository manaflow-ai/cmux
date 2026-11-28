//! A local `codex app-server`'s Seatbelt profile (`local_sandbox.rs`) follows the chat: Read Only
//! runs it in a profile with no workspace writes, every other mode in the writing one, with the
//! chat's added folders. Seatbelt is set at `exec` and never loosened or tightened after, so a
//! crossing into or out of Read Only restarts the app-server and resumes the same thread
//! (`restart_on_change`): now between turns, at the end of a running one, or at its next start.
//!
//! Under the bridge's `outer_sandbox` Codex runs every command it is allowed to with full access,
//! and a command its exec policy rules allow skips the approval policy
//! (codex `core/src/exec_policy.rs`), so the approval policy alone cannot keep Read Only from
//! writing: the profile must.

use super::*;

const READ_ONLY_MODE: &str = "read-only";

impl Hub {
    /// Before every start: what the next local Codex launch for this chat runs under.
    pub(in crate::hub) fn note_codex_sandbox(&self, session: &Session, profile: &HarnessProfile) {
        if !crate::codex_app_server::is_profile_launch(&profile.argv) {
            return;
        }
        crate::local_sandbox::want_codex(&session.id, codex_want_of(session));
        crate::local_sandbox::forget_codex_launch(&session.id);
    }

    /// After a mode change: a crossing into or out of Read Only restarts a wrapped app-server.
    pub(in crate::hub) async fn follow_codex_sandbox(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<(), RpcError> {
        if !cfg!(target_os = "macos") || !crate::local_sandbox::enabled() {
            return Ok(());
        }
        let codex = session.read_meta(|m| {
            crate::codex_app_server::is_profile_launch(
                m.spawn_argv.as_deref().unwrap_or(&m.harness_argv),
            )
        });
        let remote = session
            .launch_env
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(|env| env.get(crate::agent::REMOTE_ENV_POLICY_KEY).cloned())
            .is_some_and(|v| v == "1");
        if !codex || remote {
            return Ok(());
        }
        let want = codex_want_of(session);
        let read_only = want.read_only;
        crate::local_sandbox::want_codex(&session.id, want);
        if session.child.lock().await.is_none() {
            // Its next start takes the profile (`note_codex_sandbox`).
            return Ok(());
        }
        // A running app-server with no launch noted is a pool spare this chat claimed, started
        // for no chat in the writing profile.
        let launched = crate::local_sandbox::codex_launched_read_only(&session.id).unwrap_or(false);
        if launched == read_only {
            return Ok(());
        }
        let applied = self.restart_on_change(session).await?;
        self.append(
            session,
            "mux",
            "codex_sandbox",
            json!({"readOnly": read_only, "applied": applied}),
        );
        Ok(())
    }
}

fn codex_want_of(session: &Session) -> crate::local_sandbox::CodexWant {
    session.read_meta(|m| crate::local_sandbox::CodexWant {
        read_only: crate::web_modes::mode_of(m).as_deref() == Some(READ_ONLY_MODE),
        folders: m.additional_directories.clone(),
    })
}
