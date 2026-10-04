//! App CLI commands and MCP tools (plans/cmux-next/app-commands-codemode.md
//! sections 1 and 2): the manifest `cli.name`, app-relative `cli.path`,
//! `cli.positional`, reserved names, and MCP tool names derived from op names.

use cmux_app_manifest::{Issue, Severity, validate_catalog, validate_manifest};
use serde_json::{Value, json};

fn manifest(extra: Value) -> Value {
    let mut m = json!({ "manifestVersion": 2, "id": "local/x", "name": "X", "version": "1.0.0", "description": "d", "engines": { "cmux": "^2.0" }, "icon": "assets/icon.png" });
    for (k, v) in extra.as_object().expect("object") {
        m[k] = v.clone();
    }
    m
}

fn op(name: &str, extra: Value) -> Value {
    let mut o = json!({ "name": name, "owner": "app:local/x", "class": "mutation", "risk": "mutate-own",
        "idempotency": "required",
        "input": { "type": "object", "properties": {
            "text": { "type": "string" }, "tag": { "type": "string" }, "count": { "type": "integer" },
            "tags": { "type": "array", "items": { "type": "string" } }, "options": { "type": "object" } } },
        "docs": "Does a thing.", "since": "x/1" });
    for (k, v) in extra.as_object().expect("object") {
        o[k] = v.clone();
    }
    o
}

fn catalog(ops: Vec<Value>) -> Value {
    json!({ "family": "notes", "operations": ops })
}

fn found(issues: &[Issue]) -> Vec<(&str, &'static str, Severity)> {
    issues.iter().map(|i| (i.path.as_str(), i.code, i.severity)).collect()
}

#[test]
fn an_app_may_declare_a_short_cli_name() {
    let m = manifest(json!({ "cli": { "name": "notes" } }));
    assert!(validate_manifest(&m).is_empty(), "{:?}", validate_manifest(&m));
}

#[test]
fn a_cli_name_must_be_a_lowercase_word() {
    for bad in ["Notes", "n", "notes app", "-notes", "a-very-long-cli-name-over-24"] {
        let issues = validate_manifest(&manifest(json!({ "cli": { "name": bad } })));
        assert!(
            issues.iter().any(|i| i.severity == Severity::Error && i.path.starts_with("/cli")),
            "{bad}: {issues:?}"
        );
    }
}

#[test]
fn a_cli_name_never_takes_a_built_in_or_reserved_word() {
    for reserved in
        ["workspace", "pane", "tab", "app", "apps", "code", "docs", "mcp", "run", "help"]
    {
        let issues = validate_manifest(&manifest(json!({ "cli": { "name": reserved } })));
        assert_eq!(
            found(&issues),
            vec![("/cli/name", "cli.nameReserved", Severity::Error)],
            "{reserved}"
        );
    }
}

#[test]
fn a_first_party_app_may_claim_its_mapped_reserved_word() {
    let cloud =
        manifest(json!({ "id": "cmux/cloud", "repository": "https://github.com/manaflow-ai/cmux",
        "cli": { "name": "cloud" } }));
    assert!(validate_manifest(&cloud).is_empty(), "{:?}", validate_manifest(&cloud));

    let third_party =
        manifest(json!({ "id": "alice/cloud", "repository": "https://github.com/alice/cloud",
        "cli": { "name": "cloud" } }));
    assert_eq!(
        found(&validate_manifest(&third_party)),
        vec![("/cli/name", "cli.nameReserved", Severity::Error)]
    );

    let other_first_party =
        manifest(json!({ "id": "cmux/notes", "repository": "https://github.com/manaflow-ai/cmux",
        "cli": { "name": "cloud" } }));
    assert_eq!(
        found(&validate_manifest(&other_first_party)),
        vec![("/cli/name", "cli.nameReserved", Severity::Error)]
    );
}

#[test]
fn cli_paths_are_relative_to_the_app() {
    let m = manifest(json!({ "cli": { "name": "notes" } }));
    let ok = catalog(vec![
        op("notes.capture", json!({ "cli": { "path": "capture" } })),
        op("notes.session_start", json!({ "cli": { "path": "session start" } })),
    ]);
    assert!(validate_catalog(&m, &ok).is_empty(), "{:?}", validate_catalog(&m, &ok));

    for bad in ["apps run local/x capture", "Capture", "capture  now", "a b c d", ""] {
        let fragment = catalog(vec![op("notes.capture", json!({ "cli": { "path": bad } }))]);
        let issues = validate_catalog(&m, &fragment);
        assert!(
            issues.iter().any(|i| i.severity == Severity::Error
                && "/catalog/operations/0/cli/path".starts_with(&i.path)),
            "{bad:?}: {issues:?}"
        );
    }
}

#[test]
fn two_ops_cannot_share_a_cli_path() {
    let m = manifest(json!({}));
    let fragment = catalog(vec![
        op("notes.capture", json!({ "cli": { "path": "capture" } })),
        op("notes.capture_fast", json!({ "cli": { "path": "capture" } })),
    ]);
    assert_eq!(
        found(&validate_catalog(&m, &fragment)),
        vec![("/catalog/operations/1/cli/path", "cli.duplicate", Severity::Error)]
    );
}

#[test]
fn positionals_name_input_properties() {
    let m = manifest(json!({}));
    let ok = catalog(vec![op(
        "notes.capture",
        json!({ "cli": { "path": "capture", "positional": ["text"] } }),
    )]);
    assert!(validate_catalog(&m, &ok).is_empty(), "{:?}", validate_catalog(&m, &ok));

    let bad = catalog(vec![op(
        "notes.capture",
        json!({ "cli": { "path": "capture", "positional": ["text", "body", "text"] } }),
    )]);
    assert_eq!(
        found(&validate_catalog(&m, &bad)),
        vec![
            ("/catalog/operations/0/cli/positional/1", "cli.positionalUnknown", Severity::Error),
            ("/catalog/operations/0/cli/positional/2", "cli.duplicate", Severity::Error),
        ]
    );
}

#[test]
fn positionals_are_scalars_and_an_array_only_last() {
    let m = manifest(json!({}));
    let ok = catalog(vec![op(
        "notes.capture",
        json!({ "cli": { "path": "capture", "positional": ["text", "count", "tags"] } }),
    )]);
    assert!(validate_catalog(&m, &ok).is_empty(), "{:?}", validate_catalog(&m, &ok));

    let bad = catalog(vec![op(
        "notes.capture",
        json!({ "cli": { "path": "capture", "positional": ["tags", "options", "text"] } }),
    )]);
    assert_eq!(
        found(&validate_catalog(&m, &bad)),
        vec![
            ("/catalog/operations/0/cli/positional/0", "cli.positionalType", Severity::Error),
            ("/catalog/operations/0/cli/positional/1", "cli.positionalType", Severity::Error),
        ]
    );
}

#[test]
fn an_op_may_say_it_has_no_cli_command() {
    let m = manifest(json!({}));
    let fragment = catalog(vec![op("notes.capture", json!({ "cli": null }))]);
    assert!(validate_catalog(&m, &fragment).is_empty(), "{:?}", validate_catalog(&m, &fragment));
}

#[test]
fn exposed_ops_cannot_map_to_the_same_mcp_tool_name() {
    let m = manifest(json!({}));
    // notes.list_all and notes.list.all both become the tool `notes_list_all`.
    let fragment = catalog(vec![
        op("notes.list_all", json!({ "mcp": { "expose": "default" } })),
        op("notes.list.all", json!({ "mcp": { "expose": "opt_in" } })),
    ]);
    assert_eq!(
        found(&validate_catalog(&m, &fragment)),
        vec![("/catalog/operations/1/name", "mcp.toolNameCollision", Severity::Error)]
    );

    // An op that is never a tool does not collide.
    let hidden = catalog(vec![
        op("notes.list_all", json!({ "mcp": { "expose": "default" } })),
        op("notes.list.all", json!({ "mcp": { "expose": "never" } })),
    ]);
    assert!(validate_catalog(&m, &hidden).is_empty(), "{:?}", validate_catalog(&m, &hidden));
}

#[test]
fn exposed_tool_names_leave_room_for_client_prefixes() {
    let m = manifest(json!({}));
    let long = format!("notes.{}", "a".repeat(43)); // notes_ + 43 = 49 characters
    let fragment = catalog(vec![op(&long, json!({ "mcp": { "expose": "default" } }))]);
    assert_eq!(
        found(&validate_catalog(&m, &fragment)),
        vec![("/catalog/operations/0/name", "mcp.toolNameLength", Severity::Error)]
    );
    let fits = catalog(vec![op(
        &format!("notes.{}", "a".repeat(42)),
        json!({ "mcp": { "expose": "default" } }),
    )]);
    assert!(validate_catalog(&m, &fits).is_empty(), "{:?}", validate_catalog(&m, &fits));
}

#[test]
fn a_gesture_only_op_offered_to_agents_warns() {
    let m = manifest(json!({}));
    let fragment = catalog(vec![op(
        "notes.export",
        json!({ "gesture": "required", "mcp": { "expose": "default" } }),
    )]);
    assert_eq!(
        found(&validate_catalog(&m, &fragment)),
        vec![("/catalog/operations/0/mcp/expose", "mcp.gestureRequired", Severity::Warning)]
    );
}

#[test]
fn installed_apps_that_claim_the_same_names_conflict() {
    use cmux_app_manifest::{Conflict, ConflictKind, conflicts, mcp_tool_name};
    assert_eq!(mcp_tool_name("acme.diff-view.open"), "acme_diff_view_open");
    let a = json!({ "id": "alice/notes", "cli": { "name": "notes" } });
    let b = json!({ "id": "bob/notes", "cli": { "name": "notes" } });
    let c = json!({ "id": "carol/jot", "cli": { "name": "jot" } });
    let tools = json!({ "family": "notes", "operations": [
        { "name": "notes.capture", "mcp": { "expose": "default" } },
        { "name": "notes.list", "mcp": { "expose": "never" } },
    ] });
    let same_tool = json!({ "family": "notes", "operations": [
        { "name": "notes.capture", "mcp": { "expose": "opt_in" } },
        { "name": "notes.list", "mcp": { "expose": "never" } },
    ] });
    assert_eq!(
        conflicts(&[(&b, Some(&tools)), (&a, Some(&same_tool)), (&c, None)]),
        vec![
            Conflict {
                kind: ConflictKind::CliName,
                name: "notes".into(),
                apps: vec!["alice/notes".into(), "bob/notes".into()],
            },
            Conflict {
                kind: ConflictKind::McpTool,
                name: "notes_capture".into(),
                apps: vec!["alice/notes".into(), "bob/notes".into()],
            },
        ]
    );
}

#[test]
fn the_reserved_list_covers_the_built_in_scopes() {
    use cmux_app_manifest::is_reserved_cli_name;
    for word in ["workspace", "workspaces", "app", "apps", "code", "coderouter", "x"] {
        assert!(is_reserved_cli_name(word), "{word}");
    }
    assert!(!is_reserved_cli_name("notes"));
}
