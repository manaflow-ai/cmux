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
