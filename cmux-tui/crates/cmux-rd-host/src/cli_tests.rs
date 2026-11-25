use super::*;

#[test]
fn help_prints_usage_and_succeeds() {
    for flag in ["-h", "--help", "help"] {
        assert_eq!(run_cli(&[flag.to_string()]), 0, "{flag}");
    }
}

#[test]
fn a_typo_is_an_unknown_command_with_usage() {
    let msg = unknown_command("bnech");
    assert!(msg.starts_with("unknown command bnech"), "{msg}");
    assert!(msg.contains(USAGE), "{msg}");
}

#[test]
fn a_left_out_command_says_it_is_not_in_this_build() {
    let msg = unknown_command("bench");
    assert!(msg.starts_with("not in this build"), "{msg}");
    if !cfg!(feature = "bench") {
        assert!(msg.contains("--features bench"), "{msg}");
    }
    assert!(unknown_command("windows-host").starts_with("not in this build"));
}

#[test]
fn every_usage_command_is_known() {
    let list = USAGE.trim_start_matches("usage: cmux-rd ").split(' ').next().unwrap();
    for cmd in list.split('|') {
        assert!(KNOWN_COMMANDS.contains(&cmd), "{cmd}");
    }
}
