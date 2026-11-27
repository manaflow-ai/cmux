use super::*;
use crate::entry::{AdapterKind, Resume};

fn entry(id: &str, title: Option<(&str, TitleSource)>) -> ChatEntry {
    ChatEntry {
        harness: AdapterKind::ClaudeCode,
        session_id: id.to_owned(),
        title: title.map(|(text, _)| text.to_owned()),
        title_source: title.map(|(_, source)| source),
        cwd: None,
        created_ms: None,
        updated_ms: 0,
        message_count: None,
        source_path: PathBuf::new(),
        originator: None,
        archived: false,
        resume: Resume::Adopt,
    }
}

fn write_session(support: &Path, store: &str, file: &str, body: &Value) {
    let dir = support.join(store).join("account").join("org");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join(file), serde_json::to_vec(body).unwrap()).unwrap();
}

#[test]
fn a_desktop_session_takes_the_desktop_title_and_originator() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join(".claude/projects");
    fs::create_dir_all(&root).unwrap();
    let support = home.path().join("Library/Application Support/Claude");
    write_session(
        &support,
        "claude-code-sessions",
        "local_a.json",
        &serde_json::json!({"sessionId": "local_a", "cliSessionId": "cli-a", "title": "Fix the sidebar footer"}),
    );
    write_session(
        &support,
        "local-agent-mode-sessions",
        "local_b.json",
        &serde_json::json!({"sessionId": "local_b", "cliSessionId": "cli-b", "title": "Agent run"}),
    );
    let mut entries = vec![
        entry("cli-a", Some(("first prompt", TitleSource::Prompt))),
        entry("cli-b", None),
        entry("cli-other", Some(("terminal chat", TitleSource::Ai))),
    ];
    apply(&root, &mut entries);
    assert_eq!(entries[0].title.as_deref(), Some("Fix the sidebar footer"));
    assert_eq!(entries[0].title_source, Some(TitleSource::Custom));
    assert_eq!(entries[0].originator.as_deref(), Some(ORIGINATOR));
    assert_eq!(entries[1].title.as_deref(), Some("Agent run"));
    assert_eq!(entries[1].originator.as_deref(), Some(ORIGINATOR));
    assert_eq!(entries[2].title.as_deref(), Some("terminal chat"));
    assert_eq!(entries[2].originator, None);
}

#[test]
fn a_cli_rename_outranks_the_desktop_title() {
    let mut sessions = HashMap::new();
    sessions.insert(
        "cli-a".to_owned(),
        DesktopSession { cli_session_id: "cli-a".to_owned(), title: Some("Desktop".to_owned()) },
    );
    let mut entries = vec![entry("cli-a", Some(("Renamed", TitleSource::Custom)))];
    apply_sessions(&sessions, &mut entries);
    assert_eq!(entries[0].title.as_deref(), Some("Renamed"));
    assert_eq!(entries[0].originator.as_deref(), Some(ORIGINATOR));
}

#[test]
fn only_a_default_projects_root_has_a_desktop_store() {
    assert_eq!(default_root_home(Path::new("/u/.claude/projects")), Some(Path::new("/u")));
    assert_eq!(default_root_home(Path::new("/u/custom-claude/projects")), None);
    assert_eq!(default_root_home(Path::new("/u/.claude")), None);
}

#[test]
fn a_session_file_without_a_cli_id_or_too_large_is_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("local_x.json");
    fs::write(&path, br#"{"sessionId":"local_x","title":"No transcript yet"}"#).unwrap();
    assert_eq!(parse(&path), None);
    fs::write(&path, br#"{"cliSessionId":"","title":"t"}"#).unwrap();
    assert_eq!(parse(&path), None);
    fs::write(&path, br#"{"cliSessionId":"c","title":"  \n Line two"}"#).unwrap();
    assert_eq!(
        parse(&path),
        Some(DesktopSession { cli_session_id: "c".to_owned(), title: Some("Line two".to_owned()) })
    );
}
