use super::restricted_shell::plan;

const SELF: &str = "/usr/local/libexec/x/cmux-host";

fn refused(cmd: Option<&str>) -> String {
    match plan(cmd, Some(SELF)) {
        Ok(args) => panic!("{cmd:?} ran {args:?}"),
        Err(e) => e,
    }
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
