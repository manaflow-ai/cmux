//! The method names of `dispatch_request`'s arms (`src/server/requests.rs`), read from the source,
//! so a new arm that the table (`arms.rs`) does not name fails `request_stack` at once.
//!
//! An arm head is a line of the function's top `match m {` (8 spaces in) that starts with a method
//! constant (`method::X`, `| method::X`), a string literal, a module's `METHOD` or a catalog RPC
//! name, a module's alias of a method constant (`super::browser_workspaces::SET`), or a guard
//! over a group of methods (a module’s `handles(m)` or `METHODS`), read from their files. A
//! head of any other form panics: teach this file the new form.

use std::collections::{BTreeMap, BTreeSet};

const REQUESTS: &str = include_str!("../../src/server/requests.rs");
const RPC: &str = include_str!("../../src/rpc.rs");
const COMPOSER: &str = include_str!("../../src/server/requests/composer.rs");
const QUEUED: &str = include_str!("../../src/server/requests/queued.rs");
const AGENT_LOGIN: &str = include_str!("../../src/server/agent_login.rs");
const HARNESS_ADMIN: &str = include_str!("../../src/server/harness_admin.rs");
const CONNECTIONS: &str = include_str!("../../src/server/connections.rs");
const ACCOUNT_SIGN_IN: &str = include_str!("../../src/server/account_sign_in.rs");
const AUTO_ENROLL: &str = include_str!("../../src/server/autocloud_enroll.rs");
const WIREGUARD: &str = include_str!("../../src/peer_wg_learn.rs");
const CONTROLS: &str = include_str!("../../src/server/controls.rs");
const BROWSER_WORKSPACES: &str = include_str!("../../src/server/browser_workspaces.rs");

/// Every method name `dispatch_request` has an arm for.
pub fn methods() -> BTreeSet<String> {
    let constants = method_constants();
    let mut names = BTreeSet::new();
    for head in arm_heads() {
        let pattern = head.split(" if ").next().unwrap_or_default();
        let has_alternative = |token| pattern.split('|').any(|part| part.trim() == token);
        let mut found = constant_values(pattern, &constants);
        found.extend(literals(pattern));
        for (token, source, start) in [
            ("composer::handles(m)", COMPOSER, "fn handles("),
            ("queued::handles(m)", QUEUED, "fn handles("),
            ("account_sign_in::METHODS", ACCOUNT_SIGN_IN, "const METHODS"),
            ("connections::METHODS", CONNECTIONS, "const METHODS"),
            ("agent_login::METHODS", AGENT_LOGIN, "const METHODS"),
            ("harness_admin::METHODS", HARNESS_ADMIN, "const METHODS"),
        ] {
            if head.contains(token) {
                found.extend(constant_values(&block(source, start), &constants));
            }
        }
        for (token, source, name) in [
            ("super::autocloud_enroll::METHOD", AUTO_ENROLL, "METHOD"),
            ("crate::peer::wg_learn::ADMIT", WIREGUARD, "ADMIT"),
        ] {
            if has_alternative(token) {
                let declaration = format!("const {name}: &str = ");
                let line = source.lines().find(|line| line.contains(&declaration)).expect(token);
                found.extend(literals(line));
            }
        }
        if has_alternative("super::controls::METHOD") {
            let imports = CONTROLS
                .split_once("use crate::rpc::method::{")
                .and_then(|(_, rest)| rest.split_once("};"))
                .expect("the method imports in controls.rs")
                .0;
            let name = imports
                .split(',')
                .find_map(|import| import.trim().strip_suffix(" as METHOD"))
                .expect("the METHOD alias in controls.rs");
            found.push(constants.get(name).expect("controls METHOD in rpc.rs").clone());
        }
        // A module's own alias of a method constant (`super::browser_workspaces::SET`), read from
        // its `const NAME: &str = method::X;` line.
        for (module, source) in [("super::browser_workspaces::", BROWSER_WORKSPACES)] {
            for (at, _) in pattern.match_indices(module) {
                let rest = &pattern[at + module.len()..];
                let name: String =
                    rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
                let declaration = format!("const {name}: &str = ");
                if let Some(line) = source.lines().find(|line| line.contains(&declaration)) {
                    found.extend(constant_values(line, &constants));
                }
            }
        }
        for (token, value) in [
            ("crate::catalog::RPC_GET", acpmux::catalog::RPC_GET),
            ("crate::catalog::RPC_REFRESH", acpmux::catalog::RPC_REFRESH),
        ] {
            if pattern.contains(token) {
                found.push(value.to_owned());
            }
        }
        assert!(
            !found.is_empty() || pattern.trim() == "other",
            "an arm head this test cannot read (teach arms_in_source.rs): {head:?}"
        );
        names.extend(found);
    }
    // The methods with a file of their own, which the `other` arm asks (`server/methods/mod.rs`).
    names.extend(method_files());
    names
}

/// The `METHOD` of each method file in `src/server/methods/` (all but `mod.rs` and `*_tests.rs`).
fn method_files() -> Vec<String> {
    let folder = concat!(env!("CARGO_MANIFEST_DIR"), "/src/server/methods");
    let mut names = Vec::new();
    for entry in std::fs::read_dir(folder).expect("src/server/methods") {
        let path = entry.expect("an entry of src/server/methods").path();
        let Some(file) = path.file_name().and_then(|name| name.to_str()) else { continue };
        if !file.ends_with(".rs") || file == "mod.rs" || file.ends_with("_tests.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("a method file");
        names.extend(literals(&block(&source, "const METHOD: &str")));
    }
    assert!(!names.is_empty(), "no method file in {folder}");
    names
}

/// Read both method matches so that moving a method across the recursive dispatch boundary
/// preserves its coverage, and adding one on either side requires a table entry.
fn arm_heads() -> Vec<String> {
    let mut heads = method_heads("dispatch_request_with_identity");
    heads.extend(method_heads("dispatch_method"));
    assert!(heads.len() > 100, "read only {} arm heads of dispatch_request", heads.len());
    heads
}

fn method_heads(function: &str) -> Vec<String> {
    let start = REQUESTS
        .find(&format!("\nasync fn {function}("))
        .unwrap_or_else(|| panic!("missing {function} in requests.rs"));
    let body = &REQUESTS[start..];
    let body = &body[..body.find("\n}\n").expect("the end of dispatch_request")];
    let open = body.find("\n    match m {\n").expect("dispatch_request's match m");
    let mut heads = Vec::new();
    for line in body[open..].lines().skip(2) {
        if line == "    }" {
            break;
        }
        // An arm head is at 8 spaces; deeper lines are arm bodies.
        let Some(code) = line.strip_prefix("        ") else { continue };
        // A guarded arm whose head spans lines opens its body on a line of its own: `{`.
        if code.starts_with(' ')
            || code == "{"
            || ["}", ")", "]", "//"].iter().any(|p| code.starts_with(p))
        {
            continue;
        }
        let known = ["method::", "| ", "\"", "super::", "crate::", "m if ", "name if ", "other"];
        assert!(
            known.iter().any(|p| code.starts_with(p)),
            "an arm head this test cannot read (teach arms_in_source.rs): {code:?}"
        );
        heads.push(code.split("=>").next().unwrap_or_default().to_owned());
    }
    assert!(!heads.is_empty(), "read no arm heads of {function}");
    heads
}

/// String constants in `rpc.rs`'s `method` module, independent of their formatting.
fn method_constants() -> BTreeMap<String, String> {
    let constants = parse_method_constants(RPC);
    assert!(constants.len() > 100, "read only {} method constants", constants.len());
    constants
}

fn parse_method_constants(source: &str) -> BTreeMap<String, String> {
    let file = syn::parse_file(source).expect("rpc.rs parses");
    let items = file
        .items
        .into_iter()
        .find_map(|item| match item {
            syn::Item::Mod(module) if module.ident == "method" => module.content,
            _ => None,
        })
        .expect("rpc.rs has an inline method module")
        .1;
    let mut constants = BTreeMap::new();
    for item in items {
        let syn::Item::Const(item) = item else { continue };
        let name = item.ident.to_string();
        let syn::Expr::Lit(value) = *item.expr else {
            panic!("method::{name} is not a literal (teach arms_in_source.rs)");
        };
        let syn::Lit::Str(value) = value.lit else {
            panic!("method::{name} is not a string (teach arms_in_source.rs)");
        };
        constants.insert(name, value.value());
    }
    constants
}

#[test]
fn method_constants_follow_rust_syntax_not_line_breaks() {
    let constants = parse_method_constants(
        r##"
        pub const OUTSIDE: &str = "not a method";
        pub mod method {
            // pub const COMMENT: &str = "not a method";
            pub const ONE_LINE: &str = "one";
            pub const WRAPPED: &str =
                "wrapped";
            pub const RAW:
                &str = /* a comment inside the declaration */ r#"raw"#;
        }
        "##,
    );
    assert_eq!(
        constants,
        BTreeMap::from([
            ("ONE_LINE".into(), "one".into()),
            ("WRAPPED".into(), "wrapped".into()),
            ("RAW".into(), "raw".into()),
        ])
    );
}

/// The values of the `method::NAME` constants that `text` names.
fn constant_values(text: &str, constants: &BTreeMap<String, String>) -> Vec<String> {
    text.split("method::")
        .skip(1)
        .map(|rest| {
            let name: String = rest
                .chars()
                .take_while(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || *c == '_')
                .collect();
            constants.get(&name).unwrap_or_else(|| panic!("no method::{name} in rpc.rs")).clone()
        })
        .collect()
}

/// The string literals in `text`.
fn literals(text: &str) -> Vec<String> {
    text.split('"').skip(1).step_by(2).map(str::to_owned).collect()
}

/// `source` from the line that holds `start` to the first line after it that ends the item.
fn block(source: &str, start: &str) -> String {
    let at = source.find(start).unwrap_or_else(|| panic!("no {start:?}"));
    let mut out = String::new();
    for line in source[at..].lines() {
        out.push_str(line);
        out.push('\n');
        if line == "}" || line == "];" || (line.ends_with(';') && start.starts_with("const METHOD"))
        {
            break;
        }
    }
    out
}
