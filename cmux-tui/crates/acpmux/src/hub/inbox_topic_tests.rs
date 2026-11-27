use super::*;

#[test]
fn surge_topics_group_runner_observations_across_hosts() {
    for name in ["vm-a", "vm-b"] {
        let text = format!(
            "WARN glaeda-gh on {name}: 7 job(s) on runner label ubuntu-24 queued with no runner past 8m"
        );
        assert_eq!(topic(None, &text, None, name), "topic:ops/runner-capacity/ubuntu-24");
    }
}

#[test]
fn surge_topics_select_the_explicit_thread_then_the_qualified_subject() {
    let notice = json!({"title":"PR #23 changed","host":"vm-a","links":[{"url":"https://github.com/Org/App/pull/23#discussion"}]});
    assert_eq!(topic(None, "", Some(&notice), "vm-a"), "topic:pr/org/app/23");
    assert_eq!(topic(None, "org/other#23", None, "vm-a"), "topic:pr/org/other/23");
    assert_eq!(topic(Some("topic:followup"), "", Some(&notice), "vm-a"), "topic:followup");
    assert_eq!(topic(None, "GOAL reduce-waits: done", None, "vm-a"), "topic:goal/reduce-waits");
    assert_eq!(
        topic(None, "disk healthy", Some(&json!({"host":"vm-a"})), "tool"),
        "topic:host/vm-a"
    );
}
