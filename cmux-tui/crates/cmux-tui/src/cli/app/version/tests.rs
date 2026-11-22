use std::path::PathBuf;

use serde_json::{Map, Value, json};

use super::super::AppCommand;
use super::*;

fn nightly_identify() -> Value {
    json!({
        "app": "cmux-next",
        "app_bundle_path": "/Applications/cmux NIGHTLY.app",
        "app_cli_path": "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux",
        "build": "3937488754201",
        "bundle_id": "com.cmuxterm.app.nightly",
        "pid": 14047,
        "protocol_version": 1,
        "socket_path": "/Users/me/.local/state/cmux/cmux-nightly.sock",
        "tag": null,
        "version": "1.0.0-nightly.3937488754201",
    })
}

fn ready_updates() -> Value {
    json!({
        // NEXT keeps its raw feed identity in updates.status; cmux version's
        // public app.channel must continue to say "nightly".
        "track": "nightly-next",
        "phase": "idle",
        "detected_version": "1.0.0-nightly.3937900000000",
        "probing": false,
        "automatic_checks": true,
        "automatic_downloads": true,
        "sparkle_enabled": true,
        "feed_url": "https://example.test/appcast-arm64.xml",
        "last_probe": {"result": "update_available", "checked_at": "2026-10-20T06:30:00Z"},
        "last_probe_error": null,
        "card": {"kind": "ready", "title": "Update Ready", "lines": [], "actions": []},
        "badge": "update",
        "log": ["a", "b"],
    })
}

fn inputs(identify: Result<Value, Value>, updates: Option<Value>, cli_path: &str) -> Inputs {
    let mut components = Map::new();
    components
        .insert("acpmux".into(), json!({"commit": "f4c2e8298457235eb75783ce3f6c73f55e326d28"}));
    Inputs {
        cli: json!({"app": "cmux-tui", "version": "1.0.0", "build_commit": "c6a351b9205780cd8c27cdcb0a7876d4410a7acb"}),
        cli_path: Some(PathBuf::from(cli_path)),
        identify,
        updates,
        components,
        os: json!({"name": "macOS", "version": "26.1", "build": "25B78", "arch": "aarch64"}),
        customize: Value::Null,
    }
}

/// A bug report says which customize layers are on: a pull request's web
/// layer by number and short head, in the one line and in the JSON, read
/// from the library itself (no app needed).
#[test]
fn the_report_names_the_customize_layers_that_are_on() {
    use cmux_customize::library::CodeLayer;
    use cmux_customize::{Customize, Roots};
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let key = format!("{:064x}", 7_u8);
    let layer_dir = customize.layer_dir(&key);
    std::fs::create_dir_all(&layer_dir).unwrap();
    std::fs::write(layer_dir.join("manifest.json"), "{}").unwrap();
    let layer = CodeLayer {
        kind: Default::default(),
        source: String::new(),
        repo: "manaflow-ai/cmux".to_owned(),
        pr: 43496,
        title: "probe".to_owned(),
        head: "dbb1e3e0123456789abcdef0123456789abcdef0".to_owned(),
        base: String::new(),
        web: key,
        abi: Some(1),
        needs_build: Vec::new(),
        note: String::new(),
    };
    customize.library_use_code(layer, vec![], "cli", 1).unwrap();

    let mut inputs = inputs(Ok(nightly_identify()), None, "/usr/local/bin/cmux");
    inputs.customize = serde_json::to_value(customize.layers()).unwrap();
    let report = report(&inputs);
    let layers = &report["customize"];
    assert_eq!(layers["line"], "customize: 1 on: pr-43496 @dbb1e3e (web)");
    assert_eq!(layers["on"][0]["kind"], "pr");
    assert_eq!(layers["on"][0]["pr"], 43496);
    assert_eq!(layers["on"][0]["head"], "dbb1e3e");
    assert_eq!(layers["on"][0]["web"], true);
    assert_eq!(layers["overlay"], json!(layer_dir.to_string_lossy()));
    assert_eq!(layers["stray_overlay"], false);
    let labels = &crate::localization::catalog_for_locale("en_US.UTF-8").app_control.version;
    let text = human(&report, labels);
    assert!(text.contains("customize        1 on: pr-43496 @dbb1e3e (web)\n"), "{text}");
}

/// The report names the app behind the socket with its full nightly build,
/// channel, bundle and socket, and the updater's state an agent acts on.
#[test]
fn the_report_names_the_running_app_and_its_update_state() {
    let cli = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";
    let report = report(&inputs(Ok(nightly_identify()), Some(ready_updates()), cli));
    assert_eq!(report["cli"]["version"], "1.0.0");
    assert_eq!(report["cli"]["path"], cli);
    let app = &report["app"];
    assert_eq!(app["name"], "cmux-next");
    assert_eq!(app["version"], "1.0.0-nightly.3937488754201");
    assert_eq!(app["build"], "3937488754201");
    assert_eq!(app["channel"], "nightly");
    assert_eq!(app["classic"], false);
    assert_eq!(app["bundle_id"], "com.cmuxterm.app.nightly");
    assert_eq!(app["bundle_path"], "/Applications/cmux NIGHTLY.app");
    assert_eq!(app["socket"], "/Users/me/.local/state/cmux/cmux-nightly.sock");
    assert_eq!(app["pid"], 14047);
    assert_eq!(report["app_error"], Value::Null);
    let updates = &report["updates"];
    assert_eq!(updates["track"], "nightly-next");
    assert_eq!(updates["phase"], "idle");
    assert_eq!(updates["ready"], "ready");
    assert_eq!(updates["detected_version"], "1.0.0-nightly.3937900000000");
    assert_eq!(updates["last_check"], "2026-10-20T06:30:00Z");
    assert_eq!(updates["last_check_result"], "update_available");
    assert_eq!(updates["automatic_downloads"], true);
    assert!(updates.get("log").is_none(), "the log stays out of the report");
    assert_eq!(
        report["components"]["acpmux"]["commit"],
        "f4c2e8298457235eb75783ce3f6c73f55e326d28"
    );
    assert_eq!(report["os"]["version"], "26.1");
}

/// A CLI that is not the app's bundled one (a dev shim, another build) is
/// flagged, so an agent knows its commands may not match the app.
#[test]
fn a_cli_from_another_build_is_flagged() {
    let bundled = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";
    let same = report(&inputs(Ok(nightly_identify()), None, bundled));
    assert_eq!(same["cli_matches_app"], true);
    let other = report(&inputs(Ok(nightly_identify()), None, "/tmp/elsewhere/cmux"));
    assert_eq!(other["cli_matches_app"], false);
}

/// With no app behind the socket the report still prints the CLI side, with
/// `app: null` and why.
#[test]
fn no_app_still_reports_the_cli_and_the_reason() {
    let error = json!({"code": "app.unreachable", "message": "no cmux app at /tmp/x.sock"});
    let report = report(&inputs(Err(error), None, "/usr/local/bin/cmux"));
    assert_eq!(report["app"], Value::Null);
    assert_eq!(report["app_error"]["code"], "app.unreachable");
    assert_eq!(report["app_error"]["message"], "no cmux app at /tmp/x.sock");
    assert_eq!(report["cli_matches_app"], Value::Null);
    assert_eq!(report["updates"], Value::Null);
    assert_eq!(report["cli"]["version"], "1.0.0");
}

/// Without the updater's track, the channel comes from the bundle id; the
/// classic app (`"app": "cmux"`) is its own channel.
#[test]
fn the_channel_comes_from_the_bundle_id_without_the_updater() {
    let cases = [
        ("cmux-next", Some("com.cmuxterm.app"), "stable"),
        ("cmux-next", Some("com.cmuxterm.app.nightly"), "nightly"),
        ("cmux-next", Some("com.cmuxterm.app.rc"), "rc"),
        ("cmux-next", Some("com.cmuxterm.app.debug"), "development"),
        ("cmux-next", Some("com.cmuxterm.app.debug.my-tag"), "development"),
        ("cmux-next", Some("com.cmuxterm.app.staging"), "development"),
        ("cmux-next", Some("com.example.other"), "unknown"),
        ("cmux-next", None, "unknown"),
        ("cmux", Some("com.cmuxterm.app"), "classic"),
    ];
    for (name, bundle, channel) in cases {
        assert_eq!(channel_of(name, bundle), channel, "{name} {bundle:?}");
    }
    let mut identify = nightly_identify();
    identify["bundle_id"] = json!("com.cmuxterm.app.debug.fix-x");
    identify["tag"] = json!("fix-x");
    let report = report(&inputs(Ok(identify), None, "/x/cmux"));
    assert_eq!(report["app"]["channel"], "development");
    assert_eq!(report["app"]["tag"], "fix-x");
}

/// The bundled helpers' `bin/<name>.version` stamps are `key=value` lines.
#[test]
fn version_stamps_parse_as_key_value_lines() {
    let stamp = parse_stamp(
        "commit=ba8b81c1c52b\nsource=release-manifest\nrun=\nversion=cmux 1.0.0 (ba8b81c1c52b; ghostty a04c)\n\n",
    );
    assert_eq!(stamp["commit"], "ba8b81c1c52b");
    assert_eq!(stamp["source"], "release-manifest");
    assert!(stamp.get("run").is_none(), "an empty value is left out");
    assert_eq!(stamp["version"], "cmux 1.0.0 (ba8b81c1c52b; ghostty a04c)");
}

/// The stamps are read from the app bundle's `Contents/Resources/bin`.
#[test]
fn components_are_read_from_the_bundle() {
    let root = std::env::temp_dir().join(format!("cmux-version-test-{}", std::process::id()));
    let bin = root.join("cmux X.app/Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("acpmux.version"), "commit=aaa\nmode=alias-to-cmux\n").unwrap();
    std::fs::write(bin.join("optchat-chief.version"), "commit=bbb\n").unwrap();
    std::fs::write(bin.join("cmux"), "binary").unwrap();
    let components = read_components(&root.join("cmux X.app"));
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(components.len(), 2);
    assert_eq!(components["acpmux"]["mode"], "alias-to-cmux");
    assert_eq!(components["optchat-chief"]["commit"], "bbb");
}

/// The text report puts each fact on its own line.
#[test]
fn the_text_report_has_one_fact_per_line() {
    let cli = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";
    let report = report(&inputs(Ok(nightly_identify()), Some(ready_updates()), cli));
    let labels = &crate::localization::catalog_for_locale("en_US.UTF-8").app_control.version;
    let text = human(&report, labels);
    assert!(text.contains("cmux-next 1.0.0-nightly.3937488754201 [nightly]"), "{text}");
    assert!(text.contains("com.cmuxterm.app.nightly /Applications/cmux NIGHTLY.app"), "{text}");
    assert!(text.contains("(pid 14047)"), "{text}");
    assert!(text.contains("idle, ready, 1.0.0-nightly.3937900000000"), "{text}");
    assert!(text.contains("2026-10-20T06:30:00Z"), "{text}");
    assert!(text.contains("acpmux"), "{text}");
    assert!(text.contains("26.1 (25B78)"), "{text}");
    let none = report_without_app();
    let text = human(&none, labels);
    assert!(text.contains("no app answered (no cmux app at /tmp/x.sock)"), "{text}");
}

fn report_without_app() -> Value {
    let error = json!({"code": "app.unreachable", "message": "no cmux app at /tmp/x.sock"});
    report(&inputs(Err(error), None, "/usr/local/bin/cmux"))
}

/// `cmux version` is a command of its own, with no arguments.
#[test]
fn cmux_version_parses_to_the_version_report() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(super::super::parse(&words(&["version"])).unwrap(), Some(AppCommand::Version));
    assert!(super::super::parse(&words(&["version", "extra"])).is_err());
}

/// A bundled CLI's path names its app bundle.
#[test]
fn the_bundle_is_found_from_the_bundled_cli_path() {
    let exe = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
    assert_eq!(bundle_of(exe), Some(PathBuf::from("/Applications/cmux NIGHTLY.app")));
    assert_eq!(bundle_of(Path::new("/usr/local/bin/cmux")), None);
}

/// Leo's NIGHTLY had an overlay put there by hand that the app refused for
/// another web ABI, while the library read as empty: the report names it.
#[test]
fn the_report_names_a_hand_installed_overlay_the_app_refuses() {
    use cmux_customize::{Customize, Roots};
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let overlay = dir.path().join("web-overlay");
    std::fs::create_dir_all(&overlay).unwrap();
    std::fs::write(
        overlay.join("manifest.json"),
        json!({"stamp": "20261112T081500Z-1", "commit": "0119230412", "abi": 4}).to_string(),
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join("config")).unwrap();
    std::fs::write(
        dir.path().join("config/web-dev.json"),
        json!({"overlay": overlay, "enabled": true}).to_string(),
    )
    .unwrap();

    let mut inputs = inputs(Ok(nightly_identify()), None, "/usr/local/bin/cmux");
    let now = 1_794_733_200_000; // 2026-11-15T09:00Z
    inputs.customize = serde_json::to_value(customize.layers_at(Some(7), now)).unwrap();
    let report = report(&inputs);
    assert_eq!(report["customize"]["web_dev"]["refused"], true);
    assert_eq!(report["customize"]["web_dev"]["library"], false);
    let labels = &crate::localization::catalog_for_locale("en_US.UTF-8").app_control.version;
    let text = human(&report, labels);
    assert!(
        text.contains(
            "customize        0 on; web-dev overlay 01192304 (3 days, refused: abi 4, app 7)\n"
        ),
        "{text}"
    );
}
