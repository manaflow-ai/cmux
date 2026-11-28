use super::*;

fn line(cloud: Cloud, reason: Option<&str>, at: u64) -> String {
    show_line(cloud, "s1", reason, Some("vm-1"), at).to_string()
}

#[test]
fn newest_show_wins_since_its_state_began() {
    let log = [
        "hybrid start step: gate 3 ms".to_owned(),
        r#"{"plan":"pro"}"#.to_owned(),
        line(Cloud::Booting, None, 100),
        line(Cloud::Ready, None, 200),
        line(Cloud::Ready, None, 250),
        line(Cloud::Moving, None, 300),
    ]
    .join("\n");
    let start = newest(&log).unwrap();
    assert_eq!(
        start,
        Start { cloud: Cloud::Moving, reason: None, since_ms: Some(300), readiness: Some(100) }
    );
    let ready = newest(&log.lines().take(5).collect::<Vec<_>>().join("\n")).unwrap();
    assert_eq!(ready.since_ms, Some(200), "a repeated Show keeps when its state began");
    assert_eq!(
        serde_json::to_value(start).unwrap(),
        json!({"cloud": "moving", "sinceMs": 300, "readiness": 100})
    );
}

#[test]
fn failed_carries_its_reason() {
    let log = [line(Cloud::Booting, None, 1), line(Cloud::Failed, Some("quota"), 2)].join("\n");
    let start = newest(&log).unwrap();
    assert_eq!(start.cloud, Cloud::Failed);
    assert_eq!(start.reason.as_deref(), Some("quota"));
    assert_eq!(
        serde_json::to_value(start).unwrap(),
        json!({"cloud": "failed", "reason": "quota", "sinceMs": 2})
    );
}

#[test]
fn readiness_rides_the_show_line_and_never_goes_down() {
    let booting = newest(&line(Cloud::Booting, None, 1)).unwrap();
    assert_eq!(booting.readiness, Some(crate::hybrid_tools::BOOTING));
    assert_eq!(serde_json::to_value(&booting).unwrap()["readiness"], 5);
    // A line that carries more (a boot mark), then a lower one: the higher stands.
    let more = line(Cloud::Booting, None, 2).replace("\"readiness\":5", "\"readiness\":50");
    let log = [line(Cloud::Booting, None, 1), more, line(Cloud::Booting, None, 3)].join("\n");
    assert_eq!(newest(&log).unwrap().readiness, Some(50));
    // A line from before readiness was written reads as its stage's.
    let old = r#"{"show":{"cloud":"ready","session":"s1","at":4}}"#;
    assert_eq!(newest(old).unwrap().readiness, Some(100));
    let failed = [line(Cloud::Booting, None, 1), line(Cloud::Failed, Some("quota"), 2)];
    assert_eq!(newest(&failed.join("\n")).unwrap().readiness, None);
}

#[test]
fn no_show_is_no_start() {
    assert_eq!(newest(""), None);
    assert_eq!(newest("hybrid start step: gate 3 ms\n{\"plan\":null}\n"), None);
    assert_eq!(newest(&line(Cloud::None, None, 1)), None);
}

#[test]
fn torn_or_junk_last_line_leaves_the_show_before() {
    let ready = line(Cloud::Ready, None, 5);
    let moving = line(Cloud::Moving, None, 6);
    let torn = format!("{ready}\n{}", &moving[..moving.len() / 2]);
    assert_eq!(newest(&torn).unwrap().cloud, Cloud::Ready);
    let junk = format!("{ready}\n\u{0}garbage{{\n");
    assert_eq!(newest(&junk).unwrap().cloud, Cloud::Ready);
    let wrong = format!("{ready}\n{{\"show\":{{\"cloud\":\"sideways\"}}}}\n");
    assert_eq!(newest(&wrong).unwrap().cloud, Cloud::Ready);
}

#[test]
fn live_stays_live() {
    let log = [line(Cloud::Live, None, 9), line(Cloud::Failed, Some("late"), 10)].join("\n");
    assert_eq!(
        newest(&log).unwrap(),
        Start { cloud: Cloud::Live, reason: None, since_ms: Some(9), readiness: Some(100) }
    );
}

#[test]
fn paths_sit_beside_the_sessions_folder() {
    let sessions = Path::new("/state/cmux-tui/sessions");
    assert_eq!(log_file(sessions, "a/b c"), Path::new("/state/cmux-tui/hybrid-start/a-b-c.log"));
    assert_eq!(show_file(sessions, "s1"), Path::new("/state/cmux-tui/hybrid-start/s1.show"));
}
