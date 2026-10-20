//! Part of `Hub`; see `hub/subsessions.rs`. What holds a sub-session to the
//! session that starts or messages it: it never asks less, on either scale.
//!
//! - The acpmux permission policy: the caller's effective one (its own, else
//!   the daemon default; one acpmux cannot parse counts as `ask`), ranked
//!   deny-all < ask < approve-reads < approve-edits < approve-all.
//! - The harness's own mode and command, ranked [`Access`]: asks < does not
//!   ask < full access, by the reviewed lists (`web_modes::ASKING_MODES` and
//!   the person's `webAskingModes`, the Codex bridge's
//!   `BRIDGE_ASKING_MODES`, `NON_ASKING_MODES`, `REFUSED_FAMILIES`,
//!   `start_mode::FULL_ACCESS_MODES`, and a command that skips the
//!   permission checks or the sandbox). A caller whose mode the lists do not
//!   name counts as asking; a child's (or a child that reports no mode) as
//!   full access, unless it is the caller's own mode on the caller's own
//!   family: another family may name full autonomy anything (Goose `auto`,
//!   a custom ACP agent with no modes). A folder profile
//!   (`<folder>/.cmux/harnesses/<id>.toml`) other than the caller's own
//!   counts as full access: its command is the folder's, not the caller's.
//! - The folder: resolved once, then allowed under the person's own
//!   `trusted` decision in cmux (the nearest one wins over anything farther
//!   up), or inside the caller's own folder when no folder from it up to `/`
//!   is untrusted. Trust the person did not decide (Claude Code's and
//!   Codex's, or another chat's agent-home folder) counts only for a caller
//!   in full access. A trust record that cannot be read refuses.

use super::*;
use std::path::Path;

/// How much a session's harness runs without asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Access {
    Asks,
    DoesNotAsk,
    Full,
}

/// Why a harness `argv` runs with no permission check or no sandbox: Claude
/// Code's skip flags or `--permission-mode bypassPermissions`, Codex's bypass
/// flags, `--yolo`, or a `danger-full-access` sandbox (`--sandbox`, `-s`,
/// `-c sandbox_mode=`).
pub(super) fn argv_full_access(argv: &[String]) -> Option<String> {
    const SKIPS: [&str; 3] =
        ["--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox", "--yolo"];
    let value = |i: usize, flag: &str| -> Option<String> {
        let a = &argv[i];
        if a == flag {
            argv.get(i + 1).cloned()
        } else {
            a.strip_prefix(&format!("{flag}=")).map(str::to_owned)
        }
    };
    for (i, a) in argv.iter().enumerate() {
        if SKIPS.contains(&a.as_str()) {
            return Some(format!("its command runs {a}"));
        }
        if value(i, "--permission-mode").is_some_and(|m| m == "bypassPermissions") {
            return Some("its command runs --permission-mode bypassPermissions".into());
        }
        let sandbox = value(i, "--sandbox").or_else(|| value(i, "-s"));
        let config = value(i, "-c").or_else(|| value(i, "--config"));
        let config_sandbox = config.as_deref().is_some_and(|c| {
            c.trim_start().starts_with("sandbox_mode") && c.contains("danger-full-access")
        });
        if sandbox.is_some_and(|m| m == "danger-full-access") || config_sandbox {
            return Some("its command runs with no sandbox (danger-full-access)".into());
        }
    }
    None
}

/// Why session `m` runs in full access by its mode or its command, if it does.
fn full_access_why(m: &SessionMeta) -> Option<String> {
    if let Some(mode) = crate::web_modes::mode_of(m)
        && super::start_mode::FULL_ACCESS_MODES.contains(&mode.as_str())
    {
        return Some(format!("its mode {mode} skips every approval"));
    }
    argv_full_access(&m.harness_argv)
}

/// A policy's place from strictest to laxest.
fn policy_rank(p: PermissionPolicy) -> u8 {
    match p {
        PermissionPolicy::DenyAll => 0,
        PermissionPolicy::Ask => 1,
        PermissionPolicy::ApproveReads => 2,
        PermissionPolicy::ApproveEdits => 3,
        PermissionPolicy::ApproveAll => 4,
    }
}

/// A sub-session refusal: invalid params with `data.reason`.
pub(super) fn refusal(reason: &str, message: String, data: Value) -> RpcError {
    let mut data = data;
    data["reason"] = json!(reason);
    RpcError::invalid_params(message).with_data(data)
}

/// The refusal of a child that would ask less than its caller.
pub(super) fn asks_less(why: &str) -> RpcError {
    refusal(
        "subsessions.asks_less",
        format!(
            "start_session refused: the new session would ask less than this one ({why}). A session started here never asks less than the session that starts it, and never runs in full access unless that session does. Pick another harness, or ask the user to start it."
        ),
        json!({"why": why}),
    )
}

/// Whether `folder` passes the trust walk (module docs) for a caller in
/// `mine` (its own folder, resolved), `caller_full` when it runs in full
/// access. Reads files: run off the runtime.
fn folder_allowed(
    paths: &crate::trust::Paths,
    folder: &Path,
    mine: Option<&Path>,
    caller_full: bool,
) -> Result<(), RpcError> {
    let unreadable = |shown: &str, why: String| {
        refusal(
            "subsessions.trust_unreadable",
            format!(
                "start_session refused: the trust of {shown} could not be read ({why}), so no session starts in {}",
                folder.display()
            ),
            json!({"cwd": folder}),
        )
    };
    let why = |e: crate::trust::Failure| match e {
        crate::trust::Failure::Invalid(m) | crate::trust::Failure::Record(m) => m,
    };
    let (mut inside_own, mut inherited) = (false, false);
    for dir in folder.ancestors() {
        let shown = dir.to_string_lossy();
        let trust = crate::trust::get(paths, &shown).map_err(|e| unreadable(&shown, why(e)))?;
        let person =
            crate::trust::person_decision(paths, &shown).map_err(|e| unreadable(&shown, why(e)))?;
        match trust["level"].as_str() {
            Some("untrusted") => {
                return Err(refusal(
                    "subsessions.folder_untrusted",
                    format!(
                        "start_session refused: {} is in {shown}, which is not trusted. Ask the user to trust the folder in cmux or to start the session there.",
                        folder.display()
                    ),
                    json!({"cwd": folder, "untrusted": shown}),
                ));
            }
            // The person's own decision, the nearest one, ends the walk.
            _ if person == Some(crate::trust::Level::Trusted) => return Ok(()),
            // Claude Code's and Codex's, or an agent-home folder's.
            Some("trusted") => inherited = true,
            _ => {}
        }
        if mine == Some(dir) {
            inside_own = true;
        }
    }
    if inside_own || (caller_full && inherited) {
        return Ok(());
    }
    Err(refusal(
        "subsessions.folder_unknown",
        format!(
            "start_session refused: {} is outside this session's folder, and the user has not trusted it in cmux. Ask the user to trust it in cmux or to start the session there.",
            folder.display()
        ),
        json!({"cwd": folder}),
    ))
}

impl Hub {
    /// The policy session `m` runs: its own, else the daemon default; one
    /// acpmux cannot parse counts as `ask`.
    pub(super) async fn effective_policy(&self, m: &SessionMeta) -> PermissionPolicy {
        match m.permission_policy.as_deref() {
            Some(p) => p.parse().unwrap_or(PermissionPolicy::Ask),
            None => self.config.read().await.permission_policy,
        }
    }

    /// Whether session `m` runs a laxer policy than `than`.
    pub(super) async fn policy_laxer(&self, m: &SessionMeta, than: &SessionMeta) -> bool {
        policy_rank(self.effective_policy(m).await) > policy_rank(self.effective_policy(than).await)
    }

    /// [`Access`] of session `m` as the reviewed lists name it; None when
    /// they do not.
    fn listed_access(&self, m: &SessionMeta) -> Option<Access> {
        if full_access_why(m).is_some() {
            return Some(Access::Full);
        }
        let family = crate::web_modes::family_of(m);
        let mode = crate::web_modes::mode_of(m);
        let table = self.web_modes();
        if let Some(mode) = mode.as_deref() {
            let bridge = crate::codex_app_server::is_profile_launch(&m.harness_argv);
            if bridge && crate::web_modes::BRIDGE_ASKING_MODES.contains(&mode) {
                return Some(Access::Asks);
            }
            if table.modes(&family).iter().any(|a| a == mode) {
                return Some(Access::Asks);
            }
            if crate::web_modes::NON_ASKING_MODES.iter().any(|(_, modes)| modes.contains(&mode)) {
                return Some(Access::DoesNotAsk);
            }
        }
        table.refused().contains(&family).then_some(Access::DoesNotAsk)
    }

    /// How much caller `m` runs without asking: a mode the lists do not
    /// name counts as asking.
    pub(super) fn caller_access(&self, m: &SessionMeta) -> Access {
        self.listed_access(m).unwrap_or(Access::Asks)
    }

    /// Whether session `m` runs a folder profile other than `caller`'s own
    /// (its harness is no catalog profile).
    async fn foreign_folder_profile(&self, m: &SessionMeta, caller: &SessionMeta) -> bool {
        let own = m.harness == caller.harness && m.harness_argv == caller.harness_argv;
        !own && self.config.read().await.profile(&m.harness).is_none()
    }

    /// How much a new or receiving session `m` runs without asking, on
    /// `caller`'s scale (module docs).
    pub(super) async fn receiver_access(&self, m: &SessionMeta, caller: &SessionMeta) -> Access {
        if self.foreign_folder_profile(m, caller).await {
            return Access::Full;
        }
        self.listed_access(m).unwrap_or_else(|| {
            let same = crate::web_modes::family_of(m) == crate::web_modes::family_of(caller)
                && crate::web_modes::mode_of(m) == crate::web_modes::mode_of(caller);
            if same { self.caller_access(caller) } else { Access::Full }
        })
    }

    /// Whether a sub-session may start in `folder` (resolved) for a caller
    /// with meta `pm` (module docs).
    pub(super) async fn subsession_folder_check(
        &self,
        pm: &SessionMeta,
        folder: &Path,
    ) -> Result<(), RpcError> {
        let Some(paths) = self.trust_gate().or_else(crate::trust::Paths::current) else {
            return Err(refusal(
                "subsessions.trust_unreadable",
                "start_session refused: folder trust cannot be read here (no home folder)".into(),
                json!({"cwd": folder}),
            ));
        };
        let folder = folder.to_path_buf();
        let mine = std::fs::canonicalize(&pm.cwd).ok();
        let full = self.caller_access(pm) == Access::Full;
        tokio::task::spawn_blocking(move || folder_allowed(&paths, &folder, mine.as_deref(), full))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
    }

    /// Before anything starts: harness `harness` in `cwd`, for a caller with
    /// meta `pm`, is refused when it is a folder profile or its command
    /// skips the checks, unless the caller runs in full access or it is the
    /// caller's own harness. One the catalog cannot resolve is left to
    /// `session/new` to refuse.
    pub(super) async fn subsession_harness_check(
        &self,
        pm: &SessionMeta,
        harness: &str,
        model: Option<&str>,
        cwd: &Path,
    ) -> Result<(), RpcError> {
        if self.caller_access(pm) == Access::Full {
            return Ok(());
        }
        let resolved = {
            let cfg = self.config.read().await;
            self.resolve_new(
                &cfg,
                Some(harness.to_owned()),
                &None,
                model,
                pm.remote_origin,
                Some(cwd),
            )
        };
        let Ok(r) = resolved else { return Ok(()) };
        if r.agent == pm.harness && r.profile.argv == pm.harness_argv {
            return Ok(());
        }
        if let Some(root) = &r.folder_root {
            return Err(refusal(
                "subsessions.folder_profile",
                format!(
                    "start_session refused: harness {harness} is a folder profile of {}, whose command this session did not choose; only a session in full access starts one. Pick another harness, or ask the user to start it.",
                    root.display()
                ),
                json!({"harness": harness}),
            ));
        }
        match argv_full_access(&r.profile.argv) {
            Some(why) => Err(asks_less(&format!("harness {harness}: {why}"))),
            None => Ok(()),
        }
    }

    /// Holds new sub-session `child` to its caller (meta `pm`): when its
    /// harness asks less, it is moved to the caller's mode (same family) or
    /// its family's asking mode; a child that still asks less, or whose
    /// command or folder profile fixes it there, is refused (the caller
    /// closes it). Its policy is never laxer than the caller's.
    pub(super) async fn hold_subsession(
        self: &Arc<Self>,
        pm: &SessionMeta,
        child: &Arc<Session>,
    ) -> Result<(), RpcError> {
        let caller_policy = self.effective_policy(pm).await;
        if self.policy_laxer(&child.meta(), pm).await {
            self.set_policy(child, caller_policy).await;
        }
        let mine = self.caller_access(pm);
        if self.receiver_access(&child.meta(), pm).await <= mine {
            return Ok(());
        }
        let cm = child.meta();
        let foreign = self.foreign_folder_profile(&cm, pm).await;
        if foreign {
            return Err(refusal(
                "subsessions.folder_profile",
                format!(
                    "start_session refused: harness {} is a folder profile, whose command this session did not choose; only a session in full access starts one.",
                    cm.harness
                ),
                json!({"harness": cm.harness}),
            ));
        }
        if let Some(why) = argv_full_access(&cm.harness_argv) {
            return Err(asks_less(&format!("harness {}: {why}", cm.harness)));
        }
        let family = crate::web_modes::family_of(&cm);
        let offered: Vec<String> = cm
            .modes
            .as_ref()
            .and_then(|m| m.get("availableModes"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned))
            .collect();
        let own =
            crate::web_modes::mode_of(pm).filter(|_| crate::web_modes::family_of(pm) == family);
        let bridge: &[&str] = if crate::codex_app_server::is_profile_launch(&cm.harness_argv) {
            crate::web_modes::BRIDGE_ASKING_MODES
        } else {
            &[]
        };
        let mut candidates: Vec<String> = Vec::new();
        let table = self.web_modes();
        let asking = own
            .into_iter()
            .chain(bridge.iter().map(|m| (*m).to_owned()))
            .chain(table.modes(&family).iter().cloned())
            .chain(std::iter::once("ask".to_owned()));
        for mode in asking {
            if offered.contains(&mode) && !candidates.contains(&mode) {
                candidates.push(mode);
            }
        }
        for mode in candidates {
            if self.set_mode(child, &mode).await.is_ok()
                && self.receiver_access(&child.meta(), pm).await <= mine
            {
                return Ok(());
            }
        }
        let cm = child.meta();
        let why = full_access_why(&cm).unwrap_or_else(|| {
            format!(
                "its {family} mode {} does not ask, and it has no mode that asks",
                crate::web_modes::mode_of(&cm).as_deref().unwrap_or("(none)")
            )
        });
        Err(asks_less(&why))
    }
}

#[cfg(test)]
mod tests {
    use super::argv_full_access;

    fn argv(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn a_command_that_skips_the_checks_is_full_access() {
        for a in [
            &["claude", "--dangerously-skip-permissions"][..],
            &["claude", "--permission-mode", "bypassPermissions"],
            &["claude", "--permission-mode=bypassPermissions"],
            &["codex", "-s", "danger-full-access"],
            &["codex", "--sandbox=danger-full-access"],
            &["codex", "-c", "sandbox_mode=\"danger-full-access\""],
            &["codex", "--dangerously-bypass-approvals-and-sandbox"],
        ] {
            assert!(argv_full_access(&argv(a)).is_some(), "{a:?}");
        }
        for a in [
            &["claude", "--permission-mode", "default"][..],
            &["codex", "-s", "workspace-write"],
            &["opencode", "acp"],
        ] {
            assert!(argv_full_access(&argv(a)).is_none(), "{a:?}");
        }
    }

    #[test]
    fn attached_short_flags_and_gemini_auto_approval_are_full_access() {
        for a in [
            &["codex", "-sdanger-full-access"][..],
            &["codex", "-csandbox_mode=danger-full-access"],
            &["gemini", "-y"],
            &["qwen", "--approval-mode", "yolo"],
            &["gemini", "--approval-mode=auto_edit"],
        ] {
            assert!(argv_full_access(&argv(a)).is_some(), "{a:?}");
        }
        for a in [&["gemini", "--approval-mode", "default"][..], &["codex", "-sworkspace-write"]] {
            assert!(argv_full_access(&argv(a)).is_none(), "{a:?}");
        }
    }
}
