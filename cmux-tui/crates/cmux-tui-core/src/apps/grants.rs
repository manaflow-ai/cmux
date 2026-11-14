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
mod tests {
    use super::*;
    use serde_json::json;

    fn grant(scopes: &[&str]) -> Grant {
        Grant { scopes: scopes.iter().map(|s| s.to_string()).collect(), ..Grant::default() }
    }

    #[test]
    fn cmux_next_agent_cli_list_admits_only_the_read_grant() {
        let table = ScopeTable::get();
        assert_eq!(
            table.check(
                "agent_cli.list",
                &json!({"machine":"machine_owner"}),
                &grant(&["agent_cli:read"])
            ),
            Decision::Allow(OpClass::Read),
        );
        for scopes in [vec![], vec!["agent_cli:execute"], vec!["workspace:read"]] {
            assert!(matches!(
                table.check("agent_cli.list", &json!({}), &grant(&scopes)),
                Decision::ScopeMissing(_),
            ));
        }
    }

    #[test]
    fn cmux_next_agent_cli_list_denies_preview_and_revoked_grants() {
        let table = ScopeTable::get();
        for g in [
            Grant { preview: true, ..grant(&["agent_cli:read"]) },
            Grant { revoked: true, ..grant(&["agent_cli:read"]) },
        ] {
            assert!(matches!(
                table.check("agent_cli.list", &json!({}), &g),
                Decision::ScopeMissing(_),
            ));
        }
    }

    #[test]
    fn cmux_next_agent_cli_list_does_not_admit_execution_or_refresh_operations() {
        let g = grant(&["agent_cli:read", "agent_cli:execute"]);
        for op in
            ["agent_cli.install", "agent_cli.update", "agent_cli.sign_in", "agent_cli.refresh"]
        {
            assert_eq!(ScopeTable::get().check(op, &json!({}), &g), Decision::Unsupported);
        }
    }

    #[test]
    fn cmux_next_agent_chat_list_admits_only_the_agent_chat_read_grant() {
        let table = ScopeTable::get();
        assert_eq!(
            table.check("agent_chat.list", &json!({}), &grant(&["agent_chat:read"])),
            Decision::Allow(OpClass::Read),
        );
        for scopes in [vec![], vec!["agent:read"], vec!["agent_cli:read"], vec!["workspace:read"]] {
            assert!(matches!(
                table.check("agent_chat.list", &json!({}), &grant(&scopes)),
                Decision::ScopeMissing(_),
            ));
        }
    }

    /// The App Store chat ops (extensibility-DESIGN.md step 3): `chat.list` reads with
    /// `chat:read`; `chat.mark_read` and `chat.pin` write with `chat:write` and only with a
    /// tap's gesture token.
    #[test]
    fn chat_ops_take_the_chat_scopes_and_marks_need_a_gesture() {
        let table = ScopeTable::get();
        assert_eq!(
            table.check("chat.list", &json!({}), &grant(&["chat:read"])),
            Decision::Allow(OpClass::Read),
        );
        let mark = json!({"chat": "s1"});
        let pin = json!({"chat": "s1", "pinned": true});
        for (op, params) in [("chat.mark_read", &mark), ("chat.pin", &pin)] {
            assert_eq!(
                table.check(op, params, &grant(&["chat:write"])),
                Decision::Allow(OpClass::Mutation),
            );
            assert!(matches!(
                table.check(op, params, &grant(&["chat:read"])),
                Decision::ScopeMissing(_),
            ));
            assert!(needs_gesture(op), "{op} needs a tap");
        }
        for scopes in [vec![], vec!["agent_chat:read"], vec!["agent:read"]] {
            assert!(matches!(
                table.check("chat.list", &json!({}), &grant(&scopes)),
                Decision::ScopeMissing(_),
            ));
        }
        assert!(!needs_gesture("chat.list"));
    }

    /// What plays: `media.get` reads with `media:read`; `media.control` (play, pause, skip,
    /// seek) needs `media:control` and a tap, never `media:read` alone.
    #[test]
    fn cmux_next_media_reads_with_media_read_and_controls_only_with_media_control_and_a_tap() {
        let table = ScopeTable::get();
        assert_eq!(
            table.check("media.get", &json!({}), &grant(&["media:read"])),
            Decision::Allow(OpClass::Read),
        );
        assert!(!needs_gesture("media.get"));
        let next = json!({"command": "next"});
        assert_eq!(
            table.check("media.control", &next, &grant(&["media:control"])),
            Decision::Allow(OpClass::Mutation),
        );
        for scopes in [vec![], vec!["media:read"], vec!["actions:run"]] {
            assert!(matches!(
                table.check("media.control", &next, &grant(&scopes)),
                Decision::ScopeMissing(_),
            ));
        }
        assert!(needs_gesture("media.control"), "media.control needs a tap");
    }

    #[test]
    fn cmux_next_memory_search_admits_only_the_memory_read_grant() {
        let table = ScopeTable::get();
        let params = json!({"roots":[],"query":"deploy"});
        assert_eq!(
            table.check("memory.search", &params, &grant(&["memory:read"])),
            Decision::Allow(OpClass::Read),
        );
        for scopes in [vec![], vec!["document:read"], vec!["agent_cli:read"]] {
            assert!(matches!(
                table.check("memory.search", &params, &grant(&scopes)),
                Decision::ScopeMissing(_),
            ));
        }
    }

    #[test]
    fn a_toast_needs_no_grant_but_not_a_preview_or_a_stopping_app() {
        let table = ScopeTable::get();
        let params = json!({"title": "Saved"});
        assert_eq!(
            table.check("toast.show", &params, &grant(&[])),
            Decision::Allow(OpClass::Mutation)
        );
        let preview = Grant { preview: true, ..grant(&[]) };
        assert!(matches!(table.check("toast.show", &params, &preview), Decision::ScopeMissing(_)));
        let revoked = Grant { revoked: true, ..grant(&[]) };
        assert!(matches!(table.check("toast.show", &params, &revoked), Decision::ScopeMissing(_)));
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
    fn workspace_create_with_a_command_needs_the_execute_scope() {
        let table = ScopeTable::get();
        let write = grant(&["workspace:write"]);
        let execute = grant(&["workspace:write", "workspace:execute"]);
        let plain = json!({ "initial_content": "terminal", "cwd": "/tmp" });
        assert!(matches!(table.check("workspace.create", &plain, &write), Decision::Allow(_)));
        for command in [json!({ "argv": ["sh"] }), json!({ "shell": "true" })] {
            assert!(matches!(
                table.check("workspace.create", &command, &write),
                Decision::ScopeMissing(_)
            ));
            assert!(matches!(
                table.check("workspace.create", &command, &execute),
                Decision::Allow(_)
            ));
        }
    }

    #[test]
    fn a_terminal_created_with_a_command_needs_the_execute_scope() {
        let table = ScopeTable::get();
        let write = grant(&["workspace:write"]);
        let execute = grant(&["workspace:write", "workspace:execute"]);
        for op in ["tab.create_terminal", "pane.create", "screen.create", "pane.split"] {
            let plain = json!({ "pane": "current", "direction": "right" });
            assert!(matches!(table.check(op, &plain, &write), Decision::Allow(_)), "{op}");
            for command in [json!({ "argv": ["sh"] }), json!({ "shell": "true" })] {
                assert!(
                    matches!(table.check(op, &command, &write), Decision::ScopeMissing(_)),
                    "{op} ran a command without workspace:execute"
                );
                assert!(matches!(table.check(op, &command, &execute), Decision::Allow(_)), "{op}");
            }
        }
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
        for op in cmux_app_manifest::capabilities::VIEW_STATE_OPS {
            assert!(
                table.known_ops().iter().any(|known| known == op),
                "{op} is not in scopes.json"
            );
        }
    }
}
