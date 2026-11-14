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

#[test]
fn only_a_sender_on_another_machine_crosses_machines() {
    let own = crate::pairing::machine_name();
    assert_eq!(other_machine("lane-1/perf"), Some("lane-1"));
    assert_eq!(other_machine(&format!("{own}/perf")), None);
    assert_eq!(other_machine("local/perf"), None);
    assert_eq!(other_machine("perf"), None);
    assert_eq!(other_machine("lane-1/"), None);
}
