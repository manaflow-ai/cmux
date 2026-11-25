use super::*;

#[test]
fn bench_session_mode_defaults_to_control_and_accepts_only_wire_modes() {
    let parse = |args: &[&str]| {
        Opts::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
    };
    assert_eq!(session_mode(&parse(&[])).unwrap(), "control");
    for mode in ["view", "control"] {
        assert_eq!(session_mode(&parse(&["--mode", mode])).unwrap(), mode);
    }
    assert!(session_mode(&parse(&["--mode", "viewer"])).is_err());
}
