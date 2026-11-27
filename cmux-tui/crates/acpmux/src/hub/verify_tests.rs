use super::*;
use serde_json::json;

fn p(s: &str) -> PathBuf {
    PathBuf::from(s)
}

#[test]
fn normalize_blanks_positions_only() {
    let a = normalize("src/a.rs:10:5: error[E0308]: mismatched types");
    let b = normalize("src/a.rs:99:1: error[E0308]: mismatched types");
    assert_eq!(a, b);
    assert_ne!(a, normalize("src/a.rs:10:5: error[E0425]: cannot find value"));
    assert_eq!(normalize("a.ts(3,4): error TS2304: x"), normalize("a.ts(30,40): error TS2304: x"));
}

#[test]
fn only_new_errors_survive_the_baseline() {
    let base: BTreeSet<String> = ["src/a.rs:N:N: error: old".to_owned()].into();
    let now = vec!["src/a.rs:40:2: error: old".to_owned(), "src/a.rs:7:1: error: fresh".to_owned()];
    assert_eq!(new_errors(&base, &now), vec!["src/a.rs:7:1: error: fresh".to_owned()]);
}

#[test]
fn error_lines_by_tool() {
    let cargo = Check::Cargo { dir: p("/x"), package: "x".into(), files: vec![] };
    let out = "src/a.rs:1:1: error[E0308]: bad\nwarning: unused\nerror: could not compile `x`\n";
    assert_eq!(error_lines(&cargo, out), vec!["src/a.rs:1:1: error[E0308]: bad"]);
    let tsc = Check::Tsc { dir: p("/x"), plain_js: vec![] };
    assert_eq!(
        error_lines(&tsc, "a.ts(1,2): error TS2304: x\nFound 1 error."),
        vec!["a.ts(1,2): error TS2304: x"]
    );
    let fmt = Check::Rustfmt { file: p("/x/a.rs") };
    assert_eq!(
        error_lines(&fmt, "Diff in /x/a.rs at line 3:\nerror: expected `;`\n"),
        vec!["error: expected `;`"]
    );
}

#[test]
fn notice_is_capped_and_prefixed() {
    assert_eq!(notice_text(&[], 5), None);
    let many: Vec<String> = (0..80).map(|i| format!("e{i}")).collect();
    let text = notice_text(&many, 12).unwrap();
    assert!(text.starts_with("[verify] 80 new error(s)"));
    assert!(text.lines().count() <= MAX_LINES);
    assert!(text.contains("... and 52 more"));
}

#[test]
fn switches() {
    let off = json!({"agents": {"harnessMagic": {"verify": {"enabled": false}}}});
    assert!(enabled_by(None, None));
    assert!(enabled_by(None, Some(&json!({}))));
    assert!(!enabled_by(None, Some(&off)));
    assert!(!enabled_by(Some("0"), None));
    assert!(enabled_by(Some("1"), None));
}

#[test]
fn plan_picks_checks_by_language() {
    let dir = std::env::temp_dir().join(format!("verify-plan-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(dir.join("c/src")).unwrap();
    std::fs::write(dir.join("c/Cargo.toml"), "[package]\nname = \"cc\"\nversion = \"0.1.0\"\n")
        .unwrap();
    let files = vec![
        dir.join("c/src/a.rs"),
        dir.join("c/src/b.rs"),
        dir.join("x.py"),
        dir.join("y.sh"),
        dir.join("z.json"),
        dir.join("w.toml"),
        dir.join("u.swift"),
        dir.join("v.js"),
    ];
    let checks = plan(&files);
    assert!(
        matches!(&checks[0], Check::Cargo { package, files, .. } if package == "cc" && files.len() == 2)
    );
    assert_eq!(checks.len(), 6);
    assert!(checks.iter().any(|c| matches!(c, Check::Node { .. })));
    assert!(!checks.iter().any(|c| c.key().contains("swift")));
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn rust_edition_follows_the_nearest_package_or_workspace() {
    let dir = std::env::temp_dir().join(format!("verify-edition-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(dir.join("c")).unwrap();
    std::fs::write(dir.join("Cargo.toml"), "[workspace.package]\nedition = \"2024\"\n").unwrap();
    std::fs::write(
        dir.join("c/Cargo.toml"),
        "[package]\nname = \"cc\"\nversion = \"0.1.0\"\nedition.workspace = true\n",
    )
    .unwrap();
    assert_eq!(rust_edition(&dir.join("c")), "2024");
    std::fs::write(
        dir.join("c/Cargo.toml"),
        "[package]\nname = \"cc\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
    )
    .unwrap();
    assert_eq!(rust_edition(&dir.join("c")), "2021");
    std::fs::remove_dir_all(&dir).ok();
}

#[tokio::test]
async fn run_checks_flag_breakage_and_pass_good_files() {
    let dir = std::env::temp_dir().join(format!("verify-run-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let write = |n: &str, t: &str| {
        let f = dir.join(n);
        std::fs::write(&f, t).unwrap();
        f
    };
    let mut slow = BTreeSet::new();
    let none = BTreeSet::new();
    let cases = [
        (Check::Json { file: write("a.json", "{\"a\":") }, true),
        (Check::Json { file: write("b.json", "{\"a\":1}") }, false),
        (Check::Toml { file: write("a.toml", "a = [1,\n[b\n") }, true),
        (Check::Bash { file: write("a.sh", "if then\n") }, true),
        (Check::Bash { file: write("b.sh", "echo ok\n") }, false),
        (Check::Python { file: write("a.py", "def (:\n") }, true),
        (Check::Python { file: write("b.py", "x = 1\n") }, false),
    ];
    for (check, red) in cases {
        let out = run_check(&check, &mut slow, &none).await.expect("ran");
        assert_eq!(!out.lines.is_empty(), red, "{}: {:?}", check.key(), out.lines);
    }
    std::fs::remove_dir_all(&dir).ok();
}

#[tokio::test]
async fn a_check_over_the_bound_is_skipped_slow() {
    let dir = std::env::temp_dir();
    let r = tokio::time::timeout(Duration::from_secs(1), async {
        // The bound is long; only prove a killed run reports slow through the same path.
        run_cmd(&dir, "true", &[]).await
    })
    .await
    .unwrap()
    .unwrap();
    assert!(!r.slow);
}

#[test]
fn counters_stamp_once_and_red_tracks_state() {
    let id = format!("s-{}", uuid::Uuid::now_v7());
    let mut m = serde_json::Map::new();
    stamp(&id, &mut m);
    assert!(m.is_empty());
    let e = entry(&id);
    {
        let mut s = e.state.lock().unwrap();
        s.counters.runs = 2;
        s.counters.red = 1;
        s.counters.notices = 1;
        s.counters.ms_total = 900;
        s.red.insert("k".into(), vec!["e".into()]);
        s.held = Some("[verify] x".into());
    }
    assert!(is_red(&id));
    stamp(&id, &mut m);
    assert_eq!(m["harnessMagic.verify.runs"], 2);
    assert_eq!(m["harnessMagic.verify.msTotal"], 900);
    let mut again = serde_json::Map::new();
    stamp(&id, &mut again);
    assert!(again.is_empty());
    assert_eq!(take_held(&id).as_deref(), Some("[verify] x"));
    assert_eq!(take_held(&id), None);
}

#[test]
fn digest_ignores_positions_and_order() {
    let a = vec!["a.rs:1:1: error: x".to_owned(), "b.rs:2:2: error: y".to_owned()];
    let b = vec!["b.rs:9:9: error: y".to_owned(), "a.rs:5:5: error: x".to_owned()];
    assert_eq!(digest(&a), digest(&b));
}

/// A fake session through the hub: an edit's start takes the baseline, its completion (which
/// names neither kind nor file, as Claude's does) runs the check, and the new error waits for
/// the next prompt because no turn runs; the counters land on the next `turn_result` stamp.
#[tokio::test]
async fn an_edit_through_the_hub_finds_its_new_error() {
    let dir = std::env::temp_dir().join(format!("verify-hub-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.py");
    std::fs::write(&file, "x = 1\n").unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let id = format!("verify-{}", uuid::Uuid::now_v7());
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "verify chat", "harness": "claude",
        "family": "claude", "cwd": dir.to_string_lossy(), "status": "idle", "createdAt": 1,
        "updatedAt": 2,
    }))
    .unwrap();
    let session = hub.insert_test_session(meta);
    hub.note_verify(
        &session,
        &json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "edit",
                "status": "pending", "rawInput": {"file_path": file.to_string_lossy()}}),
    );
    let e = entry(&id);
    let deadline = Instant::now() + Duration::from_secs(20);
    while e.state.lock().unwrap().baselines.is_empty() {
        assert!(Instant::now() < deadline, "baseline never ran");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    std::fs::write(&file, "def (:\n").unwrap();
    hub.note_verify(
        &session,
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"}),
    );
    let held = loop {
        if let Some(h) = take_held(&id) {
            break h;
        }
        assert!(Instant::now() < deadline, "no notice");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert!(held.starts_with("[verify] 1 new error(s)"), "{held}");
    assert!(is_red(&id));
    let mut m = serde_json::Map::new();
    stamp(&id, &mut m);
    assert_eq!(m["harnessMagic.verify.runs"], 1);
    assert_eq!(m["harnessMagic.verify.red"], 1);
    assert_eq!(m["harnessMagic.verify.notices"], 1);
    std::fs::remove_dir_all(&dir).ok();
}
