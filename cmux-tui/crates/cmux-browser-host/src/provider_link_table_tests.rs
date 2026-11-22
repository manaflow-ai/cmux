//! The provider's tab table keeps one record per tab (`info`); the safety
//! checks read that record, never a hand-synced copy (umbrella audit P3).

use super::*;

fn announce(url: &str) -> TabAnnounce {
    TabAnnounce {
        target_id: "W".into(),
        engine: "webkit".into(),
        workspace: "w".into(),
        profile: "p".into(),
        url: url.into(),
        title: "A".into(),
        visible: true,
    }
}

/// An update of the tab record alone reaches the browser-page refusal (D1)
/// and the engine lookup.
#[test]
fn the_refusal_and_the_engine_read_the_tab_record() {
    let mut table = TabTable::default();
    table.announce(&announce("https://a.test/"));
    assert!(table.refusal("tab.info", "W").is_none());
    if let Some(tab) = table.info.iter_mut().find(|tab| tab.target_id == "W") {
        tab.url = "chrome://settings/passwords".into();
        tab.engine = "cef".into();
    }
    let refusal = table.refusal("tab.info", "W").expect("a browser page is refused");
    assert_eq!(refusal.error_name.as_deref(), Some(BROWSER_PAGE), "{refusal}");
    assert_eq!(table.engine("W").as_deref(), Some("cef"));
    table.forget("W");
    assert_eq!(table.engine("W"), None);
}
