use super::{drop_retired_run_flags, parse_run, split_mode};
use cmux_server_core::platform::InstallMode;

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

/// The unit an image baked before the carrier cut still holds; self-update replaces the binary
/// under it, so its argv must start the normal system host.
#[test]
fn an_old_native_receiver_unit_starts_the_normal_system_host() {
    let (mode, rest) =
        split_mode(&strings(&["--mode", "system", "--native-receiver"])).expect("its --mode");
    assert!(matches!(mode, Some(InstallMode::System)));
    let (rest, retired) = drop_retired_run_flags(&rest);
    assert!(rest.is_empty(), "{rest:?}");
    assert_eq!(retired, ["--native-receiver"]);
    let cfg = parse_run(&rest, Vec::new()).expect("the old unit's argv parses");
    let production = crate::config::Config::production();
    assert_eq!(cfg.paths.at("/etc/x"), production.paths.at("/etc/x"));
    assert_eq!(cfg.announce, production.announce);
}

#[test]
fn a_retired_flag_is_reported_once_and_other_flags_stay() {
    let (rest, retired) = drop_retired_run_flags(&strings(&[
        "--native-receiver",
        "--root",
        "/tmp/r",
        "--native-receiver",
    ]));
    assert_eq!(rest, strings(&["--root", "/tmp/r"]));
    assert_eq!(retired, ["--native-receiver"]);
    assert!(parse_run(&strings(&["--native-receiver"]), Vec::new()).is_err(), "only run drops it");
}

#[test]
fn the_retired_flag_is_not_in_the_help() {
    assert!(!super::USAGE.contains("native-receiver"));
}
