//! The memory inbox (`memory_inbox.rs`): which turns teach something, which of the agent's facts
//! are offered, and how an accepted one lands in the instructions file. The transcripts under
//! `tests/fixtures/memory_inbox/` replay a chat's prompts and live updates turn by turn.

use super::*;
use serde_json::json;

/// Replays a fixture: each turn end checks whether the turn taught something and which facts its
/// wrap-up offered, deduplicated as the hub does against an empty file.
fn replay(name: &str, transcript: &str) {
    let mut signals = Signals::default();
    let mut wrap_up = crate::wrap_up_suggestion::Watch::default();
    for (n, line) in transcript.lines().filter(|l| !l.trim().is_empty()).enumerate() {
        let step: Value = serde_json::from_str(line).unwrap();
        if let Some(prompt) = step["prompt"].as_str() {
            signals.prompt(prompt);
        }
        if let Some(update) = step.get("update") {
            signals.observe(update);
            wrap_up.observe(update);
        }
        if step["turn_end"] == true {
            let taught = std::mem::take(&mut signals).taught();
            let learned = wrap_up.take_learned();
            wrap_up.take();
            assert_eq!(taught, step["expect_taught"] == true, "{name} line {}", n + 1);
            if let Some(expected) = step.get("expect_learned") {
                let expected: Vec<String> = serde_json::from_value(expected.clone()).unwrap();
                assert_eq!(fresh(&learned, "", &[]), expected, "{name} line {}", n + 1);
            }
        }
    }
}

#[test]
fn fixture_transcripts_offer_facts_only_after_a_correction() {
    for (name, text) in [
        ("pnpm_correction", include_str!("../tests/fixtures/memory_inbox/pnpm_correction.jsonl")),
        ("database_url", include_str!("../tests/fixtures/memory_inbox/database_url.jsonl")),
        ("no_correction", include_str!("../tests/fixtures/memory_inbox/no_correction.jsonl")),
        ("generated_edit", include_str!("../tests/fixtures/memory_inbox/generated_edit.jsonl")),
    ] {
        replay(name, text);
    }
}

#[test]
fn corrections_are_told_apart_from_ordinary_prompts() {
    for yes in [
        "no, use pnpm",
        "No. The tests live in tests_v2",
        "nope, wrong folder",
        "Actually, run it with --release",
        "use bun not node",
        "don't use sudo for that",
        "Stop editing the lockfile",
        "you need to set DATABASE_URL first",
        "That’s wrong, the port is 4100",
        "run it with make instead",
    ] {
        assert!(is_correction(yes), "{yes}");
    }
    for no in [
        "no problem, thanks",
        "No worries! Next, add a test",
        "add a lint script",
        "what does this function do?",
        "actually I like it",
        "use the existing helper for dates",
        "nobody uses this flag",
    ] {
        assert!(!is_correction(no), "{no}");
    }
}

#[test]
fn a_failed_command_alone_or_a_success_alone_teaches_nothing() {
    let call = |id: &str, status: &str| json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute", "status": status});
    let mut s = Signals::default();
    s.observe(&call("a", "failed"));
    assert!(!s.taught());
    s.observe(&call("b", "completed"));
    assert!(s.taught());
    let mut s = Signals::default();
    s.observe(&call("a", "completed"));
    s.observe(&call("b", "completed"));
    assert!(!s.taught());
    // A read that fails is not a command.
    let mut s = Signals::default();
    s.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "r", "kind": "read", "status": "failed"}));
    s.observe(&call("b", "completed"));
    assert!(!s.taught());
}

#[test]
fn facts_the_file_already_says_or_were_dismissed_are_not_offered_again() {
    let file = "# Project\n\n- Use pnpm, not npm.\nTests need `DATABASE_URL` set.\n";
    let facts: Vec<String> = [
        "use pnpm not npm",
        "Tests need DATABASE_URL set.",
        "Never edit generated/*.",
        "Run make gen after a schema change.",
    ]
    .map(String::from)
    .to_vec();
    let dismissed = vec![key("Run make gen after a schema change.")];
    assert_eq!(fresh(&facts, file, &dismissed), vec!["Never edit generated/*.".to_owned()]);
    // Facts one word apart are two facts.
    let ports: Vec<String> =
        ["The dev server runs on port 4100.", "The dev server runs on port 4200."]
            .map(String::from)
            .to_vec();
    assert_eq!(fresh(&ports, "", &[]), ports);
    // A short fact is compared word for word, never as a subset of a long line.
    assert_eq!(
        fresh(&["Use bun.".into()], "Use bun for scripts, pnpm for packages.", &[]).len(),
        1
    );
}

#[test]
fn accepted_facts_go_under_their_heading_which_is_made_once() {
    let facts = vec!["Use pnpm, not npm.".to_owned()];
    assert_eq!(with_facts("", &facts), format!("{HEADING}\n\n- Use pnpm, not npm.\n"));
    let once = with_facts("# Notes\n\nBe brief.\n", &facts);
    assert_eq!(once, format!("# Notes\n\nBe brief.\n\n{HEADING}\n\n- Use pnpm, not npm.\n"));
    let twice = with_facts(&once, &["Tests need DATABASE_URL set.".to_owned()]);
    assert_eq!(
        twice,
        format!(
            "# Notes\n\nBe brief.\n\n{HEADING}\n\n- Use pnpm, not npm.\n- Tests need DATABASE_URL set.\n"
        )
    );
    assert!(has_heading(&twice));
    // A section in the middle keeps what follows it.
    let middle = format!("# A\n\n{HEADING}\n\n- one\n\n## Build\n\nmake\n");
    assert_eq!(
        with_facts(&middle, &["two".into()]),
        format!("# A\n\n{HEADING}\n\n- one\n- two\n\n## Build\n\nmake\n")
    );
}

#[test]
fn write_makes_or_extends_the_file_and_skips_what_it_says() {
    let dir = tempfile::tempdir().unwrap();
    let added = write(dir.path(), "AGENTS.md", &["Use pnpm, not npm.".into()]).unwrap();
    assert_eq!(added.len(), 1);
    let again = write(dir.path(), "AGENTS.md", &["use pnpm not npm".into()]).unwrap();
    assert!(again.is_empty());
    let text = std::fs::read_to_string(dir.path().join("AGENTS.md")).unwrap();
    assert_eq!(text.matches("pnpm").count(), 1);
}

#[cfg(unix)]
#[test]
fn write_never_follows_a_link_out_of_the_folder() {
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("target.md"), "keep\n").unwrap();
    let dir = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path().join("target.md"), dir.path().join("CLAUDE.md"))
        .unwrap();
    assert!(write(dir.path(), "CLAUDE.md", &["Use pnpm.".into()]).is_err());
    assert_eq!(std::fs::read_to_string(outside.path().join("target.md")).unwrap(), "keep\n");
}

#[test]
fn the_target_is_the_harness_file_the_folder_has() {
    use crate::folder_instructions::learned_target;
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(learned_target("claude", dir.path()), "CLAUDE.md");
    assert_eq!(learned_target("codex", dir.path()), "AGENTS.md");
    assert_eq!(learned_target("pi", dir.path()), "AGENTS.md");
    std::fs::write(dir.path().join("AGENTS.md"), "a\n").unwrap();
    // A Claude chat in a folder with only AGENTS.md: the file cmux already carries to it.
    assert_eq!(learned_target("claude", dir.path()), "AGENTS.md");
    std::fs::write(dir.path().join("CLAUDE.local.md"), "mine\n").unwrap();
    assert_eq!(learned_target("claude", dir.path()), "AGENTS.md");
    std::fs::write(dir.path().join("CLAUDE.md"), "c\n").unwrap();
    assert_eq!(learned_target("claude", dir.path()), "CLAUDE.md");
}

#[test]
fn dismissed_facts_are_kept_per_folder() {
    let home = tempfile::tempdir().unwrap();
    let store = Dismissed::at(home.path().join("memory-dismissed.json"));
    let a = std::path::Path::new("/work/a");
    store.add(a, &["Use pnpm.".into()]);
    assert_eq!(store.of(a), vec![key("Use pnpm.")]);
    assert!(store.of(std::path::Path::new("/work/b")).is_empty());
}

#[test]
fn learned_facts_are_read_from_object_or_string_arguments() {
    let args = json!({"recap": "r", "learned": [" - Use pnpm. ", "", "a", "b", "c"]});
    assert_eq!(learned_facts(&args), vec!["Use pnpm.", "a", "b"]);
    let text = json!(r#"{"recap":"r","learned":["x"]}"#);
    assert_eq!(learned_facts(&text), vec!["x"]);
    assert!(learned_facts(&json!({"recap": "r"})).is_empty());
}

#[cfg(unix)]
#[test]
fn write_replaces_the_file_whole_keeping_its_mode_and_leaving_no_temp_file() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("CLAUDE.md");
    std::fs::write(&path, "# Rules\n\nBe brief.\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
    write(dir.path(), "CLAUDE.md", &["Use pnpm, not npm.".into()]).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.starts_with("# Rules\n\nBe brief.\n") && text.contains("- Use pnpm, not npm."));
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o7777, 0o640);
    let names: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["CLAUDE.md".to_owned()]);
}

#[test]
fn write_refuses_a_folder_where_the_file_would_be() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("AGENTS.md")).unwrap();
    assert!(write(dir.path(), "AGENTS.md", &["Use pnpm.".into()]).is_err());
    assert!(dir.path().join("AGENTS.md").is_dir());
}

#[test]
fn concurrent_accepts_both_land() {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().to_path_buf();
    let threads: Vec<_> = (0..8)
        .map(|n| {
            let cwd = cwd.clone();
            std::thread::spawn(move || {
                write(&cwd, "AGENTS.md", &[format!("Fact number {n} about the build.")]).unwrap()
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    let text = std::fs::read_to_string(cwd.join("AGENTS.md")).unwrap();
    for n in 0..8 {
        assert!(text.contains(&format!("Fact number {n} about the build.")), "{text}");
    }
    assert_eq!(text.matches(HEADING).count(), 1);
}

#[cfg(unix)]
#[test]
fn a_file_that_cannot_be_read_is_never_replaced() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("AGENTS.md");
    std::fs::write(&path, "# Keep all of this\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o200)).unwrap();
    // Root reads any file: the refusal is then not what this checks.
    if std::fs::read(&path).is_ok() {
        return;
    }
    assert!(write(dir.path(), "AGENTS.md", &["Use pnpm, not npm.".into()]).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "# Keep all of this\n");
}

#[cfg(unix)]
#[test]
fn a_file_that_changed_since_it_was_read_is_left_alone() {
    use crate::folder_instructions::{read_whole_beneath, replace_beneath};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("CLAUDE.md");
    std::fs::write(&path, "one\n").unwrap();
    let (_, stamp) = read_whole_beneath(dir.path(), "CLAUDE.md", 1024).unwrap().unwrap();
    std::fs::write(&path, "one\ntwo, written meanwhile\n").unwrap();
    assert!(replace_beneath(dir.path(), "CLAUDE.md", b"one\nnew\n", Some(stamp)).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\ntwo, written meanwhile\n");
    // A file that appeared after it was found missing is left alone too.
    std::fs::write(dir.path().join("AGENTS.md"), "theirs\n").unwrap();
    assert!(replace_beneath(dir.path(), "AGENTS.md", b"ours\n", None).is_err());
    assert_eq!(std::fs::read_to_string(dir.path().join("AGENTS.md")).unwrap(), "theirs\n");
}

/// The `(name, window)` pairs a swap hook should have been reached in, in order.
#[cfg(unix)]
fn reached(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(name, window)| ((*name).to_owned(), (*window).to_owned())).collect()
}

#[cfg(unix)]
#[test]
fn an_edit_saved_between_the_checks_and_the_swap_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("RACE-EDIT.md");
    std::fs::write(&path, "# Mine\n").unwrap();
    let saved = path.clone();
    let hook = crate::folder_instructions::on_swap(move |name, window| {
        if name == "RACE-EDIT.md" && window == "before" {
            std::fs::write(&saved, "# Mine\n\nSaved by an editor meanwhile.\n").unwrap();
        }
    });
    let got = write(dir.path(), "RACE-EDIT.md", &["Use pnpm, not npm.".into()]);
    // The save lands before the swap, so the swap finds it and swaps back.
    assert_eq!(hook.reached(), reached(&[("RACE-EDIT.md", "before"), ("RACE-EDIT.md", "after")]));
    drop(hook);
    assert!(got.is_err(), "{got:?}");
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "# Mine\n\nSaved by an editor meanwhile.\n"
    );
    let names: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["RACE-EDIT.md".to_owned()]);
}

#[cfg(unix)]
#[test]
fn a_file_made_between_the_checks_and_the_swap_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("RACE-NEW.md");
    let made = path.clone();
    let hook = crate::folder_instructions::on_swap(move |name, window| {
        if name == "RACE-NEW.md" && window == "before" {
            std::fs::write(&made, "theirs\n").unwrap();
        }
    });
    let got = write(dir.path(), "RACE-NEW.md", &["Use pnpm, not npm.".into()]);
    assert_eq!(hook.reached(), reached(&[("RACE-NEW.md", "before")]));
    drop(hook);
    assert!(got.is_err(), "{got:?}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "theirs\n");
}

#[cfg(unix)]
#[test]
fn a_second_save_between_the_swap_and_the_swap_back_is_kept_too() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("RACE-TWICE.md");
    std::fs::write(&path, "# Mine\n").unwrap();
    let saved = path.clone();
    let hook = crate::folder_instructions::on_swap(move |name, window| {
        if name != "RACE-TWICE.md" {
            return;
        }
        let text = match window {
            "before" => "# Mine\n\nFirst save.\n",
            _ => "# Mine\n\nSecond save, over the proposed file.\n",
        };
        std::fs::write(&saved, text).unwrap();
    });
    let got = write(dir.path(), "RACE-TWICE.md", &["Use pnpm, not npm.".into()]);
    assert_eq!(hook.reached(), reached(&[("RACE-TWICE.md", "before"), ("RACE-TWICE.md", "after")]));
    drop(hook);
    assert!(got.is_err(), "{got:?}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "# Mine\n\nFirst save.\n");
    // The second save is still on disk, under the name the error gives.
    let others: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p != &path)
        .map(|p| std::fs::read_to_string(p).unwrap())
        .collect();
    assert_eq!(others, vec!["# Mine\n\nSecond save, over the proposed file.\n".to_owned()]);
    assert!(got.unwrap_err().contains("kept as"));
}
