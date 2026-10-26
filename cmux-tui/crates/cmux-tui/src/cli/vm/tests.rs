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
fn a_vm_with_no_verb_or_an_unknown_verb_lists_the_wrapper_verbs() {
    for words in [&["vm"][..], &["vm", "frobnicate"][..]] {
        let error = planned(words).unwrap_err();
        for verb in [
            "new", "ls", "get", "pause", "resume", "start", "stop", "rm", "exec", "fork",
            "snapshot",
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
