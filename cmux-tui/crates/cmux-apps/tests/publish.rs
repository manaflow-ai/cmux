//! Publish and rollback end to end over fakes.
mod common;

use std::path::PathBuf;
use std::time::Duration;

use cmux_apps::io::Unanswered;
use cmux_apps::publish::{PublishRequest, publish, rollback, settle};
use cmux_apps::state::{self, VersionState};
use common::{HEAD, SNAPSHOT, World, proc_entry, tcp_table};
use serde_json::json;

fn request() -> PublishRequest {
    let mut req = PublishRequest::new(PathBuf::from("/work/web"));
    req.name = Some("web".into());
    req.cmd = Some("npm start".into());
    req
}

/// The preview on port 3000 is `node server.js` in /work/web/site.
fn preview(world: &World) {
    world.fs.file("/proc/net/tcp", tcp_table(3000, 4242).as_bytes());
    proc_entry(&world.fs, 77, 1, 4242, "/work/web/site", &["node", "server.js"]);
}

#[test]
fn a_dirty_tree_is_refused_without_include_dirty() {
    let world = World::new();
    world.git.dirty.set(true);
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.dirty");
    assert!(failure.message.contains("--include-dirty"), "{}", failure.message);
    assert!(world.git.archives.borrow().is_empty());
    assert!(world.procs.spawned.borrow().is_empty());
    assert!(world.changes().is_empty());
}

#[test]
fn include_dirty_commits_the_tree_to_the_version_ref() {
    let world = World::new();
    world.git.dirty.set(true);
    let mut req = request();
    req.include_dirty = true;
    let done = world.with(|host| publish(host, &req)).unwrap();
    assert_eq!(*world.git.snapshots.borrow(), ["refs/cmux/apps/web/v1"]);
    assert_eq!(done.version.commit, SNAPSHOT);
    assert_eq!(world.git.archives.borrow()[0].0, SNAPSHOT);
}

#[test]
fn a_failed_probe_leaves_live_unchanged_and_never_promotes() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    let before = world.changes().len();

    world.probe.status.set(502);
    world.fs.file("/var/lib/cmux-apps/1000/web/v2/app.log", b"listening...\nError: boom\n");
    let failure = world.with(|host| publish(host, &request())).unwrap_err();

    assert_eq!(failure.code, "app.probe_failed");
    let version = failure.version.unwrap();
    assert_eq!((version.n, version.state), (2, VersionState::Failed));
    assert!(version.log_tail.unwrap().contains("Error: boom"));
    assert_eq!(*world.procs.stopped.borrow(), [version.pid.unwrap()]);
    assert_eq!(world.changes().len(), before, "a failed probe reached the platform");
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.live, Some(1));
    assert_eq!(app.version(1).unwrap().state, VersionState::Live);
    assert_eq!(app.version(2).unwrap().state, VersionState::Failed);
}

#[test]
fn a_probe_that_never_answers_times_out_within_its_bound() {
    let world = World::new();
    world.probe.refusals.set(u32::MAX);
    let mut req = request();
    req.probe_timeout = Duration::from_secs(60);
    let failure = world.with(|host| publish(host, &req)).unwrap_err();
    assert_eq!(failure.code, "app.probe_failed");
    assert!(failure.message.contains("within 60 s"), "{}", failure.message);
    assert!(world.clock.now.get() <= 61_000);
    assert!(world.promotes().is_empty());
}

#[test]
fn a_successful_publish_promotes_commit_command_machine_and_port() {
    let world = World::new();
    preview(&world);
    let mut req = PublishRequest::new(PathBuf::from("/somewhere"));
    req.port = Some(3000);
    let done = world.with(|host| publish(host, &req)).unwrap();

    let inferred = done.inferred.as_ref().unwrap();
    assert_eq!((inferred.pid, inferred.command.as_str()), (77, "node server.js"));
    let spawned = world.procs.spawned.borrow();
    assert_eq!(spawned[0].command, "node server.js");
    assert_eq!(spawned[0].version_dir, PathBuf::from("/state/apps/site/v1"));
    assert_eq!((spawned[0].subdir.as_str(), spawned[0].port), ("site", 41000));
    // The agent started it as the app user, and the record keeps the pid's start time.
    assert_eq!(done.version.run_as.as_deref(), Some("cmux-app"));
    assert_eq!(done.version.start_time, Some(5000));
    assert_eq!(done.version.run_dir, Some(PathBuf::from("/var/lib/cmux-apps/1000/site/v1")));

    let sent = world.changes();
    assert_eq!(sent[0].method, "POST");
    assert_eq!(sent[0].path, "/v1/cloud/apps");
    assert_eq!(sent[0].body, Some(json!({"name": "site", "slug": "site"})));
    let promotes = world.promotes();
    assert_eq!(promotes.len(), 1);
    assert_eq!(promotes[0].path, "/v1/cloud/apps/site/versions");
    assert_eq!(
        promotes[0].body,
        Some(
            json!({"commit": HEAD, "command": "node server.js", "machine": "vm_self", "port": 41000})
        )
    );
    assert_eq!(done.url, "https://a-web--team_abc.preview.example");
    assert_eq!(done.version.state, VersionState::Live);
    assert_eq!(done.version.platform_n, Some(1));
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "site")).unwrap().unwrap();
    assert_eq!(app.live, Some(1));
}

#[test]
fn a_promote_carries_an_idempotency_key_and_a_lost_answer_retries_with_the_same_key() {
    let world = World::new();
    world.agent.lose_answers.set(1);
    let done = world.with(|host| publish(host, &request())).unwrap();
    let promotes = world.promotes();
    assert_eq!(promotes.len(), 2);
    let key = promotes[0].key.clone().unwrap();
    assert!(key.starts_with(&format!("web:{HEAD}:")), "{key}");
    assert!(key.len() > format!("web:{HEAD}:").len(), "no attempt id in {key}");
    assert_eq!(promotes[1].key.as_deref(), Some(key.as_str()));
    assert_eq!(done.version.state, VersionState::Live);

    // Another attempt is another key.
    world.with(|host| publish(host, &request())).unwrap();
    let third = world.promotes()[2].key.clone().unwrap();
    assert_ne!(third, key);
}

#[test]
fn a_refused_promote_records_the_version_failed_and_keeps_live() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    *world.agent.versions_answer.borrow_mut() = Some((
        502,
        json!({"error": {"code": "cloud.app.promote_failed", "message": "the edge did not answer"}}),
    ));
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.promote_failed");
    assert!(failure.message.contains("cloud.app.promote_failed"));
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.live, Some(1));
    assert_eq!(app.version(2).unwrap().state, VersionState::Failed);
}

#[test]
fn an_unbound_machine_refuses_before_staging() {
    let world = World::new();
    *world.agent.refusal.borrow_mut() = Some(Unanswered {
        code: "vm.unbound".into(),
        message: "this machine is not bound to a cmux Cloud account".into(),
    });
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.platform");
    assert!(failure.message.contains("vm.unbound"), "{}", failure.message);
    assert!(world.git.archives.borrow().is_empty());
    assert!(world.procs.spawned.borrow().is_empty());
}

#[test]
fn every_platform_call_is_an_apps_route_through_the_agent() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    world.with(|host| publish(host, &request())).unwrap();
    world.with(|host| rollback(host, "web", None, Duration::from_secs(60))).unwrap();
    let sent = world.agent.sent.borrow();
    assert!(!sent.is_empty());
    for call in sent.iter() {
        assert!(call.path.starts_with("/v1/cloud/apps"), "{call:?}");
    }
}

#[test]
fn the_app_process_gets_only_the_allowlisted_environment() {
    let mut world = World::new();
    world.parent_env = vec![
        ("PATH".into(), "/usr/bin:/bin".into()),
        ("LANG".into(), "C.UTF-8".into()),
        ("TZ".into(), "UTC".into()),
        ("HOME".into(), "/root".into()),
        ("GITHUB_TOKEN".into(), "ghp_secret".into()),
        ("CMUX_PLATFORM_ORIGIN".into(), "https://platform.example".into()),
        ("ANTHROPIC_API_KEY".into(), "sk-secret".into()),
    ];
    world.with(|host| publish(host, &request())).unwrap();
    // What the agent is asked for; it adds HOME (the run directory) and PORT only.
    let env = world.procs.spawned.borrow()[0].env.clone();
    assert_eq!(
        env,
        [
            ("LANG".to_owned(), "C.UTF-8".to_owned()),
            ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ("TZ".to_owned(), "UTC".to_owned()),
        ]
    );
}

#[test]
fn service_env_literals_and_setup_come_from_app_json() {
    let mut world = World::new();
    world.parent_env.push(("GITHUB_TOKEN".into(), "ghp_secret".into()));
    world.fs.file(
        "/state/apps/web/v1/src/.cmux/apps/web/app.json",
        br#"{"service": {"setup": "npm ci", "env": {"NODE_ENV": "production", "PORT": "1", "SECRET": {"ref": "x"}}}}"#,
    );
    world.with(|host| publish(host, &request())).unwrap();
    let spawned = world.procs.spawned.borrow();
    // The setup runs in the agent's start, as the app user, never here.
    assert_eq!(spawned[0].setup.as_deref(), Some("npm ci"));
    let env = &spawned[0].env;
    assert!(env.contains(&("NODE_ENV".to_owned(), "production".to_owned())));
    assert!(env.iter().all(|(k, _)| k != "PORT"), "app.json may not move PORT");
    assert!(env.iter().all(|(k, _)| k != "SECRET" && k != "GITHUB_TOKEN"));
}

#[test]
fn rollback_restarts_the_retired_version_on_its_port_and_moves_live() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    world.with(|host| publish(host, &request())).unwrap();
    // v1's process ended since it was retired.
    world.procs.dead.borrow_mut().insert(500);

    let done = world.with(|host| rollback(host, "web", None, Duration::from_secs(60))).unwrap();
    assert_eq!(done.version.n, 1);
    let spawned = world.procs.spawned.borrow();
    assert_eq!(spawned.len(), 3);
    assert_eq!((spawned[2].version, spawned[2].port), (1, 41000));
    assert_eq!(spawned[2].setup, None);
    // Only the rollback's start asks to keep the unpacked tree; the publishes replace it.
    assert_eq!(spawned.iter().map(|s| s.restart).collect::<Vec<_>>(), [false, false, true]);
    let sent = world.agent.sent.borrow();
    let last = sent.last().unwrap();
    assert_eq!(last.path, "/v1/cloud/apps/web/rollback");
    assert_eq!(last.body, Some(json!({"to": 1})));
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.live, Some(1));
    assert_eq!(app.version(1).unwrap().state, VersionState::Live);
    assert_eq!(app.version(2).unwrap().state, VersionState::Retired);
}

#[test]
fn rollback_to_a_failed_version_is_refused() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    world.probe.status.set(500);
    world.with(|host| publish(host, &request())).unwrap_err();
    world.probe.status.set(200);
    world.with(|host| publish(host, &request())).unwrap();
    let failure =
        world.with(|host| rollback(host, "web", Some(2), Duration::from_secs(60))).unwrap_err();
    assert_eq!(failure.code, "app.no_version");
    // v1 is the platform's version 1, v3 its version 2: a rollback names the platform's number.
    world.with(|host| rollback(host, "web", Some(1), Duration::from_secs(60))).unwrap();
    assert_eq!(world.agent.sent.borrow().last().unwrap().body, Some(json!({"to": 1})));
}

#[test]
fn no_app_user_refuses_the_publish_with_no_fallback() {
    let world = World::new();
    *world.procs.refusal.borrow_mut() = Some("useradd made no cmux-app account".to_owned());
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.start");
    assert!(failure.message.contains("cmux-app"), "{}", failure.message);
    assert!(world.promotes().is_empty(), "a version that never started was promoted");
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.version(1).unwrap().state, VersionState::Failed);
}

#[test]
fn a_promote_whose_answers_are_all_lost_stays_pending_and_running() {
    let world = World::new();
    world.agent.lose_answers.set(3);
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.promote_pending");
    assert_eq!(world.promotes().len(), 3);
    assert!(world.procs.stopped.borrow().is_empty(), "a pending version was stopped");
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.version(1).unwrap().state, VersionState::Pending);
    assert_eq!(app.live, None);
}

#[test]
fn versions_settles_a_pending_version_from_the_platforms_record() {
    let world = World::new();
    world.agent.lose_answers.set(3);
    world.with(|host| publish(host, &request())).unwrap_err();
    // The platform took it after all.
    *world.agent.app_versions.borrow_mut() = vec![json!({
        "n": 4, "commit": HEAD, "command": "npm start", "machine": "vm_self", "port": 41000,
        "state": "live", "createdAt": "2026-11-17T00:00:00Z"
    })];
    let mut app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert!(world.with(|host| settle(host, &mut app)));
    assert_eq!(app.live, Some(1));
    let v1 = app.version(1).unwrap();
    assert_eq!((v1.state, v1.platform_n), (VersionState::Live, Some(4)));
    assert_eq!(app.url.as_deref(), Some("https://a-web--team_abc.preview.example"));
}

#[test]
fn a_pending_version_the_platform_never_got_settles_failed_and_stops() {
    let world = World::new();
    world.agent.lose_answers.set(3);
    world.with(|host| publish(host, &request())).unwrap_err();
    let mut app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert!(world.with(|host| settle(host, &mut app)));
    assert_eq!(app.version(1).unwrap().state, VersionState::Failed);
    assert_eq!(*world.procs.stopped.borrow(), [500]);
    assert_eq!(app.live, None);
}

const SECRET: &str = "sk_live_only_for_web";

fn with_secret(world: &World) {
    world
        .agent
        .secrets
        .borrow_mut()
        .insert("web".into(), [("STRIPE_KEY".to_owned(), SECRET.to_owned())].into_iter().collect());
}

#[test]
fn an_apps_secret_reaches_its_own_process_after_the_service_env_literals() {
    let world = World::new();
    with_secret(&world);
    world
        .agent
        .secrets
        .borrow_mut()
        .get_mut("web")
        .unwrap()
        .insert("NODE_ENV".into(), "staging".into());
    world.fs.file(
        "/state/apps/web/v1/src/.cmux/apps/web/app.json",
        br#"{"service": {"env": {"NODE_ENV": "production", "LOG_LEVEL": "info"}}}"#,
    );
    world.with(|host| publish(host, &request())).unwrap();

    let reads = world.process_env_reads();
    assert_eq!(reads.len(), 1);
    assert_eq!(
        (reads[0].method.as_str(), reads[0].path.as_str()),
        ("POST", "/v1/cloud/apps/web/process-env")
    );
    assert_eq!(reads[0].body, Some(json!({"machine": "vm_self"})));
    let env = world.procs.spawned.borrow()[0].env.clone();
    assert!(env.contains(&("STRIPE_KEY".to_owned(), SECRET.to_owned())), "{env:?}");
    assert!(env.contains(&("LOG_LEVEL".to_owned(), "info".to_owned())));
    // A secret wins over a literal of the same name, and each name appears once.
    assert!(env.contains(&("NODE_ENV".to_owned(), "staging".to_owned())), "{env:?}");
    assert_eq!(env.iter().filter(|(k, _)| k == "NODE_ENV").count(), 1);
    // Never on disk: not in the version record, the app state, or anything else written.
    assert!(!world.stored_anywhere(SECRET), "a secret value was written to disk");
}

#[test]
fn a_secret_never_reaches_another_apps_process() {
    let world = World::new();
    with_secret(&world);
    world.with(|host| publish(host, &request())).unwrap();
    let mut other = request();
    other.name = Some("api".into());
    world.with(|host| publish(host, &other)).unwrap();

    let spawned = world.procs.spawned.borrow();
    assert_eq!((spawned[0].slug.as_str(), spawned[1].slug.as_str()), ("web", "api"));
    assert!(spawned[0].env.iter().any(|(_, v)| v == SECRET));
    assert!(
        spawned[1].env.iter().all(|(k, v)| k != "STRIPE_KEY" && v != SECRET),
        "{:?}",
        spawned[1].env
    );
    let paths: Vec<String> = world.process_env_reads().into_iter().map(|s| s.path).collect();
    assert_eq!(paths, ["/v1/cloud/apps/web/process-env", "/v1/cloud/apps/api/process-env"]);
}

#[test]
fn a_process_env_refusal_fails_the_publish_before_start_and_keeps_live() {
    let world = World::new();
    world.with(|host| publish(host, &request())).unwrap();
    let before = world.changes().len();
    *world.agent.process_env_answer.borrow_mut() = Some((
        503,
        json!({"error": {"code": "cloud.app.secret_unreadable", "message": "secret STRIPE_KEY can't be opened; set it again"}}),
    ));
    let failure = world.with(|host| publish(host, &request())).unwrap_err();

    assert_eq!(failure.code, "app.secrets");
    assert!(failure.message.contains("cloud.app.secret_unreadable"), "{}", failure.message);
    assert!(failure.message.contains("STRIPE_KEY"), "{}", failure.message);
    assert_eq!(world.procs.spawned.borrow().len(), 1, "v2 started without its secrets");
    assert_eq!(world.changes().len(), before, "a version without its secrets reached the platform");
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.live, Some(1));
    assert_eq!(app.version(1).unwrap().state, VersionState::Live);
    assert_eq!(app.version(2).unwrap().state, VersionState::Failed);
}

#[test]
fn an_app_the_platform_does_not_know_yet_starts_with_no_secrets() {
    let world = World::new();
    *world.agent.process_env_answer.borrow_mut() =
        Some((404, json!({"error": {"code": "cloud.app.not_found", "message": "no such app"}})));
    let done = world.with(|host| publish(host, &request())).unwrap();
    assert_eq!(done.version.state, VersionState::Live);

    // Any other 404 (the machine is not the creator's) is a refusal.
    *world.agent.process_env_answer.borrow_mut() = Some((
        404,
        json!({"error": {"code": "cloud.app.machine_not_found", "message": "no such Cloud machine of yours"}}),
    ));
    let failure = world.with(|host| publish(host, &request())).unwrap_err();
    assert_eq!(failure.code, "app.secrets");
}

#[test]
fn a_rollback_restart_gets_its_apps_secrets_and_a_refusal_keeps_live() {
    let world = World::new();
    with_secret(&world);
    world.with(|host| publish(host, &request())).unwrap();
    world.with(|host| publish(host, &request())).unwrap();
    world.procs.dead.borrow_mut().insert(500);

    *world.agent.process_env_answer.borrow_mut() = Some((
        503,
        json!({"error": {"code": "cloud.app.secrets_unconfigured", "message": "app secrets are not configured on this deployment"}}),
    ));
    let failure =
        world.with(|host| rollback(host, "web", None, Duration::from_secs(60))).unwrap_err();
    assert_eq!(failure.code, "app.secrets");
    assert_eq!(world.procs.spawned.borrow().len(), 2);
    let app = world.with(|host| state::load(host.fs, &host.apps_root, "web")).unwrap().unwrap();
    assert_eq!(app.live, Some(2));

    *world.agent.process_env_answer.borrow_mut() = None;
    world.with(|host| rollback(host, "web", None, Duration::from_secs(60))).unwrap();
    let spawned = world.procs.spawned.borrow();
    assert!(spawned[2].restart);
    assert!(spawned[2].env.contains(&("STRIPE_KEY".to_owned(), SECRET.to_owned())));
    assert!(!world.stored_anywhere(SECRET));
}
