use super::*;

/// The words of a command before its first argument: `cmux setup
/// machine` of `cmux setup machine SSH_TARGET [--name NAME]`.
fn command_words(command: &str) -> String {
    command
        .split_whitespace()
        .take_while(|word| word.chars().all(|c| c.is_ascii_lowercase() || c == '-'))
        .take_while(|word| !word.starts_with('-'))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Every task has a Chief prompt, and the prompt names, in backticks,
/// the command that does the task: its `cmux setup` command when setup
/// runs it, else one of its check or apply commands.
#[test]
fn status_checks_have_typed_recovery_without_losing_task_fields() {
    let matrix = [
        ("trust", "needs_setup", "needs_action"),
        ("machine", "needs_user", "needs_action"),
        ("harness", "needs_user", "needs_action"),
        ("mcp", "failed", "failed"),
        ("computer_use", "not_applicable", "ok"),
        ("cloud_machine", "ok", "ok"),
        ("notifications", "needs_user", "needs_action"),
        ("browser_import", "ok", "ok"),
        ("tailnet", "unknown", "needs_action"),
    ];
    for (task, state, expected) in matrix {
        let mut check = json!({"task": task, "state": state});
        if task == "tailnet" {
            check["fix"] = json!("cmux setup tailnet");
        }
        let check = enrich_status(check);
        assert_eq!(check["check_status"], expected, "{task}: {check}");
        assert!(check["task"].is_string(), "{task}: task identity was lost");
    }

    let check = enrich_status(json!({
        "task": "machine",
        "state": "needs_setup",
        "peers": [{"name": "build", "fix": "cmux setup machine build --name build"}],
    }));
    assert_eq!(check["recovery"]["command"], "cmux setup machine build --name build");
    assert_eq!(check["peers"][0]["name"], "build");

    let failed = enrich_status(json!({"task": "harness", "state": "failed", "error": "timeout"}));
    assert_eq!(failed["check_status"], "failed");
    assert_eq!(failed["recovery"], Value::Null);

    let multiple = enrich_status(json!({
        "task": "mcp",
        "state": "needs_setup",
        "clients": [{"fix": "cmux setup mcp claude"}, {"fix": "cmux setup mcp codex"}],
    }));
    assert_eq!(multiple["check_status"], "needs_action");
    assert_eq!(multiple["recovery"].as_array().unwrap().len(), 2);

    let nested_failure = enrich_status(json!({
        "task": "mcp",
        "state": "needs_setup",
        "clients": [{"state": "failed", "error": "client timed out"}],
    }));
    assert_eq!(nested_failure["check_status"], "failed");
    assert_eq!(nested_failure["status"], Value::Null);

    let existing = enrich_status(json!({
        "task": "computer_use",
        "state": "needs_user",
        "status": {"phase": "off", "accessibility": false},
    }));
    assert_eq!(existing["check_status"], "needs_action");
    assert_eq!(existing["status"]["phase"], "off");
}

#[test]
fn chief_prompt_on_every_task_names_its_command() {
    assert!(STATUS_PROMPT.contains("`cmux setup local`"), "{STATUS_PROMPT:?}");
    for task in TASKS {
        assert!(!task.prompt.trim().is_empty(), "{} has no prompt", task.id);
        assert!(!task.prompt.contains('\n'), "{}: one paragraph", task.id);
        let commands = match task.setup {
            Some(setup) => vec![setup],
            None => task.check.iter().chain(task.apply).copied().collect(),
        };
        assert!(
            commands.iter().any(|command| {
                let words = command_words(command);
                words.split(' ').count() >= 3 && task.prompt.contains(&format!("`{words}"))
            }),
            "{}: prompt {:?} names none of {commands:?}",
            task.id,
            task.prompt
        );
    }
}

/// The generated page has one block per task, each with its prompt.
#[test]
fn chief_prompt_markdown_has_a_block_per_task() {
    let page = prompts_markdown();
    assert!(page.starts_with("# "), "{page}");
    assert!(page.contains(STATUS_PROMPT));
    for task in TASKS {
        assert!(page.contains(&format!("```text\n{}\n```", task.prompt)), "{}", task.id);
    }
}

/// The accounts prompt is the single human recovery path. Keep the
/// generated prompt useful for the states the Accounts screen exposes,
/// without teaching agents to claim that an unknown Keychain sign-in is
/// healthy.
#[test]
fn accounts_prompt_names_each_recovery_state() {
    let prompt = TASKS.iter().find(|task| task.id == "accounts").unwrap().prompt;
    for phrase in [
        "cmux accounts list --json",
        "cmux login",
        "command or browser reports offline or Cloud unavailable",
        "missing or expired",
        "cmux accounts reauth --provider PROVIDER",
        "Switch Account",
        "saved key is missing or unreadable",
        "never claim an unknown or Keychain-backed sign-in is valid",
    ] {
        assert!(prompt.contains(phrase), "accounts prompt missing {phrase:?}: {prompt}");
    }
}
