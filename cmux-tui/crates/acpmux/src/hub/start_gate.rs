//! Starting a session in a mode that does not ask without the person:
//! the caller token (inherit), approved presets and the refusal that names
//! where to approve. The rules and the threat model are in `hub/person.rs`
//! ("Starting in a mode that does not ask"), (a), (b) and (d).

use super::person::{REASON, person_required, valid_key};
use super::*;

mod preset_bind;
pub(crate) use preset_bind::StartGrant;

/// The env var that carries a session's caller token to its harness (and
/// so to the acpmux CLI its agent runs).
pub const CALLER_TOKEN_ENV: &str = "ACPMUX_SESSION_TOKEN";
/// The env var that names the socket of the daemon that issued the caller
/// token: the CLI sends the token to that socket only (`client.rs`).
pub const CALLER_SOCKET_ENV: &str = "ACPMUX_SESSION_TOKEN_SOCKET";
/// The env vars `caller_env` sets: acpmux's alone, never a profile's,
/// preset's or request's (`agent/command.rs` drops them from those).
pub const CALLER_ENV_KEYS: [&str; 2] = [CALLER_TOKEN_ENV, CALLER_SOCKET_ENV];
/// `_meta.acpmux` field of a first `initialize`: `{sessionId, token}`.
pub const CALLER_FIELD: &str = "callerSession";
/// `_meta.acpmux` field of `session/new`: the mode the session starts in.
pub const START_MODE_FIELD: &str = "mode";

/// This daemon run's caller secret: 32 random bytes, in memory only.
fn caller_secret() -> &'static [u8; 32] {
    static SECRET: std::sync::OnceLock<[u8; 32]> = std::sync::OnceLock::new();
    SECRET.get_or_init(|| {
        let mut bytes = [0u8; 32];
        // No randomness means no safe token: the daemon cannot serve.
        getrandom::fill(&mut bytes).expect("the OS random generator for the caller secret"); // crash-allow: no randomness, no safe token
        bytes
    })
}

/// Caller tokens of an earlier daemon run, by session: the one each host
/// this run adopted started its harness with (`Hub::adopt_caller_token`).
/// An agent host outlives its daemon (an update restarts acpmux), and its
/// harness and MCP servers keep the earlier run's token, so the host keeps
/// it in its owner-only record (`HostRecord::caller_token`) beside its
/// `owner_token`, which grants more (the harness's own stdio): reading the
/// record gains nothing that token did not already give. The run that adopts
/// the host accepts it for that one session until a new host of the session
/// starts. A token that proves nothing is refused with how to get a new one
/// (`acpmux session restart`, `server/subsessions.rs`).
fn adopted_callers() -> &'static std::sync::Mutex<HashMap<String, String>> {
    static ADOPTED: std::sync::OnceLock<std::sync::Mutex<HashMap<String, String>>> =
        std::sync::OnceLock::new();
    ADOPTED.get_or_init(Default::default)
}

/// The caller token of session `session_id` on this daemon run (`hub/person.rs`
/// (a)): lowercase hex HMAC-SHA256(run secret,
/// "acpmux-caller-session-v1" 0 session id).
pub fn caller_token(session_id: &str) -> String {
    let mut message = b"acpmux-caller-session-v1".to_vec();
    message.push(0);
    message.extend_from_slice(session_id.as_bytes());
    cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        caller_secret(),
        &message,
    ))
}

/// The env a harness of session `session_id` gets for (a): its caller token
/// and this daemon's socket, the one place the token is sent.
pub fn caller_env(session_id: &str) -> [(&'static str, String); 2] {
    let socket = crate::config::socket_path().to_string_lossy().into_owned();
    [(CALLER_TOKEN_ENV, caller_token(session_id)), (CALLER_SOCKET_ENV, socket)]
}

/// Whether `token` is the caller token of `session_id` (constant time).
pub fn caller_proves(session_id: &str, token: &str) -> bool {
    valid_key(token) && cmux_local_auth::tokens_match(token, &caller_token(session_id))
}

/// Remove `_meta.acpmux.callerSession` from any request's params and return
/// its `(sessionId, token)`. Only a first `initialize` is ever read
/// (`server/mod.rs`); everywhere else it is dropped unread.
pub fn take_caller(params: &mut Value) -> Option<(String, String)> {
    let taken = params
        .pointer_mut("/_meta/acpmux")
        .and_then(Value::as_object_mut)
        .and_then(|m| m.remove(CALLER_FIELD))?;
    let field = |k: &str| taken.get(k).and_then(Value::as_str).map(str::to_owned);
    Some((field("sessionId")?, field("token")?))
}

/// The name of this host the refusal names (module docs, (d)): the host
/// name without a trailing `.local`, as the person sees it in cmux NEXT.
pub fn host_label() -> &'static str {
    static HOST: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    HOST.get_or_init(|| {
        let name = read_host_name().unwrap_or_default();
        let name = name.trim();
        let name = name.strip_suffix(".local").unwrap_or(name);
        if name.is_empty() { "this machine".to_owned() } else { name.to_owned() }
    })
}

#[cfg(unix)]
fn read_host_name() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: a writable buffer of the length passed; gethostname writes at
    // most that many bytes.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return None;
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    Some(String::from_utf8_lossy(&buf[..end]).into_owned())
}

#[cfg(not(unix))]
fn read_host_name() -> Option<String> {
    std::env::var("COMPUTERNAME").ok()
}

/// The refusal of a mode that does not ask (module docs, (d)): one
/// sentence that names where the person approves it. `start`: a
/// `session/new`; else a mode change of a running session. `local`: the
/// unix socket or the local app; a Web or peer client never learns this
/// host's name (it reads "the Mac that runs it" instead, and no `host`).
pub fn mode_person_required(
    mode: &str,
    preset: Option<&str>,
    start: bool,
    local: bool,
) -> RpcError {
    let host = if local { host_label() } else { "the Mac that runs it" };
    let message = match (start, preset) {
        (true, Some(p)) => format!(
            "mode {mode} does not ask before it acts, so only the person starts a session in it: approve preset {p} once in cmux NEXT on {host}, or start the session there"
        ),
        (true, None) => format!(
            "mode {mode} does not ask before it acts, so only the person starts a session in it: start it in cmux NEXT on {host}, approve a preset with this mode there once and use acpmux new --preset NAME, or start without --mode: the session then runs in the person's own start mode"
        ),
        (false, _) => format!(
            "mode {mode} does not ask before it acts, so only the person sets it: set it in cmux NEXT on {host}, or start the session from a preset approved there once"
        ),
    };
    let mut data = json!({"reason": REASON, "mode": mode, "preset": preset});
    if local {
        data["host"] = json!(host);
    }
    RpcError::new(-32000, message).with_data(data)
}

/// What a `session/new` asks to start in (module docs, (a) and (b)).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartMode {
    /// `_meta.acpmux.mode`, else the preset's mode.
    pub mode: String,
    /// The preset the request names, for the refusal.
    pub preset: Option<String>,
    /// The request starts the named preset as it is: its own mode, its
    /// harness, no adopted conversation and no model, effort, policy, route
    /// or env of its own (module docs, (b)); a folder is fine. A route swaps
    /// the provider's base URL and keys, so it counts as env.
    pub preset_fits: bool,
    /// `preset_fits`, and the person approved the preset's current contents.
    /// The start checks it again against the contents the session resolved
    /// and spawned with (`start_gate/preset_bind.rs`).
    pub preset_approved: bool,
    /// The request adopts a conversation (`_meta.acpmux.adopt`), which may be
    /// a session already running: a mode that does not ask never applies to
    /// it without the person.
    pub adopts: bool,
}

impl StartMode {
    /// From `session/new` params against `cfg`; None when no mode is asked.
    pub fn of(params: &Value, cfg: &crate::config::Config) -> Option<Self> {
        let meta = params.pointer("/_meta/acpmux");
        let pick = |key: &str| -> Option<String> {
            meta.and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .or_else(|| params.get(key).and_then(Value::as_str))
                .map(str::to_owned)
        };
        let requested =
            meta.and_then(|m| m.get(START_MODE_FIELD)).and_then(Value::as_str).map(str::to_owned);
        let preset_name = pick("preset");
        let preset = preset_name.as_deref().and_then(|n| cfg.presets.get(n));
        let mode = requested.or_else(|| preset.and_then(|p| p.mode.clone()))?;
        let adopts = meta.and_then(|m| m.get("adopt")).is_some_and(|v| !v.is_null());
        let harness = pick("harness");
        let given = |key: &str| meta.and_then(|m| m.get(key)).or_else(|| params.get(key));
        let overrides =
            ["model", "effort", "policy", "route"].into_iter().any(|k| pick(k).is_some())
                || given("env")
                    .is_some_and(|e| !e.is_null() && e.as_object().is_none_or(|o| !o.is_empty()));
        let preset_fits = preset.is_some_and(|p| {
            p.mode.as_deref() == Some(mode.as_str())
                && harness.as_deref().is_none_or(|h| h == p.harness)
                && !adopts
                && !overrides
        });
        let preset_approved = preset_fits && preset.is_some_and(|p| p.mode_approved());
        Some(Self { mode, preset: preset_name, preset_fits, preset_approved, adopts })
    }
}

impl Hub {
    /// The session a first unix socket `initialize` proved it runs in
    /// (`hub/person.rs` (a)): `(sessionId, token)` from [`take_caller`],
    /// when the token is that session's on this run and the session is here.
    pub fn proven_caller(&self, (id, token): (String, String)) -> Option<String> {
        let proves = caller_proves(&id, &token) || self.adopted_caller_proves(&id, &token);
        if proves && self.resolve(&id).is_ok_and(|s| s.id == id) { Some(id) } else { None }
    }

    /// Whether `token` is the caller token session `session_id`'s adopted
    /// host started its harness with under an earlier daemon run (constant time).
    fn adopted_caller_proves(&self, session_id: &str, token: &str) -> bool {
        let adopted = adopted_callers().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        adopted
            .get(session_id)
            .is_some_and(|known| valid_key(token) && cmux_local_auth::tokens_match(token, known))
    }

    /// A host of session `session_id` was adopted (`hosts.rs`): its harness
    /// and the MCP servers it started keep the caller token from the host's
    /// record, so this run knows the session by that token too. A token of
    /// this run, a malformed one or none (a host of an older build) records
    /// nothing. Answers whether the agent holds a token this run knows: false
    /// asks for a restart between turns (`Hub::restart_unproven`).
    pub(super) fn adopt_caller_token(&self, session_id: &str, token: Option<String>) -> bool {
        let known = token.as_deref().is_some_and(valid_key);
        let mut adopted =
            adopted_callers().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match token.filter(|t| valid_key(t) && !caller_proves(session_id, t)) {
            Some(token) => adopted.insert(session_id.to_owned(), token),
            None => adopted.remove(session_id),
        };
        known
    }

    /// A new host of session `session_id` started: its harness has this
    /// run's token, and the adopted one's process group is gone.
    pub(super) fn forget_adopted_caller(&self, session_id: &str) {
        adopted_callers()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(session_id);
    }

    /// A `session/new` without the person (module docs, (a), (b)): a mode
    /// that does not ask only through an approved preset or from a caller
    /// session in that mode. Checked against the harness the request
    /// resolves to now; the handler checks the started session again.
    pub(super) async fn session_new_check(
        &self,
        caller: Option<&str>,
        params: &Value,
    ) -> Result<(), RpcError> {
        let meta = params.pointer("/_meta/acpmux");
        let pick = |key: &str| {
            meta.and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .or_else(|| params.get(key).and_then(Value::as_str))
                .map(str::to_owned)
        };
        // A session on a peer: that peer checks it.
        if pick("peer").is_some_and(|p| !p.is_empty()) {
            return Ok(());
        }
        let (family, bridge, start) = {
            let cfg = self.config.read().await;
            let Some(start) = StartMode::of(params, &cfg) else { return Ok(()) };
            let adopted =
                crate::adopt::AdoptRequest::from_meta(meta).ok().flatten().and_then(|a| a.harness);
            let harness = pick("harness").or(adopted);
            let cwd = params.get("cwd").and_then(Value::as_str).map(std::path::Path::new);
            match self.resolve_new(
                &cfg,
                harness,
                &pick("preset"),
                pick("model").as_deref(),
                false,
                cwd,
            ) {
                Ok(r) => (
                    crate::config::derive_family(&r.agent, &r.profile),
                    crate::codex_app_server::is_profile_launch(&r.profile.argv),
                    start,
                ),
                // Not startable: the handler answers why.
                Err(_) => return Ok(()),
            }
        };
        self.start_mode_check(caller, &family, bridge, &start).await.map(|_| ())
    }

    /// Whether a client that is not the person may start a session of
    /// `family` in `start` (module docs, (a), (b)), and why; the refusal
    /// names where to approve it (d). An adopt never takes a mode that does
    /// not ask: it may find a session already running, which only the
    /// person widens (`session/set_mode`). A mode that asks needs nothing:
    /// one the asking table lists for `family`, or on the Codex bridge
    /// (`bridge`) its `ask` or `read-only` (`start_mode.rs` `NARROW_MODES`),
    /// which the table leaves out because it refuses Codex for the Web. An
    /// adopt never takes the bridge's: the session it finds may run another
    /// harness than the one it was created on. A caller in the bridge lends
    /// its mode only to the bridge: the same id on another Codex harness (the
    /// codex-acp adapter's `read-only`) may be wider.
    pub(crate) async fn start_mode_check(
        &self,
        caller: Option<&str>,
        family: &str,
        bridge: bool,
        start: &StartMode,
    ) -> Result<StartGrant, RpcError> {
        if self.web_modes().config_value_asks(family, None, Some(start.mode.as_str()))
            || (bridge
                && !start.adopts
                && super::start_mode::NARROW_MODES.contains(&start.mode.as_str()))
        {
            return Ok(StartGrant::Asks);
        }
        if start.adopts {
            return Err(mode_person_required(&start.mode, start.preset.as_deref(), true, true));
        }
        if start.preset_approved {
            return Ok(StartGrant::Preset);
        }
        // The caller's mode now, on the session the daemon bound it to.
        let inherits = match caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)) {
            Some(s) => {
                let m = s.meta();
                crate::web_modes::family_of(&m) == family
                    && crate::web_modes::mode_of(&m).as_deref() == Some(start.mode.as_str())
                    && (bridge || !self.may_run_bridge(&m).await)
            }
            None => false,
        };
        if inherits {
            Ok(StartGrant::Inherit)
        } else {
            Err(mode_person_required(&start.mode, start.preset.as_deref(), true, true))
        }
    }

    /// Whether session `s` runs the Codex bridge both as it was created (its
    /// recorded argv) and as its harness is configured now, which a respawn
    /// (`lifecycle.rs` `child_for`) starts (`web_modes::any_mode_for_web`).
    async fn runs_bridge(&self, s: &Session) -> bool {
        let meta = s.meta();
        crate::web_modes::any_mode_for_web(&meta, self.profile_now(&meta).await.as_ref())
    }

    /// The profile session `m` would start from now, as a respawn resolves it
    /// (`lifecycle.rs` `child_for`): its catalog harness or its folder profile.
    async fn profile_now(&self, m: &crate::store::SessionMeta) -> Option<HarnessProfile> {
        let cfg = self.config.read().await;
        super::resolve::session_profile(&cfg, &m.harness, &m.cwd, m.remote_origin).ok()
    }

    /// Whether session `m` may run the Codex bridge: as it was created (its
    /// recorded argv) or as its harness is configured now.
    async fn may_run_bridge(&self, m: &crate::store::SessionMeta) -> bool {
        crate::codex_app_server::is_profile_launch(&m.harness_argv)
            || self
                .profile_now(m)
                .await
                .is_some_and(|p| crate::codex_app_server::is_profile_launch(&p.argv))
    }

    /// Whether a `session/new` keeps the harness's own start mode rather
    /// than the default one (`hub/start_mode.rs`): it names its own
    /// (`StartMode`, set after the start), or a caller session (`caller`,
    /// never the person) runs in a mode that asks, so a chat it starts is
    /// never wider than it ((a)). A caller that is the chat's starter
    /// ([`Hub::starter_of`]) instead gives it its own level (`start_mode.rs`,
    /// "Inherit").
    pub(crate) async fn keeps_harness_mode(&self, caller: Option<&str>, params: &Value) -> bool {
        if StartMode::of(params, &*self.config.read().await).is_some() {
            return true;
        }
        if self.starter_of(false, caller).is_some() {
            return false;
        }
        let caller = caller.and_then(|id| self.resolve(id).ok());
        caller.is_some_and(|s| {
            let m = s.meta();
            let family = crate::web_modes::family_of(&m);
            self.web_modes().config_value_asks(
                &family,
                None,
                crate::web_modes::mode_of(&m).as_deref(),
            )
        })
    }

    /// The caller session a `session/new` inherits from (`start_mode.rs`, "Inherit"): the one
    /// `caller` proved (an agent's call, never the person), unless the connection is `web` (a
    /// remote one, which has none), or the session is one a remote connection started.
    pub(crate) fn starter_of(&self, web: bool, caller: Option<&str>) -> Option<String> {
        let id = caller.filter(|_| !web)?;
        let s = self.resolve(id).ok().filter(|s| s.id == id)?;
        (!s.meta().remote_origin).then(|| s.id.clone())
    }

    /// A `_acpmux/presets` write without the person (module docs, (b)): no
    /// approval, and no `mode` that does not ask for the preset's family.
    pub(super) async fn preset_mode_check(&self, params: &Value) -> Result<(), RpcError> {
        if params.get("approveMode").and_then(Value::as_bool) == Some(true) {
            return Err(person_required("approving a preset's mode"));
        }
        let Some(mode) = params.pointer("/set/mode").filter(|v| !v.is_null()) else {
            return Ok(());
        };
        let refused = || person_required("a preset mode that does not ask");
        let mode = mode.as_str().ok_or_else(refused)?;
        let family = {
            let cfg = self.config.read().await;
            let name = params.get("name").and_then(Value::as_str);
            let harness = params
                .pointer("/set/harness")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| name.and_then(|n| cfg.presets.get(n)).map(|p| p.harness.clone()));
            harness
                .and_then(|h| cfg.resolve_harness(&h).ok())
                .map(|profile| crate::config::derive_family(&profile, &cfg.harnesses[&profile]))
        };
        match family {
            Some(f) if self.web_modes().config_value_asks(&f, None, Some(mode)) => Ok(()),
            _ => Err(refused()),
        }
    }

    /// A new session's start mode (`hub/person.rs` (a), (b)):
    /// `_meta.acpmux.mode`, else its preset's. The request check ran
    /// against the harness the request resolved to; this checks again
    /// against the session as it started (`person`: the connection is the
    /// person), with a preset's approval held against the contents the
    /// session resolved and spawned with, then sets the mode. A refused or
    /// failed mode ends a session this request created (never one an adopt
    /// found already running).
    pub(crate) async fn start_in_mode(
        self: &Arc<Self>,
        person: bool,
        caller: Option<&str>,
        params: &Value,
        s: &Arc<Session>,
        adopting: bool,
    ) -> Result<(), RpcError> {
        let Some((start, bound)) = self.bound_start(params, s).await else { return Ok(()) };
        // A start mode that would not ask, on a chat whose narrower policy needs one that does
        // (`policy_mode.rs`): the chat keeps its policy's mode and starts anyway.
        let wanted = json!({"modeId": start.mode});
        if let Err(e) = self.refuse_wider_mode(s, method::SESSION_SET_MODE, &wanted).await {
            tracing::warn!(session = %s.id, mode = %start.mode, "start mode skipped: {}", e.message);
            self.append(
                s,
                "mux",
                "start_default_skipped",
                json!({"modeId": start.mode, "error": e.message}),
            );
            return Ok(());
        }
        let bridge = !person && self.runs_bridge(s).await;
        let checked = if person {
            Ok(StartGrant::Person)
        } else {
            self.start_mode_check(caller, &crate::web_modes::family_of(&s.meta()), bridge, &start)
                .await
        };
        let applied = match checked {
            Ok(grant) => match self.set_mode(s, &start.mode).await {
                // The bridge's mode set on what runs now: `set_mode` may have respawned the
                // harness from a profile changed since the check.
                Ok(_)
                    if bridge
                        && matches!(grant, StartGrant::Asks)
                        && !self.runs_bridge(s).await =>
                {
                    Err(mode_person_required(&start.mode, start.preset.as_deref(), true, true))
                }
                Ok(_) => {
                    // A mode granted because the caller runs in it is cmux's own only when the
                    // caller's is: a mode the caller's harness reported by itself passes on no
                    // `mode_set_by_cmux` (`trust_wait.rs` `full_access_by_cmux`).
                    if matches!(grant, StartGrant::Inherit) && !self.mode_is_cmux_set(caller) {
                        s.meta.lock().unwrap_or_else(|e| e.into_inner()).mode_set_by_cmux = None;
                        self.save_meta(s);
                    }
                    self.note_start_grant(s, grant, bound);
                    Ok(())
                }
                Err(e) => Err(e),
            },
            Err(e) => Err(e),
        };
        if let Err(e) = applied {
            if !adopting {
                let _ = self.kill(s, true).await;
            }
            return Err(e);
        }
        Ok(())
    }

    /// Whether session `caller` runs in the mode cmux last set on it (`SessionMeta::mode_set_by_cmux`).
    fn mode_is_cmux_set(&self, caller: Option<&str>) -> bool {
        caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)).is_some_and(|s| {
            let m = s.meta();
            m.mode_set_by_cmux.is_some() && crate::web_modes::mode_of(&m) == m.mode_set_by_cmux
        })
    }

    /// A bare "agent process closed" from a process that died while it
    /// started (`initialize`, `session/new`): the same error with the last
    /// stderr line that says why, once the inbound loop has taken what the
    /// process printed. Any other error is returned as is.
    pub(super) async fn explain_start_failure(session: &Session, mut e: RpcError) -> RpcError {
        if e.message != "agent process closed" {
            return e;
        }
        let last = || {
            session
                .stderr_tail
                .lock()
                .unwrap()
                .iter()
                .rev()
                .map(|l| l.trim().to_owned())
                .find(|l| super::exit_reason::explains_exit(l))
        };
        Self::drain_inbound(session).await;
        let mut found = last();
        if found.is_none() {
            // The stderr reader can trail stdout's close by a moment: one
            // bounded wait for its last lines, then the bare error.
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            Self::drain_inbound(session).await;
            found = last();
        }
        if let Some(line) = found {
            e.message = format!("agent process closed ({}): {line}", session.meta().harness);
        }
        e
    }
}
