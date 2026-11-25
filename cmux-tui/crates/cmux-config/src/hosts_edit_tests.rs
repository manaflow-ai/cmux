use serde_json::json;

use super::*;

/// A fresh folder of this test's own, removed when dropped.
struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!(
            "cmux-hosts-edit-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn add(label: &str, endpoints: &[&str]) -> HostEdit {
    HostEdit::Add {
        label: label.into(),
        endpoints: endpoints.iter().map(|e| (*e).to_owned()).collect(),
        icon: None,
    }
}

fn items(value: Value) -> Vec<Value> {
    value.as_array().cloned().unwrap()
}

#[test]
fn add_rename_set_endpoints_and_remove_change_one_host() {
    let list = apply(&[], &add("studio", &["studio.local"])).unwrap();
    assert_eq!(list, items(json!([{"label": "studio", "endpoints": ["studio.local"]}])));
    let list = apply(
        &list,
        &HostEdit::Add {
            label: "box".into(),
            endpoints: vec!["ssh://leo@10.0.0.2:2222".into()],
            icon: Some("server.rack".into()),
        },
    )
    .unwrap();
    assert_eq!(list[1]["icon"], "server.rack");
    let list = apply(&list, &HostEdit::Rename { from: "STUDIO".into(), to: "studio mini".into() })
        .unwrap();
    assert_eq!(list[0]["label"], "studio mini");
    // A case-only rename of the same host is allowed.
    let list = apply(&list, &HostEdit::Rename { from: "box".into(), to: "Box".into() }).unwrap();
    assert_eq!(list[1]["label"], "Box");
    let list = apply(
        &list,
        &HostEdit::SetEndpoints { label: "box".into(), endpoints: vec!["b1".into(), "b2".into()] },
    )
    .unwrap();
    assert_eq!(list[1]["endpoints"], json!(["b1", "b2"]));
    let list = apply(&list, &HostEdit::Remove { label: "studio mini".into() }).unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["label"], "Box");
}

#[test]
fn edits_keep_unknown_members_and_replace_a_single_endpoint() {
    let list = items(json!([{"label": "a", "endpoint": "a1", "note": "mine", "id": "x"}]));
    let list =
        apply(&list, &HostEdit::SetEndpoints { label: "a".into(), endpoints: vec!["a2".into()] })
            .unwrap();
    assert_eq!(list[0], json!({"label": "a", "endpoints": ["a2"], "note": "mine", "id": "x"}));
}

#[test]
fn bad_edits_are_refused_with_why() {
    let list =
        items(json!([{"label": "a", "endpoints": ["a"]}, {"label": "b", "endpoints": ["b"]}]));
    let refused = |edit: HostEdit| apply(&list, &edit).unwrap_err();
    assert!(refused(add("A", &["x"])).contains("already called"));
    assert!(refused(add(" ", &["x"])).contains("label"));
    assert!(refused(add("c", &[])).contains("endpoints"));
    assert!(refused(add("c", &["http://x"])).contains("not an ssh address"));
    assert!(refused(add("c", &["-oProxyCommand=x"])).contains("not an ssh address"));
    assert!(refused(HostEdit::Rename { from: "a".into(), to: "B".into() }).contains("already"));
    assert!(refused(HostEdit::Rename { from: "z".into(), to: "y".into() }).contains("no host"));
    assert!(refused(HostEdit::Remove { label: "z".into() }).contains("no host"));
    // A list with an entry that is not a host is fixed by hand first.
    let broken = items(json!([{"label": "a", "endpoints": ["a"]}, 7]));
    assert!(apply(&broken, &add("c", &["c"])).unwrap_err().contains("machines.hosts[1]"));
}

#[test]
fn the_file_keeps_its_comments_and_other_keys() {
    let dir = Scratch::new("comments");
    let path = dir.path().join("cmux-next.json");
    let original = "{\n  // my font\n  \"terminal\": { \"fontSize\": 13 },\n  \"machines\": { /* hosts */ \"hosts\": [] }\n}\n";
    std::fs::write(&path, original).unwrap();
    let hosts = edit_file(&path, None, &add("studio", &["studio.local"])).unwrap();
    assert_eq!(hosts.len(), 1);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("// my font"), "{text}");
    assert!(text.contains("/* hosts */"), "{text}");
    assert!(text.contains("\"fontSize\": 13"), "{text}");
    let root = crate::jsonc::parse(&text).unwrap();
    assert_eq!(root["machines"]["hosts"][0]["label"], "studio");
    let hosts = edit_file(&path, None, &HostEdit::Remove { label: "studio".into() }).unwrap();
    assert!(hosts.is_empty());
    assert!(std::fs::read_to_string(&path).unwrap().contains("// my font"));
}

#[test]
fn a_missing_file_starts_from_the_seed_and_a_refusal_writes_nothing() {
    let dir = Scratch::new("seed");
    let path = dir.path().join("cmux-next.json");
    let seed = dir.path().join("cmux.json");
    std::fs::write(&seed, "{ \"app\": { \"x\": 1 } }").unwrap();
    edit_file(&path, Some(&seed), &add("a", &["a"])).unwrap();
    let root = crate::jsonc::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(root["app"]["x"], 1);
    assert_eq!(root["machines"]["hosts"][0]["label"], "a");

    let empty = dir.path().join("fresh.json");
    edit_file(&empty, None, &add("b", &["b"])).unwrap();
    let before = std::fs::read_to_string(&empty).unwrap();
    assert!(edit_file(&empty, None, &add("B", &["b"])).is_err());
    assert_eq!(std::fs::read_to_string(&empty).unwrap(), before);
}
