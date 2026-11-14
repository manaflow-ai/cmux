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
        assert!(
            matches!(table.check("agent_cli.list", &json!({}), &g), Decision::ScopeMissing(_),)
        );
    }
}

#[test]
fn cmux_next_agent_cli_list_does_not_admit_execution_or_refresh_operations() {
    let g = grant(&["agent_cli:read", "agent_cli:execute"]);
    for op in ["agent_cli.install", "agent_cli.update", "agent_cli.sign_in", "agent_cli.refresh"] {
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
    assert_eq!(table.check("toast.show", &params, &grant(&[])), Decision::Allow(OpClass::Mutation));
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
        table.check("integration.request", &json!({ "provider": "github", "method": "GET" }), &g),
        Decision::Allow(_)
    ));
    assert!(matches!(
        table.check("integration.request", &json!({ "provider": "github", "method": "POST" }), &g),
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
        assert!(matches!(table.check("workspace.create", &command, &execute), Decision::Allow(_)));
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
        assert!(table.known_ops().iter().any(|known| known == op), "{op} is not in scopes.json");
    }
}
