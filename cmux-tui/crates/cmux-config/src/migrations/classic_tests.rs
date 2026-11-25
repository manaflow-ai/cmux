//! Ports of Swift `ClassicSettingsUpgradeTests` and `ClassicLinkRoutingTests`.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::*;

fn classic() -> Value {
    json!({
      "paneBorderColor": "#112233",
      "activePaneBorderColor": "#445566",
      "app": {
        "globalFontMagnification": 120,
        "newWorkspacePlacement": "end",
        "equalizeSplitsOnCreate": true,
        "minimalMode": false,
        "focusHistoryIncludesPanesAndTabs": true
      },
      "notifications": {
        "paneFlashColor": "#778899",
        "paneFlash": false,
        "paneFlashOnTyping": false,
        "unreadPaneRing": true,
        "suppressWhenAppFocused": true
      },
      "diffViewer": { "defaultLayout": "unified" },
      "diff": { "layout": "split" },
      "browser": {
        "showSearchSuggestions": false,
        "defaultSearchEngine": "kagi",
        "discardHiddenWebViews": false
      },
      "sidebar": {
        "showPorts": true,
        "showLog": false,
        "showProgress": false,
        "showPullRequests": true,
        "showBranchDirectory": true,
        "showAgentActivity": false
      }
    })
}

/// Applies the edits to `file`, as the app's one atomic write does.
fn applied(file: &Value, edits: &[PathEdit]) -> Value {
    let mut root = file.clone();
    for (path, value) in edits {
        root = match value {
            Some(value) => crate::value::with_value(&root, value.clone(), path),
            None => without(root, path),
        };
    }
    root
}

fn without(mut root: Value, path: &[String]) -> Value {
    let Some((last, parents)) = path.split_last() else { return root };
    let mut node = &mut root;
    for part in parents {
        match node.get_mut(part) {
            Some(next) => node = next,
            None => return root,
        }
    }
    if let Some(members) = node.as_object_mut() {
        members.remove(last);
    }
    root
}

fn at<'a>(root: &'a Value, path: &str) -> Option<&'a Value> {
    let parts: Vec<&str> = path.split('.').collect();
    value_at(root, &parts)
}

#[test]
fn classic_settings_come_over_on_the_update() {
    let file = classic();
    let root = applied(&file, &rename_edits(&file));
    let expected = [
        ("layout.paneBorderColor", json!("#112233")),
        ("focusRing.color", json!("#445566")),
        ("notifications.attention.color", json!("#778899")),
        ("notifications.attention.flash", json!(false)),
        ("notifications.attention.flashOnTyping", json!(false)),
        ("workspaces.newPlacement", json!("bottom")),
        ("layout.splitSizing", json!("even")),
        ("window.titlebar", json!("standard")),
        ("navigation.history.scope", json!("everything")),
        ("notifications.desktop", json!("whenInactive")),
        ("diff.layout", json!("split")),
        ("browser.omnibar.remoteSuggestions", json!(false)),
        ("browser.searchEngine", json!("kagi")),
        ("browser.hibernation", json!("off")),
        ("sidebar.workspaceRow.ports", json!(true)),
        ("sidebar.workspaceRow.log", json!(false)),
        ("sidebar.workspaceRow.progress", json!(false)),
        ("sidebar.workspaceRow.pullRequest", json!(true)),
        ("sidebar.workspaceRow.directory", json!(true)),
        ("sidebar.workspaceRow.working", json!(false)),
    ];
    for (path, value) in expected {
        assert_eq!(at(&root, path), Some(&value), "{path}");
    }
    // Moved keys are gone; one next can't express (the ring on: next's default) stays.
    assert_eq!(at(&root, "app.newWorkspacePlacement"), None);
    assert_eq!(at(&root, "app.globalFontMagnification"), Some(&json!(120)));
    assert_eq!(at(&root, "diffViewer.defaultLayout"), None);
    assert_eq!(at(&root, "notifications.unreadPaneRing"), Some(&json!(true)));
    assert_eq!(at(&root, "notifications.attention.style"), None);
}

#[test]
fn approximate_classic_values_stay() {
    let file = json!({
      "app": { "globalFontMagnification": 200 },
      "browser": { "defaultSearchEngine": "custom", "customSearchEngineURLTemplate": "https://search.example/?q={query}" },
      "notifications": { "unreadPaneRing": false },
      "sidebar": { "showBranchDirectory": true }
    });
    let root = applied(&file, &rename_edits(&file));
    assert_eq!(at(&root, "app.uiScale"), None);
    assert_eq!(at(&root, "app.globalFontMagnification"), Some(&json!(200)));
    assert_eq!(at(&root, "browser.searchEngine"), None);
    assert_eq!(at(&root, "browser.defaultSearchEngine"), Some(&json!("custom")));
    assert_eq!(at(&root, "notifications.attention.persist"), Some(&json!(false)));
    assert_eq!(at(&root, "notifications.attention.style"), None);
    assert_eq!(at(&root, "sidebar.workspaceRow.branch"), Some(&json!(true)));
    assert_eq!(at(&root, "sidebar.workspaceRow.directory"), Some(&json!(true)));
}

#[test]
fn a_file_without_classic_keys_needs_no_edit() {
    assert!(rename_edits(&json!({"workspaces": {"newPlacement": "top"}})).is_empty());
    assert!(rename_edits(&json!({})).is_empty());
}

#[test]
fn lines_split_trim_and_drop_comments() {
    assert_eq!(
        lines(&json!("*.corp.example\n\n  intranet.local  ")),
        Some(vec!["*.corp.example".to_owned(), "intranet.local".to_owned()])
    );
    assert_eq!(lines(&json!(["*zoom.us*", "# a comment"])), Some(vec!["*zoom.us*".to_owned()]));
    assert_eq!(lines(&json!(["a", 1])), None);
    assert_eq!(lines(&json!(3)), None);
}

#[test]
fn link_routing_comes_over_from_this_channel_first() {
    let own = json!({
        "browserOpenTerminalLinksInCmuxBrowser": false,
        "browserHostWhitelist": "*.corp.example\n\n  intranet.local  ",
        "browserExternalOpenPatterns": ["*zoom.us*", "# a comment"],
    });
    let stable = json!({ "browserHostWhitelist": "stable.example" });
    let done = BTreeSet::new();
    assert!(preferences_pending(&done));
    let import = preference_edits(&done, &json!({}), &[own.clone(), stable.clone()]);
    assert_eq!(
        import.edits,
        vec![
            (owned(&["browser", "openLinksInCmuxBrowser"]), json!(false)),
            (
                owned(&["browser", "hostsToOpenInEmbeddedBrowser"]),
                json!(["*.corp.example", "intranet.local"])
            ),
            (owned(&["browser", "urlsToAlwaysOpenExternally"]), json!(["*zoom.us*"])),
        ]
    );
    let recorded: BTreeSet<String> = import.done.iter().cloned().collect();
    assert!(!preferences_pending(&recorded));
    // Imported once: a later run writes nothing, even with new values.
    let again = preference_edits(&recorded, &json!({}), &[own, stable]);
    assert!(again.edits.is_empty());
}

#[test]
fn a_disabled_browser_opened_every_link_outside() {
    let stable = json!({
        "browserDisabledOverride": true,
        "browserOpenTerminalLinksInCmuxBrowser": true,
        "browserExternalOpenPatterns": "re:^https://bank\\.example/",
    });
    let import = preference_edits(&BTreeSet::new(), &json!({}), &[json!({}), stable]);
    assert_eq!(
        import.edits,
        vec![
            (owned(&["browser", "openLinksInCmuxBrowser"]), json!(false)),
            (owned(&["browser", "enabled"]), json!(false)),
            (
                owned(&["browser", "urlsToAlwaysOpenExternally"]),
                json!(["re:^https://bank\\.example/"])
            ),
        ]
    );
}

#[test]
fn the_file_and_defaults_win() {
    let source = json!({
        "browserOpenTerminalLinksInCmuxBrowser": true,
        "browserDisabledOverride": false,
        "browserHostWhitelist": "set.example",
    });
    let file = json!({ "browser": { "hostsToOpenInEmbeddedBrowser": ["mine.example"] } });
    let import = preference_edits(&BTreeSet::new(), &file, &[source]);
    // openLinks true and enabled true are next's defaults; the hosts are set.
    assert!(import.edits.is_empty(), "{:?}", import.edits);
    assert_eq!(import.done.len(), 4);
    // The older key set in the file counts as imported.
    let file = json!({ "browser": { "openTerminalLinksInCmuxBrowser": true } });
    let import = preference_edits(
        &BTreeSet::new(),
        &file,
        &[json!({"browserOpenTerminalLinksInCmuxBrowser": false})],
    );
    assert!(import.edits.is_empty());
    let done: BTreeSet<String> = ["browser.openTerminalLinksInCmuxBrowser".to_owned()].into();
    assert!(
        preference_edits(
            &done,
            &json!({}),
            &[json!({"browserOpenTerminalLinksInCmuxBrowser": false})]
        )
        .edits
        .is_empty()
    );
}

#[test]
fn defaults_bool_reads_like_user_defaults() {
    assert!(defaults_bool(Some(&json!(true))));
    assert!(defaults_bool(Some(&json!(2))));
    assert!(!defaults_bool(Some(&json!(0))));
    assert!(defaults_bool(Some(&json!("  YES"))));
    assert!(defaults_bool(Some(&json!("007"))));
    assert!(!defaults_bool(Some(&json!("no"))));
    assert!(!defaults_bool(None));
}
