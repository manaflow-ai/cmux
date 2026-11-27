use super::*;
use serde_json::json;

fn file(entries: serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(&json!({ "spares": entries })).unwrap()
}

#[test]
fn the_shapes_are_the_newest_four_of_the_last_week() {
    let day = 24 * 3600 * 1000;
    let now = 30 * day;
    let bytes = file(json!([
        {"harness": "claude", "cwd": "/a", "usedAtMs": now - day},
        {"harness": "codex", "cwd": "/a", "model": "gpt-5.5", "usedAtMs": now - 10},
        {"harness": "old", "cwd": "/a", "usedAtMs": now - 8 * day},
        {"harness": "a", "cwd": "/a", "usedAtMs": now - 2 * day},
        {"harness": "b", "cwd": "/a", "preset": "fast", "usedAtMs": now - 3 * day},
        {"harness": "c", "cwd": "/a", "usedAtMs": now - 4 * day},
    ]));
    let got = shapes(&bytes, now);
    let names: Vec<&str> = got.iter().map(|s| s.harness.as_str()).collect();
    assert_eq!(names, ["codex", "claude", "a", "b"]);
    assert_eq!(got[0].model.as_deref(), Some("gpt-5.5"));
    assert_eq!(got[3].preset.as_deref(), Some("fast"));
    assert!(shapes(b"not json", now).is_empty());
}

#[test]
fn warm_home_without_given_shapes_sends_the_recent_ones() {
    let dir = std::env::temp_dir().join(format!("spare-shapes-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let now = 1_000_000_000;
    std::fs::write(
        dir.join(FILE),
        file(json!([
            {"harness": "codex", "cwd": "/w", "model": "gpt-5.5", "usedAtMs": now - 5},
            {"harness": "claude", "cwd": "/w", "usedAtMs": now - 9},
        ])),
    )
    .unwrap();
    let on = warm_home_command(&read(&dir, now, None));
    assert!(
        on.contains("warm-home --wait --shape 'codex:gpt-5.5' --shape 'claude' 2>/dev/null"),
        "{on}"
    );
    let off = warm_home_command(&read(&dir, now, Some("0")));
    assert!(off.contains("warm-home --wait 2>/dev/null"), "{off}");
    assert!(read(&dir.join("missing"), now, None).is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_shape_warm_home_would_refuse_is_left_out_and_quoting_holds() {
    let s = |h: &str, m: Option<&str>| Shape {
        harness: h.into(),
        preset: None,
        model: m.map(Into::into),
    };
    let cmd =
        warm_home_command(&[s("bad id;rm", None), s("codex", Some("it's")), s("x", Some("a\nb"))]);
    assert!(cmd.contains("--shape 'codex:it'\\''s' 2>/dev/null"), "{cmd}");
    assert!(!cmd.contains("bad id") && !cmd.contains("'x"), "{cmd}");
    assert!(enabled(None) && enabled(Some("1")) && !enabled(Some(" Off ")));
}
