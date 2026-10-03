//! Rules the schema cannot express.

use crate::interfaces::{KNOWN_HOST_CAPABILITIES, KNOWN_INTERFACES, option_errors};
use crate::issue::{Issue, escape};
use crate::scopes::{ScopeClass, scope_info};
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
            if let Some(options) = imp.get("options") {
                for (path, message) in option_errors(name, options) {
                    out.push(Issue::error(
                        format!("{at}/options{path}"),
                        "interface.options",
                        message,
                    ));
                }
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
    for (i, name) in m
        .pointer("/consumes/interfaces")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let name = name.as_str().unwrap_or_default();
        if !KNOWN_INTERFACES.contains(&name) {
            out.push(Issue::error(
                format!("/consumes/interfaces/{i}"),
                "interface.unknown",
                format!("{name} is not an interface of this cmux version"),
            ));
        }
    }
    for (i, name) in m
        .pointer("/requires/hostCapabilities")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let name = name.as_str().unwrap_or_default();
        if !KNOWN_HOST_CAPABILITIES.contains(&name) {
            out.push(Issue::error(
                format!("/requires/hostCapabilities/{i}"),
                "hostCapability.unknown",
                format!("{name} is not a host capability of this cmux version"),
            ));
        }
    }
    for (i, entry) in m["openWith"].as_array().into_iter().flatten().enumerate() {
        let interface = entry["interface"].as_str().unwrap_or_default();
        if m.pointer(&format!("/implements/{}", escape(interface))).is_none() {
            out.push(Issue::error(
                format!("/openWith/{i}/interface"),
                "openWith.notImplemented",
                format!("the app does not implement {interface}"),
            ));
        }
    }
    check_scopes(m, first_party, &mut out);
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

/// Scope classes: server-only scopes belong in `server.scopes`; restricted
/// scopes need first party or a Verified review; `process:spawn` needs a
/// native (first-party) server.
fn check_scopes(m: &Value, first_party: bool, out: &mut Vec<Issue>) {
    let native_server = m.pointer("/server/kind").and_then(Value::as_str) == Some("native");
    for (field, server) in
        [("/scopes", false), ("/optionalScopes", false), ("/server/scopes", true)]
    {
        for scope in m.pointer(field).and_then(Value::as_object).into_iter().flat_map(|o| o.keys())
        {
            let at = format!("{field}/{}", escape(scope));
            let Some(info) = scope_info(scope) else {
                out.push(Issue::error(
                    at,
                    "scope.unclassified",
                    format!("{scope} has no risk class"),
                ));
                continue;
            };
            if info.server_only && !server {
                out.push(Issue::error(
                    at.clone(),
                    "scope.serverOnly",
                    format!("{scope} is a server scope; declare it in server.scopes"),
                ));
            }
            if scope.starts_with("process:spawn:") && !native_server {
                out.push(Issue::error(
                    at.clone(),
                    "scope.processSpawn",
                    "process:spawn needs a native server that ships with cmux",
                ));
            }
            if info.class == ScopeClass::Restricted && !first_party {
                out.push(Issue::warning(
                    at,
                    "scope.restricted",
                    format!("{scope} is restricted: only first-party apps and Verified apps reviewed for it hold it"),
                ));
            }
        }
    }
}
