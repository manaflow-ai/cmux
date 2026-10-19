//! A cached fixed-plan producer for the owner-job flow. It does not authorize
//! execution or establish that a cached installation still exists.

use super::*;

const PLAN: &str = "_acpmux/harness/update/plan";
const PREPARE: &str = "_acpmux/harness/update/prepare";

#[path = "bun_binding.rs"]
mod bun_binding;

struct Fixture {
    root: PathBuf,
    hub: Arc<Hub>,
    cli: PathBuf,
    asked: Arc<Mutex<Vec<String>>>,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let root = scratch(name);
        let home = root.join("home");
        let user = root.join("profiles");
        let real = home.join(".local/share/claude/versions/current");
        let cli = home.join(".local/bin/claude");
        program(&real, &cli, "9.9.9 (Claude Code)");
        std::fs::write(
            &real,
            format!("#!/bin/sh\necho ran >> '{}'\necho 9.9.9\n", root.join("cli-ran").display()),
        )
        .unwrap();
        profile(
            &user,
            "work-profile",
            &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", cli.display()),
        );
        std::fs::write(root.join("auto.json"), "[\"work-profile\"]").unwrap();
        let (port, asked) = latest_server(vec![(
            "/npm/@anthropic-ai%2Fclaude-code/latest",
            json!({"version":"3.0.0"}),
        )]);
        let hub = hub_for(&root, &user, &home);
        let f = Self { root, hub, cli, asked };
        f.cache(json!([f.native()]), port);
        f
    }

    fn native(&self) -> Value {
        json!({"id":"work-profile", "program":self.cli, "path":self.cli, "channel":"native",
            "package":"@anthropic-ai/claude-code", "version":"2.0.5", "latest":"2.0.9",
            "latestCheckedAt":1, "outdated":true, "auth":"unknown", "checkedAt":1,
            "authDetail":"private@example.test secret-token", "autoUpdate":true,
            "update":{"argv":[self.cli,"update"], "command":"private display command", "elevated":false}})
    }

    fn npm(&self, id: &str, prefix: &Path) -> Value {
        json!({"id":id, "program":"codex", "path":prefix.join("bin/codex"), "channel":"npm",
            "package":"@manaflow-ai/codex", "version":"1.0.0", "latest":"1.1.0",
            "latestCheckedAt":1, "outdated":true, "auth":"unknown", "checkedAt":1,
            "update":{"argv":["npm","install","-g","--prefix",prefix,"@manaflow-ai/codex@latest"],
                "command":"private display command", "elevated":false}})
    }

    fn cache(&self, rows: Value, port: u16) {
        let path = self.root.join("health.json");
        std::fs::write(&path, rows.to_string()).unwrap();
        self.hub.health.attach(Settings {
            cache: Some(path),
            home: self.root.join("home"),
            auto_update: Some(self.root.join("auto.json")),
            sources: Some(Sources {
                npm: format!("http://127.0.0.1:{port}/npm"),
                brew: format!("http://127.0.0.1:{port}/brew"),
            }),
        });
    }

    fn replace(&self, rows: Value) {
        self.cache(rows, 9);
    }

    fn assert_idle(&self) {
        assert!(
            !self.root.join("cli-ran").exists(),
            "planning probed a CLI/auth state or ran an updater"
        );
        assert!(self.asked.lock().unwrap().is_empty(), "planning queried a registry");
        assert_eq!(
            std::fs::read_to_string(self.root.join("auto.json")).unwrap(),
            "[\"work-profile\"]"
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_is_cached_fixed_argv_without_side_effects() {
    let f = Fixture::new("update-plan-native");
    let before = std::fs::read(f.root.join("health.json")).unwrap();
    let mut client = Client::open(&f.hub, Origin::Local);
    let result = client.call(PLAN, json!({"cli":"claude"})).await.expect("cached native plan");
    assert_eq!(result, json!({"cached":true,"cli":"claude","argv":[f.cli,"update"]}));
    let cached =
        client.call(method::MUX_HARNESS_HEALTH, json!({"view":"inventory"})).await.unwrap();
    assert_eq!(
        row(&cached, "work-profile")["version"],
        "2.0.5",
        "the stand-in reports9.9.9 if probed"
    );
    assert_eq!(std::fs::read(f.root.join("health.json")).unwrap(), before);
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_preserves_the_bound_npm_fork_and_argument_bytes() {
    let f = Fixture::new("update-plan-npm");
    let prefix = f.root.join("prefix with 'quotes' and \u{03c0}");
    let cached = f.npm("custom-profile", &prefix);
    let argv = cached["update"]["argv"].clone();
    f.replace(json!([cached]));
    let mut client = Client::open(&f.hub, Origin::Local);
    assert_eq!(
        client.call(PLAN, json!({"cli":"codex"})).await.unwrap(),
        json!({"cached":true,"cli":"codex","argv":argv})
    );
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_deduplicates_aliases_of_one_target() {
    let f = Fixture::new("update-plan-aliases");
    let a = f.npm("work", &f.root.join("prefix"));
    let mut b = a.clone();
    b["id"] = json!("personal");
    f.replace(json!([a, b]));
    let mut client = Client::open(&f.hub, Origin::Local);
    let plan = client.call(PLAN, json!({"cli":"codex"})).await.unwrap();
    assert_eq!(plan["argv"][4], json!(f.root.join("prefix")));
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_refuses_distinct_targets_instead_of_choosing_one() {
    let f = Fixture::new("update-plan-ambiguous");
    f.replace(json!([f.npm("work", &f.root.join("a")), f.npm("personal", &f.root.join("b"))]));
    let mut client = Client::open(&f.hub, Origin::Local);
    let error = client.call(PLAN, json!({"cli":"codex"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.ambiguous");
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_never_selects_by_profile_name() {
    let f = Fixture::new("update-plan-profile-name");
    let mut client = Client::open(&f.hub, Origin::Local);
    let error = client.call(PLAN, json!({"cli":"work-profile"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.unavailable");
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_refuses_a_cache_that_would_hide_other_targets() {
    let f = Fixture::new("update-plan-bound");
    let mut rows: Vec<Value> =
        (0..256).map(|i| f.npm(&format!("alias-{i}"), &f.root.join("a"))).collect();
    rows.push(f.npm("other-target", &f.root.join("b")));
    f.replace(json!(rows));
    let mut client = Client::open(&f.hub, Origin::Local);
    let error = client.call(PLAN, json!({"cli":"codex"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_refuses_elevation_and_unbound_or_foreign_commands() {
    let f = Fixture::new("update-plan-unsafe");
    let mut elevated = f.native();
    elevated["update"]["elevated"] = json!(true);
    let mut shell = f.native();
    shell["update"]["argv"] = json!(["/bin/sh", "-c", "private command"]);
    let mut other = f.native();
    other["update"]["argv"] = json!([f.root.join("other/claude"), "update"]);
    let mut unbound = f.npm("work", &f.root.join("prefix"));
    unbound["update"]["argv"] = json!(["npm", "install", "-g", "@manaflow-ai/codex@latest"]);
    for (cli, row) in
        [("claude", elevated), ("claude", shell), ("claude", other), ("codex", unbound)]
    {
        f.replace(json!([row]));
        let mut client = Client::open(&f.hub, Origin::Local);
        let error = client.call(PLAN, json!({"cli":cli})).await.unwrap_err();
        assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    }
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_does_not_treat_unknown_versions_as_current_or_updateable() {
    let f = Fixture::new("update-plan-unknown");
    for (installed, latest, outdated) in [
        (Value::Null, json!("2.0.9"), true),
        (json!("2.0.5"), Value::Null, true),
        (json!("2.0.5"), json!("not-a-version"), true),
        (json!("2.0.9"), json!("2.0.9"), false),
    ] {
        let mut row = f.native();
        row["version"] = installed;
        row["latest"] = latest;
        row["outdated"] = json!(outdated);
        f.replace(json!([row]));
        let mut client = Client::open(&f.hub, Origin::Local);
        let error = client.call(PLAN, json!({"cli":"claude"})).await.unwrap_err();
        assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    }
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_refuses_manager_targets_that_are_not_bound_yet() {
    let f = Fixture::new("update-plan-manager-targets");
    for (channel, argv) in [
        ("bun", json!(["bun", "add", "-g", "@manaflow-ai/codex@latest"])),
        ("brew", json!(["brew", "upgrade", "codex"])),
        ("brewCask", json!(["brew", "upgrade", "--cask", "codex"])),
    ] {
        let mut row = f.npm("work", &f.root.join("prefix"));
        row["channel"] = json!(channel);
        row["update"]["argv"] = argv;
        f.replace(json!([row]));
        let mut client = Client::open(&f.hub, Origin::Local);
        let error = client.call(PLAN, json!({"cli":"codex"})).await.unwrap_err();
        assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    }
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_empty_cache_never_enters_first_check() {
    let f = Fixture::new("update-plan-empty");
    f.replace(json!([]));
    let before = std::fs::read(f.root.join("health.json")).unwrap();
    let mut client = Client::open(&f.hub, Origin::Local);
    let error = client.call(PLAN, json!({"cli":"claude"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.unavailable");
    assert_eq!(std::fs::read(f.root.join("health.json")).unwrap(), before);
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_accepts_only_one_cli_condition() {
    let f = Fixture::new("update-plan-params");
    let mut client = Client::open(&f.hub, Origin::Local);
    for params in [
        Value::Null,
        json!([]),
        json!({}),
        json!({"cli":true}),
        json!({"cli":""}),
        json!({"cli":"../claude"}),
        json!({"cli":"claude","argv":["sh"]}),
        json!({"cli":"claude","machine":"foreign"}),
        json!({"cli":"claude","sessionId":"foreign"}),
    ] {
        let error = client.call(PLAN, params).await.unwrap_err();
        assert_eq!(error["code"], -32602, "{error}");
    }
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_is_local_only_and_negotiated() {
    let f = Fixture::new("update-plan-origin");
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut client = Client::open(&f.hub, origin);
        let error = client.call(PLAN, json!({"cli":"claude"})).await.unwrap_err();
        assert_eq!(error["message"], "harness_update_plan.not_trusted");
    }
    let mut local = Client::open(&f.hub, Origin::Local);
    let hello = local.call(method::INITIALIZE, json!({"protocolVersion":1})).await.unwrap();
    assert!(
        hello
            .pointer("/_meta/acpmux/features")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!("harnessUpdatePlan"))
    );
    assert!(
        hello
            .pointer("/_meta/acpmux/extensions")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!(PLAN))
    );
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_plan_legacy_inventory_stays_cached_without_commands() {
    let f = Fixture::new("update-plan-cache-control");
    let mut client = Client::open(&f.hub, Origin::Local);
    let result =
        client.call(method::MUX_HARNESS_HEALTH, json!({"view":"inventory"})).await.unwrap();
    assert_eq!(row(&result, "work-profile")["version"], "2.0.5");
    assert!(row(&result, "work-profile").get("update").is_none());
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_prepare_revalidates_native_without_running_it() {
    let f = Fixture::new("update-prepare-native");
    let before = std::fs::read(f.root.join("health.json")).unwrap();
    let mut client = Client::open(&f.hub, Origin::Local);
    let result = client.call(PREPARE, json!({"cli":"claude"})).await.unwrap();
    assert_eq!(result, json!({"cli":"claude","argv":[f.cli,"update"]}));
    assert_eq!(std::fs::read(f.root.join("health.json")).unwrap(), before);
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_prepare_refuses_a_missing_or_retargeted_installation() {
    let f = Fixture::new("update-prepare-retargeted");
    let mut client = Client::open(&f.hub, Origin::Local);
    std::fs::remove_file(&f.cli).unwrap();
    assert!(client.call(PLAN, json!({"cli":"claude"})).await.is_ok(), "cached advisory");
    let error = client.call(PREPARE, json!({"cli":"claude"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    let foreign = f.root.join("foreign/claude");
    program(&foreign, &f.cli, "9.9.9");
    let error = client.call(PREPARE, json!({"cli":"claude"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_prepare_binds_the_actual_npm_fork_prefix_and_manager() {
    let f = Fixture::new("update-prepare-npm");
    let prefix = f.root.join("prefix with 'quotes' and \u{03c0}");
    let cli = prefix.join("bin/codex");
    let real = prefix.join("lib/node_modules/@manaflow-ai/codex/bin/codex.js");
    program(&real, &cli, "1.0.0");
    let manager = f.root.join("manager with spaces/npm");
    std::fs::create_dir_all(manager.parent().unwrap()).unwrap();
    std::fs::copy(&real, &manager).unwrap();
    let mut row = f.npm("work", &prefix);
    row["update"]["argv"][0] = json!(manager);
    let argv = row["update"]["argv"].clone();
    f.replace(json!([row]));
    let mut client = Client::open(&f.hub, Origin::Local);
    assert_eq!(
        client.call(PREPARE, json!({"cli":"codex"})).await.unwrap(),
        json!({"cli":"codex","argv":argv})
    );
    // The cached argv still names the old prefix, but the executable now
    // belongs to a different installation. Never update the old target.
    std::fs::remove_file(&cli).unwrap();
    let other = f.root.join("other/lib/node_modules/@manaflow-ai/codex/bin/codex.js");
    program(&other, &cli, "1.0.0");
    let error = client.call(PREPARE, json!({"cli":"codex"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_prepare_refuses_nonlocal_origins_and_controls() {
    let f = Fixture::new("update-prepare-origin");
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut client = Client::open(&f.hub, origin);
        let error = client.call(PREPARE, json!({"cli":"claude","argv":["sh"]})).await.unwrap_err();
        assert_eq!(error["message"], "harness_update_plan.not_trusted");
    }
    let mut client = Client::open(&f.hub, Origin::Local);
    let error = client.call(PREPARE, json!({"cli":"claude","argv":["sh"]})).await.unwrap_err();
    assert_eq!(error["code"], -32602);
    let hello = client.call(method::INITIALIZE, json!({"protocolVersion":1})).await.unwrap();
    assert!(
        hello
            .pointer("/_meta/acpmux/features")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!("harnessUpdatePrepare"))
    );
    assert!(
        hello
            .pointer("/_meta/acpmux/extensions")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!(PREPARE))
    );
    f.assert_idle();
}
