//! Only the person-facing app may allow (cx-1l61).
//!
//! An agent runs as the user, so it can run the acpmux CLI or open the unix
//! socket itself. Without this rule it could allow its own permission prompt
//! or turn its own session to approve-all. The daemon cannot see who sits at
//! a client, so the app proves it with a per-launch person key:
//!
//! - The app makes 32 random bytes at each launch and keeps them in memory
//!   only: never in an environment variable, argv, a file, a log, or a child
//!   process.
//! - The daemon learns the key from the app only, on one of two paths that
//!   an agent cannot take:
//!   - a Team-signed daemon (Release): `_acpmux/person_enroll` on the unix
//!     socket, from a peer whose audit token is the signed app that contains
//!     this binary (`cmux_link::app_caller`, prover A of
//!     plans/cmux-next/identity.md). A new app launch enrolls its new key.
//!   - an unsigned daemon (DEV, tests): `--person-key-fd` at spawn only. The
//!     daemon reads the key, closes the descriptor and never takes another
//!     key while it runs. A signed daemon ignores the descriptor (a same-uid
//!     process could restart the daemon with its own key).
//! - A connection presents the key in an `initialize` that is its FIRST
//!   request (`_meta.acpmux.personKey`; stripped before any handler, log or reply).
//!   A unix socket connection or a proven LocalApp connection that presents
//!   the current key is the person for its whole life. Web and Peer
//!   connections never are.
//!
//! [`Hub::person_check`] is the one check, run for every request before it
//! is handled or forwarded. Without the person, a client may read prompts and
//! deny or cancel them, and may narrow (ask, deny-all, deny rules, asking
//! modes). It may never allow (a permission answer, a question's answer, a
//! group's allow) and never widen what runs without asking (a policy other
//! than ask or deny-all for a session, the daemon default, a family default
//! or a preset; a rule that could auto-approve; a mode the reviewed asking
//! table does not list; a spawn env). Such a request gets
//! [`REASON`] and changes nothing: a prompt stays pending.
//!
//! Also without the person: no rules change under a session policy that
//! does not ask (a rule is then what keeps a tool asking), no removal of a
//! stored family-default or preset policy, no write of the `handoffKey`
//! tag (a handoff adopts the session it names, and never wider: see
//! `handoff/ops.rs`), and no session method acpmux does not handle itself
//! (the harness catch-all, [`harness_forward_check`]).
//!
//! Residual risks (not covered here):
//! - Same-uid file writes: an agent that edits config.json, a profile file
//!   or the store directly. That needs an OS boundary between the agent and
//!   the user's files.
//! - `_acpmux/harness/add` (a new harness profile), `_acpmux/defaults`
//!   `prefer` and a preset's `harness` (which profile, and so which profile
//!   default policy, a new session gets), a preset's `args`,
//!   `acp.trust.set`, `_acpmux/harness_enable` and `_acpmux/import` stay
//!   open to the unix socket.
//! - DEV only: a same-uid process that starts the unsigned daemon before the
//!   app does gives it its own spawn key; the app then hands that daemon off
//!   (when its agents run under agent hosts), but the process held the
//!   person until then.

use super::*;

/// Where the first `initialize` carries the key (`_meta.acpmux`).
pub const KEY_FIELD: &str = "personKey";
/// `error.data.reason` of a refused allow or grant.
pub const REASON: &str = "permission.person_required";
/// `error.data.reason` of `_acpmux/person_enroll` on a daemon that cannot
/// verify the app's signature and has another key (an unsigned build that
/// this app launch did not start).
pub const ENROLL_UNAVAILABLE: &str = "person.enroll_unavailable";
/// `error.data.reason` of `_acpmux/person_enroll` from a client that is not
/// the signed app.
pub const ENROLL_REFUSED: &str = "person.enroll_refused";

/// Where `_acpmux/permission_respond` carries who answered for the person
/// (`_meta.acpmux.answeredBy`), and the outcome slot that carries it to the
/// `permission_decision` record (removed before the agent gets the outcome).
pub const ANSWERED_BY_FIELD: &str = "answeredBy";
pub(crate) const ANSWERED_BY_SLOT: &str = "_acpmuxAnsweredBy";

/// `answeredBy` (cx-aocz): the person's own app answering on behalf of a
/// device the person answered on, `{device, feedItem}`. Only the person's
/// connection may say so (an audit record, never a grant). Each field: 1 to
/// 128 characters of `[A-Za-z0-9_.:-]`; no other field.
pub fn answered_by(params: &Value) -> Result<Option<Value>, RpcError> {
    let Some(v) =
        params.pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}")).filter(|v| !v.is_null())
    else {
        return Ok(None);
    };
    let bad = || {
        RpcError::invalid_params(
            "answeredBy must be {device, feedItem}: 1 to 128 of [A-Za-z0-9_.:-] each",
        )
    };
    let o = v.as_object().ok_or_else(bad)?;
    let ok = |s: &str| {
        (1..=128).contains(&s.len())
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
    };
    if o.len() != 2 {
        return Err(bad());
    }
    for key in ["device", "feedItem"] {
        if !o.get(key).and_then(Value::as_str).is_some_and(ok) {
            return Err(bad());
        }
    }
    Ok(Some(v.clone()))
}

/// The only policies a client without the person may set: every tool call
/// asks, or nothing is approved. The exact names; aliases and unknown values
/// are refused. Shared with the remote guard's Web rule.
pub(crate) const ASKING_POLICIES: &[&str] = &["ask", "deny-all"];

/// This launch's person key, once the app gave it.
#[derive(Default)]
pub struct PersonGate {
    key: StdMutex<Option<String>>,
    /// Set by `--person-key-fd`: a running unsigned daemon takes no other.
    from_spawn: AtomicBool,
}

impl PersonGate {
    /// The key the app passed on `--person-key-fd` (unsigned daemon only).
    pub fn install_spawn_key(&self, key: &str) -> Result<(), String> {
        if !valid_key(key) {
            return Err("the person key must be 64 lowercase hex characters".into());
        }
        let mut slot = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.is_some() {
            return Err("this daemon already has a person key".into());
        }
        *slot = Some(key.to_owned());
        self.from_spawn.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// Whether `presented` is this launch's key (constant time).
    pub fn matches(&self, presented: &str) -> bool {
        self.key
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            .is_some_and(|k| valid_key(presented) && cmux_local_auth::tokens_match(presented, k))
    }

    /// `_acpmux/person_enroll` from a peer the caller already proved to be
    /// the signed app (`app_verified`), or, on an unsigned daemon, a check
    /// that `key` is the spawn key.
    pub fn enroll(&self, key: &str, app_verified: bool) -> Result<Value, RpcError> {
        if !valid_key(key) {
            return Err(RpcError::invalid_params("key must be 64 lowercase hex characters"));
        }
        if app_verified {
            *self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(key.to_owned());
            return Ok(json!({"enrolled": true, "via": "signature"}));
        }
        if self.from_spawn.load(Ordering::SeqCst) && self.matches(key) {
            return Ok(json!({"enrolled": true, "via": "spawn"}));
        }
        Err(RpcError::new(
            -32000,
            "this daemon cannot verify the app and has another person key: start a new daemon with this key",
        )
        .with_data(json!({"reason": ENROLL_UNAVAILABLE})))
    }
}

/// 32 bytes as lowercase hex.
pub fn valid_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The declared refusal.
pub fn person_required(what: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "approve this on the Mac app: {what} is accepted only from the cmux app, never from the CLI, a script or an agent"
        ),
    )
    .with_data(json!({"reason": REASON}))
}

/// Remove the key from a first `initialize`'s params and return it.
pub fn take_key(params: &mut Value) -> Option<String> {
    params
        .pointer_mut("/_meta/acpmux")
        .and_then(Value::as_object_mut)
        .and_then(|m| m.remove(KEY_FIELD))
        .and_then(|v| v.as_str().map(str::to_owned))
}

/// Rules that cannot auto-approve: none (a clear), or only `autoDeny` and
/// `ask` lists with a `default` of `ask` or `deny`. No `autoApprove` entry,
/// no `default: "approve"`, and no field this check does not know.
pub(crate) fn rules_cannot_auto_approve(rules: Option<&Value>) -> bool {
    let Some(rules) = rules.filter(|r| !r.is_null()) else { return true };
    let Some(obj) = rules.as_object() else { return false };
    obj.iter().all(|(k, v)| match k.as_str() {
        "autoApprove" => match v {
            Value::Null => true,
            Value::Array(a) => a.is_empty(),
            Value::Object(o) => o.is_empty(),
            _ => false,
        },
        "autoDeny" | "ask" => v.is_null() || v.is_array(),
        "default" => v.is_null() || matches!(v.as_str(), Some("ask" | "deny")),
        _ => false,
    })
}

/// Whether `policy` asks before anything runs (ask, deny-all).
pub(crate) fn asks(policy: PermissionPolicy) -> bool {
    matches!(policy, PermissionPolicy::Ask | PermissionPolicy::DenyAll)
}

/// How much a policy runs without asking: deny-all 0, ask 1, approve-reads 2,
/// approve-edits 3, approve-all 4. A higher number is wider.
pub(crate) fn breadth(policy: PermissionPolicy) -> u8 {
    match policy {
        PermissionPolicy::DenyAll => 0,
        PermissionPolicy::Ask => 1,
        PermissionPolicy::ApproveReads => 2,
        PermissionPolicy::ApproveEdits => 3,
        PermissionPolicy::ApproveAll => 4,
    }
}

/// The catch-all that passes a session method acpmux does not handle to the
/// harness (`server/requests.rs`): a harness extension method may change
/// what the harness runs without asking, so only the person reaches it.
pub fn harness_forward_check(person: bool, m: &str) -> Result<(), RpcError> {
    if person {
        Ok(())
    } else {
        Err(person_required(&format!("{m}, a harness method acpmux does not handle,")))
    }
}

/// Absent or null: nothing is set. Present: one of the asking policies.
pub(crate) fn asking_policy_value(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => true,
        Some(Value::String(p)) => ASKING_POLICIES.contains(&p.as_str()),
        Some(_) => false,
    }
}

impl Hub {
    /// The one person check (module docs). `person`: the connection
    /// presented this launch's key.
    pub async fn person_check(
        &self,
        person: bool,
        m: &str,
        params: &Value,
    ) -> Result<(), RpcError> {
        if person {
            return Ok(());
        }
        match m {
            method::MUX_PERMISSION_RESPOND => {
                // Who answered for the person is the person's own claim.
                if params
                    .pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}"))
                    .is_some_and(|v| !v.is_null())
                {
                    return Err(person_required("answeredBy"));
                }
                // No option: a cancel.
                let Some(option) = params.get("optionId").filter(|v| !v.is_null()) else {
                    return Ok(());
                };
                if self.option_rejects(params, option) {
                    Ok(())
                } else {
                    Err(person_required("allowing a permission"))
                }
            }
            method::MUX_PERMISSION_GROUP_RESPOND => match params["decision"].as_str() {
                Some("deny") => Ok(()),
                _ => Err(person_required("allowing a permission group")),
            },
            method::MUX_SET_POLICY | "_acpmux/set_default_policy" => {
                if asking_policy_value(params.get("policy")) {
                    Ok(())
                } else {
                    Err(person_required("a permission policy other than ask or deny-all"))
                }
            }
            method::MUX_DEFAULTS | method::MUX_PRESETS => {
                let set = params.get("set");
                let env = set.and_then(|s| s.get("env")).is_some_and(|v| match v {
                    Value::Null => false,
                    Value::Object(o) => !o.is_empty(),
                    _ => true,
                });
                if env {
                    return Err(person_required("a spawn env"));
                }
                if !asking_policy_value(set.and_then(|s| s.get("policy"))) {
                    return Err(person_required("a permission policy other than ask or deny-all"));
                }
                // Removing a stored policy (a clear, or `policy: null`) lets
                // the next layer's policy apply, which may not ask.
                let removes = params.get("clear").and_then(Value::as_bool) == Some(true)
                    || set.and_then(|s| s.get("policy")).is_some_and(Value::is_null);
                if removes && self.stored_policy(m, params).await.is_some() {
                    return Err(person_required("removing a stored permission policy"));
                }
                Ok(())
            }
            method::MUX_SET_RULES => {
                if !rules_cannot_auto_approve(params.get("rules")) {
                    return Err(person_required("a permission rule that could auto-approve"));
                }
                // Under a policy that does not ask, a rule is what keeps a
                // tool asking: any change (a clear too) may widen it.
                let Some(s) =
                    crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
                else {
                    return Ok(());
                };
                let default = self.config.read().await.permission_policy;
                if asks(self.policy_for(&s, default)) {
                    Ok(())
                } else {
                    Err(person_required(
                        "changing the rules of a session whose policy does not ask",
                    ))
                }
            }
            // The handoff target tag decides which session a handoff adopts.
            method::MUX_TAG => {
                let sets = params
                    .get("set")
                    .and_then(Value::as_object)
                    .is_some_and(|o| o.contains_key(super::handoff::TARGET_TAG));
                let removes = params.get("remove").and_then(Value::as_array).is_some_and(|a| {
                    a.iter().any(|v| v.as_str() == Some(super::handoff::TARGET_TAG))
                });
                if sets || removes {
                    Err(person_required("the handoff target tag"))
                } else {
                    Ok(())
                }
            }
            method::SESSION_SET_MODE | method::SESSION_SET_CONFIG_OPTION => {
                let (id, value) = if m == method::SESSION_SET_MODE {
                    (None, params.get("modeId").and_then(Value::as_str))
                } else {
                    (
                        params.get("configId").and_then(Value::as_str),
                        params.get("value").and_then(Value::as_str),
                    )
                };
                if id.is_some_and(|i| crate::web_modes::FREE_CONFIG_IDS.contains(&i)) {
                    return Ok(());
                }
                // An unknown session is the handler's not-found; a peer's
                // session is checked by that peer.
                let Some(s) =
                    crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
                else {
                    return Ok(());
                };
                let family = crate::web_modes::family_of(&s.meta());
                if self.web_modes().config_value_asks(&family, id, value) {
                    Ok(())
                } else {
                    Err(person_required("a mode that does not ask"))
                }
            }
            _ => Ok(()),
        }
    }

    /// The policy a `_acpmux/defaults` or `_acpmux/presets` write would
    /// remove: the named family default's or preset's stored policy.
    async fn stored_policy(&self, m: &str, params: &Value) -> Option<PermissionPolicy> {
        let cfg = self.config.read().await;
        if m == method::MUX_DEFAULTS {
            let family = params.get("family").and_then(Value::as_str)?;
            cfg.defaults.get(family).and_then(|d| d.policy)
        } else {
            let name = params.get("name").and_then(Value::as_str)?;
            cfg.presets.get(name).and_then(|p| p.policy)
        }
    }

    /// Whether `option` is a reject the pending permission offered. Unknown
    /// sessions, permissions and options are not rejects: the handler still
    /// answers not-found or invalid params for a person, and a client
    /// without the person learns nothing more than its refusal.
    fn option_rejects(&self, params: &Value, option: &Value) -> bool {
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let Some(pid) = params.get("permissionId").and_then(Value::as_str) else { return false };
        let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(p) = state.pending.get(pid) else { return false };
        let offered: Vec<&Value> = p.request["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|o| o["optionId"] == *option)
            .collect();
        matches!(offered.as_slice(), [one] if matches!(one["kind"].as_str(), Some("reject_once" | "reject_always")))
    }
}
