//! hq#2509: a lane's step says what the session is doing now, and a secret
//! pasted into the prompt never leaves the daemon in it.

use serde_json::{Value, json};

use super::lane;

/// A fake token, assembled so no file holds one.
fn github_token() -> String {
    format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234")
}

fn running(prompt: &str) -> Value {
    json!({"status": "running", "turn": {"prompt": prompt, "startedAt": 5}, "turnCount": 1, "updatedAt": 9,
           "lastMessage": {"role": "agent", "text": "the last reply"}})
}

#[test]
fn a_running_turns_step_is_its_prompt_on_one_line() {
    assert_eq!(lane(&running("Run the guard\n  tests"))["step"], "Run the guard tests");
}

#[test]
fn a_secret_in_the_prompt_is_masked_in_the_step() {
    let token = github_token();
    let step = lane(&running(&format!("push with GITHUB_TOKEN={token} now")))["step"].clone();
    assert_eq!(step, "push with GITHUB_TOKEN=[github token] now");
    assert!(!step.to_string().contains(&token));
}

#[test]
fn a_secret_past_the_cut_is_masked_before_the_cut() {
    // The token straddles character 240: cutting first would leave its head unmasked.
    let token = github_token();
    let prompt = format!("{} {token} tail", "word ".repeat(46).trim_end());
    let step = lane(&running(&prompt))["step"].as_str().unwrap_or_default().to_owned();
    assert!(!step.contains("ghp_"), "{step}");
    assert!(step.contains(" [github"), "the mask starts where the token did: {step}");
}

#[test]
fn between_turns_the_step_is_the_agents_last_reply_and_never_the_persons_message() {
    let idle = |role: &str| {
        json!({"status": "idle", "turnCount": 1, "updatedAt": 9, "lastTurn": {"endedAt": 8, "status": "completed"},
               "lastMessage": {"role": role, "text": "Opened #21700"}})
    };
    assert_eq!(lane(&idle("agent"))["step"], "Opened #21700");
    assert!(lane(&idle("user"))["step"].is_null());
}

#[test]
fn a_failed_turns_error_is_masked_too() {
    let token = github_token();
    let failed = json!({"status": "idle", "turnCount": 1, "updatedAt": 9,
                        "lastTurn": {"endedAt": 8, "status": "failed", "errorText": format!("401 for token {token}")}});
    let lane = lane(&failed);
    assert_eq!(lane["state"], "failed", "{lane}");
    assert_eq!(lane["error"], "401 for token [github token]");
}

#[test]
fn the_lanes_title_is_masked_and_falls_back_to_the_masked_first_prompt() {
    let token = github_token();
    let titled = json!({"status": "idle", "turnCount": 1, "updatedAt": 9, "title": format!("rotate {token}"),
                        "lastPrompt": "unused"});
    assert_eq!(lane(&titled)["title"], "rotate [github token]");
    let untitled = json!({"status": "idle", "turnCount": 1, "updatedAt": 9,
                          "lastPrompt": format!("push with\n{token}")});
    assert_eq!(lane(&untitled)["title"], "push with [github token]");
    assert!(lane(&json!({"status": "idle", "updatedAt": 9}))["title"].is_null());
}

#[test]
fn a_huge_prompt_is_cut_before_it_is_scanned_and_its_step_still_masks_the_head() {
    // A pasted log: the step reads only its head, so the scan never walks megabytes.
    let token = github_token();
    let prompt = format!("deploy {token} {}", "x".repeat(4_000_000));
    let step = lane(&running(&prompt))["step"].as_str().unwrap_or_default().to_owned();
    assert!(step.starts_with("deploy [github token] x"), "{step}");
}
