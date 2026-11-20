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
fn sidebar_requires_open_only_marks_agent_started_sessions() {
    assert_eq!(
        lane(&json!({"status": "running", "tags": {"lane.reportsTo": "coordinator"}}))["requiresOpen"],
        true
    );
    assert_eq!(
        lane(&json!({"status": "running", "parentId": "personal-fork"}))["requiresOpen"],
        false
    );
    assert_eq!(lane(&json!({"status": "running", "parent": "coordinator"}))["requiresOpen"], true);
    assert_eq!(
        lane(&json!({"status": "running", "spawnedBy": "coordinator"}))["requiresOpen"],
        true
    );
    assert_eq!(
        lane(&json!({"status": "running", "tags": {"spawnedBy": "coordinator"}}))["requiresOpen"],
        true
    );
    assert_eq!(
        lane(&json!({"status": "running", "tags": {"mux.parent": "coordinator"}}))["requiresOpen"],
        true
    );
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

/// A harness title that is a whole prompt shows as its first 200 characters in every summary; a
/// shorter one is untouched, its spacing too.
#[test]
fn a_summary_title_is_at_most_200_characters() {
    use super::{TITLE_CHARS, summary_title};
    let short = "Fix  the\nsidebar";
    assert_eq!(summary_title(short), short);
    let edge = "é".repeat(TITLE_CHARS);
    assert_eq!(summary_title(&edge), edge);
    let prompt = "You are a fix helper. ".repeat(400);
    let cut = summary_title(&prompt);
    assert_eq!(cut.chars().count(), TITLE_CHARS + 1, "{cut}");
    assert!(cut.ends_with('…') && prompt.starts_with(cut.trim_end_matches('…').trim_end()));
}

/// A peer's row heard as a census row is cut the same, whatever acpmux the peer runs.
#[test]
fn a_peers_census_row_cuts_its_title_too() {
    let row =
        json!({"sessionId": "p", "title": "x".repeat(5_000), "tools": [], "toolsMutable": true});
    let census = super::without_summary_tools(row);
    assert_eq!(census["title"].as_str().unwrap().chars().count(), super::TITLE_CHARS + 1);
    assert!(census.get("tools").is_none() && census.get("toolsMutable").is_none());
    let short = super::without_summary_tools(json!({"sessionId": "p", "title": "a  b"}));
    assert_eq!(short["title"], "a  b");
}

/// A secret the title's cut would split is masked whole first: no head of it is left for a
/// peer's masking to miss.
#[test]
fn a_secret_across_the_title_cut_is_masked_before_the_cut() {
    let title = format!("{} {} {}", "a".repeat(180), github_token(), "b".repeat(300));
    let cut = super::summary_title(&title);
    assert!(!cut.contains("ghp_"), "{cut}");
    assert!(cut.chars().count() <= super::TITLE_CHARS + 1, "{cut}");
    let census = super::without_summary_tools(json!({"title": title}));
    assert!(!census["title"].as_str().unwrap().contains("ghp_"), "{census}");
}

/// Leo, 2026-10-30, on his sidebar: "a lot of these subtitles are bad". A running turn's step
/// (the sidebar's Now line, the hover card's task) reads another agent's message as its sender
/// and first line, as `lastPrompt` does (`prompt_line.rs`), never the envelope it came in.
#[test]
fn another_agents_message_steps_as_its_sender_and_first_line_never_its_envelope() {
    use super::super::{Control, TurnInfo, prompt_line::prompt_line};
    let step = |t: &TurnInfo| lane(&running(&t.masked_preview))["step"].clone();
    // `acpmux send` at a shell: the sender's name in brackets.
    let shell = "[coord] Fix the grid spacing\nmore below";
    let t = TurnInfo::prompted("acpmux-cli#7", shell, "t1", "p1", Control::Local);
    assert_eq!(step(&t), "coord: Fix the grid spacing");
    assert_eq!(t.masked_preview, "coord: Fix the grid spacing");
    // The turn's records keep the prompt as it was sent.
    assert_eq!(t.prompt_preview, "[coord] Fix the grid spacing more below");
    // A cmux agent message: its provenance names the sender and where its words are.
    let envelope = "[cmux agent message] from coord-deputy (acp:abc)\nMessage id: m1\n\
                    This message was delivered by cmux from another agent or person.\n\
                    Reply with: cmux agent message --reply-to m1 \"<text>\"\n---\n\n\
                    Merged #23727\nMore below\n--- end of message m1 ---";
    let p = json!({"kind": "agent_message", "from": "acp:abc", "fromName": "coord-deputy", "msgId": "m1"});
    let t = TurnInfo::prompted("cmux", envelope, "t2", "p2", Control::Local)
        .shown_as(&prompt_line(envelope, "cmux", Some(&p)));
    assert_eq!(step(&t), "coord-deputy: Merged #23727");
    assert!(!t.masked_preview.contains("Message id"), "{}", t.masked_preview);
    // A lane's report to its parent: its first line, never its session's id.
    let report = "[child] lane report: turn 5 ended, done.\nSession: 01a18a3e-239e-7ef1-8c37-b22b3a8da2e6\nLast message: ok";
    let p = json!({"kind": "lane_report", "from": "s1", "fromName": "child"});
    let t = TurnInfo::prompted("acpmux", report, "t3", "p3", Control::Local)
        .shown_as(&prompt_line(report, "acpmux", Some(&p)));
    assert_eq!(step(&t), "child: lane report: turn 5 ended, done.");
    // A secret in another agent's words is still masked in the line.
    let token = github_token();
    let t = TurnInfo::prompted(
        "acpmux-cli#7",
        &format!("[coord] push with {token}"),
        "t4",
        "p4",
        Control::Local,
    );
    assert!(!t.masked_preview.contains(&token), "{}", t.masked_preview);
    assert!(!step(&t).as_str().unwrap_or_default().contains(&token));
    // A secret the cleaned line's cut falls inside is masked before the cut, never its head left:
    // the step's scan could not tell a token's head.
    let words = format!("{}{token} tail", "word ".repeat(36));
    let envelope = format!(
        "[cmux agent message] from coord-deputy (acp:abc)\nMessage id: m2\n---\n{words}\n--- end of message m2 ---"
    );
    let p = json!({"kind": "agent_message", "from": "acp:abc", "fromName": "coord-deputy", "msgId": "m2"});
    let t = TurnInfo::prompted("cmux", &envelope, "t6", "p6", Control::Local)
        .shown_as(&prompt_line(&envelope, "cmux", Some(&p)));
    assert!(!t.masked_preview.contains("ghp_"), "{}", t.masked_preview);
    assert!(
        t.masked_preview.contains("word [GitHu"),
        "the mask starts where the token did: {}",
        t.masked_preview
    );
    assert!(!step(&t).as_str().unwrap_or_default().contains("ghp_"));
    // A restart shows the line the turn recorded (`promptLine`) as it was: no word is lost again.
    let again = TurnInfo::prompted("cmux", &envelope, "t6", "p6", Control::Local)
        .shown_as(&t.masked_preview);
    assert_eq!(again.masked_preview, t.masked_preview);
    let t = TurnInfo::prompted("acpmux-cli#7", "[coord] Checking…", "t7", "p7", Control::Local);
    assert_eq!(t.masked_preview, "coord: Checking…");
    let again =
        TurnInfo::prompted("x", "y", "t7", "p7", Control::Local).shown_as(&t.masked_preview);
    assert_eq!(again.masked_preview, "coord: Checking…");
    // The person's own prompt stays as it is.
    let t =
        TurnInfo::prompted("acpmux-cli#7", "Run the guard\n  tests", "t5", "p5", Control::Local);
    assert_eq!(step(&t), "Run the guard tests");
}
