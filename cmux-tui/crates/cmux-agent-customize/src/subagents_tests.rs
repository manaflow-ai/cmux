use super::*;

fn agent_md(dir: &Path, file: &str, front: &str) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let path = dir.join(file);
    fs::write(&path, format!("---\n{front}\n---\nYou are a reviewer.\n")).unwrap();
    path
}

#[test]
fn project_beats_user_beats_plugin_and_problems_are_named() {
    let root = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(root.path()).unwrap();
    let homes = Homes::under(base.join("home"));
    let user = homes.claude.join("agents");
    agent_md(
        &user,
        "reviewer.md",
        "name: reviewer\ndescription: user one\ntools: Read, Grep\nmodel: sonnet",
    );
    agent_md(&user.join("nested"), "tester.md", "name: tester\ndescription: >-\n  Runs\n  tests.");
    agent_md(&user, "broken.md", "description: no name");
    fs::write(user.join("notes.txt"), "not an agent").unwrap();
    agent_md(&user.join(".hidden"), "ghost.md", "name: ghost\ndescription: hidden");

    let repo = base.join("repo");
    fs::create_dir_all(repo.join(".git")).unwrap();
    let cwd = repo.join("sub");
    let project = agent_md(
        &repo.join(".claude/agents"),
        "rev.md",
        "name: reviewer\ndescription: project one\ncolor: red",
    );

    let plugin_dir = base.join("plugins/kit");
    agent_md(&plugin_dir.join("agents"), "planner.md", "name: planner\ndescription: plans");
    let off_dir = base.join("plugins/off");
    agent_md(&off_dir.join("agents"), "x.md", "name: x\ndescription: off");
    fs::create_dir_all(homes.claude.join("plugins")).unwrap();
    fs::write(
        homes.claude.join("plugins/installed_plugins.json"),
        serde_json::json!({"plugins": {
            "kit@market": [{"scope": "user", "installPath": plugin_dir}],
            "off@market": [{"scope": "user", "installPath": off_dir}],
        }})
        .to_string(),
    )
    .unwrap();
    fs::write(
        homes.claude_settings(),
        r#"{"enabledPlugins": {"kit@market": true, "off@market": false}}"#,
    )
    .unwrap();
    fs::create_dir_all(&cwd).unwrap();

    let listing = list(&homes, Some(&cwd));
    let rows: Vec<(Scope, &str, bool)> =
        listing.subagents.iter().map(|a| (a.scope, a.name.as_str(), a.active)).collect();
    assert_eq!(
        rows,
        [
            (Scope::Project, "reviewer", true),
            (Scope::User, "reviewer", false),
            (Scope::User, "tester", true),
            (Scope::Plugin, "kit:planner", true),
            (Scope::Plugin, "off:x", false),
        ]
    );
    assert_eq!(listing.subagents[1].shadowed_by.as_deref(), Some(project.as_path()));
    assert_eq!(listing.subagents[1].tools, ["Read", "Grep"]);
    assert_eq!(listing.subagents[1].model.as_deref(), Some("sonnet"));
    assert_eq!(listing.subagents[0].color.as_deref(), Some("red"));
    assert_eq!(listing.subagents[2].description, "Runs tests.");
    assert_eq!(listing.subagents[3].plugin.as_deref(), Some("kit@market"));
    assert_eq!(listing.active_count(), 3);
    assert_eq!(listing.problems.len(), 1);
    assert!(listing.problems[0].path.ends_with("broken.md"));

    // Outside any project only the person's own and plugins' count.
    let own = list(&homes, None);
    assert_eq!(own.subagents[0].name, "reviewer");
    assert!(own.subagents[0].active);
}

#[test]
fn no_folders_is_an_empty_list() {
    let root = tempfile::tempdir().unwrap();
    let listing = list(&Homes::under(root.path()), None);
    assert!(listing.subagents.is_empty() && listing.problems.is_empty());
}
