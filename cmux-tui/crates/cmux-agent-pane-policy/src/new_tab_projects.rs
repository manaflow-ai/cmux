//! New Tab project positions belong to an opening, not a live session tick.
//! The host supplies its cached list and warm chats before paint, then reconciles
//! the async project scan against that opening's seed. New folders append; a late
//! activity timestamp or repository discovery never moves an existing row.
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

fn path(cwd: &str) -> &str {
    let trimmed = cwd.trim_end_matches('/');
    if trimmed.is_empty() && cwd.starts_with('/') { "/" } else { trimmed }
}

pub(super) fn is_home(cwd: &str) -> bool {
    let parts: Vec<_> = cwd.split('/').filter(|s| !s.is_empty()).collect();
    parts.len() == 2 && matches!(parts[0], "Users" | "home")
}

fn agent_home(cwd: &str) -> bool {
    cwd.split_once("/Library/Application Support/").is_some_and(|(_, rest)| {
        rest == "cmux/agent-home" || rest.starts_with("cmux/agent-home/") ||
            rest.strip_prefix("cmux-next/builds/").and_then(|s| s.split_once('/'))
                .is_some_and(|(_, rest)| rest == "agent-home" || rest.starts_with("agent-home/"))
    })
}

pub fn snapshot(request: &Value) -> Value {
    let warm: Value =
        request["warm"].as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(Value::Null);
    let seed: Vec<Value> =
        request["seed"].as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default();
    let mut rows = Vec::new();
    let mut seen = HashSet::new();
    let mut recency: HashMap<String, (i64, usize)> = HashMap::new();
    let mut add = |cwd: &str| {
        let cwd = path(cwd);
        if cwd.is_empty() || agent_home(cwd) || !seen.insert(cwd.to_owned()) {
            return;
        }
        let label = if is_home(cwd) { "~" } else if cwd == "/" { "/" } else { cwd.rsplit('/').next().unwrap_or(cwd) };
        let mut row = json!({"cwd": cwd, "label": label});
        if request["repos"][cwd].is_object() {
            row["repo"] = request["repos"][cwd].clone();
        }
        rows.push(row);
    };
    if let Some(projects) = request["projects"].as_array() {
        for cwd in projects.iter().filter_map(Value::as_str) {
            add(cwd);
        }
    }
    if let Some(sessions) = warm["sessions"].as_array() {
        for (index, session) in sessions.iter().enumerate() {
            if ["startedBy", "spawnedBy"]
                .iter()
                .any(|key| session[key].as_str().is_some_and(|s| !s.is_empty()))
                || ["chiefChild", "chiefTurn"]
                    .iter()
                    .any(|key| session[key].as_bool() == Some(true))
                || session["peer"].as_str().is_some_and(|s| !s.is_empty())
                || session["hostKind"].as_str().is_some_and(|s| s != "local")
                || session["archived"].as_bool() == Some(true)
                || session["side"].as_bool() == Some(true)
            {
                continue;
            }
            if let Some(cwd) = session["cwd"].as_str() {
                add(cwd);
                let at = session["activityAt"]
                    .as_i64()
                    .or_else(|| session["updatedAt"].as_i64())
                    .unwrap_or(0);
                if cwd != "~" && path(cwd) != "/" {
                    recency.entry(path(cwd).to_owned())
                        .and_modify(|old| { if at > old.0 { *old = (at, index); } })
                        .or_insert((at, index));
                }
            }
        }
    }
    if let Some(cwd) = request["cwd"].as_str() {
        add(cwd);
    }
    rows.sort_by_key(|row| {
        let recent = recency.get(row["cwd"].as_str().unwrap_or_default());
        (recent.is_none(), std::cmp::Reverse(recent.map_or(0, |r| r.0)), recent.map_or(usize::MAX, |r| r.1))
    });
    let mut remaining: HashMap<String, Value> = rows
        .iter()
        .map(|row| (row["cwd"].as_str().unwrap_or_default().to_owned(), row.clone()))
        .collect();
    let mut ordered = Vec::new();
    for row in seed {
        if let Some(cwd) = row["cwd"].as_str() {
            if remaining.remove(cwd).is_some() {
                // Repository identity controls grouping. Keep it for this opening;
                // refreshed metadata is cached for the next opening.
                ordered.push(row);
            }
        }
    }
    for row in rows {
        if remaining.remove(row["cwd"].as_str().unwrap_or_default()).is_some() {
            ordered.push(row);
        }
    }
    super::new_tab_project_groups::freeze(&mut ordered, request["cwd"].as_str());
    json!({"rows": serde_json::to_string(&ordered).ok()})
}

#[cfg(test)]
mod tests {
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
        let second =
            snapshot(&json!({"projects":["/a","/b","/c","/d"],"seed":first}))["rows"].clone();
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
        assert_eq!(result.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(), ["/b","/a","/","/Users/me","/unused"]);
        assert_eq!(result[2]["label"], "/");
        assert_eq!(result[3]["label"], "~");
        assert_eq!(result[3]["displayGroup"]["hidden"], true);
    }
    #[test]
    fn late_repository_cannot_merge_or_rename_seed_groups() {
        let initial = rows(json!({"projects":["/Users/me/Projects/cmux","/Users/me/checkouts/cmux/lane","/notes"]}));
        let seed = serde_json::to_string(&initial).unwrap();
        let settled = rows(json!({"projects":["/Users/me/Projects/cmux","/Users/me/checkouts/cmux/lane","/notes","/new/cmux"],"seed":seed,
            "repos":{"/new/cmux":{"root":"/new/cmux","name":"cmux","github":"manaflow-ai/cmux"}}}));
        for (before, after) in initial.iter().zip(&settled) { assert_eq!(before["displayGroup"], after["displayGroup"]); }
        assert_ne!(settled[0]["displayGroup"]["key"], settled[3]["displayGroup"]["key"]);
    }
    #[test]
    fn appended_main_checkout_cannot_replace_existing_group_lead() {
        let repo = json!({"root":"/main","name":"repo","github":"org/repo"});
        let first = rows(json!({"projects":["/lane"],"repos":{"/lane":repo}}));
        let result = rows(json!({"projects":["/lane","/main"],"repos":{"/lane":repo,"/main":repo},"seed":serde_json::to_string(&first).unwrap()}));
        assert_eq!(result[0]["displayGroup"]["lead"], "/lane");
        assert_eq!(result[1]["displayGroup"]["lead"], "/lane");
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
        assert_eq!(
            result.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(),
            ["/a", "/c"]
        );
    }
}
