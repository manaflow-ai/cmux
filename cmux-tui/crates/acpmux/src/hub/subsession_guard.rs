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
//!   up), under one of the person's auto-trust rules (`trust_auto.rs`) outside
//!   a Web turn, or inside the caller's own folder when no folder from it up
//!   to `/` is untrusted. Trust the person did not decide (Claude Code's and
//!   Codex's, or another chat's agent-home folder) counts only for a caller
//!   in full access. A trust record that cannot be read refuses. A folder the
//!   person marked untrusted is refused before anyone is asked; one nobody
//!   decided waits for the person's answer first (`trust_wait.rs`), and the
//!   walk reads that answer.

use super::*;
use std::path::{Path, PathBuf};

/// How much a session's harness runs without asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Access {
    Asks,
    DoesNotAsk,
    Full,
}

/// Why a harness `argv` runs with no permission check or no sandbox: Claude
/// Code's skip flags or `--permission-mode bypassPermissions`, Codex's bypass
/// flags, `--yolo`, a `danger-full-access` sandbox (`--sandbox`, `-s`,
/// `-c sandbox_mode=`, also attached as `-sdanger-full-access`), or Gemini
/// CLI's and Qwen Code's `-y` and `--approval-mode yolo` or `auto_edit`.
pub(super) fn argv_full_access(argv: &[String]) -> Option<String> {
    const SKIPS: [&str; 4] = [
        "--dangerously-skip-permissions",
        "--dangerously-bypass-approvals-and-sandbox",
        "--yolo",
        "-y",
    ];
    // `--flag value`, `--flag=value`, and for a short flag `-fvalue`.
    let value = |i: usize, flag: &str| -> Option<String> {
        let a = &argv[i];
        if a == flag {
            return argv.get(i + 1).cloned();
        }
        if let Some(v) = a.strip_prefix(&format!("{flag}=")) {
            return Some(v.to_owned());
        }
        let short = flag.len() == 2 && !flag.starts_with("--");
        a.strip_prefix(flag).filter(|v| short && !v.is_empty()).map(str::to_owned)
    };
    for (i, a) in argv.iter().enumerate() {
        if SKIPS.contains(&a.as_str()) {
            return Some(format!("its command runs {a}"));
        }
        if value(i, "--permission-mode").is_some_and(|m| m == "bypassPermissions") {
            return Some("its command runs --permission-mode bypassPermissions".into());
        }
        if let Some(m) = value(i, "--approval-mode").filter(|m| m == "yolo" || m == "auto_edit") {
            return Some(format!("its command runs --approval-mode {m}"));
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

/// Whether `provenance` is a family prompt's (`subsessions::PROVENANCE_KIND`), which
/// [`Hub::family_dispatch_check`] holds when it runs.
pub(super) fn is_family_prompt(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str)
        == Some(super::subsessions::PROVENANCE_KIND)
}

/// A retry a sub-session asked for (`retry_session`, `manual` and `from` it): checked at dispatch
/// and counted against its parent's run slots as a family prompt is.
pub(super) fn is_family_retry(provenance: Option<&Value>) -> bool {
    provenance.is_some_and(|p| p.get("manual").is_some() && p.get("from").is_some())
}

/// A family prompt, a sub-session's retry, or the automatic continuation of either's cut turn,
/// which speaks for the same sender (`from`, `auto_resume.rs`): checked as a family message.
pub(super) fn is_family(provenance: Option<&Value>) -> bool {
    let continuation =
        provenance.is_some_and(|p| p["kind"] == "auto_resume" && p.get("from").is_some());
    is_family_prompt(provenance) || is_family_retry(provenance) || continuation
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

/// Which trust walk [`folder_allowed`] makes.
#[derive(Clone, Copy)]
pub(super) enum Walk {
    /// Before the trust card (`trust_wait.rs`): only the person's own nearest `untrusted`
    /// decision refuses, so a folder they said no to raises no card.
    BeforeCard,
    /// After it; `rules`: the person's auto-trust rules answer (not in a Web turn).
    Answered { rules: bool },
}

/// Whether `folder` passes the trust walk `walk` (module docs) for a caller
/// in `mine` (its own folder, resolved), `caller_full` when it runs in full
/// access. Reads files: run off the runtime.
fn folder_allowed(
    paths: &crate::trust::Paths,
    folder: &Path,
    mine: Option<&Path>,
    caller_full: bool,
    walk: Walk,
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
    let answered = matches!(walk, Walk::Answered { .. });
    let rules = matches!(walk, Walk::Answered { rules: true });
    let (mut inside_own, mut inherited, mut ruled) = (false, false, false);
    for dir in folder.ancestors() {
        let shown = dir.to_string_lossy();
        let trust = crate::trust::get(paths, &shown).map_err(|e| unreadable(&shown, why(e)))?;
        let person =
            crate::trust::person_decision(paths, &shown).map_err(|e| unreadable(&shown, why(e)))?;
        match trust["level"].as_str() {
            Some("untrusted") if answered || person == Some(crate::trust::Level::Untrusted) => {
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
            // One of the person's auto-trust rules on the folder itself, as the trust card reads
            // it: a farther `untrusted` still refuses. A parent's rule can leave out a folder
            // under it (a nested repository with another remote), so it counts as inherited.
            Some("trusted") if dir == folder && trust["auto"].is_string() => ruled = true,
            // Claude Code's and Codex's, or an agent-home folder's.
            Some("trusted") => inherited = true,
            _ => {}
        }
        if mine == Some(dir) {
            inside_own = true;
        }
    }
    // Before the card, a folder nobody decided goes on to it.
    if !answered || inside_own || (rules && ruled) || (caller_full && (inherited || ruled)) {
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

/// The folder a sub-session starts in, resolved once and held open (unix): the checks pass on
/// the folder the session gets. A folder renamed or a link swapped after the check (while the
/// start waits on the trust card, say) must not move the start into a folder nobody checked:
/// - before its worktree is made and before its harness spawns, the path must still lead to that
///   very folder, the same device and inode ([`CheckedFolder::still_at`], a refusal that names
///   the reason);
/// - its harness process checks the same identity itself, after it changed into the folder and
///   right before it execs (`cwd_pin.rs`), on every spawn of the start: none runs elsewhere.
///
/// The open handle keeps the inode from being reused meanwhile. Left over: `make_worktree` runs
/// git by path after the first check. Windows compares the session's folder only once it runs
/// (`Hub::settle_subsession`).
#[derive(Clone, Debug)]
pub struct CheckedFolder {
    path: PathBuf,
    /// Its device and inode; None off unix.
    pin: Option<crate::cwd_pin::CwdPin>,
    #[cfg(unix)]
    held: Arc<std::fs::File>,
}

impl std::ops::Deref for CheckedFolder {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.path
    }
}

impl CheckedFolder {
    /// `asked`, an absolute path, resolved to a folder on this machine and held.
    pub(super) fn resolve(asked: &Path) -> Result<Self, RpcError> {
        if !asked.is_absolute() {
            return Err(RpcError::invalid_params(format!(
                "cwd {} must be an absolute path to an existing folder",
                asked.display()
            )));
        }
        Self::open(asked).ok_or_else(|| {
            refusal(
                "subsessions.cwd_unresolved",
                format!(
                    "start_session refused: {} does not resolve to a folder on this machine",
                    asked.display()
                ),
                json!({"cwd": asked}),
            )
        })
    }

    fn open(asked: &Path) -> Option<Self> {
        let path = std::fs::canonicalize(asked).ok().filter(|f| f.is_dir())?;
        #[cfg(unix)]
        let (pin, held) = {
            use std::os::unix::fs::MetadataExt;
            let held = std::fs::File::open(&path).ok()?;
            let m = held.metadata().ok().filter(std::fs::Metadata::is_dir)?;
            (Some(crate::cwd_pin::CwdPin { dev: m.dev(), ino: m.ino() }), Arc::new(held))
        };
        #[cfg(not(unix))]
        let pin = None;
        Some(Self {
            path,
            pin,
            #[cfg(unix)]
            held,
        })
    }

    /// Ok when `cwd` still leads to this folder: it resolves to the same path, and that is the
    /// same device and inode. Else `subsessions.cwd_moved`, and nothing may start there.
    pub(super) fn still_at(&self, cwd: &Path) -> Result<(), RpcError> {
        let resolved = std::fs::canonicalize(cwd).ok();
        let moved = resolved.as_deref() != Some(self.path.as_path())
            || crate::cwd_pin::CwdPin::of(cwd) != self.pin;
        if cfg!(unix) && moved {
            return Err(moved_refusal(cwd));
        }
        Ok(())
    }

    /// The open handle on it (unix): git runs in this very folder through it
    /// (`subsession_worktree::Dir`).
    pub(super) fn held(&self) -> Option<Arc<std::fs::File>> {
        #[cfg(unix)]
        return Some(self.held.clone());
        #[cfg(not(unix))]
        None
    }
}

/// `subsessions.cwd_moved`: `cwd` no longer leads to the folder a sub-session's start checked.
fn moved_refusal(cwd: &Path) -> RpcError {
    refusal(
        "subsessions.cwd_moved",
        format!(
            "start_session refused: {} is no longer the folder that was checked (it was moved, or a link now leads elsewhere), so nothing started there",
            cwd.display()
        ),
        json!({"cwd": cwd}),
    )
}

/// Ok when `start` (a sub-session's folder in the worktree just made from `source`) is in that
/// very worktree (`subsession_worktree::verify_made`); else `subsessions.cwd_moved`.
pub(super) async fn verify_worktree(
    source: &CheckedFolder,
    made: &crate::subsession_worktree::Worktree,
    start: &CheckedFolder,
) -> Result<(), RpcError> {
    let (source_path, source_held) = (source.path.clone(), source.held());
    let (start_path, start_held) = (start.path.clone(), start.held());
    let made = made.clone();
    let checked = tokio::task::spawn_blocking(move || {
        use crate::subsession_worktree::{Dir, verify_made};
        let source = Dir::held(&source_path, source_held.as_deref());
        verify_made(source, &made, Dir::held(&start_path, start_held.as_deref()))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    checked.map_err(|why| {
        tracing::warn!(cwd = %start.path.display(), %why, "sub-session worktree");
        moved_refusal(&start.path)
    })
}

impl CheckedFolder {
    /// Its path, while it still leads to this folder ([`CheckedFolder::still_at`]).
    pub(super) fn still_here(&self) -> Result<&Path, RpcError> {
        self.still_at(&self.path).map(|()| self.path.as_path())
    }
}

impl Hub {
    /// `ensure_child` for new session `session` in the folder a sub-session start checked
    /// (`checked`): refused with nothing started when its folder is no longer that one, and every
    /// harness it spawns is pinned to it (`cwd_pin.rs`), so one whose folder moved later fails at
    /// its exec. Not only once the agent runs: an agent started in a folder nobody checked has
    /// already run that folder's own code (its settings hooks, folder profiles, MCP config). The
    /// check after the start (`settle_subsession`) stays as a backstop.
    pub(super) async fn ensure_checked_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
        spawn: &super::spawn::Spawn,
        checked: Option<&CheckedFolder>,
        stops: u64,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        let Some(checked) = checked else { return self.ensure_child(session, spawn, stops).await };
        let cwd = session.meta().cwd;
        checked.still_at(&cwd)?;
        let pinned = self.ensure_child(session, spawn, stops);
        let started = Box::pin(crate::cwd_pin::CwdPin::scope(checked.pin, pinned)).await;
        // A spawn its harness's own check failed (the folder moved since) says why.
        started.map_err(|e| checked.still_at(&cwd).err().unwrap_or(e))
    }

    /// Everything a new sub-session takes before its first prompt: the
    /// parent's rules and turned-off tools, the folder it was checked for,
    /// its start mode, and [`Hub::hold_subsession`]. An error means the
    /// caller closes it.
    pub(super) async fn settle_subsession(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        pm: &SessionMeta,
        probe: &Arc<Session>,
        cwd: &Path,
        requested_name: Option<&str>,
    ) -> Result<(), RpcError> {
        // The parent's mode as it is now: it may have left full access since the start was checked.
        let live = parent.meta();
        let parent_mode = crate::web_modes::mode_of(&live);
        // The parent's rules above its policy (which can deny) and the MCP
        // servers the user turned off apply to the child too.
        {
            let mut m = probe.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.permission_rules = pm.permission_rules.clone();
            // Titled by its name, else by its prompt and then a generated title (`titles.rs`).
            super::titles::title_subsession(&mut m, requested_name);
            for row in &pm.tools.off {
                if !m.tools.off.contains(row) {
                    m.tools.off.push(row.clone());
                }
            }
        }
        self.save_meta(probe);
        let cm = probe.meta();
        if std::fs::canonicalize(&cm.cwd).ok().as_deref() != Some(cwd) {
            return Err(refusal(
                "subsessions.cwd_moved",
                format!(
                    "start_session refused: the new session runs in {}, not the folder that was checked ({})",
                    cm.cwd.display(),
                    cwd.display()
                ),
                json!({"cwd": cwd}),
            ));
        }
        let same_family = crate::web_modes::family_of(&cm) == crate::web_modes::family_of(pm);
        // A parent still in full access after `sessions.allowFullAccess` was turned off: its child
        // starts as a cross-family child would, at the person's start level, which is not full access.
        let capped = parent_mode.as_deref().is_some_and(super::start_mode::is_full_access)
            && !self.full_access_allowed();
        let inherit = same_family && !capped;
        // Another family (or a capped parent): the parent's level on the child's modes
        // (`start_mode.rs`, "Inherit"), which `hold_subsession` then holds to the parent.
        let mode =
            if inherit { parent_mode } else { self.start_mode_for(probe, Some(&parent.id)).await };
        if let Some(mode) = mode {
            let params = json!({"_meta": {"acpmux": {(super::person::START_MODE_FIELD): mode}}});
            // The inherit rule (or the parent's level on another family) grants it; a refusal
            // ends the new session.
            if inherit {
                self.start_in_mode(false, Some(&parent.id), &params, probe, false).await?;
            } else if let Err(e) = self.set_mode(probe, &mode).await {
                tracing::warn!(session = %probe.id, "sub-session start mode skipped: {}", e.message);
            }
            // Granted for the parent's full access, which its harness may only have claimed: the
            // child's mode is cmux's own (`trust_wait.rs`) only when the parent's is, then and now.
            if !super::trust_wait::full_access_by_cmux(pm)
                || !super::trust_wait::full_access_by_cmux(&parent.meta())
            {
                probe.meta.lock().unwrap_or_else(|e| e.into_inner()).mode_set_by_cmux = None;
                self.save_meta(probe);
            }
        }
        // Capped to the parent as it is now, not as it was when the start was checked.
        self.hold_subsession(&parent.meta(), probe).await
    }

    /// `e`, a refusal of the new sub-session `probe`, once `probe` is closed: it never runs
    /// unchecked.
    pub(super) async fn close_refused(&self, probe: &Arc<Session>, e: RpcError) -> RpcError {
        let closed = match self.kill(probe, true).await {
            Ok(()) => format!("session {} was closed", probe.id),
            Err(c) => {
                format!(
                    "session {} could not be closed ({}): close it in cmux",
                    probe.id, c.message
                )
            }
        };
        let message = format!("{}; {closed}", e.message);
        RpcError { message, ..e }
    }

    /// A message runs as the receiver's prompt: never in a session that asks less than its
    /// sender, by its harness mode or its policy.
    pub(super) async fn receiver_check(
        &self,
        caller: &Session,
        target: &Session,
    ) -> Result<(), RpcError> {
        let (cm, tm) = (caller.meta(), target.meta());
        if self.receiver_access(&tm, &cm).await > self.caller_access(&cm)
            || self.policy_laxer(&tm, &cm).await
        {
            return Err(refusal(
                "subsessions.receiver_asks_less",
                format!(
                    "{} asks less than this session (its harness mode or permission policy), so a message from here would run with less checking than this session has. Ask the user to send it.",
                    tm.name
                ),
                json!({"sessionId": target.id}),
            ));
        }
        Ok(())
    }

    /// The policy session `m` runs: its own, else the daemon default; one
    /// acpmux cannot parse counts as `ask`, and so does approve-all while MDM
    /// forces full access off (`policy_for`), so comparisons and inheritance
    /// rank it as it answers.
    pub(super) async fn effective_policy(&self, m: &SessionMeta) -> PermissionPolicy {
        let policy = match m.permission_policy.as_deref() {
            Some(p) => p.parse().unwrap_or(PermissionPolicy::Ask),
            None => self.config.read().await.permission_policy,
        };
        if super::full_access_bound::policy_is_full_access(policy) && !self.approve_all_allowed() {
            return PermissionPolicy::Ask;
        }
        policy
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

    /// What harness `harness` resolves to in `cwd`: its name, the folder
    /// whose profile it is (none for a catalog profile), and the whole
    /// profile. None when it does not resolve.
    async fn profile_identity(
        &self,
        harness: &str,
        cwd: &Path,
        remote: bool,
    ) -> Option<(String, Option<std::path::PathBuf>, Value)> {
        let cfg = self.config.read().await;
        let r = self.resolve_new(&cfg, Some(harness.to_owned()), &None, None, remote, Some(cwd));
        let r = r.ok()?;
        Some((r.agent, r.folder_root, serde_json::to_value(&r.profile).ok()?))
    }

    /// Whether session `m` runs a folder profile other than `caller`'s own:
    /// its harness is no catalog profile, and it is not the very profile
    /// the caller runs (same name, same folder, same contents and command).
    async fn foreign_folder_profile(&self, m: &SessionMeta, caller: &SessionMeta) -> bool {
        if self.config.read().await.profile(&m.harness).is_some() {
            return false;
        }
        let theirs = self.profile_identity(&m.harness, &m.cwd, m.remote_origin).await;
        let own = self.profile_identity(&caller.harness, &caller.cwd, caller.remote_origin).await;
        !(theirs.is_some() && theirs == own && m.harness_argv == caller.harness_argv)
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

    /// A family prompt (`provenance` of kind `subsession_message`, a retry
    /// a sub-session asked for, `from` it, or a continuation of either) about to run in `session`: refused
    /// when its sender is gone or the receiver now asks less than the sender,
    /// by mode or policy (either changed while it waited in the queue, or the
    /// agent's start changed the mode).
    pub(super) async fn family_dispatch_check(
        &self,
        session: &Session,
        provenance: Option<&Value>,
    ) -> Result<(), RpcError> {
        let Some(p) = provenance.filter(|p| is_family(Some(p))) else {
            return Ok(());
        };
        let from = p.get("from").and_then(Value::as_str).unwrap_or_default();
        let sender = self.resolve(from).ok().filter(|s| s.id == from).ok_or_else(|| {
            refusal(
                "subsessions.sender_gone",
                format!("the session that sent this message ({from}) is gone, so it does not run"),
                json!({"from": from}),
            )
        })?;
        let (sm, tm) = (sender.meta(), session.meta());
        if self.receiver_access(&tm, &sm).await > self.caller_access(&sm)
            || self.policy_laxer(&tm, &sm).await
        {
            return Err(refusal(
                "subsessions.receiver_asks_less",
                format!(
                    "{} now asks less than {}, which sent this message, so it does not run. Ask the user to send it.",
                    tm.name, sm.name
                ),
                json!({"sessionId": session.id, "from": from}),
            ));
        }
        Ok(())
    }

    /// Where and on what a sub-session starts, before anything starts, in
    /// this order: the harness (it needs no trust answer, so a refused one
    /// asks the person nothing), a folder the person marked untrusted (refused
    /// without a card), the trust card for a folder nobody decided
    /// (`trust_wait.rs`), then the folder walk, which reads that answer. Ok
    /// is whether a decision trusts the folder (`ensure_folder_trusted`).
    pub(super) async fn subsession_place_check(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        pm: &SessionMeta,
        folder: &Path,
        harness: &str,
        model: Option<&str>,
        short: &str,
    ) -> Result<bool, RpcError> {
        self.subsession_harness_check(pm, harness, model, folder).await?;
        self.subsession_folder_check(pm, folder, Walk::BeforeCard).await?;
        let decided = self.ensure_folder_trusted(parent, folder, harness, short).await?;
        let rules = !Self::web_turn(parent);
        // The parent as it is after the card: one that left full access meanwhile walks as it is now.
        self.subsession_folder_check(&parent.meta(), folder, Walk::Answered { rules }).await?;
        Ok(decided)
    }

    /// Whether a sub-session may start in `folder` (resolved) for a caller
    /// with meta `pm`, by the trust walk `walk` (module docs).
    async fn subsession_folder_check(
        &self,
        pm: &SessionMeta,
        folder: &Path,
        walk: Walk,
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
        let allowed = move || folder_allowed(&paths, &folder, mine.as_deref(), full, walk);
        tokio::task::spawn_blocking(allowed).await.map_err(|e| RpcError::internal(e.to_string()))?
    }

    /// Before anything starts: harness `harness` in `cwd`, for a caller with
    /// meta `pm`, is refused when it is a folder profile or its command
    /// skips the checks, unless the caller runs in full access or it is the
    /// caller's own harness. One the catalog cannot resolve is left to
    /// `session/new` to refuse.
    async fn subsession_harness_check(
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
        // The caller's own harness: the very profile it runs, from the same folder.
        let own = self.profile_identity(&pm.harness, &pm.cwd, pm.remote_origin).await;
        let this = serde_json::to_value(&r.profile)
            .ok()
            .map(|p| (r.agent.clone(), r.folder_root.clone(), p));
        if own.is_some() && own == this && r.profile.argv == pm.harness_argv {
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
        self.hold_mode(pm, child).await
    }

    /// The harness half of [`Hub::hold_subsession`]: new session `child` never runs its harness
    /// asking less than `pm`, the session that started it; moved to an asking mode, else refused
    /// (the caller closes it). Also a chat a caller session started with no mode
    /// (`start_mode.rs`, "Inherit"), against that session as it is now.
    pub(super) async fn hold_mode(
        self: &Arc<Self>,
        pm: &SessionMeta,
        child: &Arc<Session>,
    ) -> Result<(), RpcError> {
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
