use super::*;

fn facts(tools: &[&str]) -> MachineFacts {
    MachineFacts {
        os: "linux".into(),
        arch: "x86_64".into(),
        tools: tools.iter().map(|t| (*t).to_owned()).collect(),
        home: PathBuf::from("/home/someone"),
        home_writable: true,
        free_bytes: Some(10 * MIN_FREE_BYTES),
    }
}

#[test]
fn npm_keeps_its_route_where_the_machine_has_it() {
    let plan = resolve("claude", &facts(&["npm", "curl", "bash"]), None).unwrap();
    assert_eq!(plan.route, Some(Route::Npm));
    assert_eq!(plan.command.as_deref(), Some("npm install -g @anthropic-ai/claude-code"));
    // The native route is still offered beside it.
    assert!(plan.routes.iter().any(|r| r.route == Route::Native && r.ready));
    assert!(plan.blocked.is_none());
}

#[test]
fn a_clean_machine_without_npm_gets_the_vendor_native_installer() {
    let plan = resolve("claude", &facts(&["curl", "bash", "sh"]), None).unwrap();
    assert_eq!(plan.route, Some(Route::Native));
    assert_eq!(plan.command.as_deref(), Some("curl -fsSL https://claude.ai/install.sh | bash"));
    let codex = resolve("codex", &facts(&["curl", "sh"]), None).unwrap();
    assert_eq!(codex.route, Some(Route::Native));
    assert!(
        codex.command.unwrap().starts_with("curl -fsSL https://chatgpt.com/codex/install.sh |")
    );
    let npm = codex.routes.iter().find(|r| r.route == Route::Npm).unwrap();
    assert!(!npm.ready);
    assert_eq!(npm.prerequisites[0].id, "npm");
    assert!(npm.prerequisites[0].fix.is_some());
}

#[test]
fn homebrew_is_the_route_when_only_brew_is_here() {
    let plan = resolve("gemini", &facts(&["brew"]), None).unwrap();
    assert_eq!(plan.route, Some(Route::Brew));
    assert_eq!(plan.command.as_deref(), Some("brew install gemini-cli"));
    let claude = resolve("claude", &facts(&["brew"]), None).unwrap();
    assert_eq!(claude.command.as_deref(), Some("brew install --cask claude-code"));
}

#[test]
fn no_route_names_the_missing_prerequisite_and_its_fix() {
    let plan = resolve("claude", &facts(&[]), None).unwrap();
    assert_eq!(plan.route, None);
    assert_eq!(plan.command, None);
    let blocked = plan.blocked.unwrap();
    assert_eq!(blocked.phase, Phase::Prerequisites);
    assert_eq!(blocked.cause, Cause::Prerequisite);
    assert!(blocked.action.contains("curl"), "{}", blocked.action);
}

#[test]
fn unsupported_platform_full_disk_and_read_only_home_block_the_native_route() {
    let mut odd = facts(&["curl", "bash"]);
    odd.arch = "riscv64".into();
    let blocked = resolve("claude", &odd, None).unwrap().blocked.unwrap();
    assert_eq!(blocked.cause, Cause::Architecture);
    assert!(blocked.action.contains("riscv64") && blocked.action.contains("code.claude.com"));

    let mut full = facts(&["curl", "bash"]);
    full.free_bytes = Some(MIN_FREE_BYTES - 1);
    assert_eq!(resolve("claude", &full, None).unwrap().blocked.unwrap().cause, Cause::Disk);

    let mut locked = facts(&["curl", "bash"]);
    locked.home_writable = false;
    assert_eq!(resolve("claude", &locked, None).unwrap().blocked.unwrap().cause, Cause::Permission);

    // An unreadable free count is not a full disk.
    let mut unknown = facts(&["curl", "bash"]);
    unknown.free_bytes = None;
    assert_eq!(resolve("claude", &unknown, None).unwrap().route, Some(Route::Native));
}

#[test]
fn an_existing_installation_keeps_its_channel_and_gets_no_install() {
    let home = tempfile::tempdir().unwrap();
    let mut here = facts(&["npm", "curl", "bash"]);
    here.home = home.path().to_path_buf();
    let versions = home.path().join(".local/share/claude/versions");
    std::fs::create_dir_all(&versions).unwrap();
    let bin = versions.join("2.1.0");
    std::fs::write(&bin, "#!/bin/sh\n").unwrap();
    let plan = resolve("claude", &here, Some(&bin)).unwrap();
    assert_eq!(plan.route, None);
    assert_eq!(plan.command, None);
    assert!(plan.blocked.is_none());
    assert_eq!(plan.existing.unwrap().channel, Channel::Native);
}

#[cfg(unix)]
#[test]
fn find_installed_reads_path_then_the_native_location() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    assert_eq!(find_installed("claude", None, home.path()), None);
    let local = home.path().join(".local/bin");
    std::fs::create_dir_all(&local).unwrap();
    let bin = local.join("claude");
    std::fs::write(&bin, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(find_installed("claude", None, home.path()), Some(bin));
    assert_eq!(find_installed("aider", None, home.path()), None);
}

#[test]
fn the_plan_serializes_for_the_page() {
    let plan = resolve("codex", &facts(&["curl", "sh"]), None).unwrap();
    let value = serde_json::to_value(&plan).unwrap();
    assert_eq!(value["route"], "native");
    assert_eq!(value["probeUrl"], "https://chatgpt.com");
    assert_eq!(value["routes"][0]["route"], "npm");
    assert_eq!(value["routes"][0]["ready"], false);
    assert!(value.get("existing").is_none());
    // Every command sits inside the page's single-quoted retry wrapper.
    for id in ids() {
        for route in resolve(id, &facts(&[]), None).unwrap().routes {
            assert!(!route.command.contains('\''), "{id}: {}", route.command);
        }
    }
}

#[test]
fn unknown_agents_have_no_plan() {
    assert!(resolve("aider", &facts(&["npm"]), None).is_none());
    assert!(!known("aider"));
    assert!(known("claude"));
}

#[test]
fn failures_name_their_cause_and_fix_per_phase() {
    let docs = "https://example.test/docs";
    let c = |phase, out| classify_failure(phase, out, docs);
    assert_eq!(
        c(Phase::Download, "curl: (6) Could not resolve host: claude.ai").cause,
        Cause::Network
    );
    assert_eq!(c(Phase::Install, "npm ERR! code EACCES").cause, Cause::Permission);
    assert_eq!(c(Phase::Install, "write: No space left on device").cause, Cause::Disk);
    assert_eq!(c(Phase::Install, "Unsupported architecture: riscv64").cause, Cause::Architecture);
    assert_eq!(c(Phase::Prerequisites, "bash: curl: command not found").cause, Cause::Prerequisite);
    let verify = c(Phase::Verify, "");
    assert_eq!((verify.phase, verify.cause), (Phase::Verify, Cause::Other));
    assert!(verify.action.contains(docs));
    assert!(c(Phase::Install, "boom").action.contains(docs));
}
