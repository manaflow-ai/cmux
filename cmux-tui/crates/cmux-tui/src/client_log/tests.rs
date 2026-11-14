use super::*;

#[test]
fn timestamps_are_iso_utc() {
    let stamp = timestamp();
    assert_eq!(stamp.len(), 20, "{stamp}");
    assert!(stamp.ends_with('Z'));
    assert_eq!(&stamp[4..5], "-");
    assert_eq!(&stamp[10..11], "T");
}

#[test]
fn sanitize_collapses_control_characters() {
    assert_eq!(sanitize("a\nb\x1b[31mc\t d "), "a b [31mc\t d");
}

#[cfg(unix)]
#[test]
fn log_file_is_created_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("cmux-tui-log-mode-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("client.log");
    let _ = fs::remove_file(&path);
    drop(append_options().open(&path).unwrap());
    let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    fs::remove_file(&path).unwrap();
    let _ = fs::remove_dir(&dir);
    assert_eq!(mode, 0o600, "log must not be readable by other users");
}

#[test]
fn oversized_messages_are_truncated_before_enqueue() {
    // Mirrors the cap logic in `log` (which needs a live queue): the
    // boundary walk must never split a multi-byte character.
    // One ASCII byte then 4-byte chars, so byte 4096 is mid-character
    // and the walk must step back to the previous boundary.
    let message = format!("a{}", "\u{1F600}".repeat(2000));
    let mut end = MAX_MESSAGE_BYTES;
    while !message.is_char_boundary(end) {
        end -= 1;
    }
    assert_eq!(end, 4093);
    assert!(message.is_char_boundary(end));
}

#[test]
fn rollover_appends_suffix() {
    assert_eq!(rollover_path(&PathBuf::from("/x/client.log")), PathBuf::from("/x/client.log.1"));
}
