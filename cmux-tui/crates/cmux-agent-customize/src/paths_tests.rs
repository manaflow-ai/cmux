use super::*;

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

#[test]
fn defaults_and_overrides() {
    let p = Paths::from_env(&env(&[("HOME", "/h")])).unwrap();
    assert_eq!(p.claude_json, PathBuf::from("/h/.claude.json"));
    assert_eq!(p.claude_dir, PathBuf::from("/h/.claude"));
    assert_eq!(p.codex_config(), PathBuf::from("/h/.codex/config.toml"));
    let p =
        Paths::from_env(&env(&[("HOME", "/h"), ("CLAUDE_CONFIG_DIR", "/c"), ("CODEX_HOME", "/x")]))
            .unwrap();
    assert_eq!(p.claude_json, PathBuf::from("/c/.claude.json"));
    assert_eq!(p.codex_config(), PathBuf::from("/x/config.toml"));
    assert!(Paths::from_env(&env(&[])).is_none());
}

#[test]
fn chain_stops_at_repo_or_home() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let repo = home.join("repo");
    let deep = repo.join("a").join("b");
    std::fs::create_dir_all(&deep).unwrap();
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    assert_eq!(project_chain(&deep, &home), vec![deep.clone(), repo.join("a"), repo.clone()]);
    let loose = home.join("loose");
    std::fs::create_dir_all(&loose).unwrap();
    assert_eq!(project_chain(&loose, &home), vec![loose.clone()]);
    assert_eq!(project_chain(&home, &home).first(), Some(&home));
}

#[test]
fn project_dirs_stop_at_the_git_root() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().join("repo");
    let deep = repo.join("a/b");
    std::fs::create_dir_all(&deep).unwrap();
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    assert_eq!(project_dirs(&deep, root.path()), vec![deep.clone(), repo.join("a"), repo.clone()]);
    // Outside any repo: the folder alone.
    let loose = root.path().join("loose/x");
    std::fs::create_dir_all(&loose).unwrap();
    assert_eq!(project_dirs(&loose, Path::new("/nonexistent-home")), vec![loose.clone()]);
    // The home folder itself is the user scope, never a project.
    assert!(project_dirs(root.path(), root.path()).is_empty());
}
