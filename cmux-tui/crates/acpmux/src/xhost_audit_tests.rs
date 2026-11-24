use super::*;

#[test]
fn a_prompts_fields_name_its_target_sender_and_size_never_its_text() {
    let params = json!({"request": {"sessionId": "lane-2/chat", "prompt": [{"type": "text", "text": "hello"}],
        "_meta": {"acpmux": {"fromAgent": "lane-1/perf", "promptId": "p-1"}}}});
    let fields = prompt_fields(&params);
    assert_eq!(
        fields,
        json!({"to": "lane-2/chat", "from": "lane-1/perf", "promptId": "p-1", "bytes": 5})
    );
    assert!(!fields.to_string().contains("hello"));
}

#[cfg(unix)]
#[test]
fn a_wider_log_is_narrowed_to_the_owner_and_a_link_is_never_followed() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("amx-xa-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let log = dir.join(FILE);
    std::fs::write(&log, "").unwrap();
    std::fs::set_permissions(&log, std::fs::Permissions::from_mode(0o644)).unwrap();
    append_to(&log, &json!({"dir": "sent"})).unwrap();
    assert_eq!(std::fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
    std::fs::remove_file(&log).unwrap();
    let elsewhere = dir.join("elsewhere");
    std::fs::write(&elsewhere, "").unwrap();
    std::os::unix::fs::symlink(&elsewhere, &log).unwrap();
    assert!(append_to(&log, &json!({"dir": "sent"})).is_err());
    assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), "");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The log stays under two caps' worth however many messages cross: past its cap it moves to
/// its previous copy, the one before that goes.
#[cfg(unix)]
#[test]
fn the_log_is_cut_past_its_cap_and_keeps_its_previous_copy() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("amx-xa-cap-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let log = dir.join(FILE);
    let line = json!({"dir": "sent", "to": "lane-2/chat", "from": "lane-1/perf", "bytes": 5});
    let cap = 4096;
    for _ in 0..2000 {
        append_capped(&log, &line, cap).unwrap();
    }
    let len = |p: &std::path::Path| std::fs::metadata(p).map_or(0, |m| m.len());
    let one = line.to_string().len() as u64 + 1;
    assert!(len(&log) <= cap + one, "{}", len(&log));
    assert!(len(&previous(&log)) <= cap + one, "{}", len(&previous(&log)));
    assert_eq!(
        std::fs::read_dir(&dir).unwrap().count(),
        2,
        "the log and one previous copy, nothing else"
    );
    let lines = read_at(&log);
    assert!(lines.len() as u64 > cap / one, "{}", lines.len());
    assert_eq!(std::fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn only_a_sender_on_another_machine_crosses_machines() {
    let own = crate::pairing::machine_name();
    assert_eq!(other_machine("lane-1/perf"), Some("lane-1"));
    assert_eq!(other_machine(&format!("{own}/perf")), None);
    assert_eq!(other_machine("local/perf"), None);
    assert_eq!(other_machine("perf"), None);
    assert_eq!(other_machine("lane-1/"), None);
}
