//! The prompt coach (`prompt_coach.rs`): which chats are offered a rewrite and when, which prompts
//! count as corrections, and what the small model is asked. The transcripts under
//! `tests/fixtures/prompt_coach/` replay a chat's person prompts and turn ends.

use super::*;
use serde_json::Value;

/// Replays a fixture: each turn end checks whether the chat is offered its rewrite then, and the
/// offer is logged the way the hub logs it.
fn replay(name: &str, transcript: &str) {
    let mut coach = Coach::default();
    let mut offers = 0;
    for (n, line) in transcript.lines().filter(|l| !l.trim().is_empty()).enumerate() {
        let step: Value = serde_json::from_str(line).unwrap();
        if let Some(prompt) = step["prompt"].as_str() {
            coach.prompt(prompt);
        }
        if let Some(end) = step["turn_end"].as_str() {
            let offer = coach.turn_ended(end == "completed");
            assert_eq!(offer, step["expect_offer"] == true, "{name} line {}", n + 1);
            if offer {
                offers += 1;
                coach.offer(format!("offer-{offers}"));
                let (corrections, count) = coach.take_ask("offer-1").unwrap();
                assert_eq!(Some(count as u64), step["expect_corrections"].as_u64(), "{name}");
                assert_eq!(corrections.len(), count, "{name}");
            }
        }
    }
    assert!(offers <= 1, "{name}: offered {offers} times");
}

#[test]
fn fixture_transcripts_offer_once_after_three_corrections_and_a_kept_result() {
    for (name, text) in [
        (
            "three_corrections",
            include_str!("../tests/fixtures/prompt_coach/three_corrections.jsonl"),
        ),
        ("still_correcting", include_str!("../tests/fixtures/prompt_coach/still_correcting.jsonl")),
        ("two_corrections", include_str!("../tests/fixtures/prompt_coach/two_corrections.jsonl")),
        ("went_fine", include_str!("../tests/fixtures/prompt_coach/went_fine.jsonl")),
    ] {
        replay(name, text);
    }
}

#[test]
fn corrections_and_redirects_are_told_apart_from_ordinary_prompts() {
    for yes in [
        "no, use pnpm",
        "Actually it should follow the system theme",
        "not that file, the other one",
        "That's not what I meant",
        "I meant the sidebar, not the header",
        "still wrong, the test fails",
        "It still retries forever",
        "let me rephrase: only the first page",
        "hmm no, keep the old name",
        "you missed the second call site",
        "I already told you the port is 4100",
    ] {
        assert!(is_redirect(yes), "{yes:?} is a correction");
    }
    for no in [
        "add a dark mode toggle",
        "great, now add a test",
        "no problem, take your time",
        "thanks! commit it",
        "what does this function do?",
        "add a fallback for when the API doesn't respond",
        "make it actually fast",
        "open a PR",
    ] {
        assert!(!is_redirect(no), "{no:?} is not a correction");
    }
}

#[test]
fn a_rewrite_is_asked_once_for_its_own_offer() {
    let mut coach = Coach::default();
    for text in ["build it", "no, in rust", "actually use tokio", "still wrong, use the pool", "ok"]
    {
        coach.prompt(text);
        coach.turn_ended(true);
    }
    assert!(coach.take_ask("o1").is_none(), "no offer yet");
    coach.offer("o1".into());
    assert!(coach.take_ask("o2").is_none(), "another chat's offer");
    let (corrections, count) = coach.take_ask("o1").unwrap();
    assert_eq!(count, 3);
    assert_eq!(corrections[0], "no, in rust");
    assert!(coach.take_ask("o1").is_none(), "asked once");
    coach.ask_failed();
    assert!(coach.take_ask("o1").is_some(), "a failed ask may be asked again");
    // Corrections after the offer are not counted, and no second offer comes.
    for text in ["no, the other one", "still wrong", "actually revert it", "fine"] {
        coach.prompt(text);
        assert!(!coach.turn_ended(true));
    }
}

#[test]
fn the_model_reads_the_first_prompt_and_corrections_only() {
    let corrections = vec!["no, use pnpm".to_owned(), "actually keep the lockfile".to_owned()];
    let prompt = rewrite_prompt("add a lint script", &corrections);
    assert!(prompt.contains("<first_message>\nadd a lint script\n</first_message>"));
    assert!(prompt.contains("<correction n=\"1\">\nno, use pnpm\n</correction>"));
    assert!(prompt.contains("<correction n=\"2\">\nactually keep the lockfile\n</correction>"));
    let long = "x".repeat(MAX_PROMPT_CHARS * 2);
    assert!(rewrite_prompt(&long, &[]).len() < MAX_PROMPT_CHARS + 1000);
    let mut coach = Coach::default();
    coach.prompt(&long);
    coach.prompt(&format!("no, {long}"));
    assert_eq!(coach.corrections[0].chars().count(), MAX_PROMPT_CHARS + 1);
    for n in 0..MAX_KEPT + 4 {
        coach.prompt(&format!("no, try {n}"));
    }
    assert_eq!(coach.corrections.len(), MAX_KEPT);
    assert_eq!(coach.count, MAX_KEPT + 5);
}

#[test]
fn a_rewrite_answer_is_cleaned() {
    assert_eq!(clean_rewrite("  \n").as_deref(), None);
    assert_eq!(clean_rewrite("\"Add a toggle.\"").as_deref(), Some("Add a toggle."));
    assert_eq!(clean_rewrite("```text\nAdd a toggle.\n```").as_deref(), Some("Add a toggle."));
    assert_eq!(clean_rewrite("```\nAdd a toggle.\n```").as_deref(), Some("Add a toggle."));
    let long = "y".repeat(MAX_REWRITE_CHARS + 10);
    assert_eq!(clean_rewrite(&long).unwrap().chars().count(), MAX_REWRITE_CHARS + 1);
}

#[test]
fn a_retried_prompt_id_counts_once() {
    let mut coach = Coach::default();
    coach.prompt_once("build it", Some("p0"));
    coach.turn_ended(true);
    // One correction, sent three times with the same id (a retry the daemon answers as a
    // duplicate), is one correction.
    for _ in 0..3 {
        coach.prompt_once("no, in rust", Some("p1"));
    }
    coach.turn_ended(true);
    coach.prompt_once("ok, ship it", Some("p2"));
    assert!(!coach.turn_ended(true), "one correction, not three");
    assert_eq!(coach.count(), 1);
    // Prompts without an id are each counted.
    for text in ["no, in go", "actually in zig"] {
        coach.prompt_once(text, None);
        coach.turn_ended(true);
    }
    coach.prompt_once("great", Some("p3"));
    assert!(coach.turn_ended(true));
    assert_eq!(coach.count(), 3);
}
