//! Every frame the agent page sends, as `schemas/agent-pane/*-params.json`
//! lists it, passes the params rule of policy.json (`breaks_params_rule`,
//! which tests/swift.rs keeps equal to AcpmuxPaneMethods+Params.swift). The
//! webviews contract tests hold the page to those files and the Swift
//! `Acpmux*ParamsContractTests` run them through the Swift rule; this runs
//! them through the Rust one, on Linux, in the PR fast tier. A key the page
//! sends and the rule does not know refuses the frame as
//! `transport.intent_invalid`: `_meta` on initialize (no chat connected,
//! cmux#49148), `afterSeq` on a reconnect's attach (#47119), `maxBytes` on a
//! finished background task's tail (#48648).

use cmux_agent_pane_policy::params::breaks_params_rule;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

/// Each contract file, the key that holds its frames, and the method they are.
const CONTRACTS: &[(&str, &str, &str)] = &[
    ("initialize-params.json", "initialize", "initialize"),
    ("attach-params.json", "attach", "_acpmux/attach"),
    ("session-new-params.json", "new", "session/new"),
    ("bg-output-params.json", "output", "_acpmux/bg/output"),
];

fn schemas() -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/agent-pane");
    assert!(dir.is_dir(), "schemas/agent-pane is missing at {}", dir.display());
    dir
}

/// The named params of each frame: a list of `{name, params}`, or one params object.
fn frames(file: &str, key: &str) -> Vec<(String, Map<String, Value>)> {
    let text =
        std::fs::read_to_string(schemas().join(file)).unwrap_or_else(|e| panic!("{file}: {e}"));
    let root: Value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{file}: {e}"));
    match &root[key] {
        Value::Array(list) => list
            .iter()
            .map(|entry| {
                let name = entry["name"].as_str().unwrap_or("?").to_owned();
                let params = entry["params"]
                    .as_object()
                    .unwrap_or_else(|| panic!("{file} {name}: no params"));
                (name, params.clone())
            })
            .collect(),
        Value::Object(params) => vec![(key.to_owned(), params.clone())],
        other => panic!("{file}: {key} is {other}"),
    }
}

fn frame(method: &str, params: &Map<String, Value>) -> Map<String, Value> {
    json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        .as_object()
        .unwrap()
        .clone()
}

#[test]
fn every_frame_the_page_sends_passes_the_params_rule() {
    let mut refused = Vec::new();
    for (file, key, method) in CONTRACTS {
        let frames = frames(file, key);
        assert!(!frames.is_empty(), "{file} lists no frame");
        for (name, params) in frames {
            if breaks_params_rule(&frame(method, &params), None) {
                refused.push(format!(
                    "{file} {name}: {method} {:?}",
                    params.keys().collect::<Vec<_>>()
                ));
            }
        }
    }
    assert!(refused.is_empty(), "frames the page sends that policy.json refuses: {refused:#?}");
}

/// A contract file nobody runs is no contract: each `*-params.json` is in `CONTRACTS`.
#[test]
fn every_params_contract_is_checked() {
    let mut listed: Vec<String> = std::fs::read_dir(schemas())
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .filter(|name| name.ends_with("-params.json"))
        .collect();
    listed.sort();
    let mut checked: Vec<String> =
        CONTRACTS.iter().map(|(file, _, _)| (*file).to_owned()).collect();
    checked.sort();
    assert_eq!(listed, checked, "schemas/agent-pane/*-params.json vs this file's CONTRACTS");
}

/// The rule still refuses a key the page never sends, on each contract's method.
#[test]
fn a_key_the_page_does_not_send_is_still_refused() {
    for (file, key, method) in CONTRACTS {
        let (name, mut params) = frames(file, key).remove(0);
        params.insert("notAParamThePageSends".to_owned(), json!(true));
        assert!(
            breaks_params_rule(&frame(method, &params), None),
            "{file} {name}: {method} took an unknown key"
        );
    }
}
