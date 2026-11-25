use super::*;

#[test]
fn a_call_names_its_subagent_until_it_ends() {
    let home = std::env::temp_dir().join(format!("subagent-call-{}", uuid::Uuid::now_v7()));
    let sub = json!({"id": "a0a68e7af3df5967e", "type": "general-purpose"});
    record(&home, "s/1", "toolu_01a", "a0a68e7af3df5967e", "general-purpose").unwrap();
    record(&home, "s/1", "toolu_01b", "a0a68e7af3df5967e", "general-purpose").unwrap();
    record(&home, "s/1", "toolu_01c", "b1", "Explore").unwrap();
    assert!(record(&home, "s/1", "..", "a0", "general-purpose").is_err(), "no path");
    assert!(record(&home, "s/1", "toolu_01d", "a/0", "general-purpose").is_err(), "no path");
    let params = json!({"name": "send", "_meta": {TOOL_USE_ID_META: "toolu_01a"}});
    assert_eq!(of_call(&home, "s/1", &params), Some(sub.clone()));
    assert_eq!(of_call(&home, "s/1", &json!({"name": "send"})), None);
    assert_eq!(of(&home, "s/2", "toolu_01a"), None, "another session's call");
    end(&home, "s/1", "toolu_01a");
    assert_eq!(of(&home, "s/1", "toolu_01a"), None);
    assert_eq!(of(&home, "s/1", "toolu_01b"), Some(sub));
    end_agent(&home, "s/1", "a0a68e7af3df5967e");
    assert_eq!(of(&home, "s/1", "toolu_01b"), None);
    assert_eq!(of(&home, "s/1", "toolu_01c"), Some(json!({"id": "b1", "type": "Explore"})));
    forget(&home, "s/1");
    assert_eq!(of(&home, "s/1", "toolu_01c"), None);
    let _ = std::fs::remove_dir_all(&home);
}
