use serde_json::json;

use super::location;
use crate::cli::Surface;
use crate::cli::command::{CommandPlan, parse};

const WS: &str = "ws_00000000000000000000000000000004";

fn workspace() -> serde_json::Value {
    json!({"id": WS, "name": "Agents reuse groups", "index": 3, "focused": false,
           "extra": {"key": "key-4", "title": "Agents reuse groups"}})
}

/// The answer names the workspace and the personal sidebar group that holds
/// it (id and name), so an agent can file its next workspace beside it.
#[test]
fn location_names_the_workspace_and_its_group() {
    let placements = json!([
        {"workspace": {"session_id": "s", "workspace_ref": "k0", "workspace_id": "ws_other"}, "index": 0, "group_id": null, "room_id": null},
        {"workspace": {"session_id": "s", "workspace_ref": "key-4", "workspace_id": WS}, "index": 1, "group_id": "wgrp_7", "room_id": "room_1"},
    ]);
    let groups = json!([
        {"id": "wgrp_7", "name": "Agents & routing", "room_id": "room_1"},
        {"id": "wgrp_8", "name": "Performance", "room_id": "room_1"},
    ]);
    assert_eq!(
        location(&workspace(), &placements, &groups, "caller"),
        json!({
            "workspace": {"id": WS, "name": "Agents reuse groups", "key": "key-4"},
            "group": {"id": "wgrp_7", "name": "Agents & routing"},
            "room_id": "room_1",
            "source": "caller",
        })
    );
}

/// A workspace outside every group answers `group: null`, not an error.
#[test]
fn an_ungrouped_workspace_answers_a_null_group() {
    let placements = json!([{"workspace": {"session_id": "s", "workspace_ref": "key-4", "workspace_id": WS}, "index": 0, "group_id": null, "room_id": null}]);
    let answer = location(&workspace(), &placements, &json!([]), "current");
    assert_eq!(answer["group"], json!(null));
    assert_eq!(answer["source"], "current");
}

/// `cmux workspace where` (and its alias `cmux whereami`) is its own plan.
#[test]
fn workspace_where_parses_to_its_plan() {
    for words in [&["workspace", "where"][..], &["whereami"][..]] {
        let args = words.iter().map(|word| (*word).to_string()).collect::<Vec<_>>();
        assert!(
            matches!(parse(&args, Surface::Cmux), Ok(CommandPlan::WorkspaceWhere)),
            "{words:?}"
        );
    }
}
