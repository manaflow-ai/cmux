use super::*;
use crate::transcript::Item;

fn sample() -> Transcript {
    let mut t = Transcript::default();
    t.items = vec![
        Item::User { text: "Use your Bash tool twice".into(), steer: false, queued: false },
        Item::Thought { text: "I will run hostname then date.".into() },
        Item::Tool {
            id: "1".into(),
            title: "hostname".into(),
            kind: "execute".into(),
            status: "completed".into(),
            detail: "mac.local".into(),
        },
        Item::Permission {
            id: "p".into(),
            title: "date".into(),
            options: vec![],
            decided: Some("allow_once".into()),
            question: None,
        },
        Item::Tool {
            id: "2".into(),
            title: "date".into(),
            kind: "execute".into(),
            status: "completed".into(),
            detail: "Thu Sep 17".into(),
        },
        Item::Assistant { text: "done".into() },
        Item::TurnEnd { stop: "end_turn".into() },
        Item::User { text: "again".into(), steer: false, queued: false },
        Item::Assistant { text: "ok".into() },
    ];
    t.status = "ready".into();
    t
}

#[test]
fn transcript_blocks_share_a_left_margin() {
    let c = Chrome::dark();
    let mut t = sample();
    t.items.truncate(6);
    t.items.push(Item::User { text: "queued followup".into(), steer: false, queued: true });
    t.status = "running".into();
    let at = now_ms();
    t.user_at.insert(0, at);
    t.turn_times.push((0, at, None));
    for width in [40, 80, 120] {
        let rows = transcript_rows(&t, width, false, false, &std::collections::HashSet::new(), &c);
        for label in [
            "Use your Bash",
            "queued followup",
            "Thought",
            "Working for",
            "2 steps",
            "done",
            "Working (",
        ] {
            let row = rows
                .iter()
                .find(|r| r.text.trim_start_matches([' ', '❯', '⋯']).starts_with(label))
                .unwrap_or_else(|| panic!("missing {label}"));
            let shown = row.line.to_string();
            if !matches!(label, "Use your Bash" | "queued followup") {
                assert_eq!(
                    shown.find(label).map(|i| shown[..i].width()).unwrap_or(0),
                    0,
                    "width={width}: {shown:?}"
                );
                assert_eq!(
                    row.text.find(label).map(|i| row.text[..i].width()).unwrap_or(0),
                    0,
                    "copy and hit-test columns"
                );
            }
            if let Some(animated) = cache::animated_line(&t, row, &c) {
                if !matches!(label, "Use your Bash" | "queued followup") {
                    assert_eq!(animated.to_string().find(label), Some(0));
                }
                if label == "Working for" {
                    assert!(animated.to_string().contains("2 steps"));
                }
            }
        }
        let timestamp = rows.iter().find(|r| r.text.contains(&when_label(at))).unwrap();
        assert!(timestamp.text.starts_with(GUTTER));
        assert_eq!(timestamp.text.trim_start(), when_label(at));
        let tool = rows
            .iter()
            .find(|r| r.text.contains("hostname") && r.toggle == Some(Toggle::Item(2)))
            .unwrap();
        assert!(tool.text.starts_with("    "), "nested tools keep their indentation");
    }
}

#[test]
fn errors_render_as_a_notice_card() {
    let c = Chrome::dark();
    let mut t = Transcript::default();
    t.items.push(Item::User { text: "go".into(), steer: false, queued: false });
    t.items.push(Item::Error { text: "API error: model not found".into() });
    let rows = transcript_rows(&t, 60, false, false, &std::collections::HashSet::new(), &c);
    let lines: Vec<String> = rows
        .iter()
        .map(|r| r.line.spans.iter().map(|s| s.content.to_string()).collect::<String>())
        .collect();
    assert!(lines.iter().any(|l| l.starts_with("╭") && l.ends_with("╮")), "{lines:?}");
    assert!(lines.iter().any(|l| l.contains("✗ API error: model not found")), "{lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("╰") && l.ends_with("╯")), "{lines:?}");
    let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert!(text.iter().any(|l| l.contains("✗ API error")), "{text:?}");
}

#[test]
fn hierarchy_renders_and_collapses() {
    let c = Chrome::dark();
    let t = sample();
    let none = std::collections::HashSet::new();
    let rows = transcript_rows(&t, 80, false, false, &none, &c);
    let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert!(text.iter().any(|l| l.trim_start().starts_with("❯ Use your Bash")), "{text:?}");
    assert!(
        text.iter().any(|l| l.trim_start().starts_with("Worked") && l.ends_with("›")),
        "{text:?}"
    );
    assert!(!text.iter().any(|l| l.contains("Allowed  date")), "{text:?}");
    // Explicitly expand the first turn.
    let mut flipped = std::collections::HashSet::new();
    flipped.insert(Toggle::Turn(0));
    let rows = transcript_rows(&t, 80, false, false, &flipped, &c);
    let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert!(
        text.iter().any(|l| l.trim_start().starts_with("Worked") && l.ends_with("▾")),
        "{text:?}"
    );
    assert!(text.iter().any(|l| l.contains("Allowed  date")), "{text:?}");
    // Collapsing the work keeps the message and the final reply.
    let rows = transcript_rows(&t, 80, false, false, &none, &c);
    let text: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert!(
        text.iter().any(|l| l.trim_start().starts_with("Worked") && l.ends_with("›")),
        "{text:?}"
    );
    assert!(
        text.iter().any(|l| l.trim_start().starts_with("❯ Use your Bash tool twice")),
        "{text:?}"
    );
    assert!(text.iter().any(|l| l == &"done"), "{text:?}");
    assert!(!text.iter().any(|l| l.contains("thinking") || l.contains("hostname")), "{text:?}");
    assert!(text.iter().any(|l| l.trim_start().starts_with("❯ again")), "{text:?}");
    // The second turn has only a final reply, with no work to fold.
    assert_eq!(text.iter().filter(|l| l.trim_start().starts_with("Worked")).count(), 1, "{text:?}");
}
