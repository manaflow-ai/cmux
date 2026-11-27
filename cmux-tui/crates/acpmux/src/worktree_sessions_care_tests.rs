use super::*;

#[test]
fn care_a_stopped_daemon_s_sessions_are_use_not_open() {
    let home = std::env::temp_dir()
        .join(format!("care-sessions-{}", cmux_worktree_care::inventory::now_ms()));
    // The shared state folder of this home (`BuildIdentity` with no build).
    let state =
        cmux_agent_pane_policy::build_identity::BuildIdentity::new(None, None).acpmux_home(&home);
    let session = state.join("sessions/one");
    std::fs::create_dir_all(&session).unwrap();
    std::fs::write(
        session.join("session.json"),
        r#"{"name":"lane","cwd":"/w/a","status":"running","updatedAt":5}"#,
    )
    .unwrap();
    let found: Vec<_> = on_disk(&home, None).into_iter().filter(|s| s.name == "lane").collect();
    assert_eq!(found.len(), 1);
    assert!(!found[0].open, "no daemon answers there");
    assert_eq!(found[0].updated_ms, 5);
    let skipped = on_disk(&home, Some(&state));
    assert!(skipped.iter().all(|s| s.name != "lane"));
    let _ = std::fs::remove_dir_all(home);
}
