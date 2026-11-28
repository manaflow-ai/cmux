//! Mirrors WorkspaceActivityNameTests' pure cases.

use super::*;

fn chat(title: &str, prompts: &[&str]) -> Tab {
    Tab::Chat {
        title: Some(title.to_owned()),
        prompts: prompts.iter().map(|p| (*p).to_owned()).collect(),
    }
}

#[test]
fn the_prompt_lists_chat_titles_prompts_folders_and_page_titles() {
    let activity = Activity::new([
        chat("Fix the login bug", &["Second ask", "Third ask", "Fourth ask"]),
        Tab::Terminal { folder: Some("/Users/me/web".into()), title: Some("npm test".into()) },
        Tab::Browser { title: Some("Login · Docs".into()) },
    ]);
    assert_eq!(
        activity.prompt(),
        "Name this workspace in 2 to 5 words from what its tabs show.\n\
         Reply with the name only: no quotes, no punctuation at the end, no explanation.\n\
         \n\
         Tabs:\n\
         - Agent chat: Fix the login bug\n  - asked: Second ask\n  - asked: Third ask\n  - asked: Fourth ask\n\
         - Terminal in /Users/me/web: npm test\n\
         - Web page: Login · Docs"
    );
}

#[test]
fn empty_tabs_are_dropped_and_an_incognito_page_sends_nothing() {
    let activity = Activity::new([
        Tab::Browser { title: None },
        Tab::Chat { title: None, prompts: vec![] },
        Tab::Terminal { folder: None, title: None },
    ]);
    assert!(activity.tabs.is_empty());
    let crowded = Activity::new((0..40).map(|n| Tab::Browser { title: Some(format!("page {n}")) }));
    assert_eq!(crowded.tabs.len(), TAB_LIMIT);
}

#[test]
fn the_prompt_stays_under_the_completion_limit() {
    let long = "界".repeat(SNIPPET_LIMIT);
    let activity = Activity::new((0..12).map(|_| chat("Chat", &[&long, &long, &long])));
    assert!(activity.prompt().len() <= PROMPT_BYTE_LIMIT);
    assert!(activity.prompt().contains("- Agent chat: Chat"));
}

#[test]
fn snippets_are_one_short_line() {
    let long = "word ".repeat(60);
    let snippet = snippet(Some(&format!("a\n\n  b \t{long}"))).unwrap();
    assert!(snippet.starts_with("a b word"));
    assert_eq!(length(&snippet), SNIPPET_LIMIT);
    assert!(snippet.ends_with('…'));
    assert_eq!(super::snippet(Some("  \n ")), None);
    assert_eq!(super::snippet(None), None);
}

#[test]
fn the_reply_keeps_its_first_line_without_quotes_labels_or_extra_words() {
    assert_eq!(
        name_from_reply("\"Login Bug Fix\"\n\nThis workspace is about…").as_deref(),
        Some("Login Bug Fix")
    );
    assert_eq!(
        name_from_reply("Name: Release notes draft.").as_deref(),
        Some("Release notes draft")
    );
    assert_eq!(name_from_reply("**Sidebar drag polish**").as_deref(), Some("Sidebar drag polish"));
    assert_eq!(
        name_from_reply("one two three four five six seven").as_deref(),
        Some("one two three four five")
    );
    assert_eq!(name_from_reply(" \n\"\" "), None);
    assert_eq!(name_from_reply("NAME:Docs!").as_deref(), Some("Docs"));
}
