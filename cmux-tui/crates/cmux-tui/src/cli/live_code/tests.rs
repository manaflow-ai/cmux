use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn verbs_parse_with_their_flags() {
    assert_eq!(parse(&words("status")), Ok(Invocation::Status { dir: None }));
    assert_eq!(
        parse(&words("undo --all --dir /tmp/live --timeout 3")),
        Ok(Invocation::Undo {
            dir: Some(PathBuf::from("/tmp/live")),
            all: true,
            wait: Some(Duration::from_secs(3))
        })
    );
    assert_eq!(
        parse(&words("apply /tmp/p.dylib --no-wait")),
        Ok(Invocation::Apply { dir: None, patch: PathBuf::from("/tmp/p.dylib"), wait: None })
    );
    assert_eq!(parse(&words("log -n 5")), Ok(Invocation::Log { dir: None, lines: 5 }));
    assert_eq!(parse(&[]), Ok(Invocation::Help));
    assert_eq!(parse(&words("undo --help")), Ok(Invocation::Help));
}

#[test]
fn bad_words_and_pull_requests_are_refused_with_a_reason() {
    assert!(parse(&words("frob")).is_err());
    assert!(parse(&words("apply")).is_err());
    assert!(parse(&words("status --all")).is_err());
    assert!(parse(&words("apply a.dylib b.dylib")).is_err());
    for pr in ["36277", "#36277", "https://github.com/manaflow-ai/cmux/pull/36277"] {
        let error = parse(&words(&format!("apply {pr}"))).expect_err(pr);
        assert!(format!("{error:?}").contains("try-pr"), "{pr}: {error:?}");
    }
}

#[test]
fn json_after_the_verb_counts() {
    let (rest, json) = without_json(&words("status --json"));
    assert!(json);
    assert_eq!(rest, words("status"));
}

#[test]
fn the_folder_is_the_flag_before_anything_else() {
    assert_eq!(folder(Some(Path::new("/x"))), PathBuf::from("/x"));
    assert!(folder(None).is_absolute() || std::env::var_os("HOME").is_none());
}

#[test]
fn the_answer_is_the_apps_line_for_that_name_only() {
    let log = "live code: watching /tmp/live\n\
               live code: applied patch-1.dylib functions=3 load_ms=12 at=1\n\
               live code: undo-2.rollback refused: no patch is applied\n\
               live code: rolled back undo-3.rollback functions=3 rollback_ms=1 left=0 at=2\n";
    assert_eq!(
        answer(log, "patch-1.dylib"),
        Some(Ok("applied patch-1.dylib functions=3 load_ms=12 at=1".into()))
    );
    assert_eq!(
        answer(log, "undo-2.rollback"),
        Some(Err("undo-2.rollback refused: no patch is applied".into()))
    );
    assert!(matches!(answer(log, "undo-3.rollback"), Some(Ok(_))));
    assert_eq!(answer(log, "patch-1"), None);
    assert_eq!(answer(log, "patch-9.dylib"), None);
}

#[test]
fn a_patch_and_its_sidecar_land_under_new_names_and_an_undo_is_a_new_file() {
    let source = tempfile::tempdir().expect("tempdir");
    let live = tempfile::tempdir().expect("tempdir");
    let patch = source.path().join("patch-1.dylib");
    std::fs::write(&patch, b"dylib").expect("write");
    std::fs::write(source.path().join("patch-1.json"), br#"{"commit":"abc"}"#).expect("write");
    let name = place_patch(live.path(), &patch).expect("place");
    assert!(name.starts_with("patch-cli-") && name.ends_with(".dylib"));
    assert_eq!(std::fs::read(live.path().join(&name)).expect("read"), b"dylib");
    assert!(live.path().join(name.replace(".dylib", ".json")).is_file());
    // Nothing half-written is left under a hidden name.
    let hidden = std::fs::read_dir(live.path())
        .expect("list")
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with('.'))
        .count();
    assert_eq!(hidden, 0);
    let one = request_undo(live.path(), false).expect("undo");
    let all = request_undo(live.path(), true).expect("undo all");
    assert!(one.ends_with(".rollback") && all.ends_with(".rollback-all") && one != all);
}

#[test]
fn status_says_whether_the_app_still_runs() {
    let live = tempfile::tempdir().expect("tempdir");
    assert!(status(live.path()).is_none());
    let mine = json!({"pid": std::process::id(), "bundle_id": "com.cmuxterm.app.nightly",
        "team_signed_only": true, "generation": 2, "last_error": null,
        "patches": [{"name": "patch-2.dylib", "commit": "abc+dirty",
                     "files": ["Packages/X.swift"], "functions": 4, "applied_at": 1.0}]});
    std::fs::write(live.path().join("status.json"), mine.to_string()).expect("write");
    let read = status(live.path()).expect("status");
    assert_eq!(read.get("watching"), Some(&Value::Bool(true)));
    let text = status_text(&read);
    assert!(text.contains("running") && text.contains("team-signed patches only"), "{text}");
    assert!(text.contains("patch-2.dylib  4 functions  abc+dirty  Packages/X.swift"), "{text}");
    // A pid now running another executable is not the app that wrote it.
    let reused = json!({"pid": std::process::id(), "executable": "/Applications/Other.app/Contents/MacOS/other", "patches": []});
    std::fs::write(live.path().join("status.json"), reused.to_string()).expect("write");
    let reused = status(live.path()).expect("status");
    assert_eq!(reused.get("watching"), Some(&Value::Bool(false)));
    let ours = json!({"pid": std::process::id(),
        "executable": std::env::current_exe().expect("exe").display().to_string(), "patches": []});
    std::fs::write(live.path().join("status.json"), ours.to_string()).expect("write");
    assert_eq!(status(live.path()).expect("status").get("watching"), Some(&Value::Bool(true)));
    // A pid that cannot exist is not running.
    let gone = json!({"pid": i32::MAX, "patches": []});
    std::fs::write(live.path().join("status.json"), gone.to_string()).expect("write");
    let gone = status(live.path()).expect("status");
    assert_eq!(gone.get("watching"), Some(&Value::Bool(false)));
    assert!(status_text(&gone).contains("no patch applied"));
}
