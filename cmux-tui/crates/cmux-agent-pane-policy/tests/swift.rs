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
fn draft_set_allows_generation_but_no_other_new_fields() {
    let known = &policy().known_params["_acpmux/draft_set"].params;
    assert!(known.contains("sessionId"));
    assert!(known.contains("text"));
    assert!(known.contains("generation"));
    assert!(!known.contains("revision"));
    assert!(!known.contains("unexpected"));
}
