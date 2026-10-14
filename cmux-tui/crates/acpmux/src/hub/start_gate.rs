//! Starting a session in a mode that does not ask without the person:
//! the caller token (inherit), approved presets and the refusal that names
//! where to approve. The rules and the threat model are in `hub/person.rs`
//! ("Starting in a mode that does not ask"), (a), (b) and (d).

use super::person::{REASON, person_required, valid_key};
use super::*;

/// The env var that carries a session's caller token to its harness (and
/// so to the acpmux CLI its agent runs).
pub const CALLER_TOKEN_ENV: &str = "ACPMUX_SESSION_TOKEN";
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
/// `session/new`; else a mode change of a running session.
pub fn mode_person_required(mode: &str, preset: Option<&str>, start: bool) -> RpcError {
    let host = host_label();
    let message = match (start, preset) {
        (true, Some(p)) => format!(
            "mode {mode} does not ask before it acts, so only the person starts a session in it: approve preset {p} once in cmux NEXT on {host}, or start the session there"
        ),
        (true, None) => format!(
            "mode {mode} does not ask before it acts, so only the person starts a session in it: start it in cmux NEXT on {host}, or approve a preset with this mode there once and use acpmux new --preset NAME"
        ),
        (false, _) => format!(
            "mode {mode} does not ask before it acts, so only the person sets it: set it in cmux NEXT on {host}, or start the session from a preset approved there once"
        ),
    };
    RpcError::new(-32000, message)
        .with_data(json!({"reason": REASON, "host": host, "mode": mode, "preset": preset}))
}

/// What a `session/new` asks to start in (module docs, (a) and (b)).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartMode {
    /// `_meta.acpmux.mode`, else the preset's mode.
    pub mode: String,
    /// The preset the request names, for the refusal.
    pub preset: Option<String>,
    /// The person approved the named preset's current contents, its mode is
    /// this one, and the request keeps its harness and adopts nothing.
    pub preset_approved: bool,
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
        let preset_approved = preset.is_some_and(|p| {
            p.mode.as_deref() == Some(mode.as_str())
                && p.mode_approved()
                && harness.as_deref().is_none_or(|h| h == p.harness)
                && !adopts
        });
        Some(Self { mode, preset: preset_name, preset_approved })
    }
}

impl Hub {
    /// The session a first unix socket `initialize` proved it runs in
    /// (`hub/person.rs` (a)): `(sessionId, token)` from [`take_caller`],
    /// when the token is that session's on this run and the session is here.
    pub fn proven_caller(&self, (id, token): (String, String)) -> Option<String> {
        if caller_proves(&id, &token) && self.resolve(&id).is_ok_and(|s| s.id == id) {
            Some(id)
        } else {
            None
        }
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
        let (family, start) = {
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
                Ok(r) => (crate::config::derive_family(&r.agent, &r.profile), start),
                // Not startable: the handler answers why.
                Err(_) => return Ok(()),
            }
        };
        self.start_mode_check(caller, &family, &start)
    }

    /// Whether a client that is not the person may start a session of
    /// `family` in `start` (module docs, (a), (b)); the refusal names where
    /// to approve it (d).
    pub(crate) fn start_mode_check(
        &self,
        caller: Option<&str>,
        family: &str,
        start: &StartMode,
    ) -> Result<(), RpcError> {
        if self.web_modes().config_value_asks(family, None, Some(start.mode.as_str())) {
            return Ok(());
        }
        if start.preset_approved {
            return Ok(());
        }
        // The caller's mode now, on the session the daemon bound it to.
        let inherits =
            caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)).is_some_and(|s| {
                let m = s.meta();
                crate::web_modes::family_of(&m) == family
                    && crate::web_modes::mode_of(&m).as_deref() == Some(start.mode.as_str())
            });
        if inherits {
            Ok(())
        } else {
            Err(mode_person_required(&start.mode, start.preset.as_deref(), true))
        }
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
    /// person), then sets the mode. A refused or failed mode ends a session
    /// this request created (never one an adopt found already running).
    pub(crate) async fn start_in_mode(
        self: &Arc<Self>,
        person: bool,
        caller: Option<&str>,
        params: &Value,
        s: &Arc<Session>,
        adopting: bool,
    ) -> Result<(), RpcError> {
        let start = {
            let cfg = self.config.read().await;
            StartMode::of(params, &cfg)
        };
        let Some(start) = start else { return Ok(()) };
        let checked = if person {
            Ok(())
        } else {
            self.start_mode_check(caller, &crate::web_modes::family_of(&s.meta()), &start)
        };
        let applied = match checked {
            Ok(()) => self.set_mode(s, &start.mode).await.map(|_| ()),
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
}
