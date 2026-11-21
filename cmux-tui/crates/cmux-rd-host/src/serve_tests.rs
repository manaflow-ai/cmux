use super::*;

#[test]
fn clipboard_sync_is_off_unless_the_setup_turns_it_on() {
    let base =
        r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"control"}"#;
    let off: Setup = serde_json::from_str(base).expect("setup");
    assert!(!off.clipboard);
    let on = r#"{"session":"s","peer_key":"00","viewer":{"user":"u","install":"i"},"scope":"control","clipboard":true}"#;
    let on: Setup = serde_json::from_str(on).expect("setup");
    assert!(on.clipboard);
}

/// A writer that keeps what reached it only at a flush, as a pipe's reader sees it.
#[derive(Default)]
struct Piped {
    pending: Vec<u8>,
    flushed: Vec<u8>,
}

impl Write for Piped {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flushed.append(&mut self.pending);
        Ok(())
    }
}

#[test]
fn every_app_line_reaches_the_pipe_whole_and_flushed() {
    let mut out = Piped::default();
    let lines = [
        AppLine { displays: Some(vec![(1920, 1080)]), current: Some(0), ..AppLine::default() },
        AppLine { key: Some("ab".repeat(32)), ..AppLine::default() },
        AppLine { candidate: Some("host 192.168.1.4:51000".into()), ..AppLine::default() },
        AppLine { candidates_done: true, ..AppLine::default() },
    ];
    for (i, line) in lines.iter().enumerate() {
        write_line(&mut out, line).unwrap();
        // Nothing waits in a buffer: the reader has every line so far, each ended by one newline.
        assert!(out.pending.is_empty());
        let read: Vec<&[u8]> =
            out.flushed.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect();
        assert_eq!(read.len(), i + 1);
        assert_eq!(AppLine::decode(read[i]).as_ref(), Some(line));
    }
    assert_eq!(out.flushed.last(), Some(&b'\n'));
}

#[test]
fn portal_sessions_control_only_with_a_remote_desktop_grant() {
    // Without the grant the portal drops input: a control session there would not be one.
    let x11 = CaptureBackend::X11.applies_input_with(false);
    assert!(view_only_for("view", x11).unwrap());
    assert!(!view_only_for("control", x11).unwrap());
    let portal = CaptureBackend::Portal.applies_input_with(false);
    assert!(view_only_for("view", portal).unwrap());
    assert!(view_only_for("control", portal).unwrap());
    let granted = CaptureBackend::Portal.applies_input_with(true);
    assert!(view_only_for("view", granted).unwrap());
    assert!(!view_only_for("control", granted).unwrap());
    assert!(view_only_for("full", x11).is_err());
}

#[test]
fn a_lan_path_starts_at_the_lan_bitrate() {
    assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 50_000), 30_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("lan"), None, 50_000), 30_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("link"), None, 50_000), 30_000);
    // A peer learned in the handshake is classed WAN; a sub-5 ms round trip is LAN.
    assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(1_200), 50_000), 30_000);
    assert_eq!(default_start_kbps(None, None, Some(4_999), 50_000), 30_000);
}

#[test]
fn other_paths_keep_the_old_start_and_max_caps_both() {
    assert_eq!(default_start_kbps(None, None, None, 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), Some("routed"), Some(5_000), 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_wan"), None, Some(40_000), 50_000), 8_000);
    // A relay is never LAN, whatever its round trip.
    assert_eq!(default_start_kbps(Some("turn_relay"), Some("lan"), Some(1_000), 50_000), 8_000);
    assert_eq!(default_start_kbps(Some("direct_lan"), None, None, 20_000), 20_000);
    assert_eq!(default_start_kbps(None, None, None, 4_000), 4_000);
}

#[test]
fn later_lines_carry_the_excluded_windows() {
    let later: Later = serde_json::from_str(r#"{"exclude_windows":[123,456]}"#).unwrap();
    assert_eq!(later.exclude_windows, Some(vec![123, 456]));
    assert!(!later.stop && later.candidate.is_none());
    let emptied: Later = serde_json::from_str(r#"{"exclude_windows":[]}"#).unwrap();
    assert_eq!(emptied.exclude_windows, Some(Vec::new()));
    let stop: Later = serde_json::from_str(r#"{"stop":true}"#).unwrap();
    assert_eq!(stop.exclude_windows, None);
}
