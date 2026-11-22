//! Read-only, on-demand projection of unfinished fleet saga logs.
//! The experiment never executes or mutates a saga; it only replays safe status fields.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::AsyncReadExt;

const MAX_BYTES: u64 = 64 * 1024;
const MAX_FILES: usize = 64;

pub(super) async fn read() -> Value {
    let root = std::env::var_os("FLEET_SAGA_DIR").map(PathBuf::from).or_else(|| {
        std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state/fleet-sagas"))
    });
    let Some(root) = root else { return json!({"available": false, "sagas": []}) };
    match tokio::time::timeout(Duration::from_secs(2), read_at(&root)).await {
        Ok(Ok(sagas)) => json!({"available": true, "sagas": sagas}),
        _ => json!({"available": false, "sagas": []}),
    }
}

async fn read_at(root: &Path) -> std::io::Result<Vec<Value>> {
    let mut dir = tokio::fs::read_dir(root).await?;
    let mut paths = Vec::new();
    while let Some(entry) = dir.next_entry().await? {
        if paths.len() >= MAX_FILES {
            break;
        }
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            paths.push(path);
        }
    }
    paths.sort();
    let mut result = Vec::new();
    for path in paths {
        let Ok(Some(value)) = read_file(&path).await else { continue };
        result.push(value);
    }
    Ok(result)
}

async fn read_file(path: &Path) -> std::io::Result<Option<Value>> {
    let file = tokio::fs::File::open(path).await?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).await?;
    if bytes.len() as u64 > MAX_BYTES {
        return Ok(None);
    }
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default();
    Ok(project(id, &bytes))
}

fn project(id: &str, bytes: &[u8]) -> Option<Value> {
    let mut created: Option<String> = None;
    let mut steps: Vec<String> = Vec::new();
    let mut succeeded = Vec::new();
    let mut current: Option<(String, &'static str)> = None;
    let mut finished = false;
    for line in bytes.split(|b| *b == b'\n') {
        let Ok(event) = serde_json::from_slice::<Value>(line) else { continue };
        let kind =
            event.get("kind").or_else(|| event.get("event")).and_then(Value::as_str).unwrap_or("");
        if kind == "created" {
            created = event
                .get("saga")
                .and_then(Value::as_str)
                .or_else(|| event.get("id").and_then(Value::as_str))
                .map(str::to_owned);
            if let Some(list) = event.get("steps").and_then(Value::as_array) {
                steps = list
                    .iter()
                    .filter_map(|step| {
                        step.as_str()
                            .map(str::to_owned)
                            .or_else(|| step.get("name").and_then(Value::as_str).map(str::to_owned))
                    })
                    .collect();
            }
        }
        let step = event
            .get("step")
            .and_then(|v| v.as_str().or_else(|| v.get("name").and_then(Value::as_str)))
            .map(str::to_owned);
        match kind {
            "abandoned" => finished = true,
            "succeeded" => {
                if let Some(step) = step {
                    if !succeeded.contains(&step) {
                        succeeded.push(step);
                    }
                }
            }
            "undo_finished" => {
                if let Some(step) = step {
                    succeeded.retain(|name| name != &step);
                }
            }
            "undo_failed" => {
                current = step.map(|name| (name, "stuck"));
            }
            "paused" => {
                current = step.map(|name| (name, "paused"));
            }
            "failed" | "undo_started" => {
                if current.as_ref().map(|(_, status)| *status) != Some("stuck") {
                    current = step.map(|name| (name, "unwinding"));
                }
            }
            "started" => {
                if current.is_none() {
                    current = step.map(|name| (name, "running"));
                }
            }
            _ => {}
        }
    }
    let saga_id = if id.is_empty() { created.unwrap_or_default() } else { id.to_owned() };
    if saga_id.is_empty() || finished {
        return None;
    }
    if current.is_none() {
        current = steps
            .iter()
            .find(|name| !succeeded.contains(name))
            .cloned()
            .map(|name| (name, "running"));
    }
    let Some((step, status)) = current else { return None };
    Some(json!({"id": saga_id, "status": status, "step": step}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_open_running_paused_and_stuck_sagas() {
        let running = br#"{"kind":"created","saga":"lend-worker","steps":["token","install"]}
{"kind":"started","step":"install"}"#;
        assert_eq!(project("a", running).unwrap()["status"], "running");
        let paused = br#"{"kind":"created","steps":["verify"]}
{"kind":"paused","step":"verify"}"#;
        assert_eq!(project("b", paused).unwrap()["status"], "paused");
        let stuck = br#"{"kind":"created","steps":["install"]}
{"kind":"undo_failed","step":"install"}"#;
        assert_eq!(project("c", stuck).unwrap()["status"], "stuck");
    }

    #[test]
    fn omits_finished_and_fully_succeeded_sagas() {
        let done = br#"{"kind":"created","steps":["install"]}
{"kind":"succeeded","step":"install"}"#;
        assert!(project("done", done).is_none());
        let abandoned = br#"{"kind":"abandoned"}"#;
        assert!(project("gone", abandoned).is_none());
    }
}
