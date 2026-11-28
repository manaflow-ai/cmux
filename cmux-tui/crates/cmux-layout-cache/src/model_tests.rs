use super::*;

#[test]
fn unknown_fields_and_kinds_read() {
    let json = r#"{"version":1,"future":true,"windows":[{"id":"w","later":1,
            "panes":{"type":"leaf","pane_id":"p","kind":"hologram","frame":{"x":0,"y":0,"width":10,"height":10}}}]}"#;
    let c = LayoutCache::from_json(json).unwrap();
    assert_eq!(c.windows[0].panes.leaves()[0].kind, PaneKind::Other);
}

#[test]
fn a_malformed_tree_drops_only_its_window() {
    let json = r#"{"version":1,"windows":[
            {"id":"bad","panes":{"type":"split","axis":"h","fractions":[1],"children":[]}},
            {"id":"good"}]}"#;
    let c = LayoutCache::from_json(json).unwrap();
    assert_eq!(c.windows.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(), ["good"]);
}

#[test]
fn wrong_version_is_none() {
    assert!(LayoutCache::from_json(r#"{"version":2}"#).is_none());
    assert!(LayoutCache::from_json(r#"{}"#).is_some());
    assert!(LayoutCache::from_json("nonsense").is_none());
}
