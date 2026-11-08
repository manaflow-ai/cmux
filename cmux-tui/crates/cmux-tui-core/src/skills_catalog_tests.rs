use super::*;

/// A folder of its own per test, removed when the test ends.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn scratch() -> Scratch {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("cmux-skills-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    Scratch(dir)
}

struct Fixture {
    _temp: Scratch,
    env: SkillsEnv,
    project: PathBuf,
}

fn fixture() -> Fixture {
    let temp = scratch();
    let root = temp.0.canonicalize().unwrap();
    let home = root.join("home");
    let project = home.join("code/app");
    fs::create_dir_all(project.join(".git")).unwrap();
    let env = SkillsEnv {
        claude_dir: home.join(".claude"),
        codex_dir: home.join(".codex"),
        codex_admin: root.join("etc/codex/skills"),
        home,
    };
    Fixture { _temp: temp, env, project }
}

fn skill(folder: &Path, name: &str, text: &str) -> PathBuf {
    let dir = folder.join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), text).unwrap();
    dir.join("SKILL.md")
}

fn front(name: &str, description: &str) -> String {
    format!("---\nname: {name}\ndescription: {description}\n---\n\nBody\n")
}

fn projects_of(f: &Fixture) -> Vec<Project> {
    projects([f.project.join("src")], &f.env.home)
}

#[test]
fn lists_every_harness_and_scope() {
    let f = fixture();
    skill(&f.env.claude_dir.join("skills"), "deploy", &front("deploy", "Ship it"));
    skill(&f.env.claude_dir.join("skills/synced"), "notes", &front("notes", "Synced"));
    skill(&f.project.join(".claude/skills"), "lint", &front("lint", "Lint the app"));
    let plugin = f.env.claude_dir.join("plugins/cache/market/tools/1.0.0");
    skill(&plugin.join("skills"), "review", &front("review", "Review a PR"));
    fs::write(
        f.env.claude_dir.join("plugins/installed_plugins.json"),
        json!({"version": 2, "plugins": {"tools@market": [{"scope": "user", "installPath": plugin}]}})
            .to_string(),
    )
    .unwrap();
    skill(&f.env.home.join(".agents/skills"), "fmt", &front("fmt", "Format"));
    skill(&f.env.codex_dir.join("skills/.system"), "skill-creator", &front("skill-creator", "Make one"));
    skill(&f.env.codex_admin, "policy", &front("policy", "Org rules"));
    skill(&f.project.join(".agents/skills"), "test", &front("test", "Run tests"));
    // Not skills: a file, a folder without SKILL.md, a hidden folder.
    fs::write(f.env.claude_dir.join("skills/README.md"), "x").unwrap();
    fs::create_dir_all(f.env.claude_dir.join("skills/empty")).unwrap();
    skill(&f.env.claude_dir.join("skills"), ".hidden", &front("hidden", "No"));

    let projects = projects_of(&f);
    assert_eq!(projects, vec![Project { root: f.project.to_string_lossy().into(), name: "app".into() }]);
    let listed = list(&f.env, &projects);
    let rows: Vec<(Harness, Scope, &str)> =
        listed.iter().map(|s| (s.harness, s.scope, s.name.as_str())).collect();
    assert_eq!(
        rows,
        vec![
            (Harness::Claude, Scope::User, "deploy"),
            (Harness::Claude, Scope::User, "notes"),
            (Harness::Claude, Scope::Project, "lint"),
            (Harness::Claude, Scope::Plugin, "review"),
            (Harness::Codex, Scope::User, "fmt"),
            (Harness::Codex, Scope::Project, "test"),
            (Harness::Codex, Scope::Admin, "policy"),
            (Harness::Codex, Scope::System, "skill-creator"),
        ]
    );
    let review = listed.iter().find(|s| s.name == "review").unwrap();
    assert_eq!(review.plugin.as_deref(), Some("tools@market"));
    assert_eq!(review.toggle, Some(Toggle::Plugin));
    assert!(review.enabled);
    let lint = listed.iter().find(|s| s.name == "lint").unwrap();
    assert_eq!(lint.project.as_deref(), Some(f.project.to_str().unwrap()));
    assert_eq!(lint.id, format!("claude:{}", f.project.join(".claude/skills/lint/SKILL.md").display()));
    assert_eq!(lint.description, "Lint the app");
}

#[test]
fn reads_frontmatter_forms_and_names_problems() {
    let f = fixture();
    let folder = f.env.claude_dir.join("skills");
    skill(&folder, "quoted", "---\nname: \"quoted\"\ndescription: 'It''s fine' # not a comment inside\n---\n");
    skill(&folder, "folded", "---\ndescription: >\n  One line\n  and more.\nallowed-tools:\n  - Bash\n---\n");
    skill(&folder, "literal", "---\ndescription: |\n  First\n  Second\n---\n");
    skill(&folder, "plain-multi", "---\ndescription: Starts here\n  and goes on\nname: plain-multi\n---\n");
    skill(&folder, "bare", "# No frontmatter\n");
    skill(&folder, "nodesc", "---\nname: nodesc\n---\n");
    let listed = list(&f.env, &[]);
    let by = |name: &str| listed.iter().find(|s| s.name == name).unwrap().clone();
    assert_eq!(by("quoted").description, "It's fine");
    assert_eq!(by("folded").description, "One line and more.");
    assert_eq!(by("literal").description, "First\nSecond");
    assert_eq!(by("plain-multi").description, "Starts here and goes on");
    assert_eq!(by("bare").problem, Some("no_frontmatter"));
    assert_eq!(by("nodesc").problem, Some("no_description"));
    // A folder's name stands in for a missing `name`.
    assert_eq!(by("folded").file, folder.join("folded/SKILL.md").to_string_lossy());
}

#[test]
fn a_personal_skill_shadows_a_project_skill_of_the_same_name() {
    let f = fixture();
    skill(&f.env.claude_dir.join("skills"), "lint", &front("lint", "Mine"));
    skill(&f.project.join(".claude/skills"), "lint", &front("lint", "The repo's"));
    let listed = list(&f.env, &projects_of(&f));
    let project = listed.iter().find(|s| s.scope == Scope::Project).unwrap();
    assert!(project.shadowed);
    assert!(!listed.iter().find(|s| s.scope == Scope::User).unwrap().shadowed);
}

#[test]
fn claude_toggle_writes_skill_overrides_and_keeps_the_rest_of_the_file() {
    let f = fixture();
    skill(&f.env.claude_dir.join("skills"), "deploy", &front("deploy", "Ship"));
    let settings = f.env.claude_dir.join("settings.json");
    let original = "{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"deny\": [\"Bash(rm *)\"],\n    \"allow\": []\n  },\n  \"alwaysThinkingEnabled\": true\n}\n";
    fs::write(&settings, original).unwrap();
    let id = list(&f.env, &[])[0].id.clone();

    let off = set_enabled(&f.env, &[], &id, false).unwrap();
    assert!(!off.enabled);
    let text = fs::read_to_string(&settings).unwrap();
    assert_eq!(
        text,
        "{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"deny\": [\"Bash(rm *)\"],\n    \"allow\": []\n  },\n  \"alwaysThinkingEnabled\": true,\n  \"skillOverrides\": {\n    \"deploy\": \"off\"\n  }\n}\n"
    );
    let on = set_enabled(&f.env, &[], &id, true).unwrap();
    assert!(on.enabled);
    assert_eq!(fs::read_to_string(&settings).unwrap(), original);
}

#[test]
fn a_project_skill_toggles_in_the_local_file_and_wins_over_the_shared_one() {
    let f = fixture();
    skill(&f.project.join(".claude/skills"), "lint", &front("lint", "Lint"));
    let shared = f.project.join(".claude/settings.json");
    fs::write(&shared, "{\"skillOverrides\": {\"lint\": \"off\"}}").unwrap();
    let projects = projects_of(&f);
    let row = list(&f.env, &projects).remove(0);
    assert!(!row.enabled);
    let on = set_enabled(&f.env, &projects, &row.id, true).unwrap();
    assert!(on.enabled);
    // The repo's shared file is the team's: never written.
    assert_eq!(fs::read_to_string(&shared).unwrap(), "{\"skillOverrides\": {\"lint\": \"off\"}}");
    let local: Value =
        serde_json::from_str(&fs::read_to_string(f.project.join(".claude/settings.local.json")).unwrap())
            .unwrap();
    assert_eq!(local, json!({"skillOverrides": {"lint": "on"}}));
}

#[test]
fn a_partial_mode_counts_as_on_and_is_reported() {
    let f = fixture();
    skill(&f.env.claude_dir.join("skills"), "ctx", &front("ctx", "Context"));
    fs::create_dir_all(&f.env.claude_dir).unwrap();
    fs::write(f.env.claude_dir.join("settings.json"), "{\"skillOverrides\":{\"ctx\":\"name-only\"}}").unwrap();
    let row = list(&f.env, &[]).remove(0);
    assert!(row.enabled);
    assert_eq!(row.mode.as_deref(), Some("name-only"));
}

#[test]
fn plugin_toggle_flips_enabled_plugins() {
    let f = fixture();
    let plugin = f.env.claude_dir.join("plugins/cache/m/p/1");
    skill(&plugin.join("skills"), "a", &front("a", "A"));
    fs::write(
        f.env.claude_dir.join("plugins/installed_plugins.json"),
        json!({"plugins": {"p@m": {"installPath": plugin}}}).to_string(),
    )
    .unwrap();
    let id = list(&f.env, &[])[0].id.clone();
    assert!(!set_enabled(&f.env, &[], &id, false).unwrap().enabled);
    let settings: Value =
        serde_json::from_str(&fs::read_to_string(f.env.claude_dir.join("settings.json")).unwrap()).unwrap();
    assert_eq!(settings, json!({"enabledPlugins": {"p@m": false}}));
    assert!(set_enabled(&f.env, &[], &id, true).unwrap().enabled);
}

#[test]
fn codex_toggle_writes_a_path_rule_and_keeps_comments() {
    let f = fixture();
    let file = skill(&f.env.home.join(".agents/skills"), "fmt", &front("fmt", "Format"));
    let config = f.env.codex_dir.join("config.toml");
    fs::create_dir_all(&f.env.codex_dir).unwrap();
    fs::write(&config, "# my config\nmodel = \"gpt\"\n").unwrap();
    let id = list(&f.env, &[])[0].id.clone();
    assert!(!set_enabled(&f.env, &[], &id, false).unwrap().enabled);
    let text = fs::read_to_string(&config).unwrap();
    assert!(text.starts_with("# my config\nmodel = \"gpt\"\n"), "{text}");
    assert!(text.contains("[[skills.config]]"), "{text}");
    assert!(text.contains(&format!("path = \"{}\"", file.display())), "{text}");
    assert!(text.contains("enabled = false"), "{text}");
    assert!(set_enabled(&f.env, &[], &id, true).unwrap().enabled);
    let text = fs::read_to_string(&config).unwrap();
    assert!(!text.contains(&file.display().to_string()), "{text}");
}

#[test]
fn codex_enabling_over_a_name_rule_appends_a_path_rule() {
    let f = fixture();
    skill(&f.env.home.join(".agents/skills"), "fmt", &front("fmt", "Format"));
    fs::create_dir_all(&f.env.codex_dir).unwrap();
    fs::write(f.env.codex_dir.join("config.toml"), "[[skills.config]]\nname = \"fmt\"\nenabled = false\n")
        .unwrap();
    let row = list(&f.env, &[]).remove(0);
    assert!(!row.enabled);
    assert!(set_enabled(&f.env, &[], &row.id, true).unwrap().enabled);
    let text = fs::read_to_string(f.env.codex_dir.join("config.toml")).unwrap();
    assert!(text.contains("name = \"fmt\""), "{text}");
    assert!(text.contains("enabled = true"), "{text}");
}

#[test]
fn an_unparseable_settings_file_is_never_written() {
    let f = fixture();
    skill(&f.env.claude_dir.join("skills"), "deploy", &front("deploy", "Ship"));
    let settings = f.env.claude_dir.join("settings.json");
    fs::write(&settings, "{ not json").unwrap();
    let id = list(&f.env, &[])[0].id.clone();
    assert_eq!(set_enabled(&f.env, &[], &id, false), Err(SkillsError::SettingsUnreadable));
    assert_eq!(fs::read_to_string(&settings).unwrap(), "{ not json");
    fs::create_dir_all(&f.env.codex_dir).unwrap();
    let file = skill(&f.env.home.join(".agents/skills"), "fmt", &front("fmt", "F"));
    fs::write(f.env.codex_dir.join("config.toml"), "skills = 3\n[[[").unwrap();
    let codex = format!("codex:{}", file.display());
    assert_eq!(set_enabled(&f.env, &[], &codex, false), Err(SkillsError::SettingsUnreadable));
}

#[test]
fn an_unknown_id_is_not_found() {
    let f = fixture();
    assert_eq!(set_enabled(&f.env, &[], "claude:/etc/passwd", false), Err(SkillsError::NotFound));
}

#[test]
fn create_scaffolds_and_refuses_bad_names_and_replacements() {
    let f = fixture();
    let projects = projects_of(&f);
    let new = |harness: &str, scope: &str, project: Option<&Path>, name: &str| NewSkill {
        harness: harness.into(),
        scope: scope.into(),
        project: project.map(|p| p.to_string_lossy().into_owned()),
        name: name.into(),
        description: "Use when \"shipping\": the steps".into(),
    };
    let made = create(&f.env, &projects, &new("claude", "user", None, "ship-it")).unwrap();
    assert_eq!(made.scope, Scope::User);
    assert_eq!(made.description, "Use when \"shipping\": the steps");
    assert_eq!(made.problem, None);
    let text = fs::read_to_string(&made.file).unwrap();
    assert!(text.starts_with("---\nname: ship-it\ndescription: \"Use when \\\"shipping\\\": the steps\"\n---\n\n# Ship It\n"), "{text}");
    let codex = create(&f.env, &projects, &new("codex", "project", Some(&f.project), "check")).unwrap();
    assert_eq!(codex.file, f.project.join(".agents/skills/check/SKILL.md").to_string_lossy());
    assert_eq!(
        create(&f.env, &projects, &new("claude", "user", None, "ship-it")).unwrap_err(),
        SkillsError::Exists
    );
    for bad in ["", "Ship", "a_b", "-a", "a--b", "a/b", "../x", &"a".repeat(65)] {
        assert_eq!(create(&f.env, &projects, &new("claude", "user", None, bad)).unwrap_err(), SkillsError::BadName, "{bad}");
    }
    // Only a listed project, and only the two harnesses.
    let elsewhere = f.env.home.join("other");
    fs::create_dir_all(&elsewhere).unwrap();
    assert_eq!(
        create(&f.env, &projects, &new("claude", "project", Some(&elsewhere), "x")).unwrap_err(),
        SkillsError::BadScope
    );
    assert_eq!(create(&f.env, &projects, &new("gemini", "user", None, "x")).unwrap_err(), SkillsError::BadScope);
    let mut multi = new("claude", "user", None, "y");
    multi.description = "two\nlines".into();
    assert_eq!(create(&f.env, &projects, &multi).unwrap_err(), SkillsError::BadDescription);
}

#[test]
fn project_roots_stop_at_home_and_dedupe() {
    let f = fixture();
    let home = &f.env.home;
    let loose = home.join("scratch");
    fs::create_dir_all(&loose).unwrap();
    let roots = projects(
        [f.project.join("a/b"), f.project.clone(), home.clone(), PathBuf::from("/"), loose.clone(), PathBuf::from("rel")],
        home,
    );
    let roots: Vec<&str> = roots.iter().map(|p| p.root.as_str()).collect();
    assert_eq!(roots, vec![f.project.to_str().unwrap(), loose.to_str().unwrap()]);
}

#[test]
fn one_folder_contributes_a_bounded_number_of_skills() {
    let f = fixture();
    let folder = f.env.claude_dir.join("skills");
    for i in 0..(MAX_ENTRIES_PER_FOLDER + 20) {
        skill(&folder, &format!("s{i:04}"), &front(&format!("s{i:04}"), "d"));
    }
    assert!(list(&f.env, &[]).len() <= MAX_ENTRIES_PER_FOLDER);
}
