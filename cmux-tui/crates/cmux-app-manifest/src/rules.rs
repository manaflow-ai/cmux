//! Rules the schema cannot express.

use crate::issue::{Issue, escape};
use crate::KNOWN_INTERFACES;
use serde_json::Value;

/// Publishers reserved for first-party apps.
const FIRST_PARTY: &[&str] = &["cmux", "manaflow-ai"];

pub(crate) fn check(m: &Value) -> Vec<Issue> {
    let mut out = Vec::new();
    let id = m["id"].as_str().unwrap_or_default();
    let publisher = id.split('/').next().unwrap_or_default();
    let first_party = FIRST_PARTY.contains(&publisher);
    let repository = m["repository"].as_str();

    match (publisher, repository) {
        ("local", _) => {}
        (_, None) => out.push(Issue::error(
            "/repository",
            "repository.required",
            "store apps need a GitHub repository",
        )),
        (_, Some(repo)) if first_party => {
            if !repo.starts_with("https://github.com/manaflow-ai/") {
                out.push(Issue::error(
                    "/id",
                    "publisher.reserved",
                    format!("publisher {publisher} is reserved for first-party apps"),
                ));
            }
        }
        (_, Some(repo)) => {
            let owner = repo.split('/').nth(3).unwrap_or_default().to_ascii_lowercase();
            if owner != publisher {
                out.push(Issue::error(
                    "/id",
                    "publisher.mismatch",
                    format!("publisher {publisher} must equal the repository owner {owner}"),
                ));
            }
        }
    }

    if let Some(implements) = m["implements"].as_object() {
        for (name, imp) in implements {
            let at = format!("/implements/{}", escape(name));
            if !KNOWN_INTERFACES.contains(&name.as_str()) {
                out.push(Issue::error(
                    at.clone(),
                    "interface.unknown",
                    format!("{name} is not an interface of this cmux version"),
                ));
            }
            if imp.get("native").is_some() && !first_party {
                out.push(Issue::error(
                    format!("{at}/native"),
                    "tier.native",
                    "native renderers are allowed only for first-party apps",
                ));
            }
            if imp.get("export").is_some() && m.pointer("/runtime/main").is_none() {
                out.push(Issue::error(
                    format!("{at}/export"),
                    "runtime.main.required",
                    "an export implementation needs runtime.main",
                ));
            }
            if imp.get("web").is_some() && m.pointer("/runtime/web").is_none() {
                out.push(Issue::error(
                    format!("{at}/web"),
                    "runtime.web.required",
                    "a web implementation needs runtime.web",
                ));
            }
        }
    }
    if let Some(consumes) = m["consumes"].as_array() {
        for (i, name) in consumes.iter().enumerate() {
            let name = name.as_str().unwrap_or_default();
            if !KNOWN_INTERFACES.contains(&name) {
                out.push(Issue::error(
                    format!("/consumes/{i}"),
                    "interface.unknown",
                    format!("{name} is not an interface of this cmux version"),
                ));
            }
        }
    }
    if m.pointer("/server/kind").and_then(Value::as_str) == Some("native") && !first_party {
        out.push(Issue::error(
            "/server/kind",
            "tier.native",
            "native servers are allowed only for first-party apps",
        ));
    }
    if let Some(variants) = m["variants"].as_array() {
        for (i, v) in variants.iter().enumerate() {
            let values: Vec<&str> =
                v["values"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
            if !values.contains(&v["default"].as_str().unwrap_or_default()) {
                out.push(Issue::error(
                    format!("/variants/{i}/default"),
                    "variant.default",
                    "default must be one of values",
                ));
            }
        }
    }
    out
}
