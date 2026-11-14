use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::time::Duration;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[test]
fn apps_place_uses_the_manifest_region_unless_one_is_named() {
    let default = parse(&words("local/customize#prs")).unwrap();
    assert!(default.get("region").is_none());
    for region in ["top", "middle", "bottom"] {
        let placed = parse(&words(&format!("local/customize#prs --region {region}"))).unwrap();
        assert_eq!(placed["region"], region);
    }
}

#[test]
fn apps_place_rejects_missing_contributions_and_bad_regions() {
    for bad in [
        "",
        "local/customize",
        "local/customize#",
        "#prs",
        "local/#prs",
        "/customize#prs",
        "local/customize/extra#prs",
        "local/customize#prs#extra",
        "local/customize#prs extra",
        "local/customize#prs --region",
        "local/customize#prs --region left",
        "local/customize#prs --region bottom --region top",
        "local/customize#prs --bogus bottom",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
    assert!(parse(&["local/customize#two words".into()]).is_err());
    assert_eq!(run_if_requested(&words("apps list")), None);
}

/// Exercise the real CLI route and transport: the exact contribution
/// and optional region reach the daemon, and its response sets the exit
/// code even when change events arrive before the response.
#[test]
fn apps_place_round_trip_uses_the_daemon_and_returns_its_verdict() {
    for (region, ok) in [(Some("bottom"), true), (None, false)] {
        let dir = cmux_unix_socket::short_test_dir("cmux-apps-place");
        let socket = dir.path().join("daemon.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let daemon = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let writer = reader.get_mut();
            writeln!(writer, "{}", json!({"event": "apps-changed"})).unwrap();
            writeln!(writer, "{}", json!({"id": "other", "ok": true})).unwrap();
            writeln!(
                writer,
                "{}",
                json!({"id": request["id"], "ok": ok,
                    "data": {"contribution": "local/customize#prs", "placed": true},
                    "error_code": "apps.not_installed", "error": "not installed"})
            )
            .unwrap();
            request
        });
        let mut args = vec![
            "--socket".into(),
            socket.to_string_lossy().into_owned(),
            "--quiet".into(),
            "apps".into(),
            "place".into(),
            "local/customize#prs".into(),
        ];
        if let Some(region) = region {
            args.extend(["--region".into(), region.into()]);
        }
        assert_eq!(crate::cli::run(&args, "test"), if ok { 0 } else { 1 });
        let request = daemon.join().unwrap();
        assert_eq!(request["cmd"], "apps-place");
        assert_eq!(request["contribution"], "local/customize#prs");
        assert_eq!(request.get("region").and_then(Value::as_str), region);
        assert!(request.get("origin").is_none(), "CLI retains its own origin");
    }
}
