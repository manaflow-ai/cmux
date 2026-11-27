//! The agent-config reader and writer over one checked-in HOME (`tests/fixtures/home`): a
//! comment-heavy Codex `config.toml`, Claude Code settings and state with keys cmux does not know,
//! both agents' hooks, MCP servers and skills. Every part lists what the fixture holds, and every
//! off-then-on (hooks, MCP servers, skills) or set-then-set-back (settings) leaves each file byte
//! for byte as it was, comments and unknown keys included.
//!
//! shadow-leo, 2026-11-26: "build one shared agent-config reader (hooks, mcp, settings, skills)
//! that runs headless against a checked-in fixture HOME with a comment-heavy toml and a json with
//! unknown keys, and round-trips byte for byte".
//!
//! Headless and fast: no agent CLI, no app-server, no GUI. The settings pane walks only prove
//! the page renders; the parse and edit logic is proven here.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_agent_customize::hooks::{self, Agent as HookAgent};
use cmux_agent_customize::hooks_paths::AgentPaths;
use cmux_agent_customize::mcp::{self, Edit, Options, Scope as McpScope, Target};
use cmux_agent_customize::paths::Paths;
use cmux_agent_customize::settings::{self, Context};
use cmux_agent_customize::skills::{self, ListOptions, SetEnabled};
use cmux_agent_customize::write::Store;
use cmux_agent_customize::{Agent, Homes};

/// The project folder's key in `~/.claude.json`, filled in once the fixture has a real path.
const PROJECT_PLACEHOLDER: &str = "__PROJECT__";
/// HOME's real path in `.codex/config.toml` (a `[[skills.config]]` path rule).
const HOME_PLACEHOLDER: &str = "__HOME__";

/// The agent files the round-trips must leave byte for byte, relative to HOME.
const WATCHED: &[&str] = &[
    ".claude/settings.json",
    ".claude.json",
    ".codex/config.toml",
    ".codex/hooks.json",
    "work/repo/.mcp.json",
    "work/repo/.claude/settings.json",
    ".claude/skills/fixture-review/SKILL.md",
    ".codex/skills/fixture-deploy/SKILL.md",
    ".codex/skills/fixture-lint/SKILL.md",
];

struct Home {
    _root: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
}

impl Home {
    /// A copy of the checked-in HOME in a temporary folder (edits never touch the fixture).
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = fs::canonicalize(root.path()).unwrap().join("home");
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/home");
        copy_tree(&source, &home);
        let project = home.join("work/repo");
        // A repository root ends the project chain; git cannot check in a `.git` folder.
        fs::create_dir_all(project.join(".git")).unwrap();
        let state = home.join(".claude.json");
        let text = fs::read_to_string(&state).unwrap();
        fs::write(&state, text.replace(PROJECT_PLACEHOLDER, &project.display().to_string()))
            .unwrap();
        let codex = home.join(".codex/config.toml");
        let text = fs::read_to_string(&codex).unwrap();
        fs::write(&codex, text.replace(HOME_PLACEHOLDER, &home.display().to_string())).unwrap();
        Self { _root: root, home, project }
    }

    fn snapshot(&self) -> BTreeMap<&'static str, Vec<u8>> {
        WATCHED.iter().map(|rel| (*rel, fs::read(self.home.join(rel)).unwrap())).collect()
    }

    fn assert_unchanged(&self, before: &BTreeMap<&'static str, Vec<u8>>, what: &str) {
        for (rel, bytes) in before {
            let now = fs::read(self.home.join(rel)).unwrap();
            assert!(
                now == *bytes,
                "{what}: {rel} is not byte for byte as it was\n--- before\n{}\n--- after\n{}",
                String::from_utf8_lossy(bytes),
                String::from_utf8_lossy(&now)
            );
        }
    }

    fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.home.join(rel)).unwrap()
    }

    fn vars(&self) -> impl Fn(&str) -> Option<std::ffi::OsString> + '_ {
        move |name| match name {
            "HOME" => Some(self.home.clone().into_os_string()),
            _ => None,
        }
    }

    fn hook_paths(&self) -> AgentPaths {
        let mut paths = AgentPaths::from_vars(&self.home, Some(self.project.clone()), self.vars());
        paths.edits = Store::new(self.home.join(".local/state/cmux-tui/agent-config"));
        paths
    }

    fn mcp_paths(&self) -> Paths {
        let env = BTreeMap::from([("HOME".to_owned(), self.home.display().to_string())]);
        Paths::from_env(&env).unwrap()
    }

    fn mcp_options(&self) -> Options {
        Options { project: Some(self.project.clone()), codex_cli: None }
    }

    fn settings_ctx(&self) -> Context {
        Context {
            homes: Homes::under(&self.home),
            cwd: Some(self.project.clone()),
            claude_managed: self.home.join("managed/managed-settings.json"),
            codex_managed: self.home.join("managed/managed_config.toml"),
            codex_system: self.home.join("managed/config.toml"),
        }
    }
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

// ---------------------------------------------------------------- hooks

#[test]
fn hooks_list_by_event() {
    let home = Home::new();
    let listing = hooks::list(&home.hook_paths());
    let mut seen: Vec<(HookAgent, String, String, bool)> = listing
        .hooks
        .iter()
        .map(|h| (h.agent, h.event.clone(), h.command.clone(), h.enabled))
        .collect();
    seen.sort_by(|a, b| (a.0.as_str(), &a.1, &a.2).cmp(&(b.0.as_str(), &b.1, &b.2)));
    assert_eq!(
        seen,
        vec![
            (HookAgent::Claude, "PreToolUse".into(), "fixture-guard-bash".into(), true),
            (HookAgent::Claude, "Stop".into(), "fixture-on-stop".into(), true),
            (HookAgent::Codex, "PreToolUse".into(), "fixture-codex-guard".into(), true),
            (HookAgent::Codex, "SessionStart".into(), "fixture-codex-start".into(), true),
        ]
    );
    assert_eq!(listing.codex_hooks_feature, Some(true));
    assert!(listing.files.iter().all(|f| f.error.is_none()), "{:?}", listing.files);
}

#[test]
fn hooks_off_then_on_round_trips_byte_for_byte() {
    let home = Home::new();
    let paths = home.hook_paths();
    let before = home.snapshot();
    for command in ["fixture-guard-bash", "fixture-codex-guard"] {
        let id = hooks::list(&paths)
            .hooks
            .into_iter()
            .find(|h| h.command == command)
            .unwrap_or_else(|| panic!("{command} not listed"))
            .id;
        let off = hooks::set_enabled(&paths, &id, false, false).unwrap();
        assert!(!off.enabled, "{command} still on");
        let on = hooks::set_enabled(&paths, &id, true, false).unwrap();
        assert!(on.enabled, "{command} still off");
        assert_eq!(on.id, id, "{command}'s id changed across off and on");
        home.assert_unchanged(&before, &format!("hook {command} off then on"));
    }
}

// ---------------------------------------------------------------- MCP servers

#[test]
fn mcp_lists_both_agents_servers() {
    let home = Home::new();
    let paths = home.mcp_paths();
    let names = |agent: Agent| {
        let listing = mcp::list(&paths, agent, &home.mcp_options());
        assert!(listing.problems.is_empty(), "{agent:?}: {:?}", listing.problems);
        let mut names: Vec<(String, McpScope, bool)> =
            listing.servers.iter().map(|s| (s.name.clone(), s.scope, s.enabled)).collect();
        names.sort_by(|a, b| a.0.cmp(&b.0));
        (names, listing)
    };
    let (claude, listing) = names(Agent::Claude);
    assert_eq!(
        claude.iter().map(|(n, s, _)| (n.as_str(), *s)).collect::<Vec<_>>(),
        vec![
            ("fixture-http", McpScope::User),
            ("fixture-project", McpScope::Project),
            ("fixture-stdio", McpScope::User),
        ]
    );
    // A secret never leaves the crate.
    let stdio = listing.servers.iter().find(|s| s.name == "fixture-stdio").unwrap();
    assert_eq!(stdio.env, vec!["FIXTURE_TOKEN".to_owned()]);
    assert!(!serde_json::to_string(&listing.servers).unwrap().contains("not-a-real-secret"));
    let (codex, _) = names(Agent::Codex);
    assert_eq!(
        codex,
        vec![
            ("fixture-codex-http".into(), McpScope::User, true),
            ("fixture-codex-stdio".into(), McpScope::User, true),
        ]
    );
}

#[test]
fn mcp_off_then_on_round_trips_byte_for_byte() {
    let home = Home::new();
    let paths = home.mcp_paths();
    let options = home.mcp_options();
    let before = home.snapshot();
    // fixture-stdio: `disabledMcpServers` is absent and must stay absent. fixture-project: a
    // project server in an approved list whose order must hold. fixture-codex-http: an
    // `enabled = true` line the person wrote, comment and all.
    for (agent, name, scope) in [
        (Agent::Claude, "fixture-stdio", McpScope::User),
        (Agent::Claude, "fixture-project", McpScope::Project),
        (Agent::Codex, "fixture-codex-stdio", McpScope::User),
        (Agent::Codex, "fixture-codex-http", McpScope::User),
    ] {
        let target = Target {
            agent,
            name: name.to_owned(),
            scope: Some(scope),
            project: Some(home.project.clone()),
        };
        let enabled = |paths: &Paths| {
            mcp::list(paths, agent, &options)
                .servers
                .iter()
                .find(|s| s.name == name)
                .unwrap()
                .enabled
        };
        assert!(mcp::apply(&paths, &target, &Edit::Disable, &options).unwrap().changed);
        assert!(!enabled(&paths), "{name} still on");
        assert!(mcp::apply(&paths, &target, &Edit::Enable, &options).unwrap().changed);
        assert!(enabled(&paths), "{name} still off");
        home.assert_unchanged(&before, &format!("{agent:?} MCP server {name} off then on"));
    }
}

// ---------------------------------------------------------------- settings

#[test]
fn settings_read_curated_values_and_unknown_keys() {
    let home = Home::new();
    let ctx = home.settings_ctx();
    let claude = settings::report(&ctx, Agent::Claude);
    let value = |report: &serde_json::Value, key: &str| {
        report["curated"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["key"] == key)
            .map(|row| row["value"].clone())
            .unwrap_or_else(|| panic!("no curated row {key}"))
    };
    assert_eq!(value(&claude, "model"), "opus");
    assert_eq!(value(&claude, "permissions.defaultMode"), "default");
    let keys: Vec<&str> =
        claude["entries"].as_array().unwrap().iter().filter_map(|e| e["key"].as_str()).collect();
    for unknown in ["futureKeyCmuxDoesNotKnow.flag", "zzLastUnknownKey"] {
        assert!(keys.iter().any(|k| k.starts_with(unknown)), "{unknown} not shown: {keys:?}");
    }
    let codex = settings::report(&ctx, Agent::Codex);
    assert_eq!(value(&codex, "model"), "gpt-5.1-codex");
    assert_eq!(value(&codex, "approval_policy"), "on-request");
}

#[test]
fn settings_set_then_set_back_round_trips_byte_for_byte() {
    let home = Home::new();
    let ctx = home.settings_ctx();
    let before = home.snapshot();
    for (agent, key, other, original, file) in [
        (Agent::Claude, "model", "sonnet", "opus", ".claude/settings.json"),
        (Agent::Codex, "model", "gpt-5.1-codex-max", "gpt-5.1-codex", ".codex/config.toml"),
        (Agent::Codex, "approval_policy", "never", "on-request", ".codex/config.toml"),
    ] {
        settings::apply(&ctx, agent, key, Some(other), None).unwrap();
        let changed = home.read(file);
        assert!(changed.contains(other), "{agent:?} {key}: {other} not written:\n{changed}");
        settings::apply(&ctx, agent, key, Some(original), None).unwrap();
        home.assert_unchanged(&before, &format!("{agent:?} {key} set then set back"));
    }
}

// ---------------------------------------------------------------- skills

#[test]
fn skills_list_both_agents() {
    let home = Home::new();
    let homes = Homes::under(&home.home);
    let listing = skills::list(&homes, &ListOptions { cwd: None, codex_live: None });
    let mut seen: Vec<(skills::Agent, &str, bool)> = listing
        .skills
        .iter()
        .filter(|s| s.kind == skills::Kind::Skill && s.name.starts_with("fixture-"))
        .map(|s| (s.agent, s.name.as_str(), s.enabled))
        .collect();
    seen.sort_by_key(|s| s.1);
    assert_eq!(
        seen,
        vec![
            (skills::Agent::Codex, "fixture-deploy", true),
            (skills::Agent::Codex, "fixture-lint", true),
            (skills::Agent::Claude, "fixture-review", true),
        ]
    );
    assert!(listing.problems.is_empty(), "{:?}", listing.problems);
}

/// Claude: the person's empty `"skillOverrides": {}` stays. Codex: fixture-deploy has a path rule
/// the person wrote (set back in place, comment kept); fixture-lint has none, so the rule cmux adds
/// to turn it off goes again on enable.
#[test]
fn skills_off_then_on_round_trips_byte_for_byte() {
    let home = Home::new();
    let homes = Homes::under(&home.home);
    let before = home.snapshot();
    for (agent, rel) in [
        (skills::Agent::Claude, ".claude/skills/fixture-review/SKILL.md"),
        (skills::Agent::Codex, ".codex/skills/fixture-deploy/SKILL.md"),
        (skills::Agent::Codex, ".codex/skills/fixture-lint/SKILL.md"),
    ] {
        let path = home.home.join(rel);
        let change = |enabled| SetEnabled {
            agent,
            path: path.clone(),
            enabled,
            cwd: None,
            codex_live: None,
        };
        assert!(!skills::set_enabled(&homes, &change(false)).unwrap().enabled);
        assert!(skills::set_enabled(&homes, &change(true)).unwrap().enabled);
        home.assert_unchanged(&before, &format!("{agent:?} skill {rel} off then on"));
    }
}
