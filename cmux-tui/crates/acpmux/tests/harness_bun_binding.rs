//! Execute the updater's production arguments with an owned stand-in manager.
//! No installed agent, registry, user configuration or real package manager runs.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::harness_health::channel::{Channel, Install, UpdatePlan, detect, update_plan};
use acpmux::harness_health::{HarnessHealth, HealthService, Settings};
use serde_json::json;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

struct Fixture {
    root: PathBuf,
    default: PathBuf,
    manager: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "acpmux-bun-binding-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let default = root.join("other-default");
        std::fs::create_dir(&default).unwrap();
        let manager = root.join("bun");
        let literal = acpmux::harness_health::channel::quote(default.to_str().unwrap());
        std::fs::write(&manager, format!(
            "#!/bin/sh\nset -eu\npackages=\"\u{24}{{BUN_INSTALL_GLOBAL_DIR:-{literal}}}\"\nbins=\"\u{24}{{BUN_INSTALL_BIN:-{literal}}}\"\nprintf '%s' \"\u{24}3\" > \"\u{24}packages/updated\"\nprintf '%s' \"\u{24}3\" > \"\u{24}bins/bin-updated\"\n"
        )).unwrap();
        std::fs::set_permissions(&manager, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { root, default, manager }
    }

    fn installation(&self, label: &str, configured: bool) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        let home = self.root.join(label);
        let global = if configured {
            home.join("custom packages")
        } else {
            home.join(".bun/install/global")
        };
        let bin = if configured { home.join("custom commands") } else { home.join(".bun/bin") };
        let real = global.join("node_modules/@manaflow-ai/codex/bin/codex.js");
        let path = bin.join("codex");
        std::fs::create_dir_all(real.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(&real, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
        symlink(&real, &path).unwrap();
        if configured {
            std::fs::write(
                home.join(".bunfig.toml"),
                format!(
                    "[install]\nglobalDir = {}\nglobalBinDir = {}\n",
                    serde_json::to_string(&global).unwrap(),
                    serde_json::to_string(&bin).unwrap()
                ),
            )
            .unwrap();
        }
        (home, global, bin, path)
    }

    fn plan(&self, home: &Path, path: &Path) -> UpdatePlan {
        let real = path.canonicalize().unwrap();
        let install = detect("codex", Some(&real), home);
        let mut plan = update_plan(&install, Some(path), Some(&real), home)
            .expect("the detected Bun installation has no bound update plan");
        // Replace only the manager, as the npm prefix tests do. All target,
        // package and quoting bytes still come from the production planner.
        let manager = plan.argv.len() - 4;
        plan.argv[manager] = self.manager.to_str().unwrap().into();
        plan
    }

    fn row(&self, id: &str, path: &Path, plan: UpdatePlan) -> HarnessHealth {
        serde_json::from_value(json!({
            "id":id,"program":"codex","path":path,"channel":"bun",
            "package":"@manaflow-ai/codex","version":"1.0.0","latest":"2.0.0",
            "outdated":true,"auth":"unknown","checkedAt":1,"update":plan
        }))
        .unwrap()
    }

    fn assert_target(&self, global: &Path, bin: &Path) {
        assert_eq!(
            std::fs::read_to_string(global.join("updated")).unwrap(),
            "@manaflow-ai/codex@latest"
        );
        assert_eq!(
            std::fs::read_to_string(bin.join("bin-updated")).unwrap(),
            "@manaflow-ai/codex@latest"
        );
        assert!(
            !self.default.join("updated").exists(),
            "the manager's ambient installation changed"
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn bun_installation_binding_targets_the_detected_package_and_bin_directories() {
    let f = Fixture::new();
    let (home, global, bin, path) = f.installation("home with 'quotes' and λ", false);
    let plan = f.plan(&home, &path);
    let status = Command::new(&plan.argv[0]).args(&plan.argv[1..]).status().unwrap();
    assert!(status.success());
    f.assert_target(&global, &bin);
}

#[test]
fn bun_installation_binding_honors_configured_custom_locations() {
    let f = Fixture::new();
    let (home, global, bin, path) = f.installation("configured home", true);
    let plan = f.plan(&home, &path);
    assert!(Command::new(&plan.argv[0]).args(&plan.argv[1..]).status().unwrap().success());
    f.assert_target(&global, &bin);
}

#[tokio::test]
async fn bun_installation_binding_keeps_distinct_installations_in_one_update_batch() {
    let f = Fixture::new();
    let mut rows = Vec::new();
    let mut targets = Vec::new();
    for name in ["first", "second"] {
        let (home, global, bin, path) = f.installation(name, false);
        rows.push(f.row(name, &path, f.plan(&home, &path)));
        targets.push((global, bin));
    }
    let (_, outcomes) = HealthService::new().run_updates(async { rows }, None).await;
    assert_eq!(outcomes.len(), 2);
    for (global, bin) in targets {
        f.assert_target(&global, &bin);
    }
}

#[tokio::test]
async fn bun_installation_binding_refuses_legacy_cached_execution() {
    let f = Fixture::new();
    let (_, _, _, path) = f.installation("legacy", false);
    let plan = UpdatePlan {
        argv: vec![
            f.manager.to_str().unwrap().into(),
            "add".into(),
            "-g".into(),
            "@manaflow-ai/codex@latest".into(),
        ],
        command: "old unbound command".into(),
        elevated: false,
    };
    let row = f.row("legacy", &path, plan);
    HealthService::new().run_updates(async { vec![row] }, None).await;
    assert!(!f.default.join("updated").exists(), "a saved unbound Bun command executed");
}

#[test]
fn bun_installation_binding_hides_unbound_cached_commands_from_visible_consumers() {
    let f = Fixture::new();
    let (home, _, _, path) = f.installation("cached", false);
    let plan = UpdatePlan {
        argv: vec!["bun".into(), "add".into(), "-g".into(), "@manaflow-ai/codex@latest".into()],
        command: "bun add -g @manaflow-ai/codex@latest".into(),
        elevated: false,
    };
    let cache = f.root.join("health.json");
    std::fs::write(&cache, serde_json::to_vec(&vec![f.row("cached", &path, plan)]).unwrap())
        .unwrap();
    let service = HealthService::new();
    service.attach(Settings { cache: Some(cache), home, ..Settings::default() });
    assert!(service.rows()[0].update.is_none(), "Settings received an unbound saved command");
}

#[test]
fn bun_installation_binding_refuses_an_unknown_target() {
    let f = Fixture::new();
    let install =
        Install { channel: Channel::Bun, package: Some("@manaflow-ai/codex".into()), writes: None };
    assert!(update_plan(&install, None, None, &f.root).is_none());
}

#[test]
fn bun_installation_binding_preserves_existing_npm_prefix_plans() {
    let f = Fixture::new();
    let prefix = f.root.join("npm-prefix");
    let install = Install {
        channel: Channel::Npm,
        package: Some("@manaflow-ai/codex".into()),
        writes: Some(prefix.join("lib/node_modules")),
    };
    let plan = update_plan(&install, None, None, &f.root).unwrap();
    let expected: Vec<String> = vec![
        "npm".into(),
        "install".into(),
        "-g".into(),
        "--prefix".into(),
        prefix.to_str().unwrap().into(),
        "@manaflow-ai/codex@latest".into(),
    ];
    assert_eq!(plan.argv, expected);
}

#[test]
fn bun_installation_binding_discovery_does_not_expand_the_default_child_environment() {
    for key in ["BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN", "XDG_CONFIG_HOME"] {
        for family in [None, Some("codex"), Some("claude")] {
            assert!(!acpmux::login_env::allowed(key, "/fixture/path", family));
        }
    }
}

#[tokio::test]
async fn bun_installation_binding_auto_update_uses_the_same_bound_plan_once() {
    let f = Fixture::new();
    let (home, global, bin, path) = f.installation("auto", false);
    let mut row = f.row("auto", &path, f.plan(&home, &path));
    row.auto_update = true;
    let cache = f.root.join("health-auto.json");
    let choice = f.root.join("auto.json");
    std::fs::write(&cache, serde_json::to_vec(&vec![row]).unwrap()).unwrap();
    std::fs::write(&choice, "[\"auto\"]").unwrap();
    let service = HealthService::new();
    service.attach(Settings {
        cache: Some(cache),
        home,
        auto_update: Some(choice),
        ..Settings::default()
    });
    assert_eq!(service.run_auto_updates().await, vec!["auto"]);
    assert!(service.run_auto_updates().await.is_empty(), "same-version auto update repeated");
    f.assert_target(&global, &bin);
}
