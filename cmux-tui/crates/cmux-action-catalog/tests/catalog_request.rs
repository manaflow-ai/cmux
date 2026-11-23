//! Catalog requests (`Action::request`) and `op:` suggestion sources: each row is well formed,
//! and the app's export carries both whole. That each row sends what its CLI verb sends is
//! cmux-tui's `catalog_request_matches_cli`.

use cmux_action_catalog::request::{LIST_SOURCES, list_source, params};
use cmux_action_catalog::*;
use serde_json::{Value, json};

/// Operations that delete a person's data: a row that sends one asks before it runs, unless it
/// removes only what the person picked ([`SINGLE_PICK_REMOVES`]).
const DESTRUCTIVE_OPERATIONS: &[&str] =
    &["closed.delete", "git.worktree.remove", "chief.profile.delete", "history.site.remove"];

/// Rows that remove one thing the person picked (a site's history, one Recently Closed item): the
/// pick is the confirmation, as removing history entries is in Chrome. Rows that remove
/// everything at once (Clear Recently Closed) still ask.
const SINGLE_PICK_REMOVES: &[&str] = &["history.removeSite", "closed.delete"];

/// The target kinds whose daemon id the app's `CatalogRequestHandlers` resolves.
const RESOLVED_TARGETS: &[&str] = &["workspace", "pane"];

fn well_formed(action: &Action) -> Result<(), String> {
    let Some(request) = &action.request else { return Ok(()) };
    let id = action.id;
    if action.cli_name.is_empty() || !action.cli() {
        return Err(format!("{id}: a request row needs its CLI verb, which the CLI test compares"));
    }
    let operation_ok = !request.operation.is_empty()
        && request.operation.chars().all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c));
    if !operation_ok {
        return Err(format!("{id}: operation {:?} is not an operation name", request.operation));
    }
    let mut names = Vec::new();
    for param in request.params {
        if names.contains(&param.name) {
            return Err(format!("{id}: param {} twice", param.name));
        }
        names.push(param.name);
        match param.source {
            ParamSource::Argument(name) if !action.arguments.iter().any(|a| a.name == name) => {
                return Err(format!("{id}: param {} reads undeclared argument {name}", param.name));
            }
            ParamSource::Target(kind) if !RESOLVED_TARGETS.contains(&kind) => {
                return Err(format!(
                    "{id}: param {} reads a {kind} target, whose daemon id the app does not resolve",
                    param.name
                ));
            }
            ParamSource::Target(kind)
                if !action.targets.contains(&kind) && action.palette_target != Some(kind) =>
            {
                return Err(format!(
                    "{id}: param {} reads a {kind} target it does not take",
                    param.name
                ));
            }
            _ => {}
        }
    }
    if DESTRUCTIVE_OPERATIONS.contains(&request.operation)
        && !action.is_destructive
        && !SINGLE_PICK_REMOVES.contains(&id)
    {
        return Err(format!(
            "{id}: {} deletes data, so the row is is_destructive",
            request.operation
        ));
    }
    Ok(())
}

#[test]
fn catalog_requests_are_well_formed() {
    let errors: Vec<String> = actions().filter_map(|a| well_formed(a).err()).collect();
    assert!(errors.is_empty(), "{errors:#?}");
}

#[test]
fn op_suggestion_sources_name_a_list() {
    for action in actions() {
        for argument in action.arguments {
            let Some(suggestions) = argument.suggestions else { continue };
            if suggestions.source.starts_with(LIST_SOURCE_PREFIX) {
                assert!(
                    list_source(suggestions.source).is_some(),
                    "{}.{}: {} names no list in LIST_SOURCES",
                    action.id,
                    argument.name,
                    suggestions.source
                );
            }
        }
    }
    for (index, list) in LIST_SOURCES.iter().enumerate() {
        assert!(
            LIST_SOURCES[..index].iter().all(|other| other.operation != list.operation),
            "{} twice",
            list.operation
        );
        assert_eq!(list_source(&list.source()), Some(list));
    }
    assert_eq!(list_source("closedEntries"), None, "a Swift source is not a list");
}

const CLOSED: Argument = Argument {
    name: "closed",
    title: Text::raw("Closed"),
    kind: ArgKind::String,
    required: true,
    suggestions: Some(Suggestions {
        source: "op:closed.list",
        pinned: &[],
        other_title: None,
        allows_multiple: false,
    }),
    is_target_name: false,
    is_target_description: false,
    is_supplied_by_target: false,
    asked_in_palette: false,
};

const DELETE: Action = Action {
    id: "test.closed.delete",
    title: Text::raw("Delete Closed Item"),
    category: "window",
    surface_plan: SurfacePlan { cli: Some(Decision::Offered), ..SurfacePlan::DEFAULT },
    cli_name: "closed delete",
    arguments: &[CLOSED],
    targets: &["workspace"],
    is_destructive: true,
    request: Some(Request {
        lane: RequestLane::Session,
        operation: "closed.delete",
        params: &[
            RequestParam { name: "closed", source: ParamSource::Argument("closed") },
            RequestParam { name: "workspace", source: ParamSource::Target("workspace") },
            RequestParam { name: "all", source: ParamSource::Constant(BindingValue::Bool(false)) },
        ],
    }),
    ..Action::DEFAULT
};

#[test]
fn the_app_export_carries_the_request_and_list_whole() {
    let row = json::app_action(&DELETE, 0);
    assert_eq!(
        row["request"],
        json!({
            "lane": "session",
            "operation": "closed.delete",
            "params": [
                {"name": "closed", "argument": "closed"},
                {"name": "workspace", "target": "workspace"},
                {"name": "all", "constant": false},
            ],
        }),
        "a false constant is data, not a default"
    );
    assert_eq!(
        row["arguments"][0]["suggestions"]["list"],
        json!({"lane": "session", "operation": "closed.list", "value": "id", "title": "name", "items": null})
    );
    // The full form (the Swift dump's) has neither: the app keeps them beside its descriptors.
    let full = json::action(&DELETE, 0);
    assert!(full.get("request").is_none());
    assert!(full["arguments"][0]["suggestions"].get("list").is_none());
    let plain = json::app_action(&Action { request: None, ..DELETE }, 0);
    assert!(plain.get("request").is_none());
    assert_eq!(well_formed(&DELETE), Ok(()));
}

#[test]
fn malformed_rows_are_refused() {
    let destructive = Action { is_destructive: false, ..DELETE };
    assert!(well_formed(&destructive).unwrap_err().contains("is_destructive"));
    let no_cli = Action { surface_plan: SurfacePlan::DEFAULT, ..DELETE };
    assert!(well_formed(&no_cli).unwrap_err().contains("CLI verb"));
    let stray = Action {
        request: Some(Request {
            lane: RequestLane::Session,
            operation: "closed.delete",
            params: &[RequestParam { name: "x", source: ParamSource::Argument("missing") }],
        }),
        ..DELETE
    };
    assert!(well_formed(&stray).unwrap_err().contains("undeclared argument"));
    let spaced = Action {
        request: Some(Request { lane: RequestLane::App, operation: "rm -rf", params: &[] }),
        ..DELETE
    };
    assert!(well_formed(&spaced).unwrap_err().contains("not an operation name"));
    let tab = Action {
        targets: &["tab"],
        request: Some(Request {
            lane: RequestLane::Session,
            operation: "closed.delete",
            params: &[RequestParam { name: "tab", source: ParamSource::Target("tab") }],
        }),
        ..DELETE
    };
    assert!(well_formed(&tab).unwrap_err().contains("does not resolve"));
}

#[test]
fn params_take_each_source_and_leave_out_omitted_ones() {
    let request = DELETE.request.as_ref().unwrap();
    let sent = params(request, |source| match source {
        ParamSource::Argument("closed") => Some(json!("cl_1")),
        _ => None,
    });
    assert_eq!(Value::Object(sent), json!({"closed": "cl_1", "all": false}));
}
