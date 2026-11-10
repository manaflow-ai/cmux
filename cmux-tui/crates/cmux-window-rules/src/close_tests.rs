use super::*;

fn terminal() -> ClosingTab {
    ClosingTab { kind: TabKind::Pty, ..ClosingTab::default() }
}

fn browser(url: &str) -> ClosingTab {
    ClosingTab { kind: TabKind::Browser, url: Some(url.to_owned()), ..ClosingTab::default() }
}

fn agent(name: Option<&str>) -> ClosingTab {
    ClosingTab { agent_at_work: true, agent: name.map(str::to_owned), ..terminal() }
}

fn answer(title: &str, program: Option<&str>) -> TerminalAnswer {
    TerminalAnswer { title: title.to_owned(), answered: true, program: program.map(str::to_owned) }
}

fn no_answer(title: &str) -> TerminalAnswer {
    TerminalAnswer { title: title.to_owned(), answered: false, program: None }
}

const BOTH: Warnings = Warnings { warn_tab: true, warn_agent: true };

#[test]
fn pages_new_tab_pages_and_dead_tabs_reopen_free() {
    for url in ["", "about:blank", "ABOUT:BLANK", "chrome://newtab/", "chrome://newtab"] {
        assert!(reopens_free(&browser(url)), "{url}");
    }
    assert!(reopens_free(&ClosingTab { kind: TabKind::Browser, ..ClosingTab::default() }));
    assert!(!reopens_free(&browser("https://example.com")));
    assert!(reopens_free(&ClosingTab { page: true, ..ClosingTab::default() }));
    assert!(reopens_free(&ClosingTab { new_tab_page: true, ..ClosingTab::default() }));
    assert!(reopens_free(&ClosingTab { dead: true, ..terminal() }));
    assert!(!reopens_free(&terminal()));
    assert!(!reopens_free(&ClosingTab::default()));
}

#[test]
fn a_new_chat_with_typed_text_does_not_reopen_free() {
    let draft = ClosingTab { new_tab_page: true, unsent_draft: true, ..ClosingTab::default() };
    assert!(!reopens_free(&draft));
    assert_eq!(toast(&[draft]), Toast::Show);
}

#[test]
fn several_real_tabs_show_the_toast() {
    assert_eq!(toast(&[browser("https://a.test"), ClosingTab::default()]), Toast::Show);
}

#[test]
fn tabs_that_reopen_free_never_count() {
    assert_eq!(toast(&[browser("about:blank"), browser("https://a.test")]), Toast::Skip);
    assert_eq!(toast(&[]), Toast::Skip);
}

#[test]
fn a_working_tab_shows_the_toast() {
    assert_eq!(toast(&[agent(Some("claude"))]), Toast::Show);
    assert_eq!(toast(&[ClosingTab { status_working: true, ..ClosingTab::default() }]), Toast::Show);
}

#[test]
fn one_idle_terminal_asks_what_it_runs() {
    let tabs = [browser("about:blank"), terminal()];
    assert_eq!(toast(&tabs), Toast::AskTerminals { terminals: vec![1] });
}

#[test]
fn nothing_reads_with_both_warnings_off_or_no_live_terminal() {
    assert_eq!(reads(&[terminal()], Warnings::default()), None);
    assert_eq!(
        reads(&[browser("https://a.test"), ClosingTab { dead: true, ..terminal() }], BOTH),
        None
    );
}

#[test]
fn a_working_agent_is_its_own_question_never_the_program_one() {
    let tabs = [agent(Some("claude")), browser("https://a.test"), terminal(), agent(None)];
    assert_eq!(
        reads(&tabs, BOTH),
        Some(Reads { agents: vec![Some("Claude".to_owned()), None], others: vec![2] })
    );
}

#[test]
fn agent_names_read_capitalized() {
    assert_eq!(display_name(Some("claude")), Some("Claude".to_owned()));
    assert_eq!(display_name(Some("éclair")), Some("Éclair".to_owned()));
    assert_eq!(display_name(Some("")), None);
    assert_eq!(display_name(None), None);
}

#[test]
fn the_agent_warning_comes_first() {
    let agents = [Some("Claude".to_owned()), Some("Codex".to_owned())];
    assert_eq!(
        warning(&agents, &[answer("zsh", Some("vim"))], true, BOTH),
        Some(Warning::Agent { name: Some("Claude".to_owned()) })
    );
    let off = Warnings { warn_agent: false, ..BOTH };
    assert_eq!(
        warning(&agents, &[answer("zsh", Some("vim"))], true, off),
        Some(Warning::Programs { programs: vec!["vim".to_owned()], unanswered: vec![] })
    );
}

#[test]
fn programs_are_unique_and_sorted_and_a_shell_asks_nothing() {
    let answers = [
        answer("a", Some("vim")),
        answer("b", Some("htop")),
        answer("c", Some("vim")),
        answer("d", None),
    ];
    assert_eq!(
        warning(&[], &answers, false, BOTH),
        Some(Warning::Programs {
            programs: vec!["htop".to_owned(), "vim".to_owned()],
            unanswered: vec![]
        })
    );
    assert_eq!(warning(&[], &[answer("a", None)], true, BOTH), None);
}

#[test]
fn a_terminal_with_no_answer_asks_only_a_persons_close() {
    let answers = [no_answer("build"), answer("b", None)];
    assert_eq!(
        warning(&[], &answers, true, BOTH),
        Some(Warning::Programs { programs: vec![], unanswered: vec!["build".to_owned()] })
    );
    assert_eq!(warning(&[], &answers, false, BOTH), None);
    let tab_off = Warnings { warn_tab: false, ..BOTH };
    assert_eq!(warning(&[], &answers, true, tab_off), None);
}

#[test]
fn the_wire_reads_the_apps_spelling() {
    let tab: ClosingTab = serde_json::from_str(
        r#"{"kind":"pty","agentAtWork":true,"agent":"claude","unsentDraft":false,"newTabPage":false}"#,
    )
    .expect("tab");
    assert_eq!(tab, agent(Some("claude")));
    let other: ClosingTab = serde_json::from_str(r#"{"kind":"markdown"}"#).expect("other kind");
    assert_eq!(other.kind, TabKind::Other);
    assert_eq!(
        serde_json::to_value(Toast::AskTerminals { terminals: vec![0] }).expect("toast"),
        serde_json::json!({"decision": "askTerminals", "terminals": [0]})
    );
    assert_eq!(
        serde_json::to_value(Warning::Agent { name: None }).expect("warning"),
        serde_json::json!({"kind": "agent", "name": null})
    );
}

#[test]
fn tab_warnings_off_read_no_terminal() {
    let agent_only = Warnings { warn_tab: false, warn_agent: true };
    assert_eq!(
        reads(&[agent(Some("claude")), terminal()], agent_only),
        Some(Reads { agents: vec![Some("Claude".to_owned())], others: vec![] })
    );
}
