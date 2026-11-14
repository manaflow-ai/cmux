use super::*;

/// A scratch folder (canonical) with `home/` in it and the trust files under `state/`.
fn scratch(tag: &str) -> (PathBuf, Paths) {
    let root = std::env::temp_dir().join(format!(
        "acpmux-trust-scope-{tag}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("state")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let paths = Paths {
        claude_json: root.join("state/claude.json"),
        codex_config: root.join("state/config.toml"),
        record: root.join("state/trust.json"),
        agent_home: None,
        cmux_worktrees: None,
        peer_scratch: None,
    };
    (root, paths)
}

/// A repository at `main` and a linked worktree of it at `tree`, laid out as git writes them.
fn repo_with_worktree(main: &Path, tree: &Path) {
    std::fs::create_dir_all(main.join("src")).unwrap();
    let gitdir = main.join(".git/worktrees/w");
    std::fs::create_dir_all(&gitdir).unwrap();
    std::fs::create_dir_all(tree.join("src")).unwrap();
    std::fs::write(tree.join(".git"), format!("gitdir: {}\n", gitdir.display())).unwrap();
    std::fs::write(gitdir.join("gitdir"), format!("{}\n", tree.join(".git").display())).unwrap();
    std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
}

fn read(paths: &Paths, cwd: &Path, home: &Path) -> Value {
    get_at(paths, &cwd.to_string_lossy(), Some(home)).unwrap()
}

#[test]
fn a_worktree_of_a_trusted_repo_is_trusted_with_no_question() {
    let (root, paths) = scratch("worktree");
    let home = root.join("home");
    let main = home.join("Projects/app");
    let tree = home.join(".cmux/worktrees/app/fix-retry");
    repo_with_worktree(&main, &tree);
    // Unknown until the repository is trusted, and the reply names the repository to trust.
    let before = read(&paths, &tree.join("src"), &home);
    assert_eq!(before["level"], "unknown", "{before}");
    assert_eq!(before["repo"]["root"], main.to_string_lossy().as_ref(), "{before}");
    assert_eq!(before["repo"]["worktree"], true, "{before}");
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    for folder in [tree.clone(), tree.join("src"), main.join("src")] {
        let reply = read(&paths, &folder, &home);
        assert_eq!(reply["level"], "trusted", "{folder:?}: {reply}");
        assert_eq!(reply["decided"], true, "{folder:?}: {reply}");
        assert_eq!(reply["via"], main.to_string_lossy().as_ref(), "{folder:?}: {reply}");
    }
    // The worktree's own answer wins over its repository's, and Undo there brings it back.
    set(&paths, &tree.to_string_lossy(), "untrusted").unwrap();
    assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "untrusted");
    set(&paths, &tree.to_string_lossy(), "unknown").unwrap();
    assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "trusted");
    // Forgetting the repository's answer asks again everywhere.
    set(&paths, &main.to_string_lossy(), "unknown").unwrap();
    assert_eq!(read(&paths, &tree, &home)["level"], "unknown");
    let _ = std::fs::remove_dir_all(&root);
}

/// A worktree cmux made (`~/.cmux/worktrees/<project>/<name>`) is trusted by construction,
/// whatever its repository's answer is, unless a person or an agent said Don't trust. Only a
/// linked worktree git wrote at that depth is one: a plain folder there is not.
#[test]
fn a_worktree_cmux_made_is_trusted_with_no_question() {
    let (root, mut paths) = scratch("cmux-worktree");
    let home = root.join("home");
    let worktrees = home.join(".cmux/worktrees");
    paths.cmux_worktrees = Some(worktrees.clone());
    let main = home.join("Projects/app");
    let tree = worktrees.join("app/directional-motion");
    repo_with_worktree(&main, &tree);
    for folder in [tree.clone(), tree.join("src")] {
        let reply = read(&paths, &folder, &home);
        assert_eq!(reply["level"], "trusted", "{folder:?}: {reply}");
        assert_eq!(reply["decided"], true, "{folder:?}: {reply}");
        assert_eq!(
            session_level(&paths, &folder.to_string_lossy(), "codex").unwrap().1,
            Level::Trusted
        );
        // A Web client still needs a person's answer: the worktree holds the repository's
        // content.
        assert_eq!(
            web_session_level(&paths, &folder.to_string_lossy(), "claude").unwrap().1,
            Level::Unknown
        );
    }
    // The repository itself is still asked about.
    assert_eq!(read(&paths, &main, &home)["level"], "unknown");
    // A plain folder under the root is no worktree cmux made.
    let plain = worktrees.join("app/plain");
    std::fs::create_dir_all(&plain).unwrap();
    assert_eq!(read(&paths, &plain, &home)["level"], "unknown");
    // A person's Don't trust, for the repository or the worktree, still wins.
    set(&paths, &main.to_string_lossy(), "untrusted").unwrap();
    assert_eq!(read(&paths, &tree, &home)["level"], "untrusted");
    set(&paths, &main.to_string_lossy(), "unknown").unwrap();
    set(&paths, &tree.to_string_lossy(), "untrusted").unwrap();
    assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "untrusted");
    set(&paths, &tree.to_string_lossy(), "unknown").unwrap();
    // So does an agent's own untrusted level, for the repository or the worktree.
    std::fs::write(
        &paths.codex_config,
        format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", main.display()),
    )
    .unwrap();
    assert_eq!(read(&paths, &tree, &home)["level"], "unknown");
    std::fs::write(
        &paths.codex_config,
        format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", tree.display()),
    )
    .unwrap();
    assert_eq!(
        session_level(&paths, &tree.to_string_lossy(), "codex").unwrap().1,
        Level::Untrusted
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_git_file_that_its_repository_does_not_name_back_inherits_nothing() {
    let (root, paths) = scratch("forged");
    let home = root.join("home");
    let main = home.join("Projects/app");
    let tree = home.join("elsewhere/tree");
    repo_with_worktree(&main, &tree);
    // Somebody's own folder points its .git file at the trusted repository's worktree entry.
    let forged = home.join("downloads/forged");
    std::fs::create_dir_all(&forged).unwrap();
    std::fs::write(
        forged.join(".git"),
        format!("gitdir: {}\n", main.join(".git/worktrees/w").display()),
    )
    .unwrap();
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    let reply = read(&paths, &forged, &home);
    assert_eq!(reply["level"], "unknown", "{reply}");
    assert!(reply["repo"].is_null(), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_git_file_with_its_own_gitdir_naming_a_trusted_repository_inherits_nothing() {
    let (root, paths) = scratch("own-gitdir");
    let home = root.join("home");
    let main = home.join("Projects/app");
    std::fs::create_dir_all(main.join(".git")).unwrap();
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    // An extracted archive: its .git file names a gitdir of its own that names the file back
    // and whose commondir is the trusted repository's .git.
    let forged = home.join("Downloads/forged");
    std::fs::create_dir_all(forged.join("meta")).unwrap();
    std::fs::write(forged.join(".git"), "gitdir: meta\n").unwrap();
    std::fs::write(forged.join("meta/gitdir"), format!("{}\n", forged.join(".git").display()))
        .unwrap();
    std::fs::write(forged.join("meta/commondir"), format!("{}\n", main.join(".git").display()))
        .unwrap();
    let reply = read(&paths, &forged, &home);
    assert_eq!(reply["level"], "unknown", "{reply}");
    assert!(reply["via"].is_null(), "{reply}");
    assert!(reply["repo"].is_null(), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_worktree_git_wrote_with_relative_paths_inherits_too() {
    let (root, paths) = scratch("relative");
    let home = root.join("home");
    let main = home.join("Projects/app");
    let tree = home.join("Projects/app-fix");
    let gitdir = main.join(".git/worktrees/app-fix");
    std::fs::create_dir_all(&gitdir).unwrap();
    std::fs::create_dir_all(&tree).unwrap();
    // As `git -c worktree.useRelativePaths=true worktree add` writes them.
    std::fs::write(tree.join(".git"), "gitdir: ../app/.git/worktrees/app-fix\n").unwrap();
    std::fs::write(gitdir.join("gitdir"), "../../../../app-fix/.git\n").unwrap();
    std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    let reply = read(&paths, &tree, &home);
    assert_eq!(reply["level"], "trusted", "{reply}");
    assert_eq!(reply["via"], main.to_string_lossy().as_ref(), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_decision_holds_and_is_forgotten_under_every_spelling_of_its_folder() {
    let (root, paths) = scratch("spelling");
    let home = root.join("home");
    let real = root.join("real");
    std::fs::create_dir_all(&real).unwrap();
    std::os::unix::fs::symlink(&real, root.join("link")).unwrap();
    // Recorded under an old spelling (a record written before keys were canonical), and a
    // stricter decision under the real one: the no holds for both spellings.
    let old = root.join("link/app");
    std::fs::create_dir_all(real.join("app")).unwrap();
    let app = real.join("app");
    let raw = json!({(old.to_string_lossy()): "trusted", (app.to_string_lossy()): "untrusted"});
    std::fs::write(&paths.record, raw.to_string()).unwrap();
    for cwd in [&old, &app] {
        assert_eq!(read(&paths, cwd, &home)["level"], "untrusted", "{}", cwd.display());
        let own = person_decision(&paths, &cwd.to_string_lossy()).unwrap();
        assert_eq!(own, Some(Level::Untrusted), "{}", cwd.display());
    }
    // Forgetting it under one spelling forgets every key that names the folder.
    set(&paths, &old.to_string_lossy(), "unknown").unwrap();
    assert_eq!(read_record(&paths.record).unwrap(), BTreeMap::new());
    // A decision for a folder that does not exist yet, under a link, keys the folder it will be.
    set(&paths, &root.join("link/later").to_string_lossy(), "untrusted").unwrap();
    std::fs::create_dir_all(real.join("later")).unwrap();
    assert_eq!(read(&paths, &real.join("later"), &home)["level"], "untrusted");
}

#[test]
fn a_decision_for_a_plain_folder_covers_only_that_folder() {
    let (root, paths) = scratch("plain");
    let home = root.join("home");
    let project = home.join("Projects/notes");
    std::fs::create_dir_all(project.join("2026/october")).unwrap();
    set(&paths, &project.to_string_lossy(), "trusted").unwrap();
    assert_eq!(read(&paths, &project, &home)["level"], "trusted");
    let inside = read(&paths, &project.join("2026/october"), &home);
    assert_eq!(inside["level"], "unknown", "{inside}");
    assert!(inside["via"].is_null(), "{inside}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_repository_answer_holds_over_agents_levels_from_folders_above() {
    let (root, paths) = scratch("agent-above");
    let home = root.join("home");
    let main = home.join("Projects/app");
    let tree = home.join(".cmux/worktrees/app/fix-retry");
    repo_with_worktree(&main, &tree);
    // Claude Code trusts every folder under home; Not now on the repository still holds in
    // its worktrees, and no auto-trust rule answers over it.
    std::fs::write(
        &paths.claude_json,
        format!(r#"{{"projects": {{"{}": {{"hasTrustDialogAccepted": true}}}}}}"#, home.display()),
    )
    .unwrap();
    set(&paths, &main.to_string_lossy(), "untrusted").unwrap();
    let reply = read(&paths, &tree, &home);
    assert_eq!(reply["level"], "untrusted", "{reply}");
    assert_eq!(reply["decided"], true, "{reply}");
    assert!(reply["auto"].is_null(), "{reply}");
    // Codex holds home untrusted; Trust repo answers the worktree for every agent.
    std::fs::write(&paths.claude_json, "").unwrap();
    std::fs::write(
        &paths.codex_config,
        format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", home.display()),
    )
    .unwrap();
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    let reply = read(&paths, &tree, &home);
    assert_eq!(reply["level"], "trusted", "{reply}");
    assert_eq!(reply["decided"], true, "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn no_home_folder_no_repository_answer() {
    let (root, paths) = scratch("no-home");
    let main = root.join("home/Projects/app");
    let tree = root.join("home/.cmux/worktrees/app/fix-retry");
    repo_with_worktree(&main, &tree);
    set(&paths, &main.to_string_lossy(), "trusted").unwrap();
    let reply = get_at(&paths, &tree.to_string_lossy(), None).unwrap();
    assert_eq!(reply["level"], "unknown", "{reply}");
    assert!(reply["repo"].is_null(), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_repository_at_home_is_never_offered_as_a_whole() {
    let (root, paths) = scratch("dotfiles");
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".git")).unwrap();
    std::fs::create_dir_all(home.join("scratch")).unwrap();
    let reply = read(&paths, &home.join("scratch"), &home);
    assert!(reply["repo"].is_null(), "{reply}");
    let _ = std::fs::remove_dir_all(&root);
}
