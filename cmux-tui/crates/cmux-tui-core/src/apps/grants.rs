//! Per-call scope checks against `cmux-app-host/generated/scopes.json`, and
//! gesture tokens. The VM is untrusted: its own filtering only shapes errors,
//! the supervisor decides every call here.

use std::collections::{BTreeSet, HashMap};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::Value;

const SCOPES_JSON: &str = include_str!("../../../cmux-app-host/generated/scopes.json");

/// How long a gesture token stays valid after the user event.
pub const GESTURE_TTL: Duration = Duration::from_secs(10);
/// A command run's token lives until its `done`, at most this long (ABI.md).
pub const COMMAND_GESTURE_TTL: Duration = Duration::from_secs(2);
const MAX_GESTURES: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpClass {
    Read,
    Mutation,
    Runtime,
    Stream,
}

#[derive(Debug)]
pub struct ScopeTable {
    ops: HashMap<String, (String, OpClass)>,
    never: BTreeSet<String>,
}

impl ScopeTable {
    pub fn get() -> &'static ScopeTable {
        static TABLE: OnceLock<ScopeTable> = OnceLock::new();
        TABLE.get_or_init(|| {
            let doc: Value =
                serde_json::from_str(SCOPES_JSON).expect("generated scopes.json is JSON");
            let ops = doc["ops"]
                .as_object()
                .into_iter()
                .flatten()
                .map(|(name, entry)| {
                    let class = match entry["class"].as_str() {
                        Some("read") => OpClass::Read,
                        Some("runtime") => OpClass::Runtime,
                        Some("stream_open") => OpClass::Stream,
                        _ => OpClass::Mutation,
                    };
                    (name.clone(), (entry["scope"].as_str().unwrap_or_default().to_string(), class))
                })
                .collect();
            let never = doc["never"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect();
            ScopeTable { ops, never }
        })
    }

    /// Every op an app may name (sent to the VM as `knownOps`).
    pub fn known_ops(&self) -> Vec<String> {
        let mut ops: Vec<String> = self.ops.keys().cloned().collect();
        ops.sort();
        ops
    }

    /// Ops a grant allows (sent to the VM as `ops`). Runtime ops whose scope
    /// depends on the target (`net:<host>`) are listed when any matching
    /// scope is granted; the call is still checked against the target.
    pub fn allowed_ops(&self, grant: &Grant) -> Vec<String> {
        let mut ops: Vec<String> = self
            .ops
            .keys()
            .filter(|op| matches!(self.check(op, &Value::Null, grant), Decision::Allow(_)))
            .cloned()
            .collect();
        ops.sort();
        ops
    }

    pub fn check(&self, op: &str, params: &Value, grant: &Grant) -> Decision {
        if self.never.contains(op) {
            return Decision::ScopeMissing("this op is not available to apps");
        }
        let Some((scope, class)) = self.ops.get(op) else { return Decision::Unsupported };
        if grant.revoked {
            return Decision::ScopeMissing("the app is stopping");
        }
        if grant.preview {
            return Decision::ScopeMissing("a preview runs without grants");
        }
        let external = scope.starts_with("net:")
            || scope.starts_with("integration:")
            || scope.ends_with(":external");
        if external && grant.sandboxed {
            return Decision::ScopeMissing("the app runs sandboxed: no network");
        }
        let granted = match scope.as_str() {
            "net:<host>" => grant.scopes.iter().any(|s| s.starts_with("net:")),
            "integration:<provider>" => match params.get("provider").and_then(Value::as_str) {
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
            },
            scope => grant.scopes.contains(scope),
        };
        if granted {
            Decision::Allow(*class)
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

/// Catalog ops that change view state (focus, selection, scroll, zoom,
/// navigation; js/ABI.md "One rule for use"). From an app they run only with
/// a live gesture token, which they spend, so automation never moves what the
/// user sees (OWNERSHIP-PRINCIPLES). `action.run` is decided in `actions.rs`.
const VIEW_STATE_OPS: &[&str] = &[
    "browser.activate",
    "browser.navigate",
    "pane.focus",
    "pane.focus_direction",
    "pane.zoom",
    "screen.focus",
    "tab.focus",
    "terminal.input.focus",
    "terminal.viewport.scroll",
    "workspace.focus",
];

/// Provider ops that open UI (a file panel) need a gesture the same way.
/// They join scopes.json with the build-time scopes; listed here first so a
/// VM can never open a panel without one.
const PANEL_OPS: &[&str] = &["fs.pick"];

pub fn needs_gesture(op: &str) -> bool {
    VIEW_STATE_OPS.contains(&op) || PANEL_OPS.contains(&op)
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
mod tests {
    use super::*;
    use serde_json::json;

    fn grant(scopes: &[&str]) -> Grant {
        Grant { scopes: scopes.iter().map(|s| s.to_string()).collect(), ..Grant::default() }
    }

    #[test]
    fn unknown_is_unsupported_and_ungranted_is_scope_missing() {
        let table = ScopeTable::get();
        assert_eq!(table.check("made.up", &json!({}), &grant(&[])), Decision::Unsupported);
        assert!(matches!(
            table.check("tab.focus", &json!({}), &grant(&["workspace:read"])),
            Decision::ScopeMissing(_)
        ));
        assert_eq!(
            table.check("workspace.list", &json!({}), &grant(&["workspace:read"])),
            Decision::Allow(OpClass::Read)
        );
        assert!(matches!(
            table.check("install.revoke", &json!({}), &grant(&["install:write"])),
            Decision::ScopeMissing(_)
        ));
    }

    #[test]
    fn sandbox_and_preview_deny_network_and_everything() {
        let table = ScopeTable::get();
        let mut g = grant(&["net:api.github.com", "workspace:read"]);
        assert_eq!(table.check("net.fetch", &json!({}), &g), Decision::Allow(OpClass::Runtime));
        g.sandboxed = true;
        assert!(matches!(table.check("net.fetch", &json!({}), &g), Decision::ScopeMissing(_)));
        assert_eq!(table.check("workspace.list", &json!({}), &g), Decision::Allow(OpClass::Read));
        let preview = Grant { preview: true, ..grant(&["workspace:read"]) };
        assert!(matches!(
            table.check("workspace.list", &json!({}), &preview),
            Decision::ScopeMissing(_)
        ));
    }

    #[test]
    fn integration_read_scope_allows_get_only() {
        let table = ScopeTable::get();
        let g = grant(&["integration:github:read"]);
        assert!(matches!(
            table.check(
                "integration.request",
                &json!({ "provider": "github", "method": "GET" }),
                &g
            ),
            Decision::Allow(_)
        ));
        assert!(matches!(
            table.check(
                "integration.request",
                &json!({ "provider": "github", "method": "POST" }),
                &g
            ),
            Decision::ScopeMissing(_)
        ));
    }

    #[test]
    fn gesture_tokens_are_per_app_single_use_for_mutations_and_expire() {
        let mut gestures = Gestures::default();
        let now = Instant::now();
        let token = gestures.mint("cmux/a", now);
        assert_eq!(gestures.present("cmux/b", Some(&token), true, now), GestureCheck::None);
        assert_eq!(gestures.present("cmux/a", Some(&token), false, now), GestureCheck::User);
        assert_eq!(gestures.present("cmux/a", Some(&token), true, now), GestureCheck::User);
        assert_eq!(gestures.present("cmux/a", Some(&token), true, now), GestureCheck::None);
        let late = gestures.mint("cmux/a", now);
        assert_eq!(
            gestures.present("cmux/a", Some(&late), true, now + GESTURE_TTL),
            GestureCheck::None
        );
        let command = gestures.accept_client("cmux/a", "palette-0001", now).expect("command token");
        assert_eq!(gestures.present("cmux/a", Some(&command), false, now), GestureCheck::User);
        assert_eq!(
            gestures.present("cmux/a", Some(&command), false, now + COMMAND_GESTURE_TTL),
            GestureCheck::None,
            "a command token lives 2 s"
        );
        let revoked = gestures.accept_client("cmux/a", "palette-0002", now).expect("command token");
        gestures.revoke(&revoked);
        assert_eq!(gestures.present("cmux/a", Some(&revoked), false, now), GestureCheck::None);
        assert!(needs_gesture("tab.focus") && needs_gesture("pane.focus_direction"));
        assert!(needs_gesture("terminal.input.focus") && !needs_gesture("tab.close"));
        assert!(needs_gesture("terminal.viewport.scroll") && needs_gesture("browser.navigate"));
        // Every listed op is an op of this cmux version.
        let table = ScopeTable::get();
        for op in VIEW_STATE_OPS {
            assert!(
                table.known_ops().iter().any(|known| known == op),
                "{op} is not in scopes.json"
            );
        }
    }
}
