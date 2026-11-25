use super::*;

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn overrides_after_the_subcommand_move_before_it_in_order() {
    let args = words(&[
        "-c",
        "agents.max_depth=2",
        "app-server",
        "--listen",
        "stdio://",
        "-c",
        "model_provider=\"openai_api_key\"",
        "--config=x=1",
        "-cy=2",
        "-c",
        "developer_instructions=\"rules\"",
    ]);
    assert_eq!(
        hoist_subcommand_config(args),
        words(&[
            "-c",
            "agents.max_depth=2",
            "-c",
            "model_provider=\"openai_api_key\"",
            "--config=x=1",
            "-cy=2",
            "-c",
            "developer_instructions=\"rules\"",
            "app-server",
            "--listen",
            "stdio://",
        ])
    );
    // No subcommand, or another one: as given.
    let other = words(&["exec", "-c", "a=1"]);
    assert_eq!(hoist_subcommand_config(other.clone()), other);
    let none = words(&["-c", "a=1"]);
    assert_eq!(hoist_subcommand_config(none.clone()), none);
    // A dangling flag never takes the subcommand as its value.
    let dangling = words(&["-c", "a=1", "app-server", "-c"]);
    assert_eq!(hoist_subcommand_config(dangling.clone()), dangling);
    // A launch with no session (a model probe) is moved too.
    assert_eq!(
        launch_args(true, &words(&["app-server", "-c", "model_provider=\"x\""]), None),
        words(&["-c", "model_provider=\"x\"", "app-server"])
    );
    assert_eq!(
        launch_args(false, &words(&["exec", "-c", "a=1"]), None),
        words(&["exec", "-c", "a=1"])
    );
}

#[test]
fn a_chat_waits_out_capacity_unless_the_person_chose_its_retries() {
    let none: Vec<(String, String)> = vec![("PATH".into(), "/bin".into())];
    let lifted = claude_retry_env(&none);
    assert!(lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG", "1")), "{lifted:?}");
    // The default scope: the capacity scope lets the gateway's 503 "no accounts" through.
    assert!(!lifted.iter().any(|(k, _)| *k == "CLAUDE_CODE_RETRY_WATCHDOG_SCOPE"), "{lifted:?}");
    // Bounded, so acpmux's capacity resume and failover still see a sustained outage.
    assert!(lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS", "300000")), "{lifted:?}");
    // A 503 is bounded by the retry count, not the wait budget.
    assert!(lifted.contains(&("CLAUDE_CODE_MAX_RETRIES", "14")), "{lifted:?}");
    // A spend or plan limit still fails fast: no usage-limit wait.
    assert!(
        lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS", "0")),
        "{lifted:?}"
    );
    for choice in CLAUDE_RETRY_CHOICES {
        let chosen = vec![((*choice).to_owned(), "7".to_owned())];
        assert!(claude_retry_env(&chosen).is_empty(), "{choice}");
    }
}

#[test]
fn a_launch_has_no_override_after_app_server() {
    let out = codex_args(
        words(&["app-server", "-c", "developer_instructions=\"rules\""]),
        &[toml::Table::new()],
    );
    let at = out.iter().position(|a| a == "app-server").unwrap();
    assert_eq!(at, out.len() - 1, "{out:?}");
    assert!(out.windows(2).any(|w| w == ["-c", "developer_instructions=\"rules\""]), "{out:?}");
}
