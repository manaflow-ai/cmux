//! Publish and rollback end to end over fakes.
mod common;

use std::path::PathBuf;
use std::time::Duration;

use cmux_apps::io::Unanswered;
use cmux_apps::publish::{PublishRequest, publish, rollback};
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
    world.fs.file("/state/apps/web/v2/app.log", b"listening...\nError: boom\n");
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
    assert_eq!(spawned[0].dir, PathBuf::from("/state/apps/site/v1/src/site"));
    assert_eq!(spawned[0].log, PathBuf::from("/state/apps/site/v1/app.log"));

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
    let mut env = world.procs.spawned.borrow()[0].env.clone();
    env.sort();
    assert_eq!(
        env,
        [
            ("HOME".to_owned(), "/state/apps/web/v1".to_owned()),
            ("LANG".to_owned(), "C.UTF-8".to_owned()),
            ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ("PORT".to_owned(), "41000".to_owned()),
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
    let ran = world.procs.ran.borrow();
    assert_eq!(ran[0].command, "npm ci");
    assert!(ran[0].env.iter().all(|(k, _)| k != "GITHUB_TOKEN" && k != "PORT"));
    let env = &world.procs.spawned.borrow()[0].env;
    assert!(env.contains(&("NODE_ENV".to_owned(), "production".to_owned())));
    assert!(env.contains(&("PORT".to_owned(), "41000".to_owned())), "app.json may not move PORT");
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
    assert!(spawned[2].env.contains(&("PORT".to_owned(), "41000".to_owned())));
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
