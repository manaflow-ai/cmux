use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn planned(words: &[&str]) -> Result<Vec<String>, UsageError> {
    let all = args(words);
    plan(split(&all).expect("a vm command").1, OutputMode::Human)
}

#[test]
fn only_the_vm_scope_and_the_machine_vm_verbs_are_owned() {
    assert!(split(&args(&["vm", "ls"])).is_some());
    assert!(split(&args(&["machine", "new"])).is_some());
    assert!(split(&args(&["machine", "list"])).is_none());
    assert!(split(&args(&["workspace", "new"])).is_none());
    assert!(split(&args(&[])).is_none());
}

#[test]
fn friendly_verbs_map_to_the_cmux_vm_cli() {
    assert_eq!(planned(&["vm", "ls"]).unwrap(), args(&["list"]));
    assert_eq!(planned(&["vm", "new", "--name", "t"]).unwrap(), args(&["create", "--name", "t"]));
    assert_eq!(
        planned(&["vm", "rm", "vm_1", "--yes"]).unwrap(),
        args(&["delete", "vm_1", "--yes"])
    );
    assert_eq!(planned(&["vm", "pause", "vm_1"]).unwrap(), args(&["pause", "vm_1"]));
    assert_eq!(planned(&["vm", "resume", "vm_1"]).unwrap(), args(&["resume", "vm_1"]));
}

#[test]
fn client_session_commands_pass_through_to_cmux_vm() {
    assert_eq!(
        planned(&["vm", "client-session", "list", "vm_1"]).unwrap(),
        args(&["client-session", "list", "vm_1"])
    );
}

#[test]
fn exec_keeps_everything_after_the_double_dash() {
    assert_eq!(
        planned(&["vm", "exec", "vm_1", "--", "acpmux", "run", "-m", "claude", "hi"]).unwrap(),
        args(&["exec", "vm_1", "--", "acpmux", "run", "-m", "claude", "hi"]),
    );
}

#[test]
fn json_output_is_a_global_flag_of_cmux_vm() {
    let all = args(&["vm", "ls"]);
    let plan = plan(split(&all).unwrap().1, OutputMode::Json).unwrap();
    assert_eq!(plan, args(&["--json", "list"]));
}

#[test]
fn a_vm_with_no_verb_or_an_unknown_verb_lists_the_wrapper_verbs() {
    for words in [&["vm"][..], &["vm", "frobnicate"][..]] {
        let error = planned(words).unwrap_err();
        for verb in [
            "new", "show", "pause", "resume", "start", "stop", "rm", "exec", "fork", "snapshot",
            "access", "key",
        ] {
            assert!(error.0.contains(verb), "{verb} missing from: {}", error.0);
        }
    }
}

#[test]
fn resize_points_at_the_cloud_action() {
    let error = planned(&["vm", "resize"]).unwrap_err();
    assert!(error.0.contains("cmux cloud resize-machine"), "{}", error.0);
}

#[test]
fn snapshot_subcommands_and_help_pass_through() {
    assert_eq!(
        planned(&["vm", "snapshot", "create", "vm_1"]).unwrap(),
        args(&["snapshot", "create", "vm_1"])
    );
    assert_eq!(planned(&["vm", "snapshot", "--help"]).unwrap(), args(&["snapshot", "--help"]));
    assert_eq!(
        planned(&["vm", "snapshot", "list", "--limit", "2"]).unwrap(),
        args(&["snapshot", "list", "--limit", "2"])
    );
}

#[test]
fn workspace_new_points_at_the_app_action() {
    let error = planned(&["vm", "workspace", "new", "vm_1"]).unwrap_err();
    assert!(error.0.contains("cmux cloud new-workspace"), "{}", error.0);
}

#[test]
fn run_and_token_pass_through_to_cmux_vm() {
    assert_eq!(
        planned(&["vm", "run", "--sync", "--", "bun", "--version"]).unwrap(),
        args(&["run", "--sync", "--", "bun", "--version"])
    );
    assert_eq!(planned(&["vm", "token", "status"]).unwrap(), args(&["token", "status"]));
}

#[test]
fn token_create_is_recognized_with_or_without_json() {
    assert!(is_token_create(&args(&["token", "create", "--ttl", "8h"])));
    assert!(is_token_create(&args(&["--json", "token", "create"])));
    assert!(!is_token_create(&args(&["token", "status"])));
    assert!(!is_token_create(&args(&["run", "--", "token", "create"])));
}

#[test]
fn json_after_vm_is_the_output_mode_wherever_it_sits() {
    for words in [&["--json", "ls"][..], &["ls", "--json"][..]] {
        let (rest, json) = without_json(&args(words));
        assert!(json);
        assert_eq!(rest, args(&["ls"]));
        assert_eq!(plan(&rest, OutputMode::Json).unwrap(), args(&["--json", "list"]));
    }
    // After `--` it belongs to the remote command.
    let (rest, json) = without_json(&args(&["exec", "vm_1", "--", "tool", "--json"]));
    assert!(!json);
    assert_eq!(rest, args(&["exec", "vm_1", "--", "tool", "--json"]));
}

#[test]
fn token_create_with_an_explicit_issuer_or_help_runs_in_process() {
    assert!(!is_token_create(&args(&["token", "create", "--config", "/tmp/issuer.json"])));
    assert!(!is_token_create(&args(&["token", "create", "--config=/tmp/issuer.json"])));
    assert!(!is_token_create(&args(&["token", "create", "--help"])));
    assert!(!is_token_create(&args(&["token", "create", "-h"])));
    // An explicit issuer or team is cmux-vm's: the app mints only at
    // its own signed-in issuer and team, so it must not take these.
    for words in [
        &["token", "create", "--base-url", "https://vm-staging.cmux.dev"][..],
        &["token", "create", "--base-url=https://vm-staging.cmux.dev"],
        &["token", "create", "--team", "team_1"],
        &["token", "create", "--team=team_1"],
    ] {
        assert!(!is_token_create(&args(words)), "{words:?}");
    }
}

#[test]
fn an_environment_key_or_config_mints_without_the_app() {
    let none = |_: &str| None;
    assert!(!has_own_credential(&none));
    let key = |name: &str| (name == "CMUX_VM_API_KEY").then(|| "cmuxvm_sk_x".to_owned());
    assert!(has_own_credential(&key));
    let empty = |name: &str| (name == "CMUX_VM_API_KEY").then(String::new);
    assert!(!has_own_credential(&empty));
}

#[test]
fn a_default_config_counts_only_with_an_api_key() {
    let base = std::env::temp_dir().join(format!("cmux-vm-own-credential-{}", std::process::id()));
    std::fs::create_dir_all(base.join("cmux")).unwrap();
    let xdg = base.to_string_lossy().into_owned();
    let env = |name: &str| (name == "XDG_CONFIG_HOME").then(|| xdg.clone());
    let file = base.join("cmux").join("vm.json");
    assert!(!has_own_credential(&env));
    std::fs::write(&file, r#"{"baseUrl":"https://vm.example.test","teamId":"team_x"}"#).unwrap();
    assert!(!has_own_credential(&env), "no apiKey: the app mints");
    std::fs::write(&file, r#"{"apiKey":"cmuxvm_sk_x"}"#).unwrap();
    assert!(has_own_credential(&env));
    std::fs::write(&file, "not json").unwrap();
    assert!(has_own_credential(&env), "a broken file is cmux-vm's to report");
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn mint_params_hold_the_budget_and_never_scopes() {
    let params = mint_params(&args(&["token", "create", "--ttl", "2h", "--max-vms=2"])).unwrap();
    assert_eq!(params["ttlSeconds"], serde_json::json!(7200));
    assert_eq!(params["maxVms"], serde_json::json!(2));
    assert_eq!(
        params["maxUsdPerHour"],
        serde_json::json!(cmux_vm::token::DEFAULT_MAX_USD_PER_HOUR)
    );
    assert!(!params.contains_key("scopes"));
    assert!(mint_params(&args(&["token", "create", "--scope", "admin"])).is_err());
    assert!(mint_params(&args(&["token", "create", "--ttl", "48h"])).is_err());
}

/// The bundle once shipped `cmux vm` with no `cmux-vm` binary beside it
/// ("cmux-vm not found in PATH"). In process, help works with no PATH at all.
#[test]
fn vm_help_runs_in_process_without_a_cmux_vm_binary() {
    let env = |_: &str| None;
    for scope in [Scope::Machine, Scope::Vm] {
        assert_eq!(run_in_process(args(&["--help"]), scope, &env), 0);
        assert_eq!(run_in_process(args(&["run", "--help"]), scope, &env), 0);
        assert_eq!(run_in_process(args(&["token", "--help"]), scope, &env), 0);
    }
}

#[test]
fn words_after_vm_reach_cmux_vm_verbatim_through_the_global_scanner() {
    let all = args(&["vm", "run", "--sync", "--keep", "--", "echo", "--json", "--sync"]);
    let (global, _, rest) = split_raw(&all).expect("a vm command");
    assert!(global.output == OutputMode::Human);
    assert_eq!(rest, &all[1..]);
    let plan = plan(rest, global.output).unwrap();
    assert_eq!(plan, args(&["run", "--sync", "--keep", "--", "echo", "--json", "--sync"]));
}

#[test]
fn globals_before_vm_still_apply() {
    let all = args(&["--json", "vm", "ls"]);
    let (global, _, rest) = split_raw(&all).expect("a vm command");
    assert!(global.output == OutputMode::Json);
    assert_eq!(plan(rest, global.output).unwrap(), args(&["--json", "list"]));
    assert!(split_raw(&args(&["workspace", "vm"])).is_none());
    assert!(split_raw(&args(&["--", "vm", "ls"])).is_none());
}

#[test]
fn app_mint_errors_keep_the_vm_cli_exit_codes() {
    assert_eq!(mint_exit("not_signed_in", None), cmux_vm::exit::UNAUTHENTICATED);
    assert_eq!(mint_exit("plan_required", None), cmux_vm::exit::PAYMENT_REQUIRED);
    assert_eq!(mint_exit("forbidden", None), cmux_vm::exit::FORBIDDEN);
    assert_eq!(mint_exit("rate_limited", None), cmux_vm::exit::QUOTA_EXCEEDED);
    assert_eq!(mint_exit("invalid_params", None), cmux_vm::exit::USAGE);
    assert_eq!(mint_exit("unavailable", None), cmux_vm::exit::NETWORK);
    assert_eq!(mint_exit("unavailable", Some(0)), cmux_vm::exit::NETWORK);
    assert_eq!(mint_exit("unavailable", Some(502)), cmux_vm::exit::SERVICE_UNAVAILABLE);
    assert_eq!(mint_exit("unavailable", Some(404)), cmux_vm::exit::NOT_FOUND);
    assert_eq!(mint_exit("labs_off", None), 3);
    assert_eq!(mint_exit("method_not_found", None), 5);
    assert_eq!(mint_exit("internal", None), cmux_vm::exit::UNEXPECTED);
}

/// The words `run_if_requested` hands `cmux-vm` for a whole `cmux …` command line.
fn forwarded(words: &[&str]) -> Vec<String> {
    let (global, _, rest) = prepared(&args(words)).expect("a vm command");
    plan_with_globals(&rest, &global).expect("a plan")
}

#[test]
fn an_idempotency_key_reaches_cmux_vm_wherever_it_was_typed() {
    let want = args(&["create", "--name", "t", "--idempotency-key", "k-1"]);
    assert_eq!(forwarded(&["vm", "new", "--name", "t", "--idempotency-key", "k-1"]), want);
    assert_eq!(forwarded(&["vm", "new", "--name", "t", "--idempotency-key=k-1"]), want);
    assert_eq!(forwarded(&["--idempotency-key", "k-1", "vm", "new", "--name", "t"]), want);
    assert_eq!(
        forwarded(&["vm", "snapshot", "create", "vm_1", "--idempotency-key", "k-2"]),
        args(&["snapshot", "create", "vm_1", "--idempotency-key", "k-2"])
    );
    for verb in ["get", "reconcile", "cancel"] {
        assert_eq!(
            forwarded(&["vm", "creation", verb, "--idempotency-key", "k-3"]),
            args(&["creation", verb, "--idempotency-key", "k-3"])
        );
    }
}

#[test]
fn a_forwarded_key_stays_before_the_double_dash_and_words_after_it_are_the_commands() {
    assert_eq!(
        forwarded(&["vm", "exec", "vm_1", "--", "tool", "--idempotency-key", "x"]),
        args(&["exec", "vm_1", "--", "tool", "--idempotency-key", "x"])
    );
    assert_eq!(forwarded(&["vm", "ls"]), args(&["list"]));
}

#[test]
fn a_key_on_a_verb_that_takes_none_is_dropped_as_before() {
    assert_eq!(
        forwarded(&["vm", "pause", "vm_1", "--idempotency-key", "k"]),
        args(&["pause", "vm_1"])
    );
    assert_eq!(
        forwarded(&["vm", "fork", "vm_1", "--idempotency-key", "k"]),
        args(&["fork", "vm_1", "--idempotency-key", "k"])
    );
}

#[test]
fn creation_list_takes_no_key() {
    assert_eq!(
        forwarded(&["vm", "creation", "list", "--idempotency-key", "k"]),
        args(&["creation", "list"])
    );
    assert_eq!(
        forwarded(&["--idempotency-key", "k", "vm", "creation", "list", "--pending"]),
        args(&["creation", "list", "--pending"])
    );
}

#[test]
fn a_key_without_a_value_never_takes_the_double_dash() {
    assert_eq!(
        forwarded(&["vm", "run", "--idempotency-key", "--", "echo", "hi"]),
        args(&["run", "--idempotency-key", "--", "echo", "hi"])
    );
}

/// cmux-vm takes its global options (`--team`, `--base-url`, `--config`, their
/// `=` forms, `--json`) between nested verbs, so the key still reaches
/// `snapshot … create` and `creation … get|reconcile|cancel` (#29709).
#[test]
fn a_key_reaches_a_nested_verb_across_cmux_vm_global_options() {
    assert_eq!(
        forwarded(&["vm", "creation", "--team", "T", "get", "--idempotency-key", "K"]),
        args(&["creation", "--team", "T", "get", "--idempotency-key", "K"])
    );
    assert_eq!(
        forwarded(&["vm", "snapshot", "--team", "T", "create", "vm_1", "--idempotency-key", "K"]),
        args(&["snapshot", "--team", "T", "create", "vm_1", "--idempotency-key", "K"])
    );
    assert_eq!(
        forwarded(&[
            "--idempotency-key",
            "K",
            "vm",
            "creation",
            "--base-url",
            "https://vm.example",
            "--config=/c.toml",
            "--team=T",
            "--config",
            "/c.toml",
            "reconcile",
        ]),
        args(&[
            "creation",
            "--base-url",
            "https://vm.example",
            "--config=/c.toml",
            "--team=T",
            "--config",
            "/c.toml",
            "reconcile",
            "--idempotency-key",
            "K",
        ])
    );
    assert_eq!(
        forwarded(&[
            "vm",
            "snapshot",
            "--base-url=https://vm.example",
            "--json",
            "create",
            "vm_1",
            "--idempotency-key=K"
        ]),
        args(&[
            "--json",
            "snapshot",
            "--base-url=https://vm.example",
            "create",
            "vm_1",
            "--idempotency-key",
            "K"
        ])
    );
}

#[test]
fn a_key_on_a_nested_verb_that_takes_none_is_dropped_across_global_options() {
    assert_eq!(
        forwarded(&["vm", "creation", "--team", "T", "list", "--idempotency-key", "K"]),
        args(&["creation", "--team", "T", "list"])
    );
    // A global option's value is never read as the nested verb.
    assert_eq!(
        forwarded(&["vm", "snapshot", "--team", "create", "list", "--idempotency-key", "K"]),
        args(&["snapshot", "--team", "create", "list"])
    );
    // Words after `--` are the guest command, never verbs.
    assert_eq!(
        forwarded(&["vm", "snapshot", "--", "create", "--idempotency-key", "K"]),
        args(&["snapshot", "--", "create", "--idempotency-key", "K"])
    );
}

/// Every renamed verb: the new `cmux machine` spelling and the old `cmux vm`
/// one hand `cmux-vm` the same words (cmuxterm-hq docs/naming.md).
#[test]
fn old_and_new_spellings_forward_the_same_words() {
    let pairs: &[(&[&str], &[&str])] = &[
        (&["machine", "new", "--name", "t"], &["vm", "create", "--name", "t"]),
        (&["machine", "new", "--name", "t"], &["vm", "new", "--name", "t"]),
        (&["machine", "show", "vm_1"], &["vm", "get", "vm_1"]),
        (&["machine", "get", "vm_1"], &["vm", "get", "vm_1"]),
        (&["machine", "pause", "vm_1"], &["vm", "pause", "vm_1"]),
        (&["machine", "resume", "vm_1"], &["vm", "resume", "vm_1"]),
        (&["machine", "start", "vm_1"], &["vm", "start", "vm_1"]),
        (&["machine", "stop", "vm_1"], &["vm", "stop", "vm_1"]),
        (&["machine", "fork", "vm_1"], &["vm", "fork", "vm_1"]),
        (&["machine", "rm", "vm_1", "--yes"], &["vm", "delete", "vm_1", "--yes"]),
        (&["machine", "delete", "vm_1", "--yes"], &["vm", "rm", "vm_1", "--yes"]),
        (&["machine", "exec", "vm_1", "--", "uname"], &["vm", "exec", "vm_1", "--", "uname"]),
        (&["machine", "run", "--sync", "--", "ls"], &["vm", "run", "--sync", "--", "ls"]),
        (&["machine", "snapshot", "new", "vm_1"], &["vm", "snapshot", "create", "vm_1"]),
        (&["machine", "snapshot", "show", "s_1"], &["vm", "snapshot", "get", "s_1"]),
        (&["machine", "snapshot", "ls"], &["vm", "snapshot", "list"]),
        (&["machine", "snapshot", "rm", "s_1"], &["vm", "snapshot", "delete", "s_1"]),
        (&["machine", "creation", "list"], &["vm", "creation", "list"]),
        (&["machine", "access", "new", "vm_1"], &["vm", "client-session", "create", "vm_1"]),
        (&["machine", "access", "ls", "vm_1"], &["vm", "client-session", "list", "vm_1"]),
        (
            &["machine", "access", "revoke", "vm_1", "vcs_1"],
            &["vm", "client-session", "revoke", "vm_1", "vcs_1"],
        ),
        (&["machine", "key", "new", "--ttl", "8h"], &["vm", "token", "create", "--ttl", "8h"]),
        (&["machine", "key", "status"], &["vm", "token", "status"]),
        (&["machine", "key", "revoke"], &["vm", "token", "revoke"]),
        // The new nouns under the old scope, and the old ones under the new.
        (&["vm", "access", "new", "vm_1"], &["machine", "client-session", "create", "vm_1"]),
        (&["vm", "key", "new"], &["machine", "token", "create"]),
    ];
    for (new, old) in pairs {
        assert_eq!(forwarded(new), forwarded(old), "{new:?} vs {old:?}");
    }
    assert_eq!(forwarded(&["machine", "show", "vm_1"]), args(&["get", "vm_1"]));
    assert_eq!(forwarded(&["machine", "key", "new"]), args(&["token", "create"]));
    assert_eq!(forwarded(&["vm", "ls"]), args(&["list"]));
}

#[test]
fn json_and_an_idempotency_key_reach_cmux_vm_under_machine_too() {
    assert_eq!(
        forwarded(&["machine", "new", "--json", "--idempotency-key", "k"]),
        args(&["--json", "create", "--idempotency-key", "k"])
    );
    assert_eq!(
        forwarded(&["--json", "machine", "snapshot", "new", "vm_1", "--idempotency-key=k"]),
        args(&["--json", "snapshot", "create", "vm_1", "--idempotency-key", "k"])
    );
    // The nested verb is found across cmux-vm's global options.
    assert_eq!(
        forwarded(&["machine", "snapshot", "--team", "T", "new", "vm_1"]),
        args(&["snapshot", "--team", "T", "create", "vm_1"])
    );
    // A global's value is never renamed as the nested verb.
    assert_eq!(
        forwarded(&["machine", "snapshot", "--team", "new", "ls"]),
        args(&["snapshot", "--team", "new", "list"])
    );
    // `key new` is the app-mintable `token create`.
    assert!(is_token_create(&forwarded(&["machine", "key", "new", "--ttl", "8h"])));
}

/// `cmux machine` keeps its catalog and joined-machine verbs: a verb word wins
/// over a machine name only for [`MACHINE_VERBS`], so `machine SELECTOR show`
/// and `machine list|ls|add|revoke|rotate|doctor` are not this module's.
#[test]
fn a_verb_word_wins_over_a_machine_name_only_for_the_reserved_verbs() {
    for words in [
        &["machine", "list"][..],
        &["machine", "ls", "--json"],
        &["--json", "machine", "ls"],
        &["machine", "mac-mini", "show"],
        &["machine", "mac-mini", "session", "list"],
        &["machine", "add", "--name", "box"],
        &["machine", "revoke", "m_1", "--yes"],
        &["machine", "rotate", "m_1"],
        &["machine", "doctor"],
        &["machine", "--help"],
        &["machine"],
        &["workspace", "new", "--name", "machine"],
    ] {
        assert!(prepared(&args(words)).is_none(), "{words:?} is not a VM command");
    }
    // `machine show ID` is the VM API's `get`; `machine ID show` the catalog's.
    assert_eq!(forwarded(&["machine", "show", "mac-mini"]), args(&["get", "mac-mini"]));
    // A machine named like a reserved verb: the verb wins (`machine:run`
    // still names it as a selector).
    assert_eq!(forwarded(&["machine", "run", "show"]), args(&["run", "show"]));
    assert!(prepared(&args(&["machine", "machine:run", "show"])).is_none());
    // `vm` owns every word, so its usage error lists the verbs.
    assert!(prepared(&args(&["vm", "frobnicate"])).is_some());
}

#[test]
fn vm_is_machine_for_the_verbs_other_modules_own() {
    assert_eq!(machine_alias(&args(&["vm", "add"])), Some(args(&["machine", "add"])));
    assert_eq!(
        machine_alias(&args(&["--json", "vm", "revoke", "m_1", "--yes"])),
        Some(args(&["--json", "machine", "revoke", "m_1", "--yes"]))
    );
    assert_eq!(
        machine_alias(&args(&["vm", "rotate", "m_1"])),
        Some(args(&["machine", "rotate", "m_1"]))
    );
    assert_eq!(machine_alias(&args(&["vm", "doctor"])), Some(args(&["machine", "doctor"])));
    // Flags typed between `vm` and the verb move before `machine`.
    assert_eq!(
        machine_alias(&args(&["vm", "--json", "add"])),
        Some(args(&["--json", "machine", "add"]))
    );
    assert_eq!(
        machine_alias(&args(&["vm", "--idempotency-key", "k", "doctor"])),
        Some(args(&["--idempotency-key", "k", "machine", "doctor"]))
    );
    assert_eq!(machine_alias(&args(&["vm", "ls"])), None);
    assert_eq!(machine_alias(&args(&["machine", "add"])), None);
    assert_eq!(machine_alias(&args(&["vm", "exec", "vm_1", "--", "add"])), None);
}

#[test]
fn access_with_a_target_or_exec_is_the_cmux_api_client_session() {
    assert_eq!(
        cloud_access(&args(&["access", "new", "--target", "machine:vm_1", "--ttl", "60"])),
        Some(args(&["create", "--target", "machine:vm_1", "--ttl", "60"]))
    );
    assert_eq!(
        cloud_access(&args(&["access", "create", "--target=machine:vm_1"])),
        Some(args(&["create", "--target=machine:vm_1"]))
    );
    assert_eq!(
        cloud_access(&args(&["access", "exec", "--target", "machine:vm_1", "--", "uname"])),
        Some(args(&["exec", "--target", "machine:vm_1", "--", "uname"]))
    );
    // The VM API's `access new VM_ID`, `ls` and `revoke` stay with cmux-vm,
    // and the old `client-session` spelling is cmux-vm's as it always was.
    assert_eq!(cloud_access(&args(&["access", "new", "vm_1"])), None);
    assert_eq!(cloud_access(&args(&["access", "new", "vm_1", "--", "--target"])), None);
    assert_eq!(cloud_access(&args(&["access", "ls", "vm_1"])), None);
    assert_eq!(cloud_access(&args(&["client-session", "exec", "--target", "machine:vm_1"])), None);
    // The words it hands over parse as `cloud client-session create|exec`'s.
    let words = cloud_access(&args(&[
        "access",
        "exec",
        "--target",
        "machine:vm_abcdefghij0123456789",
        "--",
        "uname",
    ]))
    .unwrap();
    assert!(super::super::cloud_client_session::parse(&words).is_ok());
}

#[test]
fn machine_help_names_every_new_verb_and_the_old_spellings() {
    let text = help();
    for verb in ["run", "new", "show", "pause", "resume", "rm", "exec", "access", "key"] {
        assert!(text.contains(&format!("\n  {verb} ")), "{verb} missing:\n{text}");
    }
    assert!(text.contains("cmux vm"), "{text}");
}
