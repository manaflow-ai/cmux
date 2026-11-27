//! policy.json against the macOS host's hand-written rules that are not
//! generated from it (the act-as-me covers, the click rule and its window).
//! The tables `requests`, `knownParams`, the scope tables and `gestureRules`
//! are generated from policy.json at every build
//! (scripts/cmux-next/gen-agent-pane-policy-swift.py), so they cannot differ:
//! #20644 sent params only one table knew, and the host refused them (cx-ibngi).

use cmux_agent_pane_policy::policy;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn sources() -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane");
    assert!(dir.is_dir(), "CmuxNextAgentPane is missing at {}", dir.display());
    dir
}

fn read(file: &str) -> String {
    std::fs::read_to_string(sources().join(file)).unwrap_or_else(|e| panic!("{file}: {e}"))
}

/// The Swift text from `start` to the first line that is exactly `end`, with
/// `//` comments dropped.
fn block(text: &str, start: &str, end: &str) -> String {
    let at = text.find(start).unwrap_or_else(|| panic!("{start} not found"));
    let body = &text[at + start.len()..];
    let body = &body[..body.find(end).unwrap_or_else(|| panic!("end of {start} not found"))];
    body.lines().map(|line| line.split("//").next().unwrap_or("")).collect::<Vec<_>>().join("\n")
}

/// Every `"..."` string in `text`.
fn strings(text: &str) -> Vec<String> {
    text.split('"').skip(1).step_by(2).map(str::to_owned).collect()
}

#[test]
fn the_act_as_me_covers_are_the_macos_hosts() {
    let swift: BTreeSet<String> = strings(&block(
        &read("AgentPaneActAsMe.swift"),
        "public nonisolated static let covers: Set<String> = [",
        "\n    ]",
    ))
    .into_iter()
    .collect();
    assert_eq!(
        policy().act_as_me_covers,
        swift,
        "policy.json act_as_me_covers vs AgentPaneActAsMe.covers"
    );
}

#[test]
fn the_act_as_me_managed_covers_are_the_macos_hosts() {
    let swift: BTreeSet<String> = strings(&block(
        &read("AgentPaneActAsMe.swift"),
        "public nonisolated static let managedCovers: Set<String> = [",
        "\n    ]",
    ))
    .into_iter()
    .collect();
    assert_eq!(
        policy().act_as_me_managed_covers,
        swift,
        "policy.json act_as_me_managed_covers vs AgentPaneActAsMe.managedCovers"
    );
}

/// The click rule: the methods the Swift host answers only on a fresh click
/// (`answerAllowed`'s `answers`) are policy.json `click_only`, which the
/// frame check refuses without a click (tests/click_only.rs).
#[test]
fn the_click_only_methods_are_the_macos_hosts() {
    let swift: BTreeSet<String> = strings(&block(
        &read("AcpmuxPaneMethods.swift"),
        "static func answerAllowed(_ method: String?, _ gestures: AgentPaneUserGestures) -> Bool {",
        "\n    }",
    ))
    .into_iter()
    .collect();
    assert!(!swift.is_empty(), "AcpmuxPaneMethods.answerAllowed names no method");
    assert_eq!(policy().click_only, swift, "policy.json click_only vs answerAllowed");
}

/// How old a click may be when it answers: policy.json `click_window_ms` is
/// the Swift host's `AgentPaneUserGestures.answerWindow` (seconds).
#[test]
fn the_click_window_is_the_macos_hosts() {
    let text = read("AgentPaneUserGestures.swift");
    let declaration = "public static let answerWindow: TimeInterval = ";
    let at = text.find(declaration).unwrap_or_else(|| panic!("{declaration} not found"));
    let value = text[at + declaration.len()..].lines().next().unwrap_or("").trim();
    let seconds: f64 = value.parse().unwrap_or_else(|e| panic!("answerWindow {value}: {e}"));
    assert_eq!(
        policy().click_window_ms as f64,
        seconds * 1000.0,
        "policy.json click_window_ms vs AgentPaneUserGestures.answerWindow"
    );
}
