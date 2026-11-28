use std::path::{Path, PathBuf};

use super::{
    Command, RustVerb, Swift, auto_lines, parse, recorded_swift_tree, recorded_tree,
    recorded_watch_tree, routed, setting_word, tool_path,
};
use serde_json::json;

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn no_verb_or_help_is_the_usage() {
    assert_eq!(parse(&[]).unwrap(), Command::Help);
    assert_eq!(parse(&words(&["help"])).unwrap(), Command::Help);
    assert_eq!(parse(&words(&["start", "--help"])).unwrap(), Command::Help);
}

#[test]
fn start_takes_a_worktree_and_a_port() {
    assert_eq!(parse(&words(&["start"])).unwrap(), Command::Start { worktree: None, port: None });
    assert_eq!(
        parse(&words(&["start", "--worktree", "/src/wt", "--port=4300"])).unwrap(),
        Command::Start { worktree: Some(PathBuf::from("/src/wt")), port: Some(4300) }
    );
}

#[test]
fn stop_and_status_take_only_a_worktree() {
    assert_eq!(parse(&words(&["stop"])).unwrap(), Command::Stop { worktree: None });
    assert_eq!(
        parse(&words(&["status", "--worktree=/src/wt"])).unwrap(),
        Command::Status { worktree: Some(PathBuf::from("/src/wt")) }
    );
    assert!(parse(&words(&["stop", "--port", "4300"])).is_err());
}

#[test]
fn refuses_unknown_verbs_flags_and_bad_ports() {
    assert!(parse(&words(&["apply"])).is_err());
    assert!(parse(&words(&["start", "--fast"])).is_err());
    assert!(parse(&words(&["start", "--port", "0"])).is_err());
    assert!(parse(&words(&["start", "--port", "http"])).is_err());
    assert!(parse(&words(&["start", "--worktree"])).is_err());
}

#[test]
fn reads_the_tree_the_dev_server_was_started_from() {
    let dir = std::env::temp_dir().join(format!("cmux-live-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("dev-server.tree");
    std::fs::write(&file, "/Users/me/src/cmux:4200\n").unwrap();
    assert_eq!(recorded_tree(&file), Some(PathBuf::from("/Users/me/src/cmux")));
    std::fs::write(&file, "garbage").unwrap();
    assert_eq!(recorded_tree(&file), None);
    assert_eq!(recorded_tree(&dir.join("missing")), None);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_short_gui_path_gains_bun_and_homebrew() {
    let path = tool_path(Some("/usr/bin:/bin".into()), Some("/Users/me".into())).unwrap();
    assert_eq!(
        path,
        std::ffi::OsString::from(
            "/usr/bin:/bin:/Users/me/.bun/bin:/opt/homebrew/bin:/usr/local/bin"
        )
    );
    let full = "/Users/me/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
    assert_eq!(tool_path(Some(full.into()), Some("/Users/me".into())), None);
}

#[test]
fn rust_takes_a_build_host_and_a_session_on_start() {
    assert_eq!(
        parse(&words(&[
            "start",
            "--rust",
            "--build-host",
            "build-box",
            "--session=cmux-app-nightly"
        ]))
        .unwrap(),
        Command::Rust {
            verb: RustVerb::Start,
            worktree: None,
            build_host: Some("build-box".to_owned()),
            session: Some("cmux-app-nightly".to_owned()),
            socket: None,
        }
    );
    assert_eq!(
        parse(&words(&["status", "--rust"])).unwrap(),
        Command::Rust {
            verb: RustVerb::Status,
            worktree: None,
            build_host: None,
            session: None,
            socket: None,
        }
    );
    assert_eq!(
        parse(&words(&["stop", "--rust", "--worktree", "/src/wt"])).unwrap(),
        Command::Rust {
            verb: RustVerb::Stop,
            worktree: Some(PathBuf::from("/src/wt")),
            build_host: None,
            session: None,
            socket: None,
        }
    );
}

#[test]
fn rust_start_takes_the_socket_of_the_app_to_swap() {
    let start = Command::Rust {
        verb: RustVerb::Start,
        worktree: None,
        build_host: Some("build-box".to_owned()),
        session: None,
        socket: Some(PathBuf::from("/tmp/cmux-app.sock")),
    };
    assert_eq!(
        parse(&words(&[
            "start",
            "--rust",
            "--build-host",
            "build-box",
            "--socket",
            "/tmp/cmux-app.sock"
        ]))
        .unwrap(),
        start
    );
    assert_eq!(
        parse(&words(&[
            "start",
            "--rust",
            "--build-host=build-box",
            "--socket=/tmp/cmux-app.sock"
        ]))
        .unwrap(),
        start
    );
    // A socket or a session names the daemon, not both; and only the Rust loop's start takes it.
    assert!(parse(&words(&["start", "--rust", "--socket", "/s", "--session", "x"])).is_err());
    assert!(parse(&words(&["start", "--socket", "/s"])).is_err());
    assert!(parse(&words(&["start", "--chromium", "--socket", "/s"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--socket", "/s"])).is_err());
    assert!(parse(&words(&["stop", "--rust", "--socket", "/s"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--socket"])).is_err());
}

#[test]
fn a_global_socket_or_session_routes_a_rust_start_that_names_none() {
    let bare = parse(&words(&["start", "--rust"])).unwrap();
    let socket = Path::new("/tmp/app.sock");
    let Command::Rust { socket: got, session, .. } =
        routed(&bare, Some(socket), Some("ignored-when-a-socket-is-given"))
    else {
        panic!("still the Rust loop");
    };
    assert_eq!((got.as_deref(), session), (Some(socket), None));
    let Command::Rust { socket: got, session, .. } = routed(&bare, None, Some("cmux-app-x")) else {
        panic!("still the Rust loop");
    };
    assert_eq!((got, session.as_deref()), (None, Some("cmux-app-x")));
    // The flag after the noun wins over the global one.
    let own = parse(&words(&["start", "--rust", "--socket", "/own.sock"])).unwrap();
    assert_eq!(routed(&own, Some(socket), None), own);
    // Only `start` passes a daemon on; stop and status find the running loop.
    let stop = parse(&words(&["stop", "--rust"])).unwrap();
    assert_eq!(routed(&stop, Some(socket), None), stop);
}

#[test]
fn swift_switches_start_and_stop_with_a_tag() {
    assert_eq!(
        parse(&words(&["start", "--swift", "--tag", "mine"])).unwrap(),
        Command::Swift(Swift {
            on: true,
            worktree: None,
            tag: Some("mine".to_owned()),
            detach: false,
            setting_done: false,
            discard: false,
            fresh: false,
        })
    );
    assert_eq!(
        parse(&words(&[
            "stop",
            "--swift",
            "--worktree=/src/wt",
            "--detach",
            "--setting-done",
            "--discard"
        ]))
        .unwrap(),
        Command::Swift(Swift {
            on: false,
            worktree: Some(PathBuf::from("/src/wt")),
            tag: None,
            detach: true,
            setting_done: true,
            discard: true,
            fresh: false,
        })
    );
    assert_eq!(
        parse(&words(&["start", "--swift", "--fresh"])).unwrap(),
        Command::Swift(Swift {
            on: true,
            worktree: None,
            tag: None,
            detach: false,
            setting_done: false,
            discard: false,
            fresh: true,
        })
    );
    // --fresh is start's: stop and the web loop refuse it.
    assert!(parse(&words(&["stop", "--swift", "--fresh"])).is_err());
    assert!(parse(&words(&["start", "--fresh"])).is_err());
}

#[test]
fn rust_flags_need_rust_and_the_right_verb() {
    assert!(parse(&words(&["start", "--build-host", "h"])).is_err());
    assert!(parse(&words(&["stop", "--rust", "--build-host", "h"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--port", "4300"])).is_err());
    assert!(parse(&words(&["start", "--rust=yes"])).is_err());
}

#[test]
fn chromium_passes_its_start_flags_through_with_the_build_host_first() {
    assert_eq!(
        parse(&words(&[
            "start",
            "--chromium",
            "--src",
            "~/cef/chromium/src",
            "--build-host",
            "builder",
            "--out=out/Debug_GN_arm64",
            "--gpu",
        ]))
        .unwrap(),
        Command::Chromium {
            verb: RustVerb::Start,
            worktree: None,
            args: words(&[
                "--build-host",
                "builder",
                "--src",
                "~/cef/chromium/src",
                "--out",
                "out/Debug_GN_arm64",
                "--gpu",
            ]),
        }
    );
    assert_eq!(
        parse(&words(&["status", "--chromium", "--worktree", "/src/wt"])).unwrap(),
        Command::Chromium {
            verb: RustVerb::Status,
            worktree: Some(PathBuf::from("/src/wt")),
            args: vec![],
        }
    );
}

#[test]
fn chromium_flags_need_chromium_and_start() {
    assert!(parse(&words(&["start", "--src", "/s"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--src", "/s"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--chromium"])).is_err());
    assert!(parse(&words(&["stop", "--chromium", "--out", "out/X"])).is_err());
    assert!(parse(&words(&["start", "--chromium", "--port", "4300"])).is_err());
    assert!(parse(&words(&["start", "--chromium", "--session", "s"])).is_err());
    assert!(parse(&words(&["start", "--chromium=yes"])).is_err());
}

#[test]
fn reads_the_tree_the_rust_loop_watches() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("watch.pid");
    std::fs::write(&file, "4242 /src/my tree\n").unwrap();
    assert_eq!(recorded_watch_tree(&file), Some(PathBuf::from("/src/my tree")));
    std::fs::write(&file, "nope\n").unwrap();
    assert_eq!(recorded_watch_tree(&file), None);
}

#[test]
fn swift_only_flags_need_swift_and_a_switch() {
    assert!(parse(&words(&["start", "--swift", "--port", "4300"])).is_err());
    assert!(parse(&words(&["start", "--tag", "mine"])).is_err());
    assert!(parse(&words(&["stop", "--detach"])).is_err());
    assert!(parse(&words(&["status", "--swift"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--discard"])).is_err());
    assert!(parse(&words(&["stop", "--discard"])).is_err());
    // The other loops' flags are refused, not dropped unread.
    assert!(parse(&words(&["start", "--swift", "--build-host", "h"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--session", "s"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--rust"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--chromium"])).is_err());
    assert!(parse(&words(&["start", "--swift", "--src", "/s"])).is_err());
}

#[test]
fn reads_the_tree_live_mode_ran_from() {
    let dir = std::env::temp_dir().join(format!("cmux-live-swift-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("tree");
    std::fs::write(&file, "/Users/me/src/cmux\n").unwrap();
    assert_eq!(recorded_swift_tree(&file), Some(PathBuf::from("/Users/me/src/cmux")));
    std::fs::write(&file, "relative/path").unwrap();
    assert_eq!(recorded_swift_tree(&file), None);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_live_setting_word_is_the_apps_boolean_else_unknown() {
    assert_eq!(setting_word(&json!({"value": true})), "true");
    assert_eq!(setting_word(&json!({"value": false})), "false");
    assert_eq!(setting_word(&json!({"value": "true"})), "true");
    assert_eq!(setting_word(&json!({"value": null})), "unknown");
    assert_eq!(setting_word(&json!({})), "unknown");
}

/// A fake app and checkout for the web ABI check, in a fresh temp folder.
fn abi_fixture(
    name: &str,
    app_abi: Option<i64>,
    tree_abi: Option<i64>,
) -> (PathBuf, PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-live-abi-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let app = dir.join("cmux NIGHTLY.app");
    let tree = dir.join("tree");
    let app_file = app.join(super::web_abi::APP_ABI);
    let tree_file = tree.join(super::web_abi::TREE_ABI);
    std::fs::create_dir_all(app_file.parent().unwrap()).unwrap();
    std::fs::create_dir_all(tree_file.parent().unwrap()).unwrap();
    if let Some(abi) = app_abi {
        std::fs::write(&app_file, format!("{{\"abi\": {abi}}}\n")).unwrap();
    }
    if let Some(abi) = tree_abi {
        std::fs::write(&tree_file, format!("{{\"$comment\": \"x\", \"abi\": {abi}}}\n")).unwrap();
    }
    (dir, app, tree)
}

#[test]
fn live_start_refuses_a_checkout_at_another_web_abi() {
    let (dir, app, tree) = abi_fixture("mismatch", Some(7), Some(4));
    assert_eq!(
        super::web_abi::mismatch(&tree, std::slice::from_ref(&app)),
        Some(super::web_abi::Mismatch { tree_abi: 4, app: app.clone(), app_abi: 7 })
    );
    let message = crate::localization::catalog().app_control.live.abi_mismatch;
    assert!(
        message.contains("{tree_abi}")
            && message.contains("{app_abi}")
            && message.contains("cmux app try .")
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn live_start_runs_a_checkout_at_the_apps_web_abi_or_with_none() {
    let (dir, app, tree) = abi_fixture("match", Some(7), Some(7));
    assert_eq!(super::web_abi::mismatch(&tree, std::slice::from_ref(&app)), None);
    std::fs::remove_dir_all(dir).unwrap();
    // No web-abi.json on either side: the app checks nothing, so neither does this.
    let (dir, app, tree) = abi_fixture("none-tree", Some(7), None);
    assert_eq!(super::web_abi::mismatch(&tree, std::slice::from_ref(&app)), None);
    std::fs::remove_dir_all(dir).unwrap();
    let (dir, app, tree) = abi_fixture("none-app", None, Some(4));
    assert_eq!(super::web_abi::mismatch(&tree, &[app, dir.join("missing.app")]), None);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn web_abi_targets_the_named_app_else_the_installed_next_builds() {
    assert_eq!(
        super::web_abi::target_apps(Some("/tmp/x.app".into())),
        vec![PathBuf::from("/tmp/x.app")]
    );
    assert_eq!(super::web_abi::target_apps(Some("".into())).len(), 2);
    assert_eq!(
        super::web_abi::target_apps(None)[0],
        PathBuf::from("/Applications/cmux NIGHTLY.app")
    );
}

#[test]
fn auto_takes_a_verb_and_a_worktree() {
    assert_eq!(
        parse(&words(&["auto"])).unwrap(),
        Command::Auto { verb: RustVerb::Start, worktree: None }
    );
    assert_eq!(
        parse(&words(&["auto", "status", "--worktree=/src/wt"])).unwrap(),
        Command::Auto { verb: RustVerb::Status, worktree: Some(PathBuf::from("/src/wt")) }
    );
    assert_eq!(
        parse(&words(&["auto", "--worktree", "/src/wt", "stop"])).unwrap(),
        Command::Auto { verb: RustVerb::Stop, worktree: Some(PathBuf::from("/src/wt")) }
    );
    assert_eq!(parse(&words(&["auto", "--help"])).unwrap(), Command::Help);
    assert!(parse(&words(&["auto", "start", "stop"])).is_err());
    assert!(parse(&words(&["auto", "--rust"])).is_err());
    assert!(parse(&words(&["auto", "--worktree"])).is_err());
}

#[test]
fn auto_status_prints_each_tree_and_the_latest_swaps() {
    let answer = json!({
        "trees": [{"worktree": "/src/wt", "live": {"web": true, "rust": true, "swift": false},
                   "saves": 12, "trigger_ms": {"p50": 9.04, "p95": 14.5, "samples": 12}, "error": null}],
        "recent": [
            {"event": "swap.done", "layer": "web", "ms": 9.0, "paths": ["webviews/src/a.tsx"]},
            {"event": "swap.done", "layer": "needs-build", "ms": 8.0, "paths": ["App/Info.plist"],
             "reason": "resource or manifest"}
        ]
    });
    let lines = auto_lines(&answer, RustVerb::Status);
    assert!(lines[0].contains("/src/wt") && lines[0].contains("web, rust"), "{lines:?}");
    assert!(lines[0].contains("p50 9.0 ms") && lines[0].contains("p95 14.5 ms"), "{lines:?}");
    assert_eq!(lines[1], "  needs-build 8 ms App/Info.plist: resource or manifest");
    assert_eq!(lines[2], "  web 9 ms webviews/src/a.tsx");
    let stopped = auto_lines(&json!({"trees": [], "stopped": ["/src/wt"]}), RustVerb::Stop);
    assert_eq!(stopped.len(), 2);
    assert!(stopped[0].contains("/src/wt"));
}
