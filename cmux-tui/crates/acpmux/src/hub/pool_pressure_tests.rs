use super::*;

fn doc(level: &str, at: f64, room: bool) -> Value {
    json!({"at": at, "pool": {}, "pressure": {
        "level": level, "why": "claude 1/209 usable", "codex_room": room, "codex": "30/47"}})
}

#[test]
fn reads_the_verdict_sr2_pool_wrote_and_drops_a_stale_or_ok_one() {
    let now = 1_000_000.0;
    let shed = parse(&doc("shed", now - 30.0, true), now).unwrap();
    assert_eq!(shed.level, Level::Shed);
    assert!(shed.codex_room);
    assert_eq!(shed.codex.as_deref(), Some("30/47"));
    assert_eq!(parse(&doc("tight", now, false), now).unwrap().level, Level::Tight);
    assert_eq!(parse(&doc("ok", now, true), now), None);
    assert_eq!(parse(&doc("shed", now - 601.0, true), now), None, "stale: no pressure");
    assert_eq!(parse(&json!({"at": now, "pool": {}}), now), None, "an older sr2_pool");
}

#[test]
fn reads_the_cache_file() {
    let dir = std::env::temp_dir().join(format!("acpmux-pool-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("health.json");
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    std::fs::write(&path, doc("shed", now, true).to_string()).unwrap();
    assert_eq!(read_at(&path).map(|p| p.level), Some(Level::Shed));
    std::fs::write(&path, b"{\"at\":").unwrap();
    assert_eq!(read_at(&path), None, "a torn file is no pressure");
    assert_eq!(read_at(&dir.join("missing.json")), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_warning_suggests_codex_only_when_it_has_room() {
    let now = 5.0;
    let room = parse(&doc("tight", now, true), now).unwrap();
    let text = warning(&room);
    assert!(text.contains("Claude is tight (claude 1/209 usable)"), "{text}");
    assert!(text.contains("acpmux new -m codex") && text.contains("30/47"), "{text}");
    assert!(text.contains("started on Claude as asked"), "never a refusal: {text}");
    let none = parse(&doc("shed", now, false), now).unwrap();
    assert!(!warning(&none).contains("codex"), "{}", warning(&none));
    assert_eq!(
        field(&room),
        json!({"level": "tight", "why": "claude 1/209 usable", "codexRoom": true})
    );
}

#[test]
fn only_background_work_sleeps_sooner_and_only_while_the_pool_sheds() {
    let now = 5.0;
    let shed = parse(&doc("shed", now, true), now);
    let tight = parse(&doc("tight", now, true), now);
    use crate::subrouter_priority::{BACKGROUND, INTERACTIVE};
    assert!(sleeps_sooner(shed.as_ref(), BACKGROUND));
    assert!(!sleeps_sooner(shed.as_ref(), INTERACTIVE), "person, coordinator, Chief: never");
    assert!(!sleeps_sooner(tight.as_ref(), BACKGROUND), "tight only warns");
    assert!(!sleeps_sooner(None, BACKGROUND));
    assert!(is_claude("claude") && is_claude("claude-sr2") && !is_claude("codex"));
}
