use super::*;

#[test]
fn reads_only_literals_without_interpreting_shell_expressions() {
    let vars = parse("# comment\nexport DEMO_KEY='a'\\''b\\c$HOME$(touch nope)`nope`'\nexport EMPTY=''\nunset DEMO_KEY\n. /some/script\n").unwrap();
    assert_eq!(vars["DEMO_KEY"], "a'b\\c$HOME$(touch nope)`nope`");
    assert_eq!(vars["EMPTY"], "");
    assert_eq!(parse("export MULTI='line1\nline2'\n").unwrap()["MULTI"], "line1\nline2");
    for bad in [
        "export KEY=$(command)",
        "export KEY='a'; command",
        "export KEY=\"$HOME\"",
        "export KEY='a\nb",
    ] {
        assert!(parse(bad).is_none());
    }
}

#[test]
fn loader_and_bootstrap_names_never_enter_the_overlay() {
    for name in [
        "LD_PRELOAD",
        "DYLD_INSERT_LIBRARIES",
        "BASH_ENV",
        "PYTHONSTARTUP",
        "JAVA_TOOL_OPTIONS",
        "PERL5DB",
        "ZDOTDIR",
        "GCONV_PATH",
        "GIT_SSH_COMMAND",
        "GIT_CONFIG_COUNT",
        "PATH",
        "HOME",
        "SHELL",
        "CMUX_ACCESS_TOKEN",
        "ACPMUX_HOME",
        "9BAD",
    ] {
        assert!(!allowed_name(name), "{name}");
    }
    assert!(allowed_name("API_TOKEN"));
    assert_eq!(parse("export HOME='/other'\nexport API_TOKEN='synthetic'\n").unwrap().len(), 1);
}

#[test]
#[cfg(unix)]
fn requires_a_private_owned_regular_file_and_reads_replacements() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(".config/cmux");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("machine.env");
    std::fs::write(&path, "export DEMO_KEY='first'\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read_in(home.path())["DEMO_KEY"], "first");
    let next = dir.join("next");
    std::fs::write(&next, "export DEMO_KEY='other'\n").unwrap();
    std::fs::set_permissions(&next, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::rename(&next, &path).unwrap();
    assert_eq!(read_in(home.path())["DEMO_KEY"], "other");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(read_in(home.path()).is_empty());
    std::fs::rename(&path, &next).unwrap();
    std::os::unix::fs::symlink(&next, &path).unwrap();
    assert!(read_in(home.path()).is_empty());
    std::fs::remove_file(&path).unwrap();
    assert!(read_in(home.path()).is_empty());
}
