use super::*;

#[test]
fn zone_names_come_from_the_zoneinfo_link() {
    assert_eq!(
        zone_from_path("/var/db/timezone/zoneinfo/America/Los_Angeles").as_deref(),
        Some("America/Los_Angeles")
    );
    assert_eq!(zone_from_path("/usr/share/zoneinfo/UTC").as_deref(), Some("UTC"));
    assert_eq!(zone_from_path("/etc/elsewhere"), None);
}

#[test]
fn the_default_active_chief_is_picked() {
    let list = json!({"chiefs": [
            {"id": "agent_OLD", "is_default": true, "archived_at": 5, "main_conversation": "c_old"},
            {"id": "agent_A", "is_default": false, "archived_at": null, "main_conversation": "c_a"},
            {"id": "agent_B", "is_default": true, "archived_at": null, "main_conversation": "c_b"},
        ], "tombstones": []});
    assert_eq!(default_chief(&list), Some(("agent_B".into(), "c_b".into())));
    let no_default =
        json!({"chiefs": [{"id": "agent_A", "is_default": false, "main_conversation": "c_a"}]});
    assert_eq!(default_chief(&no_default), Some(("agent_A".into(), "c_a".into())));
    assert_eq!(default_chief(&json!({"chiefs": []})), None);
}

#[test]
fn create_params_make_a_chief_job_with_a_manual_trigger() {
    let p = create_params(
        "Morning brief",
        "Summarize PRs",
        &CloudSchedule::Cron { expr: "0 9 * * 1-5".into(), tz: "America/Los_Angeles".into() },
        &("agent_B".into(), "c_b".into()),
        false,
    );
    assert_eq!(
        p["body"],
        json!({"type": "chief", "chief": "agent_B", "conversation": "c_b", "prompt": "Summarize PRs"})
    );
    assert_eq!(
        p["triggers"],
        json!([{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, {"type": "manual"}])
    );
    assert_eq!(p["enabled"], json!(true));
    assert_eq!(CloudSchedule::Manual.triggers(), json!([{"type": "manual"}]));
}
