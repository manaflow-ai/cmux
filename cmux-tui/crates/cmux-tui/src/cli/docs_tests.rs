use super::*;

#[test]
fn search_requires_all_terms_and_returns_browser_operations() {
    let results = search("browser navigate");
    assert!(results.iter().any(|result| result.name == "browser.navigate"));
    assert!(results.iter().all(|result| result.name.contains("browser")));
}

#[test]
fn scope_help_is_catalog_backed() {
    let help = scope_help("terminal");
    assert!(help.contains("terminal.screen.read [read]"));
    assert!(has_scope_operations("browser"));
    assert!(has_scope_operations("sidebar"));
    assert!(has_scope_operations("pairing"));
    assert!(has_scope_operations("projection"));
}

/// An agent that wants another agent to do work finds the chat verbs.
#[test]
fn starting_another_agent_finds_its_guide() {
    for query in ["spawn an agent", "interrupt", "screenshot a pane"] {
        let found = guides(query);
        assert_eq!(found.len(), 1, "{query}");
        assert!(found[0].text.contains("agents chat new"), "{query}");
    }
}

/// An agent that searches in its own words for showing its work finds
/// the guide, and the guide names only tools that exist.
#[test]
fn showing_work_to_the_user_finds_its_guide() {
    for query in ["show the user", "status", "open a chat"] {
        assert_eq!(guides(query).len(), 1, "{query}");
    }
    assert!(guides("browser navigate").is_empty());
    let operations = catalog()["operations"].as_object().unwrap();
    for op in [
        "workspace.open_url",
        "browser.profile.open",
        "workspace_status.set",
        "workspace_progress.set",
        "workspace_log.append",
        "notification.create",
        "tab.focus",
    ] {
        assert!(operations.contains_key(op), "{op}");
        assert!(GUIDES[0].text.contains(&op.replace('.', "_")), "{op}");
    }
}

/// `cmux docs search setup` and an agent asking in its own words for
/// setup prompts or a remote machine find the Chief prompts guide, and it
/// sends them to `cmux setup list`, where the prompts live.
#[test]
fn chief_prompt_guide_is_found_by_setup_words() {
    let topic = "Set up cmux with Chief: copyable setup prompts";
    for query in ["setup", "chief setup prompts", "set up a remote machine", "pair a tailnet mac"] {
        assert!(guides(query).iter().any(|guide| guide.topic == topic), "{query}");
    }
    let guide = GUIDES.iter().find(|guide| guide.topic == topic).unwrap();
    for words in ["`cmux setup list`", "`prompt`", "docs/chief-setup-prompts.md", "--prompts-md"] {
        assert!(guide.text.contains(words), "{words}");
    }
    assert_eq!(guides("status").len(), 1);
}

#[test]
fn docs_search_preserves_json_output_mode() {
    let plan = parse(
        &["search".to_owned(), "browser".to_owned(), "navigate".to_owned()],
        OutputMode::Json,
    )
    .unwrap();
    assert_eq!(plan.query, "browser navigate");
    assert_eq!(plan.output, OutputMode::Json);
}
