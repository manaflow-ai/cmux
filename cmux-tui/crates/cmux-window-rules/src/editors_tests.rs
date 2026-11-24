use super::*;

fn facts(installed: &[&str], configured: Option<&str>) -> PickFacts {
    PickFacts {
        installed: installed.iter().map(|id| (*id).to_owned()).collect(),
        configured: configured.map(str::to_owned),
    }
}

#[test]
fn auto_takes_the_first_installed_editor_in_table_order() {
    let pick = pick(&facts(&["zed", "vscode", "nova"], None));
    assert_eq!(pick.default.as_deref(), Some("vscode"));
    assert_eq!(pick.ordered, ["vscode", "zed", "nova"]);
}

#[test]
fn the_configured_editor_comes_first_when_installed() {
    let pick = pick(&facts(&["vscode", "zed", "cursor"], Some("zed")));
    assert_eq!(pick.default.as_deref(), Some("zed"));
    assert_eq!(pick.ordered, ["zed", "vscode", "cursor"]);
}

#[test]
fn a_configured_editor_that_is_not_installed_is_passed_over() {
    let pick = pick(&facts(&["cursor", "xcode"], Some("vscode")));
    assert_eq!(pick.default.as_deref(), Some("cursor"));
    assert_eq!(pick.ordered, ["cursor", "xcode"]);
}

#[test]
fn no_installed_editor_picks_none_and_unknown_ids_are_dropped() {
    assert_eq!(pick(&facts(&[], Some("zed"))), Pick::default());
    let pick = pick(&facts(&["textedit", "zed"], Some("textedit")));
    assert_eq!(pick.default.as_deref(), Some("zed"));
    assert_eq!(pick.ordered, ["zed"]);
}

#[test]
fn every_editor_has_a_unique_id_and_bundle_ids() {
    for (index, editor) in EDITORS.iter().enumerate() {
        assert!(!editor.bundle_ids.is_empty(), "{}", editor.id);
        assert!(EDITORS[..index].iter().all(|other| other.id != editor.id), "{}", editor.id);
        for bundle in editor.bundle_ids {
            let owners = EDITORS.iter().filter(|other| other.bundle_ids.contains(bundle)).count();
            assert_eq!(owners, 1, "{bundle}");
        }
    }
    assert_eq!(by_id("cursor").map(|editor| editor.name), Some("Cursor"));
    assert!(by_id("auto").is_none());
}

#[test]
fn the_table_serializes_as_the_app_reads_it() {
    let row = serde_json::to_value(by_id("vscode").unwrap()).unwrap();
    assert_eq!(
        row,
        serde_json::json!({
            "id": "vscode", "name": "Visual Studio Code",
            "bundleIds": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            "symbol": "chevron.left.forwardslash.chevron.right", "remoteScheme": "vscode"
        })
    );
    assert!(serde_json::to_value(by_id("zed").unwrap()).unwrap().get("remoteScheme").is_none());
}
