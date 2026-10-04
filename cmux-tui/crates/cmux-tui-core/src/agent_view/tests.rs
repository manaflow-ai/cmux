use super::*;

fn op(name: &str, scope: &str) -> OpExposure {
    OpExposure {
        name: name.to_owned(),
        scope: scope.to_owned(),
        scope_class: ScopeClass::Standard,
        risk: Risk::Read,
        mcp: McpExpose::Default,
        gesture_required: false,
        secret_output: false,
        server_only: false,
        app_disabled: false,
    }
}

fn grant(scopes: &[&str]) -> AgentGrant {
    AgentGrant { scopes: scopes.iter().map(|s| (*s).to_owned()).collect(), ..AgentGrant::default() }
}

fn everything() -> AgentGrant {
    grant(&["*"])
}

#[test]
fn a_granted_default_read_is_offered() {
    let list = op("cmux.workspace.list", "workspace:read");
    assert_eq!(agent_view(&list, &grant(&["workspace:read"])), Exposure::Offered);
    assert_eq!(agent_view(&list, &everything()), Exposure::Offered);
}

#[test]
fn an_op_that_is_never_a_tool_is_excluded() {
    let open = OpExposure { mcp: McpExpose::Never, ..op("notes.open", "notes:write") };
    assert_eq!(agent_view(&open, &everything()), Exposure::Excluded(Exclusion::NotOffered));
}

#[test]
fn an_opt_in_op_needs_the_user_to_turn_it_on() {
    let delete = OpExposure { mcp: McpExpose::OptIn, ..op("task.delete", "task:write") };
    assert_eq!(agent_view(&delete, &everything()), Exposure::Excluded(Exclusion::OptInOff));
    let mut on = everything();
    on.opted_in.insert("task.delete".to_owned());
    assert_eq!(agent_view(&delete, &on), Exposure::Offered);
}

#[test]
fn password_key_credential_and_account_ops_are_never_offered() {
    let mut all = everything();
    let secrets = [
        op("cmux.passwords.list", "passwords:read"),
        op("cmux.passwords.reveal", "passwords:read"),
        op("coderouter.app.create_key", "coderouter:keys"),
        op("cmux.credentials.get", "credentials:read"),
        op("cmux.accounts.connect", "accounts:write"),
        OpExposure { secret_output: true, ..op("acme.vault.read", "acme:read") },
    ];
    for secret in &secrets {
        all.standing_approvals.insert(secret.name.clone());
        all.opted_in.insert(secret.name.clone());
    }
    for secret in &secrets {
        assert_eq!(
            agent_view(secret, &all),
            Exposure::Excluded(Exclusion::Secret),
            "{}",
            secret.name
        );
    }
}

#[test]
fn installs_grants_and_policy_are_user_only() {
    for name in [
        "cmux.apps.install",
        "cmux.apps.uninstall",
        "cmux.apps.update",
        "cmux.apps.grant.set",
        "cmux.apps.local.add",
        "cmux.apps.local.remove",
    ] {
        let user_only = OpExposure { risk: Risk::MutateShared, ..op(name, "apps:write") };
        assert_eq!(
            agent_view(&user_only, &everything()),
            Exposure::Excluded(Exclusion::UserOnly),
            "{name}"
        );
    }
    let policy = op("browser.policy.set", "policy:write");
    assert_eq!(agent_view(&policy, &everything()), Exposure::Excluded(Exclusion::UserOnly));
    // Agents may hide and unhide apps (D55); the owner refuses the other fields.
    let set = OpExposure { risk: Risk::MutateOwn, ..op("cmux.apps.set", "apps:write") };
    assert_eq!(agent_view(&set, &everything()), Exposure::Offered);
}

#[test]
fn a_gesture_only_op_is_excluded() {
    let export = OpExposure { gesture_required: true, ..op("notes.export", "notes:read") };
    assert_eq!(agent_view(&export, &everything()), Exposure::Excluded(Exclusion::GestureRequired));
}

#[test]
fn an_op_of_a_disabled_app_is_excluded() {
    let capture = OpExposure { app_disabled: true, ..op("notes.capture", "notes:write") };
    assert_eq!(agent_view(&capture, &everything()), Exposure::Excluded(Exclusion::AppDisabled));
}

#[test]
fn an_op_outside_the_grant_is_excluded() {
    let write = OpExposure { risk: Risk::MutateShared, ..op("git.commit", "git:write") };
    assert_eq!(
        agent_view(&write, &grant(&["git:read", "workspace:read"])),
        Exposure::Excluded(Exclusion::NotGranted)
    );
    // A standing approval does not add a scope.
    let mut approved = grant(&["git:read"]);
    approved.standing_approvals.insert("git.commit".to_owned());
    assert_eq!(agent_view(&write, &approved), Exposure::Excluded(Exclusion::NotGranted));
}

#[test]
fn risky_ops_need_approval_unless_the_user_allowed_them() {
    let risky = [
        OpExposure { risk: Risk::Destructive, ..op("cmux.workspace.close", "workspace:write") },
        OpExposure { risk: Risk::SendExternal, ..op("message.send", "message:write") },
        OpExposure { risk: Risk::Money, ..op("vm.create", "vm:write") },
        OpExposure {
            risk: Risk::MutateOwn,
            scope_class: ScopeClass::Restricted,
            ..op("terminal.input.write", "terminal:input")
        },
    ];
    for op in &risky {
        assert_eq!(agent_view(op, &everything()), Exposure::NeedsApproval, "{}", op.name);
        let mut allowed = everything();
        allowed.standing_approvals.insert(op.name.clone());
        assert_eq!(agent_view(op, &allowed), Exposure::Offered, "{}", op.name);
    }
    let sensitive = OpExposure {
        risk: Risk::MutateShared,
        scope_class: ScopeClass::Sensitive,
        ..op("git.commit", "git:write")
    };
    assert_eq!(agent_view(&sensitive, &everything()), Exposure::Offered);
}

#[test]
fn exclusions_come_before_approval() {
    let closed = OpExposure {
        risk: Risk::Destructive,
        mcp: McpExpose::Never,
        ..op("cmux.workspace.close", "workspace:write")
    };
    assert_eq!(agent_view(&closed, &everything()), Exposure::Excluded(Exclusion::NotOffered));
}

fn enabled(_: &str) -> bool {
    true
}

#[test]
fn an_ir_op_gives_its_exposure_fields() {
    let ir = serde_json::json!({ "name": "cmux.git.status", "kind": "read", "scope": "git:read",
        "owner": "first-party", "mcp": { "expose": "default", "group": "git" }, "secret_output": false,
        "risk": "read", "gesture": false, "scope_class": "restricted" });
    assert_eq!(
        OpExposure::from_ir(&ir, enabled),
        Some(OpExposure {
            name: "cmux.git.status".to_owned(),
            scope: "git:read".to_owned(),
            scope_class: ScopeClass::Restricted,
            risk: Risk::Read,
            mcp: McpExpose::Default,
            gesture_required: false,
            secret_output: false,
            server_only: false,
            app_disabled: false,
        })
    );
    let declared = serde_json::json!({ "name": "cmux.x.set", "kind": "mutation", "scope": "x:write",
        "owner": "first-party", "mcp": { "expose": "opt_in" }, "risk": "mutate-own", "gesture": true,
        "scope_class": "sensitive", "server_only": true, "secret_output": false });
    let op = OpExposure::from_ir(&declared, enabled).expect("op");
    assert_eq!(
        (op.mcp, op.risk, op.gesture_required, op.scope_class, op.server_only),
        (McpExpose::OptIn, Risk::MutateOwn, true, ScopeClass::Sensitive, true)
    );
}

#[test]
fn missing_or_unknown_ir_fields_fail_closed() {
    // Only name and scope: never offered, destructive, gesture-only,
    // restricted. A missing server_only is false (emit-ir omits false).
    let bare = serde_json::json!({ "name": "cmux.x.y", "kind": "read", "scope": "x:read" });
    let op = OpExposure::from_ir(&bare, enabled).expect("op");
    assert_eq!(
        (op.mcp, op.risk, op.gesture_required, op.scope_class, op.server_only),
        (McpExpose::Never, Risk::Destructive, true, ScopeClass::Restricted, false)
    );
    let odd = serde_json::json!({ "name": "cmux.x.z", "kind": "read", "scope": "x:read",
        "mcp": { "expose": "always" }, "risk": "chaos", "gesture": "no", "scope_class": "public" });
    let op = OpExposure::from_ir(&odd, enabled).expect("op");
    assert_eq!(
        (op.mcp, op.risk, op.gesture_required, op.scope_class),
        (McpExpose::Never, Risk::Destructive, true, ScopeClass::Restricted)
    );
    let no_scope = serde_json::json!({ "name": "cmux.x.z", "kind": "read" });
    assert_eq!(OpExposure::from_ir(&no_scope, enabled), None);
}

#[test]
fn a_server_only_scope_is_never_offered_to_agents() {
    let spawn = OpExposure { server_only: true, ..op("acme.tool.spawn", "process:spawn:git") };
    assert_eq!(agent_view(&spawn, &everything()), Exposure::Excluded(Exclusion::ServerOnly));
}

#[test]
fn an_app_op_is_disabled_when_its_app_is() {
    let ir = serde_json::json!({ "name": "com.example.hello.greet", "kind": "read", "scope": "hello:read",
        "owner": "app:com.example.hello", "mcp": { "expose": "default" }, "risk": "read",
        "gesture": false, "scope_class": "standard" });
    let op = OpExposure::from_ir(&ir, |app: &str| app == "cmux/notes").expect("op");
    assert!(op.app_disabled);
    let op = OpExposure::from_ir(&ir, |app: &str| app == "com.example.hello").expect("op");
    assert!(!op.app_disabled);
}

#[test]
fn every_op_in_the_committed_ir_has_an_agent_answer() {
    let ir: serde_json::Value =
        serde_json::from_str(include_str!("../../../cmux-pane-protocol/spec/pane-protocol.json"))
            .expect("IR is JSON");
    let ops = ir["ops"].as_array().expect("ops");
    assert!(!ops.is_empty());
    for raw in ops {
        let op = OpExposure::from_ir(raw, enabled).expect("every IR op has a name and scope");
        // The committed IR declares every field, so nothing falls back.
        assert!(raw.get("risk").is_some() && raw.get("gesture").is_some(), "{}", op.name);
        assert_eq!(op.gesture_required, raw["gesture"] == true, "{}", op.name);
        assert_eq!(
            format!("{:?}", op.scope_class).to_lowercase(),
            raw["scope_class"].as_str().expect("scope_class"),
            "{}",
            op.name
        );
        let answer = agent_view(&op, &everything());
        if raw["secret_output"] == true {
            assert_eq!(answer, Exposure::Excluded(Exclusion::Secret), "{}", op.name);
        }
        if raw["mcp"]["expose"] == "never" {
            assert!(matches!(answer, Exposure::Excluded(_)), "{}", op.name);
        }
    }
}
