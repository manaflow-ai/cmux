//! Updates must target the installation that the owner detected, including
//! multiple copies of a fork under different npm prefixes. Only stand-in
//! package managers run here; no npm, registry or installed CLI is touched.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::harness_health::channel::{Channel, Install, detect, update_plan};
use acpmux::harness_health::{HarnessHealth, HealthService};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Scratch(PathBuf);
impl Scratch {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("acpmux-update-prefix-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn manager(&self, default: &Path) -> PathBuf {
        let program = self.0.join("npm");
        let default = serde_json::to_string(&default.to_str().unwrap()).unwrap();
        std::fs::write(
            &program,
            format!(
                "#!/usr/bin/env python3\nimport pathlib, sys\nargs = sys.argv[1:]\nprefix = args[args.index('--prefix') + 1] if '--prefix' in args else {default}\npathlib.Path(prefix, 'updated').write_text(args[-1])\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program
    }

    fn install(&self, prefix: &Path) -> (Install, PathBuf) {
        let real = prefix.join("lib/node_modules/@manaflow-ai/codex/bin/codex.js");
        std::fs::create_dir_all(real.parent().unwrap()).unwrap();
        let install = detect("codex", Some(&real), &self.0);
        assert_eq!(install.channel, Channel::Npm);
        assert_eq!(install.package.as_deref(), Some("@manaflow-ai/codex"));
        (install, real)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn cmux_next_harness_health_npm_update_targets_the_detected_prefix_and_fork() {
    let root = Scratch::new("selected");
    let default = root.0.join("shell-default");
    std::fs::create_dir_all(&default).unwrap();
    let manager = root.manager(&default);
    for name in ["node-v22", "node prefix with spaces", "node-'quoted-λ"] {
        let prefix = root.0.join(name);
        let (install, real) = root.install(&prefix);
        let plan = update_plan(&install, Some(&real), Some(&real), &root.0).unwrap();
        // Execute the production plan's arguments with a hermetic package
        // manager that records the target. The user's npm never runs.
        assert!(Command::new(&manager).args(&plan.argv[1..]).status().unwrap().success());
        assert_eq!(
            std::fs::read_to_string(prefix.join("updated")).ok().as_deref(),
            Some("@manaflow-ai/codex@latest"),
            "the detected installation must receive its own fork update"
        );
        assert!(!default.join("updated").exists(), "the shell's other npm prefix was updated");
    }
}

#[test]
fn cmux_next_harness_health_npm_update_refuses_an_unknown_or_invalid_target() {
    let root = Scratch::new("unknown");
    for writes in
        [None, Some(PathBuf::from("relative/lib/node_modules")), Some(root.0.join("other"))]
    {
        let install =
            Install { channel: Channel::Npm, package: Some("@manaflow-ai/codex".into()), writes };
        assert!(
            update_plan(&install, None, None, &root.0).is_none(),
            "an unknown target must not fall back to the current npm prefix"
        );
    }
}

#[tokio::test]
async fn cmux_next_harness_health_npm_update_keeps_distinct_installations_in_a_batch() {
    let root = Scratch::new("batch");
    let default = root.0.join("shell-default");
    std::fs::create_dir_all(&default).unwrap();
    let manager = root.manager(&default);
    let mut rows = Vec::new();
    for id in ["node-v20", "node-v22"] {
        let prefix = root.0.join(id);
        let (install, real) = root.install(&prefix);
        let mut plan = update_plan(&install, Some(&real), Some(&real), &root.0).unwrap();
        plan.argv[0] = manager.to_str().unwrap().to_owned();
        rows.push(
            serde_json::from_value::<HarnessHealth>(json!({
                "id":id, "program":"codex", "path":real, "channel":"npm",
                "package":"@manaflow-ai/codex", "version":"1.0.0", "latest":"2.0.0",
                "outdated":true, "auth":"unknown", "checkedAt":1, "update":plan
            }))
            .unwrap(),
        );
    }
    let service = HealthService::new();
    let (_, outcomes) = service.run_updates(async { rows }, None).await;
    assert_eq!(outcomes.len(), 2);
    for id in ["node-v20", "node-v22"] {
        assert!(root.0.join(id).join("updated").exists(), "{id} was incorrectly deduplicated");
    }
    assert!(!default.join("updated").exists());
}

#[test]
fn cmux_next_harness_health_npm_update_leaves_non_npm_plans_unchanged() {
    let home = Path::new("/home/user");
    for (channel, expected) in [
        (Channel::Bun, vec!["bun", "add", "-g", "@manaflow-ai/codex@latest"]),
        (Channel::Brew, vec!["brew", "upgrade", "@manaflow-ai/codex"]),
        (Channel::BrewCask, vec!["brew", "upgrade", "--cask", "@manaflow-ai/codex"]),
    ] {
        let install = Install { channel, package: Some("@manaflow-ai/codex".into()), writes: None };
        assert_eq!(update_plan(&install, None, None, home).unwrap().argv, expected);
    }
}

#[test]
fn cmux_next_harness_health_npm_update_refuses_legacy_or_mismatched_cached_plans() {
    use acpmux::harness_health::auto::updatable;
    let root = Scratch::new("saved");
    let prefix = root.0.join("selected");
    let (install, real) = root.install(&prefix);
    let plan = update_plan(&install, Some(&real), Some(&real), &root.0).unwrap();
    let mut row = serde_json::from_value::<HarnessHealth>(json!({
        "id":"fork", "program":"codex", "path":real, "channel":"npm",
        "package":"@manaflow-ai/codex", "version":"1.0.0", "latest":"2.0.0",
        "outdated":true, "auth":"unknown", "checkedAt":1, "update":plan
    }))
    .unwrap();
    let original = row.update.as_ref().unwrap().argv.clone();
    assert_eq!(updatable(&row), Some(original.clone()));
    for argv in [
        vec!["npm", "install", "-g", "@manaflow-ai/codex@latest"],
        vec!["npm", "install", "-g", "--prefix", "relative", "@manaflow-ai/codex@latest"],
        vec!["npm", "install", "-g", "--prefix", "/tmp/../other", "@manaflow-ai/codex@latest"],
        vec!["npm", "install", "-g", "--prefix", "/tmp/other", "@openai/codex@latest"],
    ] {
        row.update.as_mut().unwrap().argv = argv.into_iter().map(str::to_owned).collect();
        assert!(
            updatable(&row).is_none(),
            "a saved plan cannot use a default target or another fork"
        );
    }
    row.update.as_mut().unwrap().argv = original;
    row.update.as_mut().unwrap().elevated = true;
    assert!(updatable(&row).is_none(), "prefix binding never permits elevation");
}
