//! policy.json against the macOS host's own tables (CmuxNextAgentPane
//! `AcpmuxPaneMethods.requests` and `knownParams`), which enforce the pane's
//! frames today. The Swift side of the parity tests is gone, so these say
//! when one side gains a method or a param the other lacks: #20644 sent
//! params only one table knew, and the host refused them (cx-ibngi).

use cmux_agent_pane_policy::policy;
use std::collections::{BTreeMap, BTreeSet};
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
fn the_requests_are_the_macos_hosts() {
    let swift: BTreeSet<String> = strings(&block(
        &read("AcpmuxPaneMethods.swift"),
        "public static let requests: Set<String> = [",
        "\n    ]",
    ))
    .into_iter()
    .collect();
    assert_eq!(policy().requests, swift, "policy.json requests vs AcpmuxPaneMethods.requests");
}

#[test]
fn the_known_params_are_the_macos_hosts() {
    let table = block(
        &read("AcpmuxPaneMethods+Params.swift"),
        "static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [",
        "\n    ]",
    );
    // One entry per line: `"method": (["param", ...], ["acpmux key", ...]),`.
    let mut swift = BTreeMap::new();
    for line in table.lines().map(str::trim).filter(|line| line.starts_with('"')) {
        let (method, rest) = line[1..].split_once('"').unwrap_or_else(|| panic!("entry: {line}"));
        let (params, acpmux) = rest.split_once("], [").unwrap_or_else(|| panic!("entry: {line}"));
        let set = |text: &str| strings(text).into_iter().collect::<BTreeSet<_>>();
        swift.insert(method.to_owned(), (set(params), set(acpmux)));
    }
    let rust: BTreeMap<_, _> = policy()
        .known_params
        .iter()
        .map(|(method, known)| (method.clone(), (known.params.clone(), known.acpmux.clone())))
        .collect();
    assert_eq!(rust, swift, "policy.json known_params vs AcpmuxPaneMethods.knownParams");
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

/// The method sets of one Swift `Set<String>` table, `// comments` dropped.
fn swift_set(file: &str, declaration: &str) -> BTreeSet<String> {
    strings(&block(&read(file), declaration, "\n    ]")).into_iter().collect()
}

#[test]
fn the_session_scoped_methods_are_the_macos_hosts() {
    let swift =
        swift_set("AcpmuxPaneMethods.swift", "public static let sessionScoped: Set<String> = [");
    assert_eq!(
        policy().session_scoped,
        swift,
        "policy.json session_scoped vs AcpmuxPaneMethods.sessionScoped"
    );
    let swift = swift_set(
        "AcpmuxPaneMethods.swift",
        "public static let optionallySessionScoped: Set<String> = [",
    );
    assert_eq!(
        policy().optionally_session_scoped,
        swift,
        "policy.json optionally_session_scoped vs AcpmuxPaneMethods.optionallySessionScoped"
    );
}

/// `whenOptionAllows` as policy.json names it: `when_option_allows`.
fn snake_case(swift_case: &str) -> String {
    let mut out = String::new();
    for c in swift_case.chars() {
        if c.is_ascii_uppercase() {
            out.push('_');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

#[test]
fn the_gesture_rules_are_the_macos_hosts() {
    let table = block(
        &read("AcpmuxPaneMethods.swift"),
        "public static let gestureRules: [String: GestureRule] = [",
        "\n    ]",
    );
    // One entry per line: `"method": .rule,`.
    let mut swift = BTreeMap::new();
    for line in table.lines().map(str::trim).filter(|line| line.starts_with('"')) {
        let (method, rest) = line[1..].split_once('"').unwrap_or_else(|| panic!("entry: {line}"));
        let rule = rest.trim_start_matches(':').trim().trim_end_matches(',');
        let rule = rule.strip_prefix('.').unwrap_or_else(|| panic!("entry: {line}"));
        swift.insert(method.to_owned(), snake_case(rule));
    }
    let raw: serde_json::Value =
        serde_json::from_str(include_str!("../policy.json")).expect("policy.json parses");
    let rust: BTreeMap<String, String> = raw["gesture_rules"]
        .as_object()
        .expect("policy.json gesture_rules")
        .iter()
        .map(|(method, rule)| (method.clone(), rule.as_str().expect("a rule name").to_owned()))
        .collect();
    assert_eq!(rust, swift, "policy.json gesture_rules vs AcpmuxPaneMethods.gestureRules");
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
