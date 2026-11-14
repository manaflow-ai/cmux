use serde_json::json;

use super::EventMatch;

fn wait(until: Option<&str>, matches: &[&str]) -> EventMatch {
    match EventMatch::new("events", until, matches) {
        Ok(Some(wait)) => wait,
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_name_matches_exactly_or_by_a_star_prefix() {
    let event = json!({"name": "workspace.created"});
    assert!(wait(Some("workspace.created"), &[]).matches(Some("workspace.created"), &event));
    assert!(!wait(Some("workspace.create"), &[]).matches(Some("workspace.created"), &event));
    assert!(wait(Some("workspace.*"), &[]).matches(Some("workspace.created"), &event));
    assert!(wait(Some("*"), &[]).matches(Some("anything"), &event));
    assert!(!wait(Some("tab.*"), &[]).matches(Some("workspace.created"), &event));
    assert!(!wait(Some("workspace.*"), &[]).matches(None, &event));
}

#[test]
fn fields_match_by_dotted_path_and_every_one_must_hold() {
    let event = json!({
        "workspace_id": "ws_1",
        "payload": {"state": "idle", "count": 3, "ok": true, "gone": null, "ids": ["a", "b"]},
    });
    let hits = [
        "workspace_id=ws_1",
        "payload.state=idle",
        "payload.count=3",
        "payload.ok=true",
        "payload.gone=null",
        "payload.ids.1=b",
    ];
    for one in hits {
        assert!(wait(None, &[one]).matches(None, &event), "{one}");
    }
    assert!(wait(None, &hits).matches(None, &event));
    for miss in ["workspace_id=ws_2", "payload.state.deeper=x", "payload.ids.9=a", "nope=1"] {
        assert!(!wait(None, &[miss]).matches(None, &event), "{miss}");
    }
    assert!(!wait(None, &["workspace_id=ws_1", "payload.state=busy"]).matches(None, &event));
    // An empty value matches an empty string.
    assert!(wait(None, &["e="]).matches(None, &json!({"e": ""})));
}

#[test]
fn bad_flags_name_the_form_they_take() {
    assert_eq!(EventMatch::new("events", None, &[]).ok(), Some(None));
    for (until, matches) in
        [(Some(""), vec![]), (Some("a*b"), vec![]), (None, vec!["noequals"]), (None, vec![".a=1"])]
    {
        let error = EventMatch::new("events", until, &matches).err().map(|error| error.0);
        assert!(error.as_deref().is_some_and(|text| text.starts_with("events: --")), "{error:?}");
    }
}

#[test]
fn describe_says_what_the_wait_was_for() {
    let wait = wait(Some("workspace.*"), &["payload.state=idle"]);
    assert_eq!(wait.describe(), json!({"name": "workspace.*", "match": {"payload.state": "idle"}}));
}
