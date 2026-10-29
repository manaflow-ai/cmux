//! Outside input to the remote CLI returns an error, never a panic.

use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn no_remote_command_is_an_error() {
    let error = run_inner(&[], "USAGE", || panic!("no command loads the config")).unwrap_err();
    assert!(error.to_string().contains("unknown remote command"), "{error:#}");
    assert!(error.to_string().contains("USAGE"), "{error:#}");
}

#[test]
fn flag_value_needs_a_following_value() {
    assert_eq!(flag_value(&strings(&["--destination"]), "--destination"), None);
    assert_eq!(flag_value(&strings(&[]), "--destination"), None);
    assert_eq!(
        flag_value(&strings(&["--x", "--destination", "/a"]), "--destination").as_deref(),
        Some("/a")
    );
}

#[test]
fn update_need_rejects_malformed_arguments() {
    let cases: [&[&str]; 4] =
        [&[], &["--probe-json"], &["--probe-jsonx"], &["--probe-json", "a", "b"]];
    for args in cases {
        let error = run_update_need(&strings(args)).unwrap_err();
        assert_eq!(error.to_string(), catalog().remote.remote_update_need_help, "{args:?}");
    }
}

#[test]
fn update_need_reads_the_inline_probe_path() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("probe.json");
    fs::write(&path, "[]").unwrap();
    let error = run_update_need(&[format!("--probe-json={}", path.display())]).unwrap_err();
    assert_eq!(error.to_string(), "the probe is not a JSON object");
}

#[test]
fn enroll_admin_actions_check_their_positionals() {
    let cases: [(&[&str], usize); 2] = [(&["approve"], 1), (&["disconnect", "device"], 2)];
    for (args, arity) in cases {
        let error = parse_enroll_admin_args(&strings(args)).err().unwrap();
        let action = EnrollAdminAction::parse(args[0]).unwrap();
        assert_eq!(error.to_string(), catalog().remote_client.enroll_arity(action.name(), arity));
    }
}
