use std::fs;
use std::path::{Path, PathBuf};

use super::*;

fn skill_md(dir: &Path, front: &str) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let file = dir.join("SKILL.md");
    fs::write(&file, format!("---\n{front}\n---\nbody\n")).unwrap();
    file
}

fn names(listing: &Listing, agent: Agent, kind: Kind) -> Vec<String> {
    listing
        .skills
        .iter()
        .filter(|s| s.agent == agent && s.kind == kind)
        .map(|s| s.name.clone())
        .collect()
}

struct Fixture {
    _root: tempfile::TempDir,
    homes: Homes,
    repo: PathBuf,
    cwd: PathBuf,
}

/// A home with Claude Code and Codex skills of every kind, and a repo with project ones.
fn fixture() -> Fixture {
    let root = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(root.path()).unwrap();
    let homes = Homes::under(base.join("home"));
    let claude = &homes.claude;
    skill_md(
        &claude.join("skills/wrangler"),
        "name: wrangler\ndescription: >-\n  Deploy\n  Workers.",
    );
    // The folder names it, not the frontmatter.
    skill_md(&claude.join("skills/alpha"), "name: alpha-renamed\ndescription: Alpha");
    skill_md(&claude.join("skills/no-front-name"), "description: only a description");
    // Nested skills are not Claude Code's.
    skill_md(&claude.join("skills/group/nested"), "name: nested\ndescription: x");
    fs::create_dir_all(claude.join("skills/empty")).unwrap();
    #[cfg(unix)]
    {
        let elsewhere = base.join("elsewhere/linked");
        skill_md(&elsewhere, "name: linked\ndescription: symlinked folder");
        std::os::unix::fs::symlink(&elsewhere, claude.join("skills/linked")).unwrap();
    }
    fs::create_dir_all(claude.join("commands/sub")).unwrap();
    fs::write(claude.join("commands/top.md"), "---\ndescription: top cmd\n---\nDo it\n").unwrap();
    fs::write(claude.join("commands/sub/deep.md"), "no frontmatter\n").unwrap();
    fs::write(claude.join("commands/notes.txt"), "not a command").unwrap();
    // A plugin, on, with a skill and a command; and one off.
    let on = base.join("plugins/on-plugin");
    skill_md(&on.join("skills/helper"), "name: helper\ndescription: plugin skill");
    fs::create_dir_all(on.join("commands")).unwrap();
    fs::write(on.join("commands/run.md"), "---\ndescription: run\n---\n").unwrap();
    let off = base.join("plugins/off-plugin");
    skill_md(&off.join("skills/quiet"), "name: quiet\ndescription: off plugin");
    fs::create_dir_all(claude.join("plugins")).unwrap();
    fs::write(
        claude.join("plugins/installed_plugins.json"),
        serde_json::json!({"version": 2, "plugins": {
            "on-plugin@market": [{"scope": "user", "installPath": on}],
            "off-plugin@market": [{"scope": "user", "installPath": off}],
        }})
        .to_string(),
    )
    .unwrap();
    fs::write(
        homes.claude_settings(),
        "{\n  \"model\": \"opus\",\n  \"enabledPlugins\": {\"on-plugin@market\": true, \"off-plugin@market\": false},\n  \"skillOverrides\": {\"alpha\": \"off\", \"wrangler\": \"name-only\"},\n  \"env\": {\"TOKEN\": \"secret\"}\n}\n",
    )
    .unwrap();

    let codex = &homes.codex;
    skill_md(&codex.join("skills/cloudflare"), "name: cloudflare\ndescription: CF");
    skill_md(&codex.join("skills/group/deep-one"), "name: deep-one\ndescription: two deep");
    skill_md(&codex.join("skills/.hidden/h"), "name: h\ndescription: hidden");
    skill_md(&codex.join("skills/.system/imagegen"), "name: imagegen\ndescription: system");
    skill_md(&codex.join("skills/broken"), "name: broken");
    skill_md(
        &homes.agents_skills().join("aws-auth"),
        "name: aws-auth\ndescription: |\n  AWS\n  auth",
    );
    let cache = codex.join("plugins/cache/market/pdf/1.0.0");
    skill_md(&cache.join("skills/pdf"), "name: pdf\ndescription: PDFs");
    skill_md(&codex.join("plugins/cache/market/unused/1.0/skills/u"), "name: u\ndescription: off");
    fs::write(
        homes.codex_config(),
        "# my codex\nmodel = \"gpt\"\n\n[plugins.\"pdf@market\"]\nenabled = true\n\n[plugins.\"unused@market\"]\nenabled = false\n\n[[skills.config]]\nname = \"cloudflare\"\nenabled = false\n",
    )
    .unwrap();

    let repo = base.join("repo");
    let cwd = repo.join("inner/work");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::create_dir_all(&cwd).unwrap();
    skill_md(&repo.join(".claude/skills/project-one"), "name: project-one\ndescription: project");
    skill_md(&repo.join("inner/.claude/skills/inner-one"), "name: inner-one\ndescription: inner");
    fs::create_dir_all(repo.join(".claude/commands")).unwrap();
    fs::write(repo.join(".claude/commands/ship.md"), "---\ndescription: Ship it\n---\n").unwrap();
    skill_md(&repo.join(".agents/skills/repo-agent"), "name: repo-agent\ndescription: repo");
    skill_md(&repo.join(".codex/skills/repo-codex"), "name: repo-codex\ndescription: repo codex");
    skill_md(
        &repo.join("inner/.agents/skills/inner-agent"),
        "name: inner-agent\ndescription: inner",
    );
    // Above the git root: not the project's.
    skill_md(&base.join(".claude/skills/above"), "name: above\ndescription: above");
    Fixture { _root: root, homes, repo, cwd }
}

#[test]
fn claude_skills_and_commands_as_claude_code_lists_them() {
    let f = fixture();
    let listing = list(&f.homes, &ListOptions { cwd: Some(f.cwd.clone()), codex_live: None });
    let mut skills = names(&listing, Agent::Claude, Kind::Skill);
    skills.sort();
    let mut expected = vec![
        "alpha",
        "inner-one",
        "no-front-name",
        "off-plugin:quiet",
        "on-plugin:helper",
        "project-one",
        "wrangler",
    ];
    if cfg!(unix) {
        expected.push("linked");
    }
    expected.sort();
    assert_eq!(skills, expected);
    assert_eq!(
        names(&listing, Agent::Claude, Kind::Command),
        ["on-plugin:run", "ship", "sub:deep", "top"]
    );
    let by = |name: &str| {
        listing.skills.iter().find(|s| s.agent == Agent::Claude && s.name == name).unwrap()
    };
    assert_eq!(by("wrangler").description, "Deploy Workers.");
    assert!(by("wrangler").enabled);
    assert_eq!(by("wrangler").r#override.as_deref(), Some("name-only"));
    assert!(!by("alpha").enabled);
    assert!(by("on-plugin:helper").enabled);
    assert!(!by("off-plugin:quiet").enabled);
    assert_eq!(by("on-plugin:helper").plugin.as_deref(), Some("on-plugin@market"));
    assert_eq!(by("project-one").scope, Scope::Project);
    assert_eq!(
        by("project-one").switch_file.as_deref(),
        Some(f.repo.join(".claude/settings.local.json").as_path())
    );
    assert_eq!(by("wrangler").switch_file.as_deref(), Some(f.homes.claude_settings().as_path()));
    assert_eq!(by("top").switch_file, None);
    // Without a working folder only the person's own.
    let own = list(&f.homes, &ListOptions::default());
    assert!(!names(&own, Agent::Claude, Kind::Skill).contains(&"project-one".to_owned()));
}

#[test]
fn codex_skills_as_codex_lists_them() {
    let f = fixture();
    let listing = list(&f.homes, &ListOptions { cwd: Some(f.cwd.clone()), codex_live: None });
    assert_eq!(listing.sources.codex, "files");
    assert_eq!(
        names(&listing, Agent::Codex, Kind::Skill),
        [
            "aws-auth",
            "cloudflare",
            "deep-one",
            "imagegen",
            "inner-agent",
            "pdf:pdf",
            "repo-agent",
            "repo-codex"
        ]
    );
    let by = |name: &str| {
        listing.skills.iter().find(|s| s.agent == Agent::Codex && s.name == name).unwrap()
    };
    assert!(!by("cloudflare").enabled, "a name rule turns it off");
    assert_eq!(by("imagegen").scope, Scope::System);
    assert_eq!(by("pdf:pdf").scope, Scope::Plugin);
    assert_eq!(by("aws-auth").description, "AWS\nauth");
    assert_eq!(by("repo-codex").scope, Scope::Project);
    assert_eq!(listing.problems.len(), 1);
    assert!(listing.problems[0].path.ends_with("broken/SKILL.md"));
    assert_eq!(listing.problems[0].message, "missing field `description`");
    assert_eq!(listing.enabled_count(Agent::Codex, Kind::Skill), 7);
}

#[test]
fn claude_switch_round_trips_and_keeps_the_file() {
    let f = fixture();
    let settings = f.homes.claude_settings();
    let before = fs::read_to_string(&settings).unwrap();
    let wrangler = f.homes.claude.join("skills/wrangler/SKILL.md");
    let change = |path: &Path, enabled| SetEnabled {
        agent: Agent::Claude,
        path: path.to_path_buf(),
        enabled,
        cwd: Some(f.cwd.clone()),
        codex_live: None,
    };
    let off = set_enabled(&f.homes, &change(&wrangler, false)).unwrap();
    assert!(!off.enabled);
    let text = fs::read_to_string(&settings).unwrap();
    assert!(text.starts_with("{\n  \"model\": \"opus\",\n  \"enabledPlugins\""), "{text}");
    assert!(text.contains("\"wrangler\": \"off\""));
    assert!(text.contains("\"env\": {\"TOKEN\": \"secret\"}"));
    let real = fs::canonicalize(&settings).unwrap();
    assert_eq!(fs::read_to_string(f.homes.edits.backup_path(&real)).unwrap(), before);
    // The backup is in cmux's private store, never beside the settings file.
    assert!(!settings.with_file_name("settings.json.cmux-backup").exists());
    // On removes the override; the others stay.
    let alpha = f.homes.claude.join("skills/alpha/SKILL.md");
    assert!(set_enabled(&f.homes, &change(&alpha, true)).unwrap().enabled);
    let text = fs::read_to_string(&settings).unwrap();
    assert!(!text.contains("\"alpha\""));
    assert!(text.contains("\"wrangler\": \"off\""));
    // A project skill goes to the project's local settings.
    let project = f.repo.join(".claude/skills/project-one/SKILL.md");
    assert!(!set_enabled(&f.homes, &change(&project, false)).unwrap().enabled);
    let local = fs::read_to_string(f.repo.join(".claude/settings.local.json")).unwrap();
    assert_eq!(local, "{\n  \"skillOverrides\": {\n    \"project-one\": \"off\"\n  }\n}\n");
    // Commands and plugin skills have no switch.
    let top = f.homes.claude.join("commands/top.md");
    assert!(matches!(set_enabled(&f.homes, &change(&top, false)), Err(ToggleError::NoSwitch(_))));
    assert!(matches!(
        set_enabled(&f.homes, &change(Path::new("/nope/SKILL.md"), false)),
        Err(ToggleError::NotListed(_))
    ));
    // A settings file that is not JSON is left alone.
    fs::write(&settings, "{ not json").unwrap();
    assert!(matches!(
        set_enabled(&f.homes, &change(&wrangler, true)),
        Err(ToggleError::Unreadable(..))
    ));
    assert_eq!(fs::read_to_string(&settings).unwrap(), "{ not json");
}

#[test]
fn codex_switch_round_trips_and_keeps_comments() {
    let f = fixture();
    let config = f.homes.codex_config();
    let pdf =
        fs::canonicalize(f.homes.codex.join("plugins/cache/market/pdf/1.0.0/skills/pdf/SKILL.md"))
            .unwrap();
    let change = |enabled| SetEnabled {
        agent: Agent::Codex,
        path: pdf.clone(),
        enabled,
        cwd: None,
        codex_live: None,
    };
    assert!(!set_enabled(&f.homes, &change(false)).unwrap().enabled);
    let text = fs::read_to_string(&config).unwrap();
    assert!(text.starts_with("# my codex\nmodel = \"gpt\"\n"), "{text}");
    assert!(
        text.contains(&format!(
            "[[skills.config]]\npath = \"{}\"\nenabled = false\n",
            pdf.display()
        )),
        "{text}"
    );
    assert!(text.contains("name = \"cloudflare\""));
    assert!(set_enabled(&f.homes, &change(true)).unwrap().enabled);
    let text = fs::read_to_string(&config).unwrap();
    assert_eq!(text.matches("[[skills.config]]").count(), 1, "path rule removed: {text}");
    assert!(!text.contains(&pdf.display().to_string()), "{text}");
    // A path rule after the name rule turns a skill back on.
    let cloudflare = fs::canonicalize(f.homes.codex.join("skills/cloudflare/SKILL.md")).unwrap();
    let on = set_enabled(
        &f.homes,
        &SetEnabled {
            agent: Agent::Codex,
            path: cloudflare,
            enabled: true,
            cwd: None,
            codex_live: None,
        },
    )
    .unwrap();
    assert!(on.enabled);
}

#[test]
fn codex_app_server_reply_parses() {
    let reply = serde_json::json!({"data": [{"cwd": "/w", "skills": [
        {"name": "agents-sdk", "description": "d", "path": "/h/.codex/skills/agents-sdk/SKILL.md", "scope": "user", "enabled": true, "pluginId": null},
        {"name": "codex-security:fix", "description": "f", "path": "/h/.codex/plugins/cache/r/codex-security/0.1/skills/fix/SKILL.md", "scope": "user", "enabled": false, "pluginId": "codex-security@r"},
        {"name": "imagegen", "description": "i", "path": "/h/.codex/skills/.system/imagegen/SKILL.md", "scope": "system", "enabled": true, "pluginId": null},
        {"name": "repo-one", "description": "r", "path": "/w/.agents/skills/repo-one/SKILL.md", "scope": "repo", "enabled": true},
        {"description": "no name", "path": "/x", "scope": "user"}
    ], "errors": [{"path": "/w/.agents/skills/bad/SKILL.md", "message": "missing field `description`"}]}]});
    let (skills, problems) = codex_live::parse(&reply);
    let scopes: Vec<_> = skills.iter().map(|s| (s.name.as_str(), s.scope, s.enabled)).collect();
    assert_eq!(
        scopes,
        [
            ("agents-sdk", Scope::User, true),
            ("codex-security:fix", Scope::Plugin, false),
            ("imagegen", Scope::System, true),
            ("repo-one", Scope::Project, true),
        ]
    );
    assert_eq!(problems.len(), 1);
}

/// A stand-in `codex` whose app-server answers `skills/list`, so the live path runs end to end.
#[cfg(unix)]
#[test]
fn codex_live_list_runs_the_app_server() {
    use std::os::unix::fs::PermissionsExt as _;
    let f = fixture();
    let bin = f.homes.home.join("fake-codex");
    fs::write(
        &bin,
        "#!/bin/sh\n[ \"$1\" = app-server ] || exit 3\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *'\"id\":1'*) echo '{\"id\":1,\"result\":{}}' ;;\n    *'skills/list'*) echo '{\"method\":\"note\"}'; echo '{\"id\":2,\"result\":{\"data\":[{\"skills\":[{\"name\":\"remote:only\",\"description\":\"r\",\"path\":\"/r/SKILL.md\",\"scope\":\"user\",\"enabled\":true,\"pluginId\":\"remote@x\"}],\"errors\":[]}]}}' ;;\n  esac\ndone\n",
    )
    .unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    let live = CodexLive { program: bin, timeout: std::time::Duration::from_secs(10) };
    let listing = list(&f.homes, &ListOptions { cwd: Some(f.cwd.clone()), codex_live: Some(live) });
    assert_eq!(listing.sources.codex, "app-server");
    assert_eq!(names(&listing, Agent::Codex, Kind::Skill), ["remote:only"]);
    let skill = listing.skills.iter().find(|s| s.name == "remote:only").unwrap();
    assert_eq!(skill.switch_file.as_deref(), Some(f.homes.codex_config().as_path()));
    // An app-server that does not answer: the folders instead.
    let dead = CodexLive {
        program: PathBuf::from("/nonexistent/codex"),
        timeout: std::time::Duration::from_secs(1),
    };
    let listing = list(&f.homes, &ListOptions { cwd: None, codex_live: Some(dead) });
    assert_eq!(listing.sources.codex, "files");
}
