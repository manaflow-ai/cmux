use std::collections::BTreeSet;
use std::path::PathBuf;

use super::{ir_text, registry};

fn spec_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("spec/acpmux-protocol.json")
}

/// The committed IR is what the registry emits. To refresh it:
/// `ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux protocol_ir_is_current`,
/// then `bun run acpmux-protocol:codegen` in webviews.
#[test]
fn protocol_ir_is_current() {
    let fresh = ir_text();
    let path = spec_path();
    if std::env::var_os("ACPMUX_PROTOCOL_BLESS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap_or(&path)).ok();
        std::fs::write(&path, &fresh).unwrap_or_else(|e| panic!("write {}: {e}", path.display()));
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default();
    if committed != fresh {
        // The whole IR, so a run without the tree's write access still yields it.
        eprintln!(
            "----- BEGIN acpmux-protocol.json -----\n{fresh}----- END acpmux-protocol.json -----"
        );
        panic!(
            "{} is stale: rerun with ACPMUX_PROTOCOL_BLESS=1 and regenerate the web types",
            path.display()
        );
    }
}

#[test]
fn protocol_registry_names_are_unique() {
    let mut seen = BTreeSet::new();
    for decl in registry() {
        assert!(seen.insert(decl.name), "{} is declared twice", decl.name);
    }
}

/// Every name the dispatcher and its notifications use is in the registry:
/// the constants in `rpc::method` and the literal names in the server.
#[test]
fn protocol_registry_names_every_served_method() {
    let names: BTreeSet<&str> = registry().iter().map(|d| d.name).collect();
    let rpc = include_str!("../rpc.rs");
    let module = rpc.split("pub mod method {").nth(1).unwrap_or_default();
    let constant = regex::Regex::new(r#"pub const [A-Z0-9_]+: &str = "([^"]+)";"#).unwrap();
    let literal = regex::Regex::new(r#""((?:_acpmux/|catalog\.|acp\.)[A-Za-z0-9_./]+)""#).unwrap();
    let mut missing = BTreeSet::new();
    for capture in constant.captures_iter(module) {
        if !names.contains(&capture[1]) {
            missing.insert(capture[1].to_owned());
        }
    }
    let sources = [
        include_str!("../server/requests.rs"),
        include_str!("../server/mod.rs"),
        include_str!("../server/chats.rs"),
        include_str!("../server/secrets.rs"),
        include_str!("../server/peer_forward.rs"),
        include_str!("../server/remote_guard.rs"),
        include_str!("../server/redact.rs"),
        include_str!("../server/requests/composer.rs"),
    ];
    // Prefixes the dispatcher matches on, not method names.
    let prefixes = ["_acpmux/chat", "_acpmux/transfer_"];
    for source in sources {
        // The served code, not the test modules at the end of each file: a test may name a
        // method the server doesn't serve (`request_admission_tests` sends `_acpmux/unknown`).
        let served = source.split("\n#[cfg(test)]\nmod ").next().unwrap_or_default();
        for capture in literal.captures_iter(served) {
            let name = &capture[1];
            if !names.contains(name) && !prefixes.contains(&name) {
                missing.insert(name.to_owned());
            }
        }
    }
    assert!(missing.is_empty(), "declare these in protocol::registry(): {missing:?}");
}

/// `_acpmux/sessions` pages (`hub::session_pages`): the IR names its `limit`
/// and `cursor` params and the reply's `nextCursor`, so typed clients may send
/// and read them.
#[test]
fn protocol_sessions_names_its_page_fields() {
    let ir: serde_json::Value = serde_json::from_str(&ir_text()).expect("IR is JSON");
    let fields = |ty: &str| -> BTreeSet<String> {
        ir["types"][ty]["properties"]
            .as_object()
            .map(|props| props.keys().cloned().collect())
            .unwrap_or_default()
    };
    let params = fields("SessionsParams");
    assert!(params.contains("limit") && params.contains("cursor"), "SessionsParams: {params:?}");
    assert!(fields("SessionsResult").contains("nextCursor"), "SessionsResult lacks nextCursor");
}

#[test]
fn protocol_mail_send_supports_optional_reports_target() {
    let ir: serde_json::Value = serde_json::from_str(&ir_text()).expect("IR is JSON");
    let params = &ir["types"]["MailSendParams"];
    let properties = params["properties"].as_object().expect("MailSendParams properties");
    assert_eq!(properties["target"]["type"], serde_json::json!(["string", "null"]));
    assert_eq!(properties["recipient"]["type"], serde_json::json!(["string", "null"]));
    let required = params["required"].as_array().expect("MailSendParams required");
    assert!(required.iter().all(|field| field != "target" && field != "recipient"));
    assert!(required.iter().any(|field| field == "id"));
    assert!(required.iter().any(|field| field == "sender"));
    assert!(required.iter().any(|field| field == "body"));
}
