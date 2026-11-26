use super::*;

fn parse(args: &[&str]) -> Result<Opts, String> {
    Opts::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
}

#[test]
fn listen_systemd_takes_no_value() {
    let o = parse(&["--listen-systemd", "--peer-uid", "0", "--display", ":99"]).expect("parse");
    assert!(o.flag("listen-systemd"));
    assert_eq!(o.get("peer-uid"), Some("0"));
    assert_eq!(o.get("display"), Some(":99"));
    assert!(!parse(&["--display", ":99"]).expect("parse").flag("listen-systemd"));
    assert!(parse(&["--display"]).is_err());
}

#[test]
fn flag_or_keeps_its_default_and_turns_off_with_zero() {
    assert!(parse(&[]).expect("parse").flag_or("input-frame-now", true));
    assert!(!parse(&[]).expect("parse").flag_or("input-frame-now", false));
    for off in ["0", "false", "off"] {
        let o = parse(&["--input-frame-now", off]).expect("parse");
        assert!(!o.flag_or("input-frame-now", true), "{off} turns it off");
    }
    assert!(parse(&["--input-frame-now", "1"]).expect("parse").flag_or("input-frame-now", false));
}
