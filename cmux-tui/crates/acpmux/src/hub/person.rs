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
//! Not covered (the daemon cannot stop same-uid file writes): an agent that
//! edits config.json, a profile file or the store directly. That needs an OS
//! boundary between the agent and the user's files.

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
                    Err(person_required("a spawn env"))
                } else if !asking_policy_value(set.and_then(|s| s.get("policy"))) {
                    Err(person_required("a permission policy other than ask or deny-all"))
                } else {
                    Ok(())
                }
            }
            method::MUX_SET_RULES => {
                if rules_cannot_auto_approve(params.get("rules")) {
                    Ok(())
                } else {
                    Err(person_required("a permission rule that could auto-approve"))
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
