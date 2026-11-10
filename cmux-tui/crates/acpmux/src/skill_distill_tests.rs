//! The skill distiller (`skill_distill.rs`): which chats make a pattern, that a pattern is
//! offered once and a dismissed one never comes back, and how a draft is read and saved. The
//! transcripts under `tests/fixtures/skill_distill/` replay a chat's prompts and live updates turn
//! by turn, the way the hub records them at each turn's end.

use super::*;
use serde_json::json;

const RELEASE_1: &str = include_str!("../tests/fixtures/skill_distill/release_1.jsonl");
const RELEASE_2: &str = include_str!("../tests/fixtures/skill_distill/release_2.jsonl");
const RELEASE_3: &str = include_str!("../tests/fixtures/skill_distill/release_3.jsonl");
const LOGIN: &str = include_str!("../tests/fixtures/skill_distill/login_color.jsonl");

/// Replays chat `session` of `transcript` into `record`: at each turn end the turn's shape is
/// recorded and a pattern looked for, as `Hub::record_task_shape` does. The offers it made.
fn replay(record: &mut Record, session: &str, transcript: &str) -> Vec<Found> {
    let mut turn = Turn::default();
    let mut found = Vec::new();
    for line in transcript.lines().filter(|l| !l.trim().is_empty()) {
        let step: Value = serde_json::from_str(line).unwrap();
        if let Some(prompt) = step["prompt"].as_str() {
            turn.prompt(prompt);
        }
        if let Some(update) = step.get("update") {
            turn.observe(update);
        }
        if step["turn_end"] == true {
            let shape = shape_of(session, std::mem::take(&mut turn));
            record.update(shape);
            found.extend(record.claim(session, &format!("offer-{session}")));
        }
    }
    found
}

/// What [`take`] makes of a turn.
fn shape_of(session: &str, turn: Turn) -> Shape {
    let prompt = turn.prompt.unwrap_or_default();
    Shape {
        session: session.into(),
        intent: intent(&prompt),
        prompt: one_line(&prompt, MAX_PROMPT_CHARS),
        steps: turn.steps,
        commands: turn.commands,
        claimed: false,
    }
}

#[test]
fn three_similar_chats_make_an_offer() {
    let mut record = Record::default();
    assert!(replay(&mut record, "r1", RELEASE_1).is_empty());
    assert!(replay(&mut record, "login", LOGIN).is_empty());
    assert!(replay(&mut record, "r2", RELEASE_2).is_empty());
    let found = replay(&mut record, "r3", RELEASE_3);
    assert_eq!(found.len(), 1, "{found:?}");
    let ids: Vec<&str> = found[0].chats.iter().map(|c| c.session.as_str()).collect();
    assert_eq!(ids, ["r3", "r2", "r1"]);
    assert_eq!(record.patterns.len(), 1);
    assert_eq!(record.patterns[0].state, "offered");
    // The unrelated chat is no part of it, and stays free.
    assert!(!record.chats.iter().find(|c| c.session == "login").unwrap().claimed);
}

#[test]
fn two_similar_chats_make_none() {
    let mut record = Record::default();
    assert!(replay(&mut record, "r1", RELEASE_1).is_empty());
    assert!(replay(&mut record, "r2", RELEASE_2).is_empty());
    assert!(replay(&mut record, "login", LOGIN).is_empty());
    assert!(record.patterns.is_empty());
}

#[test]
fn a_chat_of_several_turns_keeps_its_first_prompt_and_all_its_steps() {
    let mut record = Record::default();
    replay(&mut record, "r2", RELEASE_2);
    let chat = &record.chats[0];
    assert_eq!(chat.prompt, "bump version to 0.5.0 and cut the release, tests first");
    assert_eq!(chat.steps, ["read", "edit", "cargo test", "git commit", "git tag", "git push"]);
    // An argv's script, and a `cd` before the command, are read through.
    assert!(chat.commands.contains(&"git tag v0.5.0".to_owned()), "{:?}", chat.commands);
}

#[test]
fn a_dismissed_pattern_never_comes_back() {
    let mut record = Record::default();
    replay(&mut record, "r1", RELEASE_1);
    replay(&mut record, "r2", RELEASE_2);
    let found = replay(&mut record, "r3", RELEASE_3);
    assert_eq!(found.len(), 1);
    record.pattern_mut(&found[0].offer_id).unwrap().state = "dismissed".into();
    // Three more releases: the same pattern, never offered again.
    for (n, text) in [RELEASE_1, RELEASE_2, RELEASE_3, RELEASE_1].iter().enumerate() {
        assert!(replay(&mut record, &format!("again{n}"), text).is_empty(), "chat {n}");
    }
    // Nor after the record is written and read back.
    let back: Record = serde_json::from_slice(&serde_json::to_vec(&record).unwrap()).unwrap();
    let mut back = back;
    assert!(replay(&mut back, "later", RELEASE_3).is_empty());
}

#[test]
fn an_open_offer_is_not_made_twice() {
    let mut record = Record::default();
    for (n, text) in [RELEASE_1, RELEASE_2, RELEASE_3].iter().enumerate() {
        replay(&mut record, &format!("a{n}"), text);
    }
    for (n, text) in [RELEASE_1, RELEASE_2, RELEASE_3].iter().enumerate() {
        assert!(replay(&mut record, &format!("b{n}"), text).is_empty(), "chat {n}");
    }
    assert_eq!(record.patterns.len(), 1);
}

#[test]
fn a_chat_no_person_asked_gets_no_entry() {
    let mut record = Record::default();
    record.update(Shape {
        session: "agent".into(),
        steps: vec!["cargo test".into()],
        ..Shape::default()
    });
    assert!(record.chats.is_empty());
    // A person's chat keeps the steps of a later turn that came without a prompt.
    replay(&mut record, "r1", RELEASE_1);
    record.update(Shape { session: "r1".into(), steps: vec!["gh pr".into()], ..Shape::default() });
    assert_eq!(record.chats[0].steps.last().map(String::as_str), Some("gh pr"));
}

#[test]
fn records_stay_bounded() {
    let mut record = Record::default();
    for n in 0..(MAX_CHATS * 2) {
        replay(&mut record, &format!("login{n}"), LOGIN);
    }
    assert!(record.chats.len() <= MAX_CHATS);
}

#[test]
fn commands_with_secrets_are_never_kept() {
    let mut record = Record::default();
    replay(&mut record, "r3", RELEASE_3);
    let chat = &record.chats[0];
    assert!(chat.commands.iter().all(|c| !c.contains("abc123")), "{:?}", chat.commands);
    assert!(chat.commands.contains(&"git push origin main --tags".to_owned()));
}

#[test]
fn a_command_that_comes_after_its_kind_still_counts() {
    let mut turn = Turn::default();
    turn.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "x", "kind": "execute", "rawInput": {}}));
    turn.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "rawInput": {"command": "pnpm build"}}));
    turn.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "completed", "rawInput": {"command": "pnpm build"}}));
    assert_eq!(turn.steps, ["pnpm build"]);
    assert_eq!(turn.commands, ["pnpm build"]);
}

#[test]
fn steps_are_normalised() {
    for (line, step) in [
        ("cargo test -p acpmux", "cargo test"),
        ("cd web && RUST_LOG=debug cargo +nightly build", "cargo build"),
        ("sudo /usr/bin/make install", "make install"),
        ("ls -la", "ls"),
        ("gh pr create --fill", "gh pr"),
    ] {
        assert_eq!(command_step(line), step, "{line}");
    }
}

#[test]
fn intents_match_across_wording() {
    let a = intent("Cut a release: bump the version, run the tests, tag it and push");
    let b = intent("bump version to 0.5.0 and cut the release, tests first");
    let (shared, ratio) = overlap(&a, &b);
    assert!(shared >= 4 && ratio >= 0.5, "{a:?} {b:?}");
    assert!(intent("do it for me").is_empty());
}

#[test]
fn a_harness_draft_is_read() {
    let answer = "name: Cut Release\n\
                  description: Use when asked to cut a release of this crate.\n\
                  steps:\n\
                  1. Bump the version in Cargo.toml\n\
                  2. Run `cargo test --workspace`\n\
                  3. Commit, tag and push\n\
                  commands:\n\
                  - cargo test --workspace\n\
                  - git push origin main --tags\n\
                  - curl -H 'Authorization: Bearer x' https://example.com\n";
    let draft = parse_draft(answer).unwrap();
    assert_eq!(draft.name, "cut-release");
    assert_eq!(draft.description, "Use when asked to cut a release of this crate.");
    assert_eq!(draft.drafted, "harness");
    assert!(draft.body.contains("1. Bump the version in Cargo.toml"));
    assert!(draft.body.contains("```sh\ncargo test --workspace\ngit push origin main --tags\n```"));
    assert!(!draft.body.contains("Bearer"));
    assert!(parse_draft("Sorry, I can't help with that.").is_none());
}

#[test]
fn a_shapes_draft_names_the_shared_task() {
    let mut record = Record::default();
    replay(&mut record, "r1", RELEASE_1);
    replay(&mut record, "r2", RELEASE_2);
    let found = replay(&mut record, "r3", RELEASE_3).remove(0);
    let draft = shapes_draft(&found.chats);
    assert_eq!(draft.name, "release-bump-version");
    assert_eq!(draft.drafted, "shapes");
    assert!(draft.body.contains("Run `cargo test`"), "{}", draft.body);
    assert!(draft.body.contains("git push origin main --tags"), "{}", draft.body);
    check_skill(&draft.name, &draft.description, &draft.body).unwrap();
    // The prompt to the harness carries every chat, within the completion's limit.
    let prompt = draft_prompt(&found.chats);
    assert!(prompt.contains("Chat 3, asked:") && prompt.len() <= crate::complete::MAX_PROMPT_BYTES);
}

#[test]
fn a_saved_draft_is_a_skill_every_chat_reads() {
    let dir = tempfile::tempdir().unwrap();
    let draft = parse_draft("name: cut-release\ndescription: Use when cutting a \"release\".\nsteps:\n1. Run the tests\n").unwrap();
    let path = write_skill(dir.path(), &draft.name, &draft.description, &draft.body).unwrap();
    assert_eq!(path, dir.path().join("cut-release/SKILL.md"));
    let skills = crate::agent_guidance::user_skills(dir.path());
    assert_eq!(skills.len(), 1);
    assert_eq!(skills[0].name, "cut-release");
    assert_eq!(skills[0].description, "Use when cutting a 'release'.");
    // A skill of that name is never replaced.
    let again = write_skill(dir.path(), "cut-release", "Other.", "## Steps\n\n1. x\n");
    assert_eq!(again.unwrap_err(), "a skill named cut-release already exists");
    assert!(std::fs::read_to_string(&path).unwrap().contains("Run the tests"));
    // Nor is a bad name or a multi-line description written.
    assert!(write_skill(dir.path(), "../evil", "x", "y").is_err());
    assert!(write_skill(dir.path(), "ok", "two\nlines", "y").is_err());
}

#[test]
fn folder_records_are_written_and_read_back() {
    let dir = tempfile::tempdir().unwrap();
    let records = Records::at(dir.path().join("skill-patterns"));
    let cwd = Path::new("/work/project");
    for (session, text) in [("r1", RELEASE_1), ("r2", RELEASE_2)] {
        let mut turn = Turn::default();
        for line in text.lines() {
            let step: Value = serde_json::from_str(line).unwrap();
            if let Some(p) = step["prompt"].as_str() {
                turn.prompt(p);
            }
            if let Some(u) = step.get("update") {
                turn.observe(u);
            }
        }
        let shape = shape_of(session, turn);
        assert!(
            records
                .change(cwd, |r| {
                    r.update(shape);
                    r.claim(session, "o")
                })
                .is_none()
        );
    }
    assert_eq!(records.load(cwd).chats.len(), 2);
    assert!(records.load(Path::new("/work/other")).chats.is_empty());
}
