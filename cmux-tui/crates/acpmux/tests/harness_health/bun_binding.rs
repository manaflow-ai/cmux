//! The private fixed-plan RPC keeps the Bun binding and performs no probes.

use super::*;

fn row_and_marker(f: &Fixture) -> (Value, PathBuf, PathBuf) {
    let home = f.root.join("home");
    let cli = home.join(".bun/bin/codex");
    let real = home.join(".bun/install/global/node_modules/@manaflow-ai/codex/bin/codex.js");
    program(&real, &cli, "1.0.0");
    let marker = f.root.join("bun-ran");
    std::fs::write(&real, format!("#!/bin/sh\necho ran >> '{}'\n", marker.display())).unwrap();
    let manager = f.root.join("manager with spaces/bun");
    std::fs::create_dir_all(manager.parent().unwrap()).unwrap();
    std::fs::copy(&real, &manager).unwrap();
    let install = acpmux::harness_health::channel::detect("codex", Some(&real), &home);
    let mut plan =
        acpmux::harness_health::channel::update_plan(&install, Some(&cli), Some(&real), &home)
            .unwrap();
    let index = plan.argv.len() - 4;
    plan.argv[index] = manager.to_str().unwrap().into();
    (
        json!({"id":"bound-fork","program":"codex","path":cli,"channel":"bun",
        "package":"@manaflow-ai/codex","version":"1.0.0","latest":"1.1.0",
        "outdated":true,"auth":"unknown","checkedAt":1,"update":plan}),
        marker,
        cli,
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bun_installation_binding_prepare_revalidates_the_fork_without_execution() {
    let f = Fixture::new("bun-prepare-bound");
    let (row, marker, cli) = row_and_marker(&f);
    let argv = row["update"]["argv"].clone();
    f.replace(json!([row]));
    let mut client = Client::open(&f.hub, Origin::Local);
    assert_eq!(
        client.call(PREPARE, json!({"cli":"codex"})).await.unwrap(),
        json!({"cli":"codex","argv":argv})
    );
    assert!(!marker.exists(), "preparation ran a manager or CLI");
    std::fs::remove_file(&cli).unwrap();
    let other = f.root.join("home/.bun/install/global/node_modules/@openai/codex/bin/codex.js");
    program(&other, &cli, "1.0.0");
    assert!(client.call(PLAN, json!({"cli":"codex"})).await.is_ok(), "cached advisory");
    let error = client.call(PREPARE, json!({"cli":"codex"})).await.unwrap_err();
    assert_eq!(error["data"]["reason"], "harness_update_plan.not_updatable");
    assert!(!marker.exists());
    f.assert_idle();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bun_installation_binding_prepare_refuses_cached_redirection_and_extra_environment() {
    let f = Fixture::new("bun-prepare-tampered");
    let (row, marker, _) = row_and_marker(&f);
    let mut redirected = row.clone();
    redirected["update"]["argv"][3] =
        json!(format!("BUN_INSTALL_GLOBAL_DIR={}", f.root.join("other").display()));
    let mut extra = row.clone();
    extra["update"]["argv"].as_array_mut().unwrap().insert(5, json!("NPM_TOKEN=fixture-value"));
    let mut wrong_bin = row.clone();
    wrong_bin["update"]["argv"][4] =
        json!(format!("BUN_INSTALL_BIN={}", f.root.join("elsewhere").display()));
    for changed in [redirected, extra, wrong_bin] {
        f.replace(json!([changed]));
        let mut client = Client::open(&f.hub, Origin::Local);
        assert!(client.call(PREPARE, json!({"cli":"codex"})).await.is_err());
    }
    assert!(!marker.exists());
    f.assert_idle();
}
