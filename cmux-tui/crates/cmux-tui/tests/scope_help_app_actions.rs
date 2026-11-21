//! `cmux <scope> --help` lists every app action the catalog
//! (plans/cmux-next/action-surfaces.json) offers to the CLI as
//! `cmux <scope> <verb…>`, for every such scope, through the real binary's
//! help routing. `cmux tab --help` once listed none of its 57 app verbs
//! (`new-mac-screen`, `stop-mac-screen-viewing`, `new-browser`, …) and
//! `cmux remote --help` printed the root help. `cloud` keeps its own grouped
//! help and test (cli/cloud_help/tests.rs).
#![cfg(unix)]

use std::collections::BTreeMap;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

use serde_json::Value;

const CATALOG: &str = include_str!("../../../../plans/cmux-next/action-surfaces.json");

/// The offered app verbs by scope (the CLI name's first word).
fn offered() -> BTreeMap<String, Vec<String>> {
    let catalog: Value = serde_json::from_str(CATALOG).expect("action-surfaces.json is valid JSON");
    let mut scopes: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for action in catalog["actions"].as_array().expect("actions array") {
        if action["cli"] != "offered" {
            continue;
        }
        if let Some((scope, verb)) =
            action["cli_name"].as_str().and_then(|name| name.split_once(' '))
        {
            scopes.entry(scope.to_owned()).or_default().push(verb.to_owned());
        }
    }
    scopes.remove("cloud");
    scopes
}

/// `cmux <words…>`'s stdout, run as `cmux` (argv[0]) with no app or session.
fn cmux(words: &[&str]) -> String {
    let home = std::env::temp_dir().join(format!("cmux-scope-help-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg0("cmux")
        .args(words)
        .env("HOME", &home)
        .env("CMUX_APP_SOCKET", home.join("no-app.sock"))
        .env("CMUX_SOCKET", home.join("no-session.sock"))
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_SOCKET_PATH")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn lists(help: &str, verb: &str) -> bool {
    help.lines().any(|line| {
        line.strip_prefix("  ")
            .is_some_and(|rest| rest == verb || rest.starts_with(&format!("{verb} ")))
    })
}

#[test]
fn every_scope_help_lists_its_offered_app_verbs() {
    let mut missing = BTreeMap::new();
    for (scope, verbs) in offered() {
        for spelling in [vec![scope.as_str(), "--help"], vec!["help", scope.as_str()]] {
            let help = cmux(&spelling);
            let absent =
                verbs.iter().filter(|verb| !lists(&help, verb)).cloned().collect::<Vec<_>>();
            if !absent.is_empty() {
                missing.insert(spelling.join(" "), absent);
            }
        }
    }
    assert!(missing.is_empty(), "scope help omits offered app verbs: {missing:#?}");
}

#[test]
fn tab_help_lists_screen_sharing_with_its_title() {
    let help = cmux(&["tab", "--help"]);
    let row = help.lines().find(|line| line.trim_start().starts_with("new-mac-screen "));
    assert!(row.is_some_and(|row| row.ends_with("Screen Sharing")), "{help}");
    assert!(lists(&help, "stop-mac-screen-viewing"), "{help}");
    assert!(lists(&help, "new-browser"), "{help}");
    // The hand-written usage stays first.
    assert!(help.starts_with("USAGE\n  cmux tab list"), "{help}");
}
