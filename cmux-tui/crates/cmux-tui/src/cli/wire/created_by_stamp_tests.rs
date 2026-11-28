use super::*;

#[test]
fn a_creator_line_names_the_session_host_and_purpose() {
    let agent = json!({"kind": "agent", "session": "0123456789", "session_name": "desktop-helper",
                       "host": "studio-mac", "purpose": "Demo project"});
    assert_eq!(creator_line(&agent).as_deref(), Some("desktop-helper@studio-mac: Demo project"));
    let nameless = json!({"kind": "agent", "session": "0123456789"});
    assert_eq!(creator_line(&nameless).as_deref(), Some("01234567"));
    let script = json!({"kind": "script", "workspace": "ws_a", "purpose": "flow check"});
    assert_eq!(creator_line(&script).as_deref(), Some("script: flow check"));
    assert_eq!(creator_line(&json!({"kind": "person"})), None);
    assert_eq!(creator_line(&json!({"kind": "script", "workspace": "ws_a"})), None);
}

fn facts() -> SessionFacts {
    SessionFacts {
        name: Some("desktop-helper".into()),
        title: Some("Demo project for the weather widget\nand more".into()),
        host: Some("studio-mac".into()),
    }
}

fn create(operation: &str, params: Value) -> Value {
    json!({"operation": operation, "params": params})
}

#[test]
fn an_agent_create_names_its_session_host_and_title() {
    for operation in CREATES {
        let mut request = create(operation, json!({"name": "x"}));
        assert!(stamp_with(&mut request, "s-1", facts));
        assert_eq!(
            request["params"]["created_by"],
            json!({"kind": "agent", "session": "s-1", "session_name": "desktop-helper",
                   "host": "studio-mac", "purpose": "Demo project for the weather widget"}),
            "{operation}"
        );
    }
}

#[test]
fn a_given_purpose_wins_and_a_script_stamp_becomes_the_agent() {
    let mut request = create(
        "workspace.create",
        json!({"created_by": {"kind": "script", "workspace": "ws_a", "purpose": "flow check"}}),
    );
    assert!(stamp_with(&mut request, "s-1", facts));
    let by = &request["params"]["created_by"];
    assert_eq!(by["kind"], "agent");
    assert_eq!(by["workspace"], "ws_a");
    assert_eq!(by["purpose"], "flow check");
}

#[test]
fn a_person_and_other_operations_get_nothing() {
    let mut person = create("workspace.create", json!({"created_by": {"kind": "person"}}));
    assert!(!stamp_with(&mut person, "s-1", facts));
    assert_eq!(person["params"]["created_by"], json!({"kind": "person"}));
    let mut list = create("workspace.list", json!({}));
    assert!(!stamp_with(&mut list, "s-1", facts));
    assert!(list["params"].get("created_by").is_none());
}

#[test]
fn no_facts_still_names_the_session() {
    let mut request = create("tab.create_terminal", json!({}));
    assert!(stamp_with(&mut request, "s-9", SessionFacts::default));
    assert_eq!(request["params"]["created_by"], json!({"kind": "agent", "session": "s-9"}));
}
