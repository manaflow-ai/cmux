//! A successful no-op update needs evidence of the newest known version.
//! These requests use the real hub and only a stand-in CLI/loopback registry.

use super::*;

enum Registry {
    Disabled,
    Missing,
    Version(&'static str),
}

async fn check(name: &str, registry: Registry, expected_ok: bool) {
    let root = scratch(name);
    let home = root.join("home");
    let user = root.join("profiles");
    let real = home.join(".local/share/claude/versions/current");
    let cli = home.join(".local/bin/claude");
    let runs = root.join("updates");
    program(&real, &cli, "2.0.5 (Claude Code)");
    std::fs::write(
        &real,
        format!(
            "#!/bin/sh\nif [ \"$1\" = update ]; then echo run >> '{}'; exit 0; fi\necho '2.0.5 (Claude Code)'\n",
            runs.display()
        ),
    )
    .unwrap();
    profile(
        &user,
        "claude",
        &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", cli.display()),
    );
    let sources = match registry {
        Registry::Disabled => None,
        Registry::Missing | Registry::Version(_) => {
            let answers = match registry {
                Registry::Version(v) => {
                    vec![("/npm/@anthropic-ai%2Fclaude-code/latest", json!({"version":v}))]
                }
                _ => vec![],
            };
            let (port, _) = latest_server(answers);
            Some(Sources {
                npm: format!("http://127.0.0.1:{port}/npm"),
                brew: format!("http://127.0.0.1:{port}/brew"),
            })
        }
    };
    let hub = hub_for(&root, &user, &home);
    hub.health.attach(Settings { sources, home, ..Settings::default() });
    let mut client = Client::open(&hub, Origin::Local);
    let health = client.call(method::MUX_HARNESS_HEALTH, json!({})).await.unwrap();
    assert_eq!(row(&health, "claude")["version"], "2.0.5");
    assert_eq!(row(&health, "claude")["outdated"], false);
    let reply = client.call(method::MUX_HARNESS_UPDATE, json!({"ids":["claude"]})).await.unwrap();
    let result = &reply["results"][0];
    assert_eq!(result["id"], "claude", "{reply}");
    assert_eq!(result["version"], "2.0.5", "observations remain available: {reply}");
    assert_eq!(result["ok"], expected_ok, "a false outdated flag alone is not current: {reply}");
    if !expected_ok {
        assert!(result["error"].as_str().is_some_and(|s| !s.is_empty()), "{reply}");
    }
    assert!(!runs.exists(), "unknown or current must not run an updater");
    drop(client);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_current_proof_requires_a_latest_source() {
    check("current-no-source", Registry::Disabled, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_current_proof_rejects_an_unavailable_registry() {
    check("current-registry-unavailable", Registry::Missing, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_current_proof_rejects_an_uncomparable_latest() {
    check("current-registry-invalid", Registry::Version("not-a-version"), false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_current_proof_accepts_a_known_equal_version() {
    check("current-known-equal", Registry::Version("2.0.5"), true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_update_current_proof_accepts_an_installed_newer_version() {
    check("current-known-newer", Registry::Version("2.0.4"), true).await;
}
