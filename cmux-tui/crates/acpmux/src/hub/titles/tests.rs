use super::*;

#[test]
fn only_thin_first_messages_are_eligible_for_a_refresh() {
    for prompt in ["hi", "continue", "OK", "thanks"] {
        assert!(is_thin_prompt(prompt), "{prompt}");
    }
    for prompt in ["Plan a three-dish picnic menu", "Fix the sidebar spinner"] {
        assert!(!is_thin_prompt(prompt), "{prompt}");
    }
}

#[test]
fn a_rename_after_an_empty_title_request_stops_title_requests() {
    for unsettled in [None, Some(PROMPT), Some(ASKED), Some(LAUNCHED)] {
        let mut source = unsettled.map(str::to_owned);
        assert!(renamed_source(&mut source));
        assert_eq!(source.as_deref(), Some(NAMED), "{unsettled:?} renamed title is final");
    }
    for done in [GENERATED, HARNESS, ADOPTED] {
        let mut source = Some(done.to_owned());
        assert!(!renamed_source(&mut source));
        assert_eq!(source.as_deref(), Some(done));
    }
}

#[test]
fn a_retried_title_reads_the_latest_prompt() {
    assert!(
        request("Reply with only: OK", "", true).contains("first message:\nReply with only: OK")
    );
    assert!(
        request("Fix the sidebar spinner", "", false)
            .contains("latest message:\nFix the sidebar spinner")
    );
}

#[test]
fn a_named_subsession_is_titled_by_its_name_not_its_prompt() {
    // The session name made it NAMED (`lifecycle.rs`); the requested name titles it.
    let (mut title, mut source) = (None, Some(NAMED.to_owned()));
    subsession_title_fields(&mut title, &mut source, Some("  sidebar-cleanup "));
    assert_eq!(title.as_deref(), Some("sidebar-cleanup"));
    assert_eq!(source.as_deref(), Some(NAMED));
}

#[test]
fn an_unnamed_subsession_gets_a_generated_title() {
    // Not NAMED: the first prompt's line is only the fallback, and a title is generated after it.
    for started in [NAMED, LAUNCHED] {
        let (mut title, mut source) = (None, Some(started.to_owned()));
        subsession_title_fields(&mut title, &mut source, Some(" "));
        assert_eq!((title, source), (None, None), "{started}");
    }
}

#[test]
fn a_chat_started_under_a_name_is_titled_by_its_first_prompt_and_asks_for_a_title() {
    // `--name` (a lane) is a handle: its first prompt titles it and is what the title
    // request reads, as for an unnamed chat (`title_after_prompt` asks only from PROMPT).
    let (mut title, mut source, mut prompt) = (None, Some(LAUNCHED.to_owned()), None);
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Reply with only: OK");
    assert_eq!(source.as_deref(), Some(LAUNCHED), "a probe settles nothing");
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
    assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"));
    assert_eq!(source.as_deref(), Some(PROMPT));
    assert_eq!(prompt.as_deref(), Some("Fix the sidebar spinner"));
    // A renamed chat keeps the line and asks for nothing.
    let (mut title, mut source, mut prompt) = (None, Some(NAMED.to_owned()), None);
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
    assert_eq!(
        (title.as_deref(), source.as_deref()),
        (Some("Fix the sidebar spinner"), Some(NAMED))
    );
    assert_eq!(prompt, None);
}

#[test]
fn a_chat_adopted_under_a_name_keeps_the_title_it_came_with() {
    let mut source = Some(LAUNCHED.to_owned());
    assert!(adopted_source(&mut source));
    assert_eq!(source.as_deref(), Some(ADOPTED));
    let mut source = Some(NAMED.to_owned());
    assert!(!adopted_source(&mut source), "a name given before adoption stays");
}

#[test]
fn a_probe_titles_no_chat_and_the_first_real_message_does() {
    let (mut title, mut source, mut prompt) = (None, None, None);
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Reply with only: OK");
    assert_eq!((title.as_deref(), source.as_deref()), (None, None), "a probe titles nothing");
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
    assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"));
    assert_eq!(source.as_deref(), Some(PROMPT));
    assert_eq!(prompt.as_deref(), Some("Fix the sidebar spinner"), "the title request reads it");
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Now add a test");
    assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"), "a later message keeps it");
}

#[test]
fn a_chat_a_probe_titled_before_takes_the_first_real_message() {
    let mut title = Some("Reply with only: OK".to_owned());
    let mut source = Some(PROMPT.to_owned());
    let mut prompt = None;
    fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
    assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"));
    assert_eq!(prompt.as_deref(), Some("Fix the sidebar spinner"));
    // A title the person or a model gave stays, even one that reads like a probe.
    for kept in [NAMED, GENERATED, HARNESS] {
        let mut title = Some("Reply with only: OK".to_owned());
        let mut source = Some(kept.to_owned());
        fallback_title_fields(&mut title, &mut source, &mut None, "Fix the sidebar spinner");
        assert_eq!(title.as_deref(), Some("Reply with only: OK"), "{kept}");
    }
}

#[test]
fn a_plain_prompt_is_titled_by_its_first_line() {
    let gist = prompt_gist("\n  Plan a three-dish picnic menu\nwith dessert");
    assert_eq!(gist.line, "Plan a three-dish picnic menu");
}

#[test]
fn a_chief_subagent_prompt_is_titled_by_its_task_title_not_its_chat_view() {
    let text = "<chat>\n0+512|user: merge PR 17453\n</chat>Your task:\n\nTitle: ACP agent tab names\nGroup: cmux-next app\nUser (msg 5944): rename the tabs";
    let gist = prompt_gist(text);
    assert_eq!(gist.line, "ACP agent tab names");
    assert!(
        !gist.body.contains("<chat>"),
        "the title command reads the task, not the chat view: {}",
        gist.body
    );
    assert!(gist.body.contains("rename the tabs"));
}

#[test]
fn a_task_without_a_title_header_skips_its_label_and_group() {
    let gist = prompt_gist(
        "<chat>\nview\n</chat>\nYour task:\nGroup: Performance\nMake create and close fast",
    );
    assert_eq!(gist.line, "Make create and close fast");
}

#[test]
fn an_unclosed_context_block_gives_no_title() {
    assert_eq!(prompt_gist("<chat> 0+512|user: merge cmux PR 17453 (outcome?)…").line, "");
}

#[test]
fn a_line_that_only_looks_like_a_tag_still_titles() {
    assert_eq!(prompt_gist("<3 this app, make it faster").line, "<3 this app, make it faster");
    assert_eq!(prompt_gist("a < b: why").line, "a < b: why");
}
