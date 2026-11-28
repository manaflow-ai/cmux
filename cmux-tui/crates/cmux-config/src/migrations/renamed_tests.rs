use serde_json::json;

use super::*;

fn path(dotted: &str) -> Vec<String> {
    dotted.split('.').map(str::to_owned).collect()
}

#[test]
fn the_renamed_keys_name_their_old_key() {
    let cases = [
        ("appearance.background", "appearance.backdropArt"),
        ("agentPane.display.sessionInfo.placement", "agentPane.display.inspector.placement"),
        ("computerUse.mode", "computerUse.enabled"),
        ("sidebar.workspaceRow.directory", "sidebar.showWorkspaceDirectory"),
        ("sidebar.workspaceRow.tabCount", "sidebar.showCounts"),
    ];
    for (row, old) in cases {
        assert_eq!(legacy_path(&path(row)), Some(path(old)), "{row}");
    }
    assert_eq!(legacy_path(&path("sidebar.workspaceRow.branch")), None);
    assert_eq!(legacy_path(&path("editor.fontSize")), None);
    for (row, old) in legacy_paths() {
        assert_eq!(legacy_path(&row), Some(old));
    }
    assert!(legacy_paths().iter().any(|(row, _)| *row == path("appearance.background")));
}

#[test]
fn automatic_updates_reads_the_first_toggle_the_table_lists() {
    let automatic = path("updates.automatic");
    let read = |updates: Value| legacy_value(&automatic, &json!({ "updates": updates }));
    assert_eq!(
        read(json!({ "checkAutomatically": false, "installWhenIdle": true })),
        Some(json!("off"))
    );
    // checkAutomatically: true lists nothing, so the next toggle answers.
    assert_eq!(
        read(json!({ "checkAutomatically": true, "installWhenIdle": true })),
        Some(json!("idle"))
    );
    assert_eq!(read(json!({ "downloadAutomatically": false })), Some(json!("notify")));
    assert_eq!(
        read(json!({ "installWhenIdle": false, "downloadAutomatically": true })),
        Some(json!("download"))
    );
    assert_eq!(read(json!({ "checkAutomatically": true })), None);
    assert_eq!(read(json!({})), None);
}

#[test]
fn old_values_read_as_the_new_row_shows_them() {
    let root = json!({
        "computerUse": { "enabled": false },
        "agentPane": { "display": { "inspector": { "placement": "right" } } },
        "sidebar": { "showCounts": false },
        "appearance": { "backdropArt": "met-sunflowers-436524" },
    });
    assert_eq!(legacy_value(&path("computerUse.mode"), &root), Some(json!("off")));
    assert_eq!(
        legacy_value(&path("agentPane.display.sessionInfo.placement"), &root),
        Some(json!("right"))
    );
    assert_eq!(legacy_value(&path("sidebar.workspaceRow.tabCount"), &root), Some(json!(false)));
    assert_eq!(legacy_value(&path("sidebar.workspaceRow.directory"), &root), None);
    assert_eq!(
        legacy_value(&path("appearance.background"), &root),
        Some(json!("van-gogh-sunflowers"))
    );
    let on = json!({ "computerUse": { "enabled": true } });
    assert_eq!(legacy_value(&path("computerUse.mode"), &on), None);
}

#[test]
fn a_backdrop_art_reads_as_a_work_or_none() {
    let read = |art: Value| {
        legacy_value(&path("appearance.background"), &json!({"appearance": {"backdropArt": art}}))
    };
    assert_eq!(read(json!("van-gogh-sunflowers")), Some(json!("van-gogh-sunflowers")));
    assert_eq!(read(json!("goya-saturn")), Some(json!("none")));
    assert_eq!(read(json!("no-such-work")), Some(json!("none")));
    assert_eq!(read(json!(3)), Some(json!("none")));
    assert_eq!(read(json!("none")), Some(json!("none")));
}
