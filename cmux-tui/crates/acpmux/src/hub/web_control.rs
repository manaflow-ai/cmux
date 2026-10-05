//! Part of `Hub`; see `hub/mod.rs`. Web control of a session (a prompt, a
//! permission answer, a mode or option set) follows the asking-mode table
//! (`web_modes.rs`), built and logged once at start and at every reload.
//!
//! The check is stateless on the mode: a Web connection controls a session
//! only while its CURRENT mode is in the table, whatever wrote that mode (a
//! load, a resume, a pool claim, a preset, a harness switch, the harness
//! itself). It runs in the remote guard and again when a queued prompt is
//! dispatched or an answer is applied, under the session's meta lock, the
//! same lock every mode write takes (`write_mode_state`, the one setter).
//! The sticky `web_control_ended` flag adds one rule: after a mode left
//! the table, the harness's own return does not restore Web control; the
//! unix socket or the local app setting an asking mode does.
//!
//! `Control::Peer` (a proven peer daemon of the same user,
//! `server/peer_auth.rs`) has no mode rule, unless it forwards a request
//! for its own Web client (`_meta.acpmux.via = "web"`): that request runs
//! as `Control::Web`.

use super::*;
use crate::web_modes::WebModeTable;

/// The `webAskingModes` the table was built from, and the table.
pub(super) type WebModeCache = (std::collections::BTreeMap<String, Vec<String>>, Arc<WebModeTable>);

impl Hub {
    /// The merged asking-mode table the remote guard and Web control use.
    /// config.json stays the source: a config changed without a reload (as
    /// in-process tests do) rebuilds the table quietly, still minus the
    /// non-asking entries.
    pub(crate) fn web_modes(&self) -> Arc<WebModeTable> {
        let mut cached = self.web_modes.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(c) = self.config.try_read()
            && c.web_asking_modes != cached.0
        {
            *cached =
                (c.web_asking_modes.clone(), Arc::new(WebModeTable::build(&c.web_asking_modes).0));
        }
        cached.1.clone()
    }

    /// `_acpmux/web_modes {sessionId?, configId?, value?}` (unix socket
    /// only): the merged table, the guard's mode fields and free config
    /// ids, and for a known session its family and mode; with configId and
    /// value also whether that value keeps it asking. An unknown session is
    /// no error (no `session` key); an ambiguous key is.
    pub(crate) fn web_modes_view(&self, params: &Value) -> Result<Value, RpcError> {
        let table = self.web_modes();
        let mut out = json!({
            "families": table.families(),
            "modeFields": crate::web_modes::MODE_FIELDS,
            "freeConfigIds": crate::web_modes::FREE_CONFIG_IDS,
        });
        let Some(key) = params.get("sessionId").and_then(Value::as_str) else { return Ok(out) };
        let s = match self.resolve(key) {
            Ok(s) => s,
            Err(e) if e.code == RpcError::not_found("").code => return Ok(out),
            Err(e) => return Err(e),
        };
        let m = s.meta();
        let family = crate::web_modes::family_of(&m);
        out["session"] =
            json!({"sessionId": s.id, "family": family, "mode": crate::web_modes::mode_of(&m)});
        let text = |k: &str| params.get(k).and_then(Value::as_str);
        if let (Some(id), Some(value)) = (text("configId"), text("value")) {
            out["session"]["asks"] = json!(table.config_value_asks(&family, Some(id), Some(value)));
        }
        Ok(out)
    }

    /// Build the table from config.json and log it (and every ignored
    /// `webAskingModes` entry) once.
    pub(super) fn refresh_web_modes(
        &self,
        extra: &std::collections::BTreeMap<String, Vec<String>>,
    ) {
        let (table, warnings) = WebModeTable::build(extra);
        for w in &warnings {
            tracing::warn!("{w}");
        }
        tracing::info!("web asking modes: {}", table.summary());
        *self.web_modes.lock().unwrap_or_else(|e| e.into_inner()) =
            (extra.clone(), Arc::new(table));
    }

    /// The one setter for a session's mode state (`modes`, the current mode,
    /// `configOptions`). Leaving the table (a known asking mode before the
    /// write, one that does not ask after it) sets the sticky flag, under
    /// the same meta lock as the write, so no write path skips it. A session
    /// that starts in a mode that does not ask never left the table: the
    /// stateless rule refuses it (`remote.mode_not_asking`).
    pub(crate) fn write_mode_state(
        &self,
        session: &Session,
        writes: impl IntoIterator<Item = ModeWrite>,
    ) {
        let table = self.web_modes();
        let left = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let asked = crate::web_modes::mode_of(&m).is_some() && table.session_asks(&m);
            for w in writes {
                match w {
                    ModeWrite::Modes(v) => m.modes = Some(v),
                    ModeWrite::CurrentMode(v) => {
                        if let Some(modes) = m.modes.as_mut() {
                            modes["currentModeId"] = v;
                        }
                    }
                    ModeWrite::ConfigOptions(v) => m.config_options = Some(v),
                }
            }
            (asked
                && !table.session_asks(&m)
                && !session.web_control_ended.swap(true, Ordering::SeqCst))
            .then(|| crate::web_modes::mode_of(&m))
        };
        if let Some(mode) = left {
            tracing::warn!(session = %session.id, ?mode, "the session left the asking-mode table: Web control ends");
            self.append(session, "mux", "remote_control_ended", json!({"mode": mode}));
        }
    }

    /// The unix socket or the local app set the mode (or the daemon moved a
    /// new Web session to its asking default): an asking mode clears the
    /// sticky flag.
    pub(crate) fn restore_web_control(&self, session: &Session) {
        let asks = self.web_modes().session_asks(&session.meta());
        if asks && session.web_control_ended.swap(false, Ordering::SeqCst) {
            self.append(session, "mux", "remote_control_restored", json!({}));
        }
    }

    /// Whether `control` may control `session` now: for the Web, only
    /// while the sticky flag is clear, the current mode asks (or there is
    /// none), and the permission policy and rules ask. The one check, used
    /// by the guard and again at dispatch.
    pub(crate) fn web_control_check(
        &self,
        session: &Session,
        control: Control,
    ) -> Result<(), RpcError> {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        self.web_control_verdict(session, &meta, control)
    }

    /// A steer into the running turn: checked like a prompt, and a Web steer
    /// makes that turn a Web turn (no chat allowance for what it adds).
    pub(super) fn check_steer(&self, session: &Session, control: Control) -> Result<(), RpcError> {
        self.web_control_check(session, control)?;
        if control == Control::Web
            && let Some(t) = session.turn.lock().unwrap_or_else(|e| e.into_inner()).as_mut()
        {
            t.control = Control::Web;
        }
        Ok(())
    }

    /// Checked again at dispatch, under the meta lock every mode, policy and
    /// rules write takes: the session may have changed since the guard ran,
    /// or while this prompt waited in the queue. A refused prompt never
    /// reaches the harness; the log records `prompt_refused`.
    pub(super) fn check_dispatch(
        &self,
        session: &Session,
        control: Control,
        prompt_id: &str,
        turn_id: &str,
        client: &str,
    ) -> Result<(), RpcError> {
        let refused = {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            self.web_control_verdict(session, &m, control).err()
        };
        let Some(e) = refused else { return Ok(()) };
        self.append(
            session,
            "mux",
            "prompt_refused",
            json!({"promptId": prompt_id, "turnId": turn_id, "client": client, "error": e.message, "data": e.data}),
        );
        Err(e)
    }

    /// `web_control_check` for a caller that holds the meta lock (dispatch).
    pub(crate) fn web_control_verdict(
        &self,
        session: &Session,
        meta: &crate::store::SessionMeta,
        control: Control,
    ) -> Result<(), RpcError> {
        if control != Control::Web {
            return Ok(());
        }
        let mode = crate::web_modes::mode_of(meta);
        let shown = mode.as_deref().unwrap_or("(unknown)").to_owned();
        if session.web_control_ended.load(Ordering::SeqCst) {
            return Err(RpcError::new(
                -32000,
                format!(
                    "Web control of this session ended: its mode left the asking-mode table (now {shown}); the local user or the local app can set an asking mode again"
                ),
            )
            .with_data(json!({"reason": "remote.mode_left_asking_table", "mode": mode})));
        }
        if !self.web_modes().session_asks(meta) {
            return Err(RpcError::new(
                -32000,
                format!(
                    "this session runs in mode {shown}, which does not ask before it acts; a paired device cannot prompt it or answer its permissions until the local user sets an asking mode"
                ),
            )
            .with_data(json!({
                "reason": "remote.mode_not_asking",
                "mode": mode,
                "harness": meta.harness,
                "family": crate::web_modes::family_of(meta),
            })));
        }
        // The permission policy and rules must ask too: a session with no
        // mode relies on them, and `approve-all` approves under any mode.
        let default = self.config.try_read().ok().map(|c| c.permission_policy);
        if let Some(why) = policy_not_asking(meta, default) {
            return Err(RpcError::new(
                -32000,
                format!(
                    "this session's permission settings do not ask before it acts ({}); a paired device cannot prompt it or answer its permissions until the local user sets ask or deny-all",
                    why["why"].as_str().unwrap_or_default()
                ),
            )
            .with_data(json!({
                "reason": "remote.policy_not_asking",
                "policy": why["policy"],
                "rules": why["rules"],
                "harness": meta.harness,
            })));
        }
        Ok(())
    }
}

/// A Web permission answer that would grant more than this one request
/// (an `allow_always` or `reject_always` option, or the chat allowance).
pub(crate) fn lasting_grant_refused(what: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "a paired device can allow once or deny only; {what} is a lasting grant and is refused"
    ))
    .with_data(json!({"reason": "remote.lasting_grant_refused", "option": what}))
}

/// Why a session's permission settings do not ask, or None when they do:
/// its effective policy must be `ask` or `deny-all`, and its rules may not
/// auto-approve (any `autoApprove` entry, or `default: approve`). Without
/// the daemon default (the config is being written) it fails closed.
fn policy_not_asking(
    meta: &crate::store::SessionMeta,
    default: Option<crate::config::PermissionPolicy>,
) -> Option<Value> {
    use crate::config::PermissionPolicy;
    let own = meta.permission_policy.as_deref().and_then(|p| p.parse::<PermissionPolicy>().ok());
    let Some(policy) = own.or(default) else {
        return Some(
            json!({"why": "the daemon default policy is being changed; retry", "policy": null, "rules": null}),
        );
    };
    if !matches!(policy, PermissionPolicy::Ask | PermissionPolicy::DenyAll) {
        let p = policy.to_string();
        return Some(json!({"why": format!("policy {p}"), "policy": p, "rules": null}));
    }
    let rules = meta.permission_rules.as_ref();
    let approves = rules
        .and_then(|r| r.get("autoApprove"))
        .and_then(Value::as_array)
        .is_some_and(|a| !a.is_empty());
    let default_approve =
        rules.and_then(|r| r.get("default")).and_then(Value::as_str) == Some("approve");
    if approves || default_approve {
        let why = if approves { "an autoApprove rule" } else { "rule default approve" };
        return Some(json!({"why": why, "policy": policy.to_string(), "rules": rules}));
    }
    None
}

/// One write of a session's mode state (`Hub::write_mode_state`).
pub(crate) enum ModeWrite {
    Modes(Value),
    CurrentMode(Value),
    ConfigOptions(Value),
}

/// The rules a request that controls a session runs under.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Control {
    /// The unix socket or the local app: no mode rule.
    #[default]
    Local,
    /// A Web connection, or a peer forwarding for its Web client.
    Web,
    /// A proven peer daemon acting for its own local user: no mode rule.
    Peer,
}
