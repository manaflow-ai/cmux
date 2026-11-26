//! Parity with the Swift tests these rules came from
//! (`NotificationBannerContentTests`), plus the regex edge cases the
//! hand-written matchers must keep.

use super::*;

fn banner(
    headline: &str,
    poster: Option<&str>,
    body: &str,
    workspace: Option<&str>,
    tab: Option<&str>,
) -> Facts {
    Facts {
        headline: headline.into(),
        poster_subtitle: poster.map(Into::into),
        body: body.into(),
        workspace: workspace.map(Into::into),
        tab: tab.map(Into::into),
        ..Facts::default()
    }
}

fn plain(markdown: &str) -> String {
    plain_text(markdown, MAX_BODY_CHARACTERS)
}

#[test]
fn an_agent_finished_names_the_workspace_and_tab_and_says_what_the_agent_said() {
    let content = content(&banner(
        "Claude finished",
        None,
        "Fixed the **flaky** login test and pushed `main`.",
        Some("api-server"),
        Some("Claude Code"),
    ));
    assert_eq!(content.title, "api-server › Claude Code");
    assert_eq!(content.subtitle.as_deref(), Some("Claude finished"));
    assert_eq!(content.body, "Fixed the flaky login test and pushed main.");
}

#[test]
fn a_chat_named_like_the_headline_is_not_repeated() {
    let content = content(&banner(
        "Fix login needs input",
        None,
        "Run the tests?",
        Some("api"),
        Some("Fix login"),
    ));
    assert_eq!(content.title, "api › Fix login");
    assert_eq!(content.subtitle.as_deref(), Some("Needs input"));
}

#[test]
fn a_tab_named_like_its_workspace_shows_the_workspace_once() {
    let content = content(&banner("Codex finished", None, "", Some("web"), Some("web")));
    assert_eq!(content.title, "web");
}

#[test]
fn a_terminal_program_writes_only_the_subtitle_and_body() {
    let content =
        content(&banner("Build finished", None, "42 targets in 3m", Some("ios"), Some("zsh")));
    assert_eq!(content.title, "ios › zsh", "the app, not the program, names where it came from");
    assert_eq!(content.subtitle.as_deref(), Some("Build finished"));
    assert_eq!(content.body, "42 targets in 3m");
}

#[test]
fn a_notify_subtitle_follows_the_headline() {
    let content =
        content(&banner("Deploy", Some("staging"), "done", Some("infra"), Some("deploy")));
    assert_eq!(content.subtitle.as_deref(), Some("Deploy · staging"));
}

#[test]
fn a_remote_terminal_names_its_machine() {
    let mut facts = banner("Claude finished", None, "", Some("api"), Some("claude"));
    facts.host = Some("cmux-mini-3".into());
    assert_eq!(content(&facts).title, "api › claude · cmux-mini-3");
}

#[test]
fn without_a_tab_the_headline_is_the_title() {
    let content = content(&banner("Claude finished", Some("x"), "ok", None, None));
    assert_eq!(content.title, "Claude finished");
    assert_eq!(content.subtitle.as_deref(), Some("x"));
}

#[test]
fn without_a_workspace_or_headline_the_tab_then_cmux_is_the_title() {
    assert_eq!(content(&banner("  ", None, "", None, Some("zsh"))).title, "zsh");
    assert_eq!(content(&banner("", None, "", Some(" "), None)).title, "cmux");
}

#[test]
fn markdown_becomes_plain_text() {
    let markdown = "## Summary\n\n- Fixed [the login bug](https://github.com/x/y/pull/1)\n- Added ![a screenshot](shot.png) and *two* tests\n\n```swift\nlet x = 1\n```\n> Pushed to __main__.";
    assert_eq!(
        plain(markdown),
        "Summary\n• Fixed the login bug\n• Added a screenshot and two tests\nlet x = 1\nPushed to main."
    );
}

#[test]
fn snake_case_and_arithmetic_keep_their_characters() {
    assert_eq!(plain("set max_retries to 2*3*4"), "set max_retries to 2*3*4");
}

#[test]
fn a_long_message_is_cut_on_a_word() {
    let long = vec!["word"; 100].join(" ");
    let body = plain(&long);
    assert!(body.graphemes(true).count() <= 241);
    assert!(body.ends_with("word…"), "{body}");
}

#[test]
fn a_long_name_is_cut() {
    let content = content(&banner("", None, "", Some(&"w".repeat(60)), None));
    assert_eq!(content.title, "w".repeat(39) + "…");
    assert_eq!(content.subtitle, None);
}

#[test]
fn a_body_kept_as_given_is_not_cut_or_cleaned() {
    let mut facts = banner("Approve?", None, "**rm** -rf build\n\n", Some("api"), Some("zsh"));
    facts.plain = false;
    assert_eq!(content(&facts).body, "**rm** -rf build\n\n");
}

#[test]
fn headings_quotes_and_bullets_lose_their_marks() {
    assert_eq!(plain("###### six"), "six");
    assert_eq!(plain("####### seven"), "####### seven", "a heading has at most six marks");
    assert_eq!(plain("#tag"), "#tag", "a heading mark needs a space after it");
    assert_eq!(plain("> > >nested"), "nested");
    assert_eq!(plain("*   item"), "• item");
    assert_eq!(plain("+ item"), "• item");
    assert_eq!(plain("-item"), "-item");
}

#[test]
fn emphasis_follows_the_app_regexes() {
    assert_eq!(plain("*a*"), "a", "one character between the stars");
    assert_eq!(plain("*lead* and *tail*"), "lead and tail");
    assert_eq!(plain("a*b*"), "a*b*", "the opening star follows no word character");
    assert_eq!(plain("(*x*)"), "(x)");
    assert_eq!(plain("* not a bullet*"), "• not a bullet*");
    assert_eq!(plain("*x*y"), "*x*y", "the closing star is followed by no word character");
    assert_eq!(plain("__a__ ***b***"), "a b");
    // The app's bold regex tries its longer form first, so its text runs to the line's last closing
    // mark: kept as the app had it (this is a move, not a redesign).
    assert_eq!(plain("**a** and **b**"), "a** and **b");
    assert_eq!(plain("**a**b**"), "a**b");
    assert_eq!(plain("*a**b*"), "*a**b*");
    assert_eq!(plain("x *a *b* c*"), "x *a b c*");
    assert_eq!(plain("~~gone~~ ~~~~"), "gone ~~~~");
    assert_eq!(plain("~~a~~b~~"), "ab~~");
}

#[test]
fn links_and_images_keep_their_text() {
    assert_eq!(plain("see [docs](x) and ![](y)"), "see docs and");
    assert_eq!(plain("[](x)"), "[](x)", "a link needs text");
    assert_eq!(plain("[a] (x)"), "[a] (x)");
    assert_eq!(plain("[a](x"), "[a](x");
}

#[test]
fn lines_are_split_on_newlines_and_trimmed_of_spaces_only() {
    assert_eq!(plain("\u{a0} one \t\n\n  two"), "one\ntwo");
    assert_eq!(plain("~~~\nfenced\n```"), "fenced");
}

#[test]
fn lengths_count_characters_not_bytes() {
    let flags = "🇯🇵".repeat(50);
    let content = content(&banner("", None, "", Some(&flags), None));
    assert_eq!(content.title, "🇯🇵".repeat(39) + "…");
}

#[test]
fn a_cut_without_a_late_space_keeps_the_characters() {
    let text = "a ".to_owned() + &"b".repeat(300);
    let body = plain_text(&text, 240);
    assert_eq!(body, "a ".to_owned() + &"b".repeat(237) + "…");
}
