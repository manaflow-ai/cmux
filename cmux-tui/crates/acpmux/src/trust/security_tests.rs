use super::*;

#[test]
fn acpmux_trust_record_never_follows_a_link() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-trust-link-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let cwd = root.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let target = root.join("planted.json");
    std::fs::write(&target, format!(r#"{{"{}":"trusted"}}"#, cwd.display())).unwrap();
    let record = root.join("trust.json");
    std::os::unix::fs::symlink(&target, &record).unwrap();
    let paths = Paths {
        claude_json: root.join("claude.json"),
        codex_config: root.join("config.toml"),
        record,
        agent_home: None,
        cmux_worktrees: None,
        peer_scratch: None,
    };
    let error = get(&paths, &cwd.to_string_lossy()).expect_err("a linked trust decision loaded");
    assert!(matches!(error, Failure::Record(_)), "{error:?}");
    let _ = std::fs::remove_dir_all(&root);
}
