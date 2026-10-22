//! A connection frame that took long names itself on stderr (the owner's
//! client log): the app saw 12-15 s owner stalls (2026-10-21: 23 `tab.update`
//! replies and a `list-workspaces` resync timed out) with nothing on the
//! daemon side saying which request held the connection. Only the frame's
//! name and its duration are written, never its arguments.

use std::time::Duration;

use serde_json::Value;

/// A frame this long is reported.
pub(super) const SLOW_FRAME: Duration = Duration::from_millis(500);

/// Longest name a report keeps.
const MAX_NAME: usize = 64;

/// The report line for a frame that took `took`, when that is at least
/// `threshold`: its wire name (a legacy `cmd`, a resource `operation`, or a
/// JSON-RPC `method`) and its duration in milliseconds.
pub(super) fn slow_frame_report(
    message: &str,
    took: Duration,
    threshold: Duration,
) -> Option<String> {
    if took < threshold {
        return None;
    }
    Some(format!("slow request {}: {} ms", frame_name(message), took.as_millis()))
}

/// The frame's wire name, kept to a short run of name characters so nothing
/// a caller sent beyond its name reaches the log.
fn frame_name(message: &str) -> String {
    let value = serde_json::from_str::<Value>(message).ok();
    let name = value.as_ref().and_then(|value| {
        ["cmd", "operation", "method"].iter().find_map(|key| value.get(key).and_then(Value::as_str))
    });
    let Some(name) = name else { return "(unnamed)".into() };
    let kept: String = name
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '/' | ':'))
        .take(MAX_NAME)
        .collect();
    if kept.is_empty() { "(unnamed)".into() } else { kept }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fast_frame_reports_nothing() {
        let line = r#"{"id":1,"cmd":"list-workspaces"}"#;
        assert_eq!(slow_frame_report(line, Duration::from_millis(40), SLOW_FRAME), None);
    }

    #[test]
    fn a_slow_legacy_command_names_its_cmd() {
        let line = r#"{"id":7,"cmd":"list-workspaces"}"#;
        assert_eq!(
            slow_frame_report(line, Duration::from_millis(10_250), SLOW_FRAME).as_deref(),
            Some("slow request list-workspaces: 10250 ms")
        );
    }

    #[test]
    fn a_slow_resource_operation_names_its_operation_and_not_its_params() {
        let line = r#"{"protocol":"cmux.resource/2","type":"request","id":"r1","operation":"tab.update","params":{"title":"secret token sk-123"}}"#;
        let report = slow_frame_report(line, Duration::from_millis(2_000), SLOW_FRAME).unwrap();
        assert_eq!(report, "slow request tab.update: 2000 ms");
        assert!(!report.contains("secret"));
    }

    #[test]
    fn a_name_is_cut_at_the_first_character_that_is_not_part_of_a_name() {
        let line = r#"{"cmd":"ping\nforged log line"}"#;
        assert_eq!(
            slow_frame_report(line, SLOW_FRAME, SLOW_FRAME).as_deref(),
            Some("slow request ping: 500 ms")
        );
    }

    #[test]
    fn a_line_without_a_name_is_unnamed() {
        assert_eq!(
            slow_frame_report("not json", SLOW_FRAME, SLOW_FRAME).as_deref(),
            Some("slow request (unnamed): 500 ms")
        );
    }
}
