use super::*;

#[test]
fn instructions_before_source_before_deps() {
    let mut v = vec![
        Entry { path: "node_modules/x/index.js".into(), size: 100, age_secs: None },
        Entry { path: "src/a/b/c.rs".into(), size: 100, age_secs: None },
        Entry { path: "AGENTS.md".into(), size: 100, age_secs: None },
    ];
    fill_order(&mut v);
    assert_eq!(v[0].path, "AGENTS.md");
    assert_eq!(v[2].path, "node_modules/x/index.js");
}
