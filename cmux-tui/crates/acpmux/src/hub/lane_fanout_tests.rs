use super::*;

fn row(id: &str, parent: Option<&str>, live: bool) -> Row {
    Row { id: id.into(), parent: parent.map(Into::into), live }
}

fn links(rows: &[Row]) -> HashMap<String, Option<String>> {
    rows.iter().map(|r| (r.id.clone(), r.parent.clone())).collect()
}

#[test]
fn a_lane_is_the_top_of_the_walk_or_a_parent_held_elsewhere() {
    let rows = [row("root", None, true), row("a", Some("root"), true), row("b", Some("a"), true)];
    assert_eq!(lane_of(&links(&rows), "b"), "root");
    assert_eq!(lane_of(&links(&rows), "root"), "root");
    let remote = [row("x", Some("peer-session"), true), row("y", Some("x"), true)];
    assert_eq!(lane_of(&links(&remote), "y"), "peer-session");
    let looped = [row("p", Some("q"), true), row("q", Some("p"), true)];
    let _ = lane_of(&links(&looped), "p"); // ends
}

#[test]
fn the_count_is_the_lanes_live_descendants_and_its_open_creates() {
    let rows = [
        row("root", None, true),
        row("a", Some("root"), true),
        row("b", Some("a"), true),
        row("c", Some("a"), false),
        row("other", None, true),
        row("d", Some("other"), true),
    ];
    assert_eq!(count(&rows, &[], "root"), 2, "root itself and the closed one do not count");
    let open = Making::for_lane(Some("root".into()));
    let made = Making::for_lane(Some("root".into()));
    made.set_made("b");
    let elsewhere = Making::for_lane(Some("other".into()));
    let open = [Arc::new(open), Arc::new(made), Arc::new(elsewhere)];
    assert_eq!(
        count(&rows, &open, "root"),
        3,
        "a create is counted once, as its session once it runs"
    );
}

#[test]
fn the_limit_reads_env_then_settings_within_the_ceiling() {
    assert_eq!(max_from(None, None), (DEFAULT_MAX, "default"));
    assert_eq!(max_from(None, Some(5)), (5, "settings"));
    assert_eq!(max_from(Some("7"), Some(5)), (7, "env"));
    assert_eq!(max_from(Some("0"), None), (1, "env"));
    assert_eq!(max_from(Some("99999"), None), (CEILING, "env"));
    assert_eq!(max_from(Some("nope"), Some(5)), (5, "settings"));
}

#[test]
fn the_refusal_names_reason_next_step_and_override() {
    let e = refusal("root", 32, 32, "default");
    let text = format!("{e:?}");
    assert!(text.contains(REASON));
    assert!(text.contains("close or hibernate"));
    assert!(text.contains("--force-admit"));
    assert!(Lane { id: "r".into(), live: 32, max: 32, source: "default" }.over());
    assert!(!Lane { id: "r".into(), live: 31, max: 32, source: "default" }.over());
}
