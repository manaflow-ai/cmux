use super::*;

#[test]
fn timestamps() {
    assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(parse_rfc3339("2026-11-23T09:42:00.123Z"), Some(1_795_426_920_123));
    assert_eq!(parse_rfc3339("2026-11-23T10:42:00.123+01:00"), Some(1_795_426_920_123));
    assert_eq!(parse_rfc3339("2000-02-29T00:00:00.5Z"), Some(951_782_400_500));
    assert_eq!(parse_rfc3339("2026-11-23"), None);
    assert_eq!(parse_rfc3339("2026-13-23T09:42:00Z"), None);
}

#[test]
fn what_starts_a_turn() {
    let yes = [
        r#"{"type":"user","message":{"role":"user","content":"fix the build"},"timestamp":"2026-11-23T09:42:00.000Z"}"#,
        r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix it"}]},"isSidechain":false}"#,
        r#"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}}]}}"#,
        r#"{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
        r#"{"type":"user","message":{"role":"user","content":"say \"type\":\"tool_result\" back"}}"#,
    ];
    let no = [
        r#"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"ok"}]},"toolUseResult":{}}"#,
        r#"{"type":"user","message":{"role":"user","content":"x"},"isMeta":true}"#,
        r#"{"type":"user","message":{"role":"user","content":"x"},"isSidechain":true}"#,
        r#"{"type":"user","message":{"role":"user","content":"This session is being continued"},"isCompactSummary":true,"isVisibleInTranscriptOnly":true}"#,
        r#"{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
        r#"{"type":"user","message":{"role":"user","content":"done"},"origin":{"kind":"task-notification"}}"#,
        r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}"#,
        r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
        r#"{"type":"last-prompt","lastPrompt":"fix the build"}"#,
        r#"{"type":"user","message":{"role":"user","content":[]}}"#,
        "not json \"type\":\"user\"",
    ];
    for l in yes {
        assert!(starts_turn(l.as_bytes()), "{l}");
    }
    for l in no {
        assert!(!starts_turn(l.as_bytes()), "{l}");
    }
}
