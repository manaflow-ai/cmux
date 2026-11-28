use super::*;
fn rows(request: Value) -> Vec<Value> {
    serde_json::from_str(snapshot(&request)["rows"].as_str().unwrap()).unwrap()
}
#[test]
fn cached_order_survives_recency_and_repo_hydration() {
    let initial = json!({"projects":["/a","/b"],"warm":r#"{"sessions":[{"cwd":"/a","activityAt":20},{"cwd":"/b","activityAt":10}]}"#});
    let seed = snapshot(&initial)["rows"].as_str().unwrap().to_owned();
    let settled = rows(json!({"projects":["/b","/a","/c"],"seed":seed,
      "repos":{"/a":{"root":"/b","name":"b"}},
      "warm":r#"{"sessions":[{"cwd":"/b","activityAt":30},{"cwd":"/a","activityAt":20}]}"#}));
    assert_eq!(
        settled.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(),
        ["/a", "/b", "/c"]
    );
    assert!(settled[0].get("repo").is_none());
}
#[test]
fn appended_rows_keep_positions_on_subsequent_refresh() {
    let first = snapshot(&json!({"projects":["/a","/b"]}))["rows"].clone();
    let second = snapshot(&json!({"projects":["/a","/b","/c","/d"],"seed":first}))["rows"].clone();
    let refreshed = rows(json!({"projects":["/d","/c","/b","/a"],"seed":second}));
    assert_eq!(
        refreshed.iter().map(|row| row["cwd"].as_str().unwrap()).collect::<Vec<_>>(),
        ["/a", "/b", "/c", "/d"]
    );
}
#[test]
fn labels_hidden_sessions_and_equal_recency_match_existing_picker() {
    let result = rows(json!({"projects":["/","/Users/me","/a","/b","/unused"],
      "warm":r#"{"sessions":[{"cwd":"/b","activityAt":20},{"cwd":"/a","activityAt":20},{"cwd":"/archived","archived":true,"activityAt":30},{"cwd":"/aside","side":true,"activityAt":30},{"cwd":"/unused","archived":true,"activityAt":40}]}"#}));
    assert_eq!(
        result.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(),
        ["/b", "/a", "/", "/Users/me", "/unused"]
    );
    assert_eq!(result[2]["label"], "/");
    assert_eq!(result[3]["label"], "~");
    assert_eq!(result[3]["displayGroup"]["hidden"], true);
}
#[test]
fn late_repository_cannot_merge_or_rename_seed_groups() {
    let initial = rows(
        json!({"projects":["/Users/me/Projects/cmux","/Users/me/checkouts/cmux/lane","/notes"]}),
    );
    let seed = serde_json::to_string(&initial).unwrap();
    let settled = rows(
        json!({"projects":["/Users/me/Projects/cmux","/Users/me/checkouts/cmux/lane","/notes","/new/cmux"],"seed":seed,
        "repos":{"/new/cmux":{"root":"/new/cmux","name":"cmux","github":"manaflow-ai/cmux"}}}),
    );
    for (before, after) in initial.iter().zip(&settled) {
        assert_eq!(before["displayGroup"], after["displayGroup"]);
    }
    assert_ne!(settled[0]["displayGroup"]["key"], settled[3]["displayGroup"]["key"]);
}
#[test]
fn appended_main_checkout_cannot_replace_existing_group_lead() {
    let repo = json!({"root":"/main","name":"repo","github":"org/repo"});
    let first = rows(json!({"projects":["/lane"],"repos":{"/lane":repo}}));
    let result = rows(
        json!({"projects":["/lane","/main"],"repos":{"/lane":repo,"/main":repo},"seed":serde_json::to_string(&first).unwrap()}),
    );
    assert_eq!(result[0]["displayGroup"]["lead"], "/lane");
    assert_eq!(result[1]["displayGroup"]["lead"], "/lane");
}
#[test]
fn main_lead_prefers_current_clones_root() {
    let first = json!({"root":"/first","name":"repo","github":"org/repo"});
    let second = json!({"root":"/second","name":"repo","github":"org/repo"});
    let result = rows(json!({"projects":["/first","/second","/second-lane"],"cwd":"/second-lane",
        "repos":{"/first":first,"/second":second,"/second-lane":second}}));
    assert_eq!(result[0]["displayGroup"]["lead"], "/second-lane");
    assert_eq!(result[0]["displayGroup"]["mainLead"], "/second");
}
#[test]
fn next_opening_uses_new_recency_and_metadata() {
    let result = rows(json!({"projects":["/a","/b"],"repos":{"/b":{"root":"/b","name":"b"}},
      "warm":r#"{"sessions":[{"cwd":"/b","activityAt":30},{"cwd":"/a","activityAt":20}]}"#}));
    assert_eq!(result[0]["cwd"], "/b");
    assert_eq!(result[0]["repo"]["name"], "b");
}
#[test]
fn removals_duplicates_and_foreign_chats() {
    let result = rows(
        json!({"projects":["/a/","/a","/c"],"seed":r#"[{"cwd":"/gone","label":"gone"},{"cwd":"/a","label":"a"}]"#,
      "warm":r#"{"sessions":[{"cwd":"/remote","hostKind":"ssh"},{"cwd":"/child","spawnedBy":"agent"},{"cwd":"/Users/me/Library/Application Support/cmux/agent-home/abc"}]}"#}),
    );
    assert_eq!(result.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(), ["/a", "/c"]);
}
