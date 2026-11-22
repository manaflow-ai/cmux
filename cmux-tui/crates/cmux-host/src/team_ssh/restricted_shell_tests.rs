use super::restricted_shell::{CMUX_BIN, plan, words};

const SELF: &str = "/usr/local/libexec/x/cmux-host";

fn ok(cmd: &str) -> Vec<String> {
    plan(Some(cmd), Some(SELF)).unwrap_or_else(|e| panic!("{cmd:?} refused: {e}"))
}

fn refused(cmd: Option<&str>) -> String {
    match plan(cmd, Some(SELF)) {
        Ok(args) => panic!("{cmd:?} ran {args:?}"),
        Err(e) => e,
    }
}

#[test]
fn words_follow_shell_quoting_without_any_expansion() {
    assert_eq!(words("cmux  team\twhoami").expect("w"), ["cmux", "team", "whoami"]);
    assert_eq!(
        words(r#"a 'b c' "d \"e\" \$f \x" g\ h ''"#).expect("w"),
        ["a", "b c", r#"d "e" $f \x"#, "g h", ""]
    );
    assert_eq!(words("x;y $(id) `id` *").expect("w"), ["x;y", "$(id)", "`id`", "*"]);
    assert!(words("a 'b").is_err());
    assert!(words("a \"b").is_err());
    assert!(words("a \\").is_err());
    assert!(words("a\nb").is_err(), "newline");
    assert!(words("a\0b").is_err(), "NUL");
    assert!(words(&"a".repeat(16 * 1024 + 1)).is_err(), "too long");
}

#[test]
fn only_allowlisted_cmux_team_verbs_run_as_this_executable() {
    assert_eq!(ok("cmux team whoami"), ["team", "whoami"]);
    assert_eq!(ok(&format!("{CMUX_BIN} team whoami")), ["team", "whoami"]);
    assert_eq!(ok(&format!("{SELF} team whoami")), ["team", "whoami"]);
    assert_eq!(ok("'cmux' \"team\" whoami"), ["team", "whoami"]);
}

#[test]
fn shells_other_programs_and_other_verbs_are_refused() {
    assert!(refused(None).contains("no shell"));
    assert!(refused(Some("")).contains("no shell"));
    assert!(refused(Some("   ")).contains("no shell"));
    for cmd in [
        "id",
        "bash -c id",
        "sh",
        "systemd-run --user sleep 1",
        "at now",
        "crontab -l",
        "/bin/cmux team whoami",
        "./cmux team whoami",
        "cmux host team-ssh reap",
        "cmux team",
        "cmux team restricted-shell",
        "cmux team nosuchverb",
        "cmux team whoami extra",
        "cmux team whoami; id",
        "cmux team whoami && id",
        "cmux team whoami $(id)",
        "cmux 'team whoami'",
        "cmux team 'whoami '",
    ] {
        refused(Some(cmd));
    }
}
