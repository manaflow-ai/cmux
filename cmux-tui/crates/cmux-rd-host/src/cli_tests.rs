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
fn bench_usage_names_every_option() {
    let src = include_str!("bench.rs");
    let mut seen = 0;
    for call in ["opts.get(\"", "opts.num_or(\"", "opts.str_or(\""] {
        for (i, _) in src.match_indices(call) {
            let rest = &src[i + call.len()..];
            let key = &rest[..rest.find('"').unwrap()];
            seen += 1;
            assert!(
                BENCH_USAGE.contains(&format!("[--{key} "))
                    || BENCH_USAGE.contains(&format!(" --{key} ")),
                "bench.rs reads --{key}, but `cmux-rd bench --help` (BENCH_USAGE) does not name it"
            );
        }
    }
    assert!(seen > 20, "found only {seen} option reads in bench.rs");
    assert!(BENCH_USAGE.contains("[--marker-scale N/D"));
}

#[test]
fn every_usage_command_is_known() {
    let list = USAGE.trim_start_matches("usage: cmux-rd ").split(' ').next().unwrap();
    for cmd in list.split('|') {
        assert!(KNOWN_COMMANDS.contains(&cmd), "{cmd}");
    }
}
