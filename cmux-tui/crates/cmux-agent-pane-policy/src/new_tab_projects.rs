//! New Tab project positions belong to an opening, not a live session tick.
//! The host supplies its cached list and warm chats before paint, then reconciles
//! the async project scan against that opening's seed. New folders append; a late
//! activity timestamp or repository discovery never moves an existing row.
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

pub fn snapshot(request: &Value) -> Value {
    let warm: Value =
        request["warm"].as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(Value::Null);
    let seed: Vec<Value> =
        request["seed"].as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default();
    let mut rows = Vec::new();
    let mut seen = HashSet::new();
    let mut recency: HashMap<String, i64> = HashMap::new();
    let mut add = |cwd: &str| {
        let cwd = cwd.trim_end_matches('/');
        if cwd.is_empty() || cwd.contains("/agent-home/") || !seen.insert(cwd.to_owned()) {
            return;
        }
        let mut row = json!({"cwd": cwd, "label": cwd.rsplit('/').next().unwrap_or(cwd)});
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
        for session in sessions {
            if ["startedBy", "spawnedBy"]
                .iter()
                .any(|key| session[key].as_str().is_some_and(|s| !s.is_empty()))
                || ["chiefChild", "chiefTurn"]
                    .iter()
                    .any(|key| session[key].as_bool() == Some(true))
                || session["peer"].as_str().is_some_and(|s| !s.is_empty())
                || session["hostKind"].as_str().is_some_and(|s| s != "local")
            {
                continue;
            }
            if let Some(cwd) = session["cwd"].as_str() {
                add(cwd);
                let at = session["activityAt"]
                    .as_i64()
                    .or_else(|| session["updatedAt"].as_i64())
                    .unwrap_or(0);
                recency
                    .entry(cwd.trim_end_matches('/').to_owned())
                    .and_modify(|old| *old = (*old).max(at))
                    .or_insert(at);
            }
        }
    }
    if let Some(cwd) = request["cwd"].as_str() {
        add(cwd);
    }
    rows.sort_by_key(|row| {
        std::cmp::Reverse(recency.get(row["cwd"].as_str().unwrap()).copied().unwrap_or(0))
    });
    let mut remaining: HashMap<String, Value> =
        rows.iter().map(|row| (row["cwd"].as_str().unwrap().to_owned(), row.clone())).collect();
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
        if remaining.remove(row["cwd"].as_str().unwrap()).is_some() {
            ordered.push(row);
        }
    }
    json!({"rows": serde_json::to_string(&ordered).expect("project rows serialize")})
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
          "warm":r#"{"sessions":[{"cwd":"/remote","hostKind":"ssh"},{"cwd":"/child","spawnedBy":"agent"},{"cwd":"/private/agent-home/abc"}]}"#}),
        );
        assert_eq!(
            result.iter().map(|r| r["cwd"].as_str().unwrap()).collect::<Vec<_>>(),
            ["/a", "/c"]
        );
    }
}
