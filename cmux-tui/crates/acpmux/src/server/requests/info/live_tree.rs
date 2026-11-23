//! Read-only, on-demand projection of the live-tree daemon's status file. No polling or commands.

use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::AsyncReadExt;

const MAX_BYTES: u64 = 64 * 1024;
const MAX_AGE: f64 = 300.0;

pub(super) async fn read(cwd: &Path) -> Value {
    let root = std::env::var_os("LIVETREE_ROOT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "/work/livetree".into());
    let result = tokio::time::timeout(Duration::from_secs(2), read_at(&root, cwd)).await;
    match result {
        Ok(Ok(value)) => value,
        _ => json!({"available": false}),
    }
}

async fn read_at(root: &Path, cwd: &Path) -> std::io::Result<Value> {
    let tree = tokio::fs::canonicalize(root.join("tree")).await?;
    let cwd = tokio::fs::canonicalize(cwd).await?;
    if !cwd.starts_with(&tree) {
        return Ok(json!({"available": false}));
    }
    let state = tokio::fs::canonicalize(root.join("state")).await?;
    let path = tokio::fs::canonicalize(state.join("status.json")).await?;
    if !path.starts_with(&state) || !tokio::fs::metadata(&path).await?.is_file() {
        return Ok(json!({"available": false}));
    }
    let file = tokio::fs::File::open(path).await?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).await?;
    if bytes.len() as u64 > MAX_BYTES {
        return Ok(json!({"available": false}));
    }
    let raw: Value = serde_json::from_slice(&bytes)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64();
    Ok(project(&raw, now))
}

/// Only numeric lane facts leave the host: never paths, diagnostics, writers or snapshot messages.
/// A result from another sequence is unknown, even if that lane did not change (conservative).
fn project(raw: &Value, now: f64) -> Value {
    let Some(seq) = raw["seq"].as_u64() else { return json!({"available": false}) };
    let Some(updated) = raw["updated"].as_f64() else { return json!({"available": false}) };
    let stale = !(0.0..=MAX_AGE).contains(&(now - updated));
    let lanes: Vec<Value> = ["rust", "webviews", "swift"]
        .into_iter()
        .map(|name| {
            let lane = raw.get("lanes").and_then(|lanes| lanes.get(name)).unwrap_or(&Value::Null);
            let current = !stale
                && raw["pending"].as_u64() == Some(0)
                && lane["seq"].as_u64() == Some(seq)
                && lane["stale"] == false;
            let verdict = if !current {
                "unknown"
            } else {
                match lane["ok"].as_bool() {
                    Some(true) => "passed",
                    Some(false) => "failed",
                    None => "unknown",
                }
            };
            json!({"name": name, "verdict": verdict})
        })
        .collect();
    json!({"available": true, "updated": updated, "seq": seq, "stale": stale, "lanes": lanes})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_tree_current_missing_and_stale_lanes() {
        let mut raw = json!({"seq": 4, "updated": 1000, "pending": 0, "lanes": {
            "rust": {"ok": true, "seq": 4, "stale": false},
            "webviews": {"ok": false, "seq": 4, "stale": false},
            "swift": {"ok": true, "seq": 3, "stale": false}
        }});
        let value = project(&raw, 1001.0);
        assert_eq!(value["lanes"][0]["verdict"], "passed");
        assert_eq!(value["lanes"][1]["verdict"], "failed");
        assert_eq!(value["lanes"][2]["verdict"], "unknown");
        for now in [999.0, 1301.0] {
            assert_eq!(project(&raw, now)["lanes"][0]["verdict"], "unknown");
        }
        raw["pending"] = json!(1);
        assert_eq!(project(&raw, 1001.0)["lanes"][0]["verdict"], "unknown");
        assert_eq!(project(&json!({}), 1001.0)["available"], false);
    }

    #[tokio::test]
    async fn live_tree_reads_only_for_its_tree_and_bounds_the_file() -> std::io::Result<()> {
        let root = tempfile::tempdir()?;
        let tree = root.path().join("tree");
        let state = root.path().join("state");
        std::fs::create_dir(&tree)?;
        std::fs::create_dir(&state)?;
        let path = state.join("status.json");
        std::fs::write(&path, br#"{"seq":1,"pending":0,"updated":0}"#)?;
        assert_eq!(read_at(root.path(), &tree).await?["available"], true);
        assert_eq!(read_at(root.path(), root.path()).await?["available"], false);
        std::fs::write(path, vec![b' '; MAX_BYTES as usize + 1])?;
        assert_eq!(read_at(root.path(), &tree).await?["available"], false);
        Ok(())
    }
}
