//! The prompt coach (`prompt_coach.rs`): which chats are offered a rewrite and when, which prompts
//! count as corrections, and what the small model is asked. The transcripts under
//! `tests/fixtures/prompt_coach/` replay a chat's person prompts and turn ends.

use super::*;
use serde_json::Value;

/// Replays a fixture: each prompt starts its own turn, each turn end ends the latest prompt's turn
/// and checks whether the chat is offered its rewrite then, and the offer is logged the way the
/// hub logs it.
fn replay(name: &str, transcript: &str) {
    let mut coach = Coach::default();
    let mut offers = 0;
    let mut latest = String::new();
    for (n, line) in transcript.lines().filter(|l| !l.trim().is_empty()).enumerate() {
        let step: Value = serde_json::from_str(line).unwrap();
        if let Some(prompt) = step["prompt"].as_str() {
            latest = format!("p{n}");
            coach.prompt(&latest, prompt);
        }
        if let Some(end) = step["turn_end"].as_str() {
            let offer = coach.turn_ended(&latest, end == "completed");
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
    for (n, text) in
        ["build it", "no, in rust", "actually use tokio", "still wrong, use the pool", "ok"]
            .into_iter()
            .enumerate()
    {
        coach.prompt(&format!("p{n}"), text);
        coach.turn_ended(&format!("p{n}"), true);
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
    for (n, text) in
        ["no, the other one", "still wrong", "actually revert it", "fine"].into_iter().enumerate()
    {
        coach.prompt(&format!("q{n}"), text);
        assert!(!coach.turn_ended(&format!("q{n}"), true));
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
    coach.prompt("long", &long);
    coach.prompt("long-no", &format!("no, {long}"));
    assert_eq!(coach.corrections[0].chars().count(), MAX_PROMPT_CHARS + 1);
    for n in 0..MAX_KEPT + 4 {
        coach.prompt(&format!("try-{n}"), &format!("no, try {n}"));
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

/// Three corrections, the last still running: the person queues their go-ahead behind it. The
/// correction's turn ending is not the go-ahead's (cmux#38893 review, `prompt_coach.rs:821`).
#[test]
fn a_queued_go_ahead_settles_only_its_own_turn() {
    let mut coach = Coach::default();
    for (id, text) in
        [("p0", "add retries"), ("p1", "no, only on 5xx"), ("p2", "still wrong, use the helper")]
    {
        coach.prompt(id, text);
        assert!(!coach.turn_ended(id, true));
    }
    coach.prompt("p3", "actually cap it at 30 seconds");
    coach.prompt("p4", "great, ship it");
    assert!(!coach.turn_ended("p3", true), "the correction's turn: the person did not move on yet");
    assert!(coach.turn_ended("p4", true), "the go-ahead's own turn");
}

/// The person's go-ahead waits while an agent's (or a peer's) turn runs: that turn ends with an id
/// the person never sent, so it decides nothing and leaves the go-ahead for its own turn.
#[test]
fn a_turn_no_person_started_leaves_the_persons_prompt_alone() {
    let mut coach = Coach::default();
    for (id, text) in [
        ("p0", "add retries"),
        ("p1", "no, only on 5xx"),
        ("p2", "still wrong"),
        ("p3", "I meant a cap"),
    ] {
        coach.prompt(id, text);
        coach.turn_ended(id, true);
    }
    coach.prompt("p4", "thanks, looks right");
    assert!(!coach.turn_ended("agent-turn", true), "an agent's turn");
    assert!(coach.turn_ended("p4", true), "the person's own turn still counts");
    // A stopped turn drops its prompt: it never counts later.
    let mut stopped = Coach::default();
    for (id, text) in
        [("p0", "no, use the pool"), ("p1", "no, in rust"), ("p2", "no, keep the old name")]
    {
        stopped.prompt(id, text);
    }
    stopped.prompt("p3", "ok good");
    assert!(!stopped.turn_ended("p3", false));
    assert!(!stopped.turn_ended("p3", true), "settled once");
}

/// A resend of a prompt still waiting for its turn (a client retry, same id) counts once.
#[test]
fn a_resent_prompt_counts_once() {
    let mut coach = Coach::default();
    coach.prompt("p0", "no, the other file");
    coach.prompt("p0", "no, the other file");
    assert_eq!(coach.count(), 1);
}
