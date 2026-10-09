//! The ACP Registry (cx-1785): checked parsing, how each agent starts, the
//! installed agents as harnesses, and the profile file `add --registry` writes.

use super::*;

const FIXTURE: &str = include_str!("../tests/fixtures/acp-registry.json");

fn registry() -> Registry {
    parse(FIXTURE.as_bytes()).unwrap()
}

fn on_path(found: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
    move |bin: &str| found.contains(&bin).then(|| format!("/u/bin/{bin}"))
}

#[test]
fn parse_keeps_checked_agents_and_drops_bad_ones_alone() {
    let ids: Vec<String> = registry().agents.into_iter().map(|a| a.id).collect();
    assert_eq!(
        ids,
        ["goose", "github-copilot-cli", "auggie", "fast-agent", "codex-acp", "grok-build"]
    );
    // The first `goose` wins; the floating version, the bad id, the archive
    // path that leaves the archive, a loader env key, a plain-http archive
    // and an argument expansion are all dropped.
    let goose = registry().agent("goose").cloned().unwrap();
    assert_eq!(goose.version, "1.54.0");
    assert_eq!(goose.binary["darwin-aarch64"].cmd, "./goose");
    assert!(goose.binary["windows-x86_64"].sha256.is_none());
    assert_eq!(
        registry().agent("auggie").unwrap().npx.as_ref().unwrap().env["AUGMENT_DISABLE_AUTO_UPDATE"],
        "1"
    );
}

#[test]
fn parse_refuses_a_bad_envelope() {
    assert!(parse(b"{}").is_err());
    assert!(parse(b"not json").is_err());
    assert!(parse(&vec![b' '; MAX_BODY_BYTES + 1]).is_err());
}

#[test]
fn program_names_are_plain() {
    assert_eq!(program_name("./goose").as_deref(), Some("goose"));
    assert_eq!(program_name("./goose-package\\goose.exe").as_deref(), Some("goose"));
    assert_eq!(program_name("./dist-package/cursor-agent").as_deref(), Some("cursor-agent"));
    assert_eq!(program_name("./bin/.hidden"), None);
}

#[test]
fn launch_prefers_the_installed_program_then_npx_then_uvx() {
    let reg = registry();
    let goose = reg.agent("goose").unwrap();
    assert_eq!(
        goose.launch(Some("darwin-aarch64"), &on_path(&["goose", "npx"])),
        Launch::Installed { argv: vec!["/u/bin/goose".into(), "acp".into()], env: BTreeMap::new() }
    );
    // Not installed and only an archive: its download page, never a download.
    assert_eq!(goose.launch(Some("darwin-aarch64"), &on_path(&["npx"])).method(), "download");
    assert_eq!(goose.launch(Some("windows-aarch64"), &on_path(&[])), Launch::Unavailable);
    let copilot = reg.agent("github-copilot-cli").unwrap();
    assert_eq!(
        copilot.launch(None, &on_path(&["copilot", "npx"])),
        Launch::Installed {
            argv: vec!["/u/bin/copilot".into(), "--acp".into()],
            env: BTreeMap::new()
        }
    );
    assert_eq!(
        copilot.launch(None, &on_path(&["npx"])),
        Launch::Npx {
            argv: vec![
                "/u/bin/npx".into(),
                "-y".into(),
                "@github/copilot@1.0.93".into(),
                "--acp".into()
            ],
            env: BTreeMap::new()
        }
    );
    let fast = reg.agent("fast-agent").unwrap();
    assert_eq!(
        fast.launch(None, &on_path(&["uvx"])),
        Launch::Uvx {
            argv: vec!["/u/bin/uvx".into(), "fast-agent-acp@0.10.1".into(), "-x".into()],
            env: BTreeMap::new()
        }
    );
    assert_eq!(fast.launch(None, &on_path(&["npx"])), Launch::Unavailable);
}

#[test]
fn only_installed_agents_become_harnesses_and_known_ones_keep_our_ids() {
    let reg = registry();
    let found = discovered(
        &reg,
        Some("linux-x86_64"),
        &on_path(&["goose", "copilot", "npx", "uvx"]),
        &|_| false,
    );
    // npx and uvx alone never add a harness: running a package is a choice.
    assert_eq!(found.keys().collect::<Vec<_>>(), ["github-copilot-cli", "goose"]);
    assert_eq!(found["goose"].argv, vec!["/u/bin/goose".to_owned(), "acp".into()]);
    assert_eq!(found["goose"].kind, HarnessKind::Acp);
    assert!(found["goose"].description.as_deref().unwrap().contains("ACP Registry"));
    // A harness found another way keeps its id.
    let found = discovered(&reg, Some("linux-x86_64"), &on_path(&["goose"]), &|id| id == "goose");
    assert!(found.is_empty());
    assert_eq!(harness_id("codex-acp"), "codex");
    assert_eq!(harness_id("grok-build"), "grok");
    assert_eq!(harness_id("glm.agent_x"), "glm-agent-x");
}

#[test]
fn the_registry_profile_loads_as_a_harness_profile() {
    let reg = registry();
    let auggie = reg.agent("auggie").unwrap();
    let launch = auggie.launch(None, &on_path(&["npx"]));
    let text = profile_toml(auggie, &launch).unwrap();
    let dir = std::env::temp_dir().join(format!("acpmux-registry-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("auggie.toml");
    std::fs::write(&path, &text).unwrap();
    let parsed = crate::config::profiles::parse_profile_toml(
        &text,
        &path,
        Some("auggie"),
        crate::config::ProfileSource::UserFile,
    );
    let _ = std::fs::remove_dir_all(&dir);
    let (_, profile, meta, warnings) = parsed.unwrap();
    assert!(warnings.is_empty(), "{warnings:?}");
    assert_eq!(
        profile.argv,
        vec![
            "/u/bin/npx".to_owned(),
            "-y".into(),
            "@augmentcode/auggie@0.36.0".into(),
            "--acp".into()
        ]
    );
    assert_eq!(profile.env["AUGMENT_DISABLE_AUTO_UPDATE"], "1");
    assert_eq!(meta.display_name.as_deref(), Some("Auggie CLI"));
    assert!(profile_toml(auggie, &Launch::Unavailable).is_none());
}

#[test]
fn save_keeps_only_a_body_that_parses_and_reports_a_change() {
    let home = std::env::temp_dir().join(format!("acpmux-registry-save-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    assert!(save(&home, b"{}").is_err());
    assert!(load_cached(&home).is_none());
    assert_eq!(save(&home, FIXTURE.as_bytes()), Ok(true));
    assert_eq!(save(&home, FIXTURE.as_bytes()), Ok(false));
    assert_eq!(load_cached(&home).unwrap(), registry());
    let _ = std::fs::remove_dir_all(&home);
}
