//! Progressive, catalog-backed documentation for agents and scripts.

use std::borrow::Cow;
use std::io::{self, Write};
use std::sync::OnceLock;

use serde::Serialize;
use serde_json::Value;

use super::{GlobalArgs, OutputMode, UsageError};

const CATALOG_JSON: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/resource-operations-v2.json"));

#[derive(Clone, Debug)]
pub(super) struct Plan {
    pub(super) query: String,
    pub(super) output: OutputMode,
}

/// Claims the local `docs` command before the resource parser sees it.
pub(super) fn command(
    args: &[String],
    global: GlobalArgs,
) -> Result<Option<super::command::ParsedCommand>, UsageError> {
    if args.first().map(String::as_str) != Some("docs") {
        return Ok(None);
    }
    if args[1..].iter().any(|arg| matches!(arg.as_str(), "-h" | "--help")) {
        return Ok(Some(super::command::ParsedCommand::Help(Some("docs".to_owned()))));
    }
    Ok(Some(super::command::ParsedCommand::Docs(parse(&args[1..], global.output)?)))
}

pub(super) fn append_scope_help(scope: &str, text: Cow<'static, str>) -> Cow<'static, str> {
    if has_scope_operations(scope) {
        Cow::Owned(format!("{}\n{}", text, scope_help(scope)))
    } else {
        text
    }
}

#[derive(Clone, Debug, Serialize)]
struct SearchResult {
    name: String,
    class: String,
    target: String,
    selectors: Vec<String>,
    fields: Vec<String>,
    result: String,
}

#[derive(Serialize)]
struct SearchResponse {
    query: String,
    results: Vec<SearchResult>,
}

fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(CATALOG_JSON).expect("the checked-in resource operation catalog")
    })
}

pub(super) fn parse(args: &[String], output: OutputMode) -> Result<Plan, UsageError> {
    match args.first().map(String::as_str) {
        Some("search") => {
            let query = args[1..].join(" ").trim().to_owned();
            if query.is_empty() {
                return Err(UsageError::new("docs search needs a query"));
            }
            Ok(Plan { query, output })
        }
        Some(other) => Err(UsageError::new(format!(
            "unknown docs command {other}; use `cmux docs search <query>`"
        ))),
        None => Err(UsageError::new("missing docs command; use `cmux docs search <query>`")),
    }
}

pub(super) fn help() -> &'static str {
    "USAGE\n  cmux docs search <query> [--json]\n\nSearch the catalog without connecting to a cmux session.\n"
}

pub(super) fn run(plan: Plan) -> i32 {
    let results = search(&plan.query);
    let response = SearchResponse { query: plan.query, results };
    let mut stdout = io::stdout().lock();
    match plan.output {
        OutputMode::Quiet => {}
        OutputMode::Json | OutputMode::JsonLines => {
            let _ = serde_json::to_writer(&mut stdout, &response);
            let _ = stdout.write_all(b"\n");
        }
        OutputMode::Human => {
            let _ = writeln!(stdout, "cmux docs search: {}", response.query);
            if response.results.is_empty() {
                let _ = writeln!(stdout, "No matching operations.");
            } else {
                for result in response.results {
                    let selectors = if result.selectors.is_empty() {
                        String::new()
                    } else {
                        format!(" selectors: {}", result.selectors.join(", "))
                    };
                    let fields = if result.fields.is_empty() {
                        String::new()
                    } else {
                        format!(" fields: {}", result.fields.join(", "))
                    };
                    let _ = writeln!(
                        stdout,
                        "  {} [{}] target: {}{}{} -> {}",
                        result.name, result.class, result.target, selectors, fields, result.result
                    );
                }
            }
        }
    }
    let _ = stdout.flush();
    0
}

fn search(query: &str) -> Vec<SearchResult> {
    let terms = query.split_whitespace().map(|term| term.to_ascii_lowercase()).collect::<Vec<_>>();
    let operations = catalog()["operations"].as_object().expect("catalog operations object");
    let mut matches = operations
        .iter()
        .filter_map(|(name, descriptor)| {
            let haystack = serde_json::to_string(&(name, descriptor)).ok()?.to_ascii_lowercase();
            if !terms.iter().all(|term| haystack.contains(term)) {
                return None;
            }
            Some((score(name, &haystack, &terms), result(name, descriptor)))
        })
        .collect::<Vec<_>>();
    matches.sort_by(|(left_score, left), (right_score, right)| {
        right_score.cmp(left_score).then_with(|| left.name.cmp(&right.name))
    });
    matches.into_iter().take(20).map(|(_, result)| result).collect()
}

fn score(name: &str, haystack: &str, terms: &[String]) -> usize {
    terms
        .iter()
        .map(|term| {
            let mut score = if name.to_ascii_lowercase().contains(term) { 10 } else { 0 };
            if haystack.starts_with(term) {
                score += 1;
            }
            score
        })
        .sum()
}

fn result(name: &str, descriptor: &Value) -> SearchResult {
    let params = descriptor["params"].as_object();
    let names = |key| {
        params
            .and_then(|params| params.get(key))
            .and_then(Value::as_object)
            .map(|values| values.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    SearchResult {
        name: name.to_owned(),
        class: descriptor["class"].as_str().unwrap_or("unknown").to_owned(),
        target: descriptor["target"].as_str().unwrap_or("unknown").to_owned(),
        selectors: names("selectors"),
        fields: names("fields"),
        result: type_name(&descriptor["result"]),
    }
}

fn type_name(value: &Value) -> String {
    match value.get("name").and_then(Value::as_str) {
        Some(name) => name.to_owned(),
        None => value["kind"].as_str().unwrap_or("value").to_owned(),
    }
}

pub(super) fn has_scope_operations(scope: &str) -> bool {
    let target = catalog_target(scope);
    catalog()["operations"].as_object().is_some_and(|operations| {
        operations.values().any(|descriptor| descriptor["target"] == target)
    })
}

pub(super) fn scope_help(scope: &str) -> String {
    let target = catalog_target(scope);
    let operations = catalog()["operations"]
        .as_object()
        .expect("catalog operations object")
        .iter()
        .filter(|(_, descriptor)| descriptor["target"] == target)
        .map(|(name, descriptor)| (name, descriptor["class"].as_str().unwrap_or("unknown")))
        .collect::<Vec<_>>();
    let mut output = String::from("CATALOG OPERATIONS\n");
    for (name, class) in operations {
        output.push_str("  ");
        output.push_str(name);
        output.push_str(" [");
        output.push_str(class);
        output.push_str("]\n");
    }
    output.push_str("\nRun `cmux docs search <term>` for parameter and result details.\n");
    output
}

fn catalog_target(scope: &str) -> &str {
    match scope {
        "sidebar" => "sidebar_view",
        "pairing" => "pairing_request",
        "projection" => "frontend_projection",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_requires_all_terms_and_returns_browser_operations() {
        let results = search("browser navigate");
        assert!(results.iter().any(|result| result.name == "browser.navigate"));
        assert!(results.iter().all(|result| result.name.contains("browser")));
    }

    #[test]
    fn scope_help_is_catalog_backed() {
        let help = scope_help("terminal");
        assert!(help.contains("terminal.screen.read [read]"));
        assert!(has_scope_operations("browser"));
        assert!(has_scope_operations("sidebar"));
        assert!(has_scope_operations("pairing"));
        assert!(has_scope_operations("projection"));
    }

    #[test]
    fn docs_search_preserves_json_output_mode() {
        let plan = parse(
            &["search".to_owned(), "browser".to_owned(), "navigate".to_owned()],
            OutputMode::Json,
        )
        .unwrap();
        assert_eq!(plan.query, "browser navigate");
        assert_eq!(plan.output, OutputMode::Json);
    }
}
