//! The method names of `dispatch_request`'s arms (`src/server/requests.rs`), read from the source,
//! so a new arm that the table (`arms.rs`) does not name fails `request_stack` at once.
//!
//! An arm head is a line of the function's top `match m {` (8 spaces in) that starts with a method
//! constant (`method::X`, `| method::X`), a string literal, a module's `METHOD` or a catalog RPC
//! name, or a guard over a group of methods (`composer::handles(m)`, `queued::handles(m)`,
//! `agent_login::METHODS`, `harness_admin::METHODS`), whose members are read from their files. A
//! head of any other form panics: teach this file the new form.

use std::collections::{BTreeMap, BTreeSet};

const REQUESTS: &str = include_str!("../../src/server/requests.rs");
const RPC: &str = include_str!("../../src/rpc.rs");
const COMPOSER: &str = include_str!("../../src/server/requests/composer.rs");
const QUEUED: &str = include_str!("../../src/server/requests/queued.rs");
const AGENT_LOGIN: &str = include_str!("../../src/server/agent_login.rs");
const HARNESS_ADMIN: &str = include_str!("../../src/server/harness_admin.rs");
const VM_HOST: &str = include_str!("../../src/server/vm_host.rs");
const HOST_NOTICE: &str = include_str!("../../src/server/host_notice.rs");

/// Every method name `dispatch_request` has an arm for.
pub fn methods() -> BTreeSet<String> {
    let constants = method_constants();
    let mut names = BTreeSet::new();
    for head in arm_heads() {
        let pattern = head.split(" if ").next().unwrap_or_default();
        let mut found = constant_values(pattern, &constants);
        found.extend(literals(pattern));
        for (token, source, start) in [
            ("composer::handles(m)", COMPOSER, "fn handles("),
            ("queued::handles(m)", QUEUED, "fn handles("),
            ("agent_login::METHODS", AGENT_LOGIN, "const METHODS"),
            ("harness_admin::METHODS", HARNESS_ADMIN, "const METHODS"),
        ] {
            if head.contains(token) {
                found.extend(constant_values(&block(source, start), &constants));
            }
        }
        for (token, source) in
            [("super::vm_host::METHOD", VM_HOST), ("super::host_notice::METHOD", HOST_NOTICE)]
        {
            if pattern.contains(token) {
                found.extend(literals(&block(source, "const METHOD: &str")));
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
    names
}

/// The heads of the top-level arms of `dispatch_request`'s `match m`, each up to its `=>`. The
/// match is in `dispatch_request_with_identity`, which `dispatch_request` runs on the heap with no
/// fixed identity (#33811).
fn arm_heads() -> Vec<String> {
    let start = REQUESTS
        .find("\nasync fn dispatch_request_with_identity(")
        .expect("dispatch_request_with_identity in requests.rs");
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
        if code.starts_with(' ') || ["}", ")", "]", "//"].iter().any(|p| code.starts_with(p)) {
            continue;
        }
        let known = ["method::", "| ", "\"", "super::", "crate::", "m if ", "name if ", "other"];
        assert!(
            known.iter().any(|p| code.starts_with(p)),
            "an arm head this test cannot read (teach arms_in_source.rs): {code:?}"
        );
        heads.push(code.split("=>").next().unwrap_or_default().to_owned());
    }
    assert!(heads.len() > 100, "read only {} arm heads of dispatch_request", heads.len());
    heads
}

/// `pub const NAME: &str = "value";` of `rpc.rs`'s `pub mod method`.
fn method_constants() -> BTreeMap<String, String> {
    let module = block(RPC, "pub mod method {");
    let mut constants = BTreeMap::new();
    for line in module.lines() {
        let Some(rest) = line.trim().strip_prefix("pub const ") else { continue };
        let Some((name, value)) = rest.split_once(": &str = \"") else { continue };
        let Some(value) = value.strip_suffix("\";") else { continue };
        constants.insert(name.to_owned(), value.to_owned());
    }
    assert!(constants.len() > 100, "read only {} method constants", constants.len());
    constants
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
