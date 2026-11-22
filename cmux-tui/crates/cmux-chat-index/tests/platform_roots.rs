//! The store-root table for macOS, Linux and Windows, run with an injected
//! home and env on any host (no process env, no real home).

mod common;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_chat_index::{
    AdapterKind, DiscoveryInput, Platform, RootSource, default_roots, discover_on,
};

/// `/`-separated segments joined one by one (host separator).
fn at(base: &Path, rel: &str) -> PathBuf {
    rel.split('/').fold(base.to_path_buf(), |path, part| path.join(part))
}

struct Case {
    home: PathBuf,
    env: HashMap<String, String>,
    _dir: tempfile::TempDir,
}

impl Case {
    fn new(env: &[(&str, &str)]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = fs::canonicalize(dir.path()).unwrap().join("home");
        let env = env
            .iter()
            .map(|(key, rel)| ((*key).to_owned(), at(&home, rel).display().to_string()))
            .collect();
        Self { home, env, _dir: dir }
    }

    fn roots(&self, kind: AdapterKind, platform: Platform) -> Vec<(PathBuf, RootSource)> {
        default_roots(kind, platform, &self.home, &|key| self.env.get(key).cloned())
    }

    fn paths(&self, kind: AdapterKind, platform: Platform) -> Vec<PathBuf> {
        self.roots(kind, platform).into_iter().map(|(path, _)| path).collect()
    }

    fn h(&self, rel: &str) -> PathBuf {
        at(&self.home, rel)
    }
}

#[test]
fn every_harness_has_absolute_defaults_inside_the_injected_home_on_every_platform() {
    let case = Case::new(&[]);
    for platform in Platform::ALL {
        for kind in AdapterKind::ALL {
            let roots = case.roots(kind, platform);
            if kind != AdapterKind::Crush {
                assert!(!roots.is_empty(), "{kind:?} on {platform:?} has no default root");
            }
            for (path, _) in roots {
                assert!(path.is_absolute(), "{kind:?} {platform:?}: {}", path.display());
                assert!(
                    path.starts_with(&case.home),
                    "{kind:?} {platform:?} leaked outside the injected home: {}",
                    path.display()
                );
            }
        }
    }
}

#[test]
fn env_overrides_come_first_and_name_their_source() {
    let case = Case::new(&[
        ("CLAUDE_CONFIG_DIR", "alt/claude"),
        ("CODEX_HOME", "alt/codex"),
        ("XDG_DATA_HOME", "alt/data"),
        ("PI_CODING_AGENT_SESSION_DIR", "alt/pi-flat"),
        ("GEMINI_CLI_HOME", "alt/gem"),
        ("QWEN_HOME", "alt/qwen"),
        ("COPILOT_HOME", "alt/copilot"),
        ("GROK_HOME", "alt/grok"),
        ("KIMI_SHARE_DIR", "alt/kimi"),
        ("KIMI_CODE_HOME", "alt/kimi-code"),
        ("GOOSE_PATH_ROOT", "alt/goose"),
        ("FACTORY_HOME_OVERRIDE", "alt/factory"),
        ("CLINE_DATA_DIR", "alt/cline"),
        ("CONTINUE_GLOBAL_DIR", "alt/continue"),
        ("OPENHANDS_CONVERSATIONS_DIR", "alt/oh"),
        ("CURSOR_DATA_DIR", "alt/cursor"),
    ]);
    let expected = [
        (AdapterKind::ClaudeCode, "alt/claude/projects"),
        (AdapterKind::Codex, "alt/codex"),
        (AdapterKind::OpenCode, "alt/data/opencode"),
        (AdapterKind::Kilo, "alt/data/kilo"),
        (AdapterKind::Amp, "alt/data/amp/threads"),
        (AdapterKind::Pi, "alt/pi-flat"),
        (AdapterKind::Gemini, "alt/gem/.gemini"),
        (AdapterKind::QwenCode, "alt/qwen"),
        (AdapterKind::CopilotCli, "alt/copilot"),
        (AdapterKind::Grok, "alt/grok/sessions"),
        (AdapterKind::KimiCli, "alt/kimi"),
        (AdapterKind::KimiCode, "alt/kimi-code"),
        (AdapterKind::Goose, "alt/goose/data/sessions"),
        (AdapterKind::Droid, "alt/factory/.factory/sessions"),
        (AdapterKind::Cline, "alt/cline"),
        (AdapterKind::Continue, "alt/continue/sessions"),
        (AdapterKind::OpenHands, "alt/oh"),
        (AdapterKind::CursorAgent, "alt/cursor/chats"),
    ];
    for platform in Platform::ALL {
        for (kind, rel) in expected {
            let roots = case.roots(kind, platform);
            assert_eq!(
                roots.first(),
                Some(&(case.h(rel), RootSource::Env)),
                "{kind:?} {platform:?}"
            );
        }
    }
}

#[test]
fn per_platform_defaults_match_each_harness() {
    let case = Case::new(&[("APPDATA", "AppData/Roaming"), ("LOCALAPPDATA", "AppData/Local")]);
    let (mac, linux, win) = (Platform::MacOs, Platform::Linux, Platform::Windows);
    let h = |rel: &str| case.h(rel);

    // Claude: ~/.claude everywhere; ~/.config/claude (1.0.28-1.0.31) off Windows.
    assert_eq!(
        case.paths(AdapterKind::ClaudeCode, mac),
        [h(".claude/projects"), h(".config/claude/projects")]
    );
    assert_eq!(case.paths(AdapterKind::ClaudeCode, win), [h(".claude/projects")]);
    // OpenCode: xdg-basedir on every OS; env-paths (0.0.53-0.0.55) per OS.
    assert_eq!(
        case.paths(AdapterKind::OpenCode, mac),
        [h(".local/share/opencode"), h("Library/Application Support/opencode")]
    );
    assert_eq!(case.paths(AdapterKind::OpenCode, linux), [h(".local/share/opencode")]);
    assert_eq!(
        case.paths(AdapterKind::OpenCode, win),
        [h(".local/share/opencode"), h("AppData/Local/opencode/Data")]
    );
    // goose: etcetera Xdg on macOS and Linux, %APPDATA%\Block on Windows.
    for platform in [mac, linux] {
        assert_eq!(case.paths(AdapterKind::Goose, platform), [h(".local/share/goose/sessions")]);
    }
    assert_eq!(
        case.paths(AdapterKind::Goose, win),
        [h("AppData/Roaming/Block/goose/data/sessions")]
    );
    // Gemini seatbelt sandbox home only on macOS.
    assert_eq!(case.paths(AdapterKind::Gemini, mac), [h(".gemini"), h(".cache/.gemini")]);
    assert_eq!(case.paths(AdapterKind::Gemini, win), [h(".gemini")]);
    // VS Code globalStorage per OS.
    let cline = |platform| case.paths(AdapterKind::Cline, platform);
    let storage = "User/globalStorage/saoudrizwan.claude-dev";
    assert!(cline(mac).contains(&h(&format!("Library/Application Support/Code/{storage}"))));
    assert!(cline(linux).contains(&h(&format!(".config/Code/{storage}"))));
    assert!(cline(win).contains(&h(&format!("AppData/Roaming/Code/{storage}"))));
    assert!(cline(win).contains(&h(&format!("AppData/Roaming/Cursor/{storage}"))));
    assert_eq!(cline(linux).first(), Some(&h(".cline/data")));
    let roo = case.paths(AdapterKind::RooCode, linux);
    assert!(
        roo.contains(&h(".config/Code - Insiders/User/globalStorage/rooveterinaryinc.roo-cline"))
    );
    // Plain home dirs on every OS.
    for platform in Platform::ALL {
        assert_eq!(case.paths(AdapterKind::Codex, platform), [h(".codex")]);
        assert_eq!(
            case.paths(AdapterKind::Pi, platform),
            [h(".pi/agent/sessions"), h(".coding-agent/sessions")]
        );
        assert_eq!(case.paths(AdapterKind::Droid, platform), [h(".factory/sessions")]);
        assert_eq!(case.paths(AdapterKind::Grok, platform), [h(".grok/sessions")]);
        assert_eq!(case.paths(AdapterKind::GrokCli, platform), [h(".grok")]);
        assert_eq!(case.paths(AdapterKind::Auggie, platform), [h(".augment/sessions")]);
        assert_eq!(case.paths(AdapterKind::KimiCode, platform), [h(".kimi-code")]);
        assert_eq!(case.paths(AdapterKind::CopilotCli, platform), [h(".copilot")]);
    }
}

#[test]
fn windows_app_data_falls_back_to_the_profile_when_unset() {
    let case = Case::new(&[]);
    assert_eq!(
        case.paths(AdapterKind::Goose, Platform::Windows),
        [case.h("AppData/Roaming/Block/goose/data/sessions")]
    );
    assert!(
        case.paths(AdapterKind::KiloCode, Platform::Windows)
            .contains(&case.h("AppData/Roaming/Code/User/globalStorage/kilocode.kilo-code"))
    );
}

#[test]
fn pi_reads_the_session_dir_setting_and_crush_reads_its_project_index() {
    let case = Case::new(&[]);
    common::write(&case.h(".pi/agent/settings.json"), r#"{"sessionDir":"~/pi-sessions"}"#);
    assert_eq!(
        case.roots(AdapterKind::Pi, Platform::Linux)[0],
        (case.h("pi-sessions"), RootSource::Env)
    );

    let project = case.h("work/app");
    let index = serde_json::json!({"projects": [
        {"path": project.display().to_string(), "data_dir": project.join(".crush").display().to_string(), "last_accessed": "2026-10-01T10:00:00Z"},
        {"path": project.display().to_string(), "data_dir": "relative-data", "last_accessed": "2026-10-01T10:00:00Z"},
    ]});
    common::write(&case.h(".local/share/crush/projects.json"), &index.to_string());
    let crush = case.paths(AdapterKind::Crush, Platform::MacOs);
    assert_eq!(crush, [project.join(".crush"), project.join("relative-data")]);
}

#[test]
fn discovery_on_windows_finds_the_windows_store_dirs() {
    let case = Case::new(&[("APPDATA", "AppData/Roaming")]);
    let goose = case.h("AppData/Roaming/Block/goose/data/sessions");
    fs::create_dir_all(&goose).unwrap();
    fs::create_dir_all(case.h(".codex")).unwrap();
    let found = discover_on(
        &DiscoveryInput {
            home: &case.home,
            env: &|key| case.env.get(key).cloned(),
            refuse: &|_| None,
            recorded: &[],
            user: &[],
        },
        Platform::Windows,
    );
    let kinds: Vec<(AdapterKind, PathBuf)> =
        found.roots.iter().map(|root| (root.harness, root.path.clone())).collect();
    assert!(kinds.contains(&(AdapterKind::Goose, goose)), "{kinds:?}");
    assert!(kinds.contains(&(AdapterKind::Codex, case.h(".codex"))), "{kinds:?}");
}
