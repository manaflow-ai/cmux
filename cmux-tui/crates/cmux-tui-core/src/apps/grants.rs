//! Per-call scope checks against the capability manifest
//! (`cmux_app_manifest::capabilities`: scopes.json typed, with the gesture
//! and escalation rules), and gesture tokens. The VM is untrusted: its own
//! filtering only shapes errors, the supervisor decides every call here.

use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, Instant};

use cmux_app_manifest::Capabilities;
use cmux_app_manifest::capabilities::escalation;
pub use cmux_app_manifest::capabilities::needs_gesture;
pub use cmux_app_manifest::{OpClass, OpScope};
use serde_json::Value;

/// How long a gesture token stays valid after the user event.
pub const GESTURE_TTL: Duration = Duration::from_secs(10);
/// A command run's token lives until its `done`, at most this long (ABI.md).
pub const COMMAND_GESTURE_TTL: Duration = Duration::from_secs(2);
const MAX_GESTURES: usize = 256;

/// The per-call check over the one capability manifest.
#[derive(Debug)]
pub struct ScopeTable {
    capabilities: &'static Capabilities,
}

impl ScopeTable {
    pub fn get() -> &'static ScopeTable {
        static TABLE: std::sync::OnceLock<ScopeTable> = std::sync::OnceLock::new();
        TABLE.get_or_init(|| ScopeTable { capabilities: Capabilities::get() })
    }

    /// Every op an app may name (sent to the VM as `knownOps`).
    pub fn known_ops(&self) -> Vec<String> {
        self.capabilities.ops().map(|(name, _)| name.to_string()).collect()
    }

    /// Ops a grant allows (sent to the VM as `ops`). Runtime ops whose scope
    /// depends on the target (`net:<host>`) are listed when any matching
    /// scope is granted; the call is still checked against the target.
    pub fn allowed_ops(&self, grant: &Grant) -> Vec<String> {
        self.capabilities
            .ops()
            .map(|(name, _)| name)
            .filter(|op| matches!(self.check(op, &Value::Null, grant), Decision::Allow(_)))
            .map(str::to_string)
            .collect()
    }

    pub fn check(&self, op: &str, params: &Value, grant: &Grant) -> Decision {
        if self.capabilities.is_never(op) {
            return Decision::ScopeMissing("this op is not available to apps");
        }
        let Some(capability) = self.capabilities.op(op) else { return Decision::Unsupported };
        if grant.revoked {
            return Decision::ScopeMissing("the app is stopping");
        }
        if grant.preview {
            return Decision::ScopeMissing("a preview runs without grants");
        }
        if capability.scope.external() && grant.sandboxed {
            return Decision::ScopeMissing("the app runs sandboxed: no network");
        }
        // A workspace, screen, pane or terminal tab created with a command
        // runs it, as `workspace.run` does (the manifest's escalation).
        let escalated = escalation(op)
            .filter(|e| e.when_params.iter().any(|p| params.get(p).is_some()))
            .map(|e| e.scope);
        let granted = match (&capability.scope, escalated) {
            (_, Some(scope)) => grant.scopes.contains(scope),
            // Local, non-network ops every app may call (`toast.show`): no grant to hold.
            (OpScope::Ungated, None) => true,
            (OpScope::NetHost, None) => grant.scopes.iter().any(|s| s.starts_with("net:")),
            (OpScope::IntegrationProvider, None) => {
                match params.get("provider").and_then(Value::as_str) {
                    Some(provider) => {
                        let read_only = params
                            .get("method")
                            .and_then(Value::as_str)
                            .is_none_or(|m| m.eq_ignore_ascii_case("GET"));
                        grant.scopes.contains(&format!("integration:{provider}"))
                            || read_only
                                && grant.scopes.contains(&format!("integration:{provider}:read"))
                    }
                    None => grant.scopes.iter().any(|s| s.starts_with("integration:")),
                }
            }
            (OpScope::Named(scope), None) => grant.scopes.contains(scope),
        };
        if granted {
            Decision::Allow(capability.class)
        } else {
            Decision::ScopeMissing("the app holds no grant for this op")
        }
    }
}

/// What one host may do.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Grant {
    pub scopes: BTreeSet<String>,
    pub sandboxed: bool,
    /// A store preview of an app that is not installed: nothing is granted.
    pub preview: bool,
    /// The app was uninstalled or disabled; its host is on its way out.
    pub revoked: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow(OpClass),
    /// Not an op of this cmux version (`operation.unsupported`).
    Unsupported,
    /// Known but not granted (`scope.missing`), with the reason.
    ScopeMissing(&'static str),
}

struct Token {
    app: String,
    expires: Instant,
    spent: bool,
}

/// Gesture tokens minted for user-origin dispatches.
#[derive(Default)]
pub struct Gestures {
    tokens: HashMap<String, Token>,
    /// Client tokens of palette/keybinding invocations already honored, so
    /// one invocation yields one gesture.
    client_seen: HashMap<String, Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GestureCheck {
    /// Valid; for a mutation it is now spent and the call runs with origin user.
    User,
    /// Absent, expired, spent or another app's.
    None,
}

impl Gestures {
    /// An event token (10 s).
    pub fn mint(&mut self, app: &str, now: Instant) -> String {
        self.mint_for(app, now, GESTURE_TTL)
    }

    /// Ends a token early (a command's token at its `done`).
    pub fn revoke(&mut self, token: &str) {
        self.tokens.remove(token);
    }

    fn mint_for(&mut self, app: &str, now: Instant, ttl: Duration) -> String {
        self.tokens.retain(|_, t| t.expires > now);
        if self.tokens.len() >= MAX_GESTURES
            && let Some(oldest) =
                self.tokens.iter().min_by_key(|(_, t)| t.expires).map(|(k, _)| k.clone())
        {
            self.tokens.remove(&oldest);
        }
        let mut bytes = [0u8; 16];
        if getrandom::fill(&mut bytes).is_err() {
            bytes = (now.elapsed().as_nanos() ^ 0x5eed).to_le_bytes();
        }
        let token = format!("g_{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
        self.tokens.insert(
            token.clone(),
            Token { app: app.to_string(), expires: now + ttl, spent: false },
        );
        token
    }

    /// A user invocation from a client (palette, keybinding) presents its own
    /// token; the supervisor answers with a gesture of its own minting, once
    /// per client token. Malformed or reused tokens get none.
    pub fn accept_client(&mut self, app: &str, client_token: &str, now: Instant) -> Option<String> {
        let well_formed = (8..=128).contains(&client_token.len())
            && client_token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        self.client_seen.retain(|_, at| *at + GESTURE_TTL > now);
        if !well_formed
            || self.client_seen.contains_key(client_token)
            || self.client_seen.len() >= MAX_GESTURES
        {
            return None;
        }
        self.client_seen.insert(client_token.to_string(), now);
        Some(self.mint_for(app, now, COMMAND_GESTURE_TTL))
    }

    /// Presents `token` for `app`. A view-state change (`spend`) uses it up;
    /// other calls run with origin user while it is live (ABI.md).
    pub fn present(
        &mut self,
        app: &str,
        token: Option<&str>,
        spend: bool,
        now: Instant,
    ) -> GestureCheck {
        let Some(token) = token.and_then(|t| self.tokens.get_mut(t)) else {
            return GestureCheck::None;
        };
        if token.app != app || token.spent || token.expires <= now {
            return GestureCheck::None;
        }
        if spend {
            token.spent = true;
        }
        GestureCheck::User
    }
}

#[cfg(test)]
mod tests;
