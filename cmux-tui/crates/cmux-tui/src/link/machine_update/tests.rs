use std::path::PathBuf;

use super::{Request, machine_is_older, parse};

fn args(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_takes_the_flags_in_any_order() {
    let request =
        |to_bundled, if_older| Request { socket: PathBuf::from("/s"), to_bundled, if_older };
    assert_eq!(parse(&args("update --socket /s")), Some(request(false, false)));
    assert_eq!(parse(&args("update --socket /s --to-bundled")), Some(request(true, false)));
    assert_eq!(parse(&args("update --to-bundled --socket /s")), Some(request(true, false)));
    assert_eq!(
        parse(&args("update --socket /s --to-bundled --if-older")),
        Some(request(true, true))
    );
    assert_eq!(
        parse(&args("update --if-older --to-bundled --socket /s")),
        Some(request(true, true))
    );
}

#[test]
fn parse_refuses_bad_usage() {
    for line in [
        "",
        "update",
        "update --socket",
        "status --socket /s",
        "update --socket /s --if-older",
        "update --socket /s --to-bundled --to-bundled",
        "update --socket /s --socket /t",
        "update --socket /s --force",
    ] {
        assert_eq!(parse(&args(line)), None, "{line}");
    }
}

#[test]
fn a_machine_is_older_only_by_an_earlier_build_time() {
    let local = 1_793_095_467;
    // A daemon from before `build_time` in identify, or one that knows none.
    assert!(machine_is_older(None, local));
    assert!(machine_is_older(Some(0), local));
    assert!(machine_is_older(Some(local - 1), local));
    // The same source tree, or a newer build: never moved back.
    assert!(!machine_is_older(Some(local), local));
    assert!(!machine_is_older(Some(local + 1), local));
    // This client does not know its own time: no order.
    assert!(!machine_is_older(None, 0));
    assert!(!machine_is_older(Some(1), 0));
}
