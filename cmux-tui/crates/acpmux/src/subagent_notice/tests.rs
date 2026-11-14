use super::*;
use serde_json::json;

#[test]
fn a_notice_is_taken_once_and_a_stop_mark_stays() {
    let home = std::env::temp_dir().join(format!("subagent-notice-{}", uuid::Uuid::now_v7()));
    let dir = agent_dir(&home, "s/1", "a0a68e7af3df5967e").unwrap();
    assert!(dir.starts_with(home.join("run/subagent-notices/s_1")), "{dir:?}");
    assert_eq!(agent_dir(&home, "s1", "../x"), None, "no path from an id");
    assert_eq!(agent_dir(&home, "s1", ".."), None, "no path from an id");
    assert_eq!(agent_dir(&home, "s1", "."), None, "no path from an id");
    let path = leave(&dir, "lane-report-1", &json!({"text": "one"})).unwrap();
    leave(&dir, "lane-report-2", &json!({"text": "two"})).unwrap();
    assert_eq!(take(&path), Some(json!({"text": "one"})));
    assert_eq!(take(&path), None, "taken once");
    assert_eq!(take_all(&dir), vec![json!({"text": "two"})]);
    assert!(take_all(&dir).is_empty());
    assert_eq!(agents(&home, "s/1"), vec![(dir.clone(), false)]);
    mark_stopped(&dir).unwrap();
    assert!(stopped(&dir));
    assert_eq!(agents(&home, "s/1"), vec![(dir.clone(), true)]);
    let kept = leave(&dir, "lane-report-3", &json!({"text": "three"})).unwrap();
    tidy(&home, "s/1");
    assert_eq!(take(&kept), Some(json!({"text": "three"})), "tidy keeps a left notice");
    tidy(&home, "s/1");
    assert!(agents(&home, "s/1").is_empty());
    leave(&dir, "lane-report-4", &json!({"text": "four"})).unwrap();
    forget(&home, "s/1");
    assert!(agents(&home, "s/1").is_empty());
    let _ = std::fs::remove_dir_all(&home);
}
