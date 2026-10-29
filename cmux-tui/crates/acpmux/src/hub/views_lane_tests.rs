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
    assert_eq!(step, "push with GITHUB_TOKEN=[GitHub Personal Access Token] now");
    assert!(!step.to_string().contains(&token));
}

#[test]
fn a_secret_past_the_cut_is_masked_before_the_cut() {
    // The token straddles character 240: cutting first would leave its head unmasked.
    let token = github_token();
    let prompt = format!("{} {token} tail", "word ".repeat(46).trim_end());
    let step = lane(&running(&prompt))["step"].as_str().unwrap_or_default().to_owned();
    assert!(!step.contains("ghp_"), "{step}");
    assert!(step.contains(" [GitHub"), "the mask starts where the token did: {step}");
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
    assert_eq!(lane["error"], "401 for token [GitHub Personal Access Token]");
}

/// A failed turn's error can be a whole pasted log: only its head is
/// scanned, and the error is cut there, masked first.
#[test]
fn a_huge_error_is_cut_before_it_is_scanned_and_its_head_still_masked() {
    let token = github_token();
    let error = format!("401 for {token} {}", "x".repeat(4_000_000));
    let failed = json!({"status": "idle", "turnCount": 1, "updatedAt": 9,
                        "lastTurn": {"endedAt": 8, "status": "failed", "errorText": error}});
    let lane = lane(&failed);
    let error = lane["error"].as_str().unwrap();
    assert!(error.starts_with("401 for [GitHub Personal Access Token] x"), "{}", &error[..60]);
    assert!(error.ends_with('…'), "the error was not cut");
    assert!(error.chars().count() <= 3_073, "{} chars", error.chars().count());
}

#[test]
fn the_lanes_title_is_masked_and_falls_back_to_the_masked_latest_prompt() {
    let token = github_token();
    let titled = json!({"status": "idle", "turnCount": 1, "updatedAt": 9, "title": format!("rotate {token}"),
                        "lastPrompt": "unused"});
    assert_eq!(lane(&titled)["title"], "rotate [GitHub Personal Access Token]");
    let untitled = json!({"status": "idle", "turnCount": 1, "updatedAt": 9,
                          "lastPrompt": format!("push with\n{token}")});
    assert_eq!(lane(&untitled)["title"], "push with [GitHub Personal Access Token]");
    assert!(lane(&json!({"status": "idle", "updatedAt": 9}))["title"].is_null());
}

#[test]
fn a_huge_prompt_is_cut_before_it_is_scanned_and_its_step_still_masks_the_head() {
    // A pasted log: the step reads only its head, so the scan never walks megabytes.
    let token = github_token();
    let prompt = format!("deploy {token} {}", "x".repeat(4_000_000));
    let step = lane(&running(&prompt))["step"].as_str().unwrap_or_default().to_owned();
    assert!(step.starts_with("deploy [GitHub Personal Access Token] x"), "{step}");
}

#[test]
fn whitespace_before_a_secret_does_not_move_the_scan_cut_into_it() {
    // The step folds whitespace, so the scan must cut the folded text: cutting the raw text
    // inside the token would leave its head unmasked once the blank run folds away.
    let token = github_token();
    let prompt = format!("{}{token} tail", " ".repeat(4_090));
    let step = lane(&running(&prompt))["step"].as_str().unwrap_or_default().to_owned();
    assert_eq!(step, "[GitHub Personal Access Token] tail");
}

/// manaflow-ai/cmux#25230: between turns, work the session started that still runs keeps it
/// working; a failed last turn, a lost agent and a peer gone unreachable still say so.
#[test]
fn work_below_the_turn_is_working_unless_the_chat_failed_or_its_peer_went() {
    use super::status_indicator;
    let at = |status: &str, last: Option<&str>| {
        let mut s = json!({"status": status, "turnCount": 1, "updatedAt": 9, "subagentsWorkingSince": 7,
                           "lastTurn": {"endedAt": 6}});
        match last {
            Some(last) => s["lastTurn"]["status"] = json!(last),
            None => s["lastTurn"] = Value::Null,
        }
        s
    };
    let ready = at("ready", Some("completed"));
    assert_eq!(status_indicator(&ready), Some("working"));
    assert_eq!(lane(&ready)["state"], "working");
    assert_eq!(lane(&ready)["since"], 7);
    // Its harness stopped for idleness while a sub-session it started runs.
    assert_eq!(status_indicator(&at("idle", Some("completed"))), Some("working"));
    assert_eq!(status_indicator(&at("disconnected", Some("completed"))), Some("working"));
    assert_eq!(status_indicator(&at("ready", None)), Some("working"));
    assert_eq!(status_indicator(&at("ready", Some("failed"))), Some("failed"));
    assert_eq!(status_indicator(&at("disconnected", Some("cancelled"))), Some("lost"));
    assert_eq!(status_indicator(&at("unreachable", Some("completed"))), Some("done"));
    assert_eq!(status_indicator(&at("unreachable", None)), None);
    assert_eq!(status_indicator(&at("closed", Some("completed"))), None);
    let mut done = at("ready", Some("completed"));
    done["subagentsWorkingSince"] = Value::Null;
    assert_eq!(status_indicator(&done), Some("done"));
}
