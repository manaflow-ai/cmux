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
