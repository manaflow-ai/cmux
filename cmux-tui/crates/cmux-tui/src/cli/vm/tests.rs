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
