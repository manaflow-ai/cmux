use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn planned(words: &[&str]) -> Result<Vec<String>, UsageError> {
    let all = args(words);
    plan(split(&all).expect("a vm command"), OutputMode::Human)
}

#[test]
fn only_the_vm_scope_is_owned() {
    assert!(split(&args(&["vm", "ls"])).is_some());
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
    let plan = plan(split(&all).unwrap(), OutputMode::Json).unwrap();
    assert_eq!(plan, args(&["--json", "list"]));
}

#[test]
fn a_vm_with_no_verb_or_an_unknown_verb_is_a_usage_error() {
    assert!(planned(&["vm"]).is_err());
    assert!(planned(&["vm", "frobnicate"]).is_err());
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
fn an_environment_key_or_config_mints_without_the_app() {
    let none = |_: &str| None;
    assert!(!has_own_credential(&none));
    let key = |name: &str| (name == "CMUX_VM_API_KEY").then(|| "cmuxvm_sk_x".to_owned());
    assert!(has_own_credential(&key));
    let empty = |name: &str| (name == "CMUX_VM_API_KEY").then(String::new);
    assert!(!has_own_credential(&empty));
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
    assert_eq!(run_in_process(args(&["--help"]), &env), 0);
    assert_eq!(run_in_process(args(&["run", "--help"]), &env), 0);
    assert_eq!(run_in_process(args(&["token", "--help"]), &env), 0);
}
