use super::*;

fn folder(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (name, text) in files {
        let path = dir.path().join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    dir
}

#[test]
fn claude_gets_agents_md_when_the_folder_has_no_claude_md() {
    let dir = folder(&[("AGENTS.md", "codeword KESTREL"), (".codex/config.toml", "")]);
    let got = part("claude", dir.path()).unwrap();
    assert_eq!(got.source, SOURCE);
    assert_eq!(got.label, "Folder instructions (AGENTS.md)");
    assert!(got.text.unwrap().contains("codeword KESTREL"));
}

#[test]
fn a_harness_with_its_own_file_gets_nothing() {
    let dir = folder(&[("AGENTS.md", "a"), ("CLAUDE.md", "c")]);
    assert!(part("claude", dir.path()).is_none());
    assert!(part("codex", dir.path()).is_none());
    let dir = folder(&[(".claude/CLAUDE.md", "c"), ("AGENTS.md", "a")]);
    assert!(part("claude", dir.path()).is_none());
}

#[test]
fn codex_and_gemini_get_another_harness_file() {
    let dir = folder(&[("CLAUDE.md", "from claude")]);
    assert!(part("codex", dir.path()).unwrap().text.unwrap().contains("from claude"));
    let dir = folder(&[(".cursorrules", "from cursor")]);
    let got = part("gemini", dir.path()).unwrap();
    assert_eq!(got.label, "Folder instructions (.cursorrules)");
    let dir = folder(&[(".github/copilot-instructions.md", "from vscode")]);
    assert!(part("claude", dir.path()).unwrap().text.unwrap().contains("from vscode"));
}

#[test]
fn agents_md_wins_over_the_others_and_an_empty_folder_gets_nothing() {
    let dir = folder(&[("GEMINI.md", "g"), ("AGENTS.md", "a")]);
    assert_eq!(part("claude", dir.path()).unwrap().label, "Folder instructions (AGENTS.md)");
    assert!(part("claude", folder(&[]).path()).is_none());
    assert!(part("claude", folder(&[("AGENTS.md", "  \n")]).path()).is_none());
}

#[cfg(unix)]
#[test]
fn a_link_is_never_followed() {
    let outside = folder(&[("secret.md", "outside")]);
    let dir = folder(&[]);
    std::os::unix::fs::symlink(outside.path().join("secret.md"), dir.path().join("AGENTS.md"))
        .unwrap();
    assert!(part("claude", dir.path()).is_none());
}

#[test]
fn a_claude_sessions_first_turn_carries_the_folders_agents_md_once_captured() {
    let dir = folder(&[("AGENTS.md", "codeword KESTREL")]);
    let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "claude",
        "cwd": dir.path(), "status": "idle", "createdAt": 0, "updatedAt": 0,
    }))
    .unwrap();
    let parts =
        crate::context_inventory::snapshot_session(&meta, &crate::config::Config::default());
    // The file changing after the session began changes nothing it was given.
    std::fs::write(dir.path().join("AGENTS.md"), "later").unwrap();
    let mut blocks = Vec::new();
    crate::context_inventory::append_snapshot(Some(&parts), &mut blocks);
    let text: Vec<&str> = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
    let folder = text.iter().find(|t| t.starts_with("<cmux-folder-context>")).unwrap();
    assert!(folder.contains("codeword KESTREL"));
    assert!(!folder.contains("later"));
}

#[test]
fn a_native_fork_moved_elsewhere_says_the_old_folders_instructions_no_longer_apply() {
    let from = folder(&[("AGENTS.md", "old words")]);
    let to = folder(&[("AGENTS.md", "codeword OSPREY")]);
    let parts =
        moved(part("claude", from.path()).into_iter().collect(), "claude", to.path(), from.path());
    let text: Vec<&str> = parts.iter().filter_map(|p| p.text.as_deref()).collect();
    assert_eq!(text.len(), 1, "the parent's part is replaced, not kept beside the new one");
    assert!(text[0].contains("no longer apply") && text[0].contains("codeword OSPREY"));
    assert!(!text[0].contains("old words"));
    // A folder with no instructions still says the earlier ones are gone.
    let bare = folder(&[]);
    let parts = moved(
        part("claude", from.path()).into_iter().collect(),
        "claude",
        bare.path(),
        from.path(),
    );
    assert_eq!(parts.len(), 1);
    assert!(parts[0].text.as_deref().unwrap().contains("no longer apply"));
}

#[cfg(unix)]
#[test]
fn a_linked_folder_on_the_way_is_never_followed() {
    let outside = folder(&[("copilot-instructions.md", "outside words")]);
    let dir = folder(&[]);
    std::os::unix::fs::symlink(outside.path(), dir.path().join(".github")).unwrap();
    assert!(part("claude", dir.path()).is_none());
    // A linked folder on the way to the harness's own file is not its own file either.
    let claude = folder(&[("CLAUDE.md", "c")]);
    let dir = folder(&[("AGENTS.md", "a")]);
    std::os::unix::fs::symlink(claude.path(), dir.path().join(".claude")).unwrap();
    assert_eq!(part("claude", dir.path()).unwrap().label, "Folder instructions (AGENTS.md)");
}

#[test]
fn an_empty_file_of_the_harnesses_own_still_counts_as_its_own() {
    let dir = folder(&[("CLAUDE.md", ""), ("AGENTS.md", "a")]);
    assert!(part("claude", dir.path()).is_none());
}

#[test]
fn a_huge_file_is_read_only_up_to_the_cap() {
    let dir = folder(&[]);
    let file = std::fs::File::create(dir.path().join("AGENTS.md")).unwrap();
    file.set_len(1 << 30).unwrap();
    // A sparse 1 GiB file of zeros: read whole, the test would take a gigabyte.
    let got = part("claude", dir.path()).unwrap();
    assert_eq!(got.source_bytes, Some(1 << 30));
    assert!(got.text.unwrap().len() < 2 * MAX_BYTES);
}

#[test]
fn a_claude_code_profile_of_its_own_family_reads_claude_md() {
    let mut cfg = crate::config::Config::default();
    cfg.harnesses.insert(
        "claude-sr2".into(),
        serde_json::from_value(serde_json::json!({
            "kind": "claude-stdio", "argv": ["sr2"], "family": "claude-sr2",
        }))
        .unwrap(),
    );
    let family = crate::context_inventory::family_for_folder(&cfg, "claude-sr2");
    assert_eq!(family, "claude");
    let dir = folder(&[("CLAUDE.md", "c"), ("AGENTS.md", "a")]);
    assert!(part(&family, dir.path()).is_none());
}

#[test]
fn a_fork_into_another_folder_carries_that_folders_instructions() {
    let parent = folder(&[("AGENTS.md", "parent words")]);
    let child = folder(&[("GEMINI.md", "child words")]);
    let parts =
        retarget(part("claude", parent.path()).into_iter().collect(), "claude", child.path());
    assert_eq!(parts.len(), 1);
    assert!(parts[0].text.as_deref().unwrap().contains("child words"));
    let none = retarget(parts, "claude", folder(&[]).path());
    assert!(none.is_empty());
}

#[test]
fn a_long_file_is_cut_on_a_character_boundary() {
    let long = "é".repeat(MAX_BYTES);
    let dir = folder(&[("AGENTS.md", &long)]);
    let text = part("claude", dir.path()).unwrap().text.unwrap();
    assert!(text.contains("[cut: AGENTS.md is"));
    assert!(text.len() < long.len());
}
