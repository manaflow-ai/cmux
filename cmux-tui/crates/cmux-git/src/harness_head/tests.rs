use super::*;

#[test]
fn the_head_is_the_root_and_subpath_folders_own_files_and_their_harness_folders() {
    for (path, subpath, want) in [
        ("README.md", "", true),
        (".mcp.json", "", true),
        (".claude/skills/a/SKILL.md", "", true),
        ("src/main.rs", "", false),
        (".git/HEAD", "", false),
        ("app/CLAUDE.md", "app/web", true),
        ("app/web/CLAUDE.md", "app/web", true),
        ("app/web/.codex/config.toml", "app/web", true),
        ("app/.claude/settings.json", "app/web", true),
        ("app/web/src/index.ts", "app/web", false),
        ("app/other/CLAUDE.md", "app/web", false),
        ("application/x", "app", false),
        ("README.md", "/app/", true),
    ] {
        assert_eq!(in_head(path, subpath), want, "{path} at {subpath:?}");
    }
}

#[test]
fn start_settings_in_the_root_or_a_subpath_folder_keep_the_head_unmarked() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("app/web")).unwrap();
    let folders = [Path::new("app"), Path::new("app/web")];
    assert!(head_allowed(root, &folders));
    std::fs::write(root.join("app/web/.mcp.json"), "{}").unwrap();
    assert!(!head_allowed(root, &folders), "a subpath folder's MCP servers");
    assert!(head_allowed(root, &[]), "the root alone has none");
    std::fs::write(root.join(".mcp.json"), "{}").unwrap();
    assert!(!head_allowed(root, &[]), "the root's MCP servers");
}

#[test]
fn a_subpath_folder_link_out_of_the_head_keeps_it_unmarked() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("app/.claude")).unwrap();
    std::os::unix::fs::symlink("../../docs/a.md", root.join("app/.claude/a.md")).unwrap();
    assert!(head_allowed(root, &[]), "a folder off the head is not read");
    assert!(!head_allowed(root, &[Path::new("app")]));
}

/// Review F1 (cmux#39018): a harness folder linked to a folder resolves, but the head
/// holds only that folder's own files, not the skills below it.
#[test]
fn a_harness_folder_linked_to_a_folder_keeps_the_head_unmarked() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("skills/review")).unwrap();
    std::fs::write(root.join("skills/review/SKILL.md"), "x").unwrap();
    assert!(head_allowed(root, &[]));
    std::os::unix::fs::symlink(".", root.join(".claude")).unwrap();
    assert!(!head_allowed(root, &[]), "a root harness folder");
    std::fs::remove_file(root.join(".claude")).unwrap();
    std::fs::create_dir_all(root.join(".codex")).unwrap();
    std::os::unix::fs::symlink("../skills", root.join(".codex/skills")).unwrap();
    assert!(!head_allowed(root, &[]), "a folder link inside a harness folder");
    std::fs::remove_file(root.join(".codex/skills")).unwrap();
    std::fs::create_dir_all(root.join("app")).unwrap();
    std::os::unix::fs::symlink("..", root.join("app/.claude")).unwrap();
    assert!(head_allowed(root, &[]), "a folder off the head is not read");
    assert!(!head_allowed(root, &[Path::new("app")]), "a subpath folder's harness folder");
    std::fs::remove_file(root.join("app/.claude")).unwrap();
    std::os::unix::fs::symlink("app", root.join(".claude")).unwrap();
    assert!(
        !head_allowed(root, &[Path::new("app")]),
        "a root harness folder linked to the subpath"
    );
}
