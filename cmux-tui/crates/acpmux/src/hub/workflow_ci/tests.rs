use super::*;
use crate::workflow_runs::{Child, State, Store};
use std::os::unix::fs::PermissionsExt;

fn run(cwd: &Path) -> RunRecord {
    RunRecord {
        version: 1,
        id: "wf-ci-test".into(),
        name: "CI machine".into(),
        owner_session_id: "owner".into(),
        local_principal: true,
        source: "machine('test')".into(),
        source_hash: String::new(),
        args: json!([]),
        allowed_tools: None,
        cwd: cwd.into(),
        generation: 1,
        state: State::Running,
        activities: Default::default(),
        outcome: None,
        caller_subagent: None,
    }
}

async fn repository(dir: &Path) {
    git(dir, &["init", "--quiet"]).await.unwrap();
    git(
        dir,
        &["remote", "add", "origin", "https://secret:credential@github.com/example/project.git"],
    )
    .await
    .unwrap();
    commit(dir).await;
}

async fn commit(dir: &Path) {
    git(
        dir,
        &[
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "fixture",
        ],
    )
    .await
    .unwrap();
}

fn fake(dir: &Path, intent: &CiIntent, lost_ack: bool) -> Client {
    std::fs::write(dir.join("intent.json"), serde_json::to_vec(intent).unwrap()).unwrap();
    if lost_ack {
        std::fs::write(dir.join("lose-ack"), "").unwrap();
    }
    let program = dir.join("client.py");
    std::fs::write(&program, r#"#!/usr/bin/env python3
import json, pathlib, subprocess, sys
root = pathlib.Path(__file__).parent
args = sys.argv[1:]
op = args[0]
def flag(name, default=''):
    return args[args.index(name)+1] if name in args else default
intent = json.loads((root/'intent.json').read_text())
state = root/'job.json'
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\n')
if op == 'submit':
    wanted = {'command':flag('--command'),'repo':flag('--repo'),'ref':flag('--ref'),'kind':flag('--kind'),'target_worker':flag('--target-worker'),'request_key':flag('--request-key')}
    if state.exists():
        job=json.loads(state.read_text())
        if any(job[k] != v for k,v in wanted.items()): sys.exit(9)
    else:
        job=dict(wanted,id='a'*24,command_digest='sha256:'+'b'*64,state='queued')
        state.write_text(json.dumps(job))
        (root/'created').write_text('one job')
    if (root/'lose-ack').exists():
        (root/'lose-ack').unlink()
        sys.exit(1)
    pathlib.Path(flag('--receipt')).write_text(json.dumps(job))
    print(json.dumps(job))
elif op == 'status':
    if not state.exists(): sys.exit(1)
    print(state.read_text())
elif op == 'cancel':
    job=json.loads(state.read_text())
    if args[1] != job['id'] or flag('--request-key') != job['request_key'] or flag('--command-digest') != job['command_digest']: sys.exit(9)
    job['state']='cancelled'
    state.write_text(json.dumps(job))
    print(json.dumps(job))
elif op == 'wait':
    job=json.loads(state.read_text())
    result=subprocess.run(job['command'],shell=True,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    job['state']='done' if result.returncode == 0 else 'failed'
    pathlib.Path(flag('--receipt')).write_text(json.dumps(job))
    pathlib.Path(flag('--full-log')).write_bytes(b'worker checkout logs\njob: nofile report\n'+result.stdout+(b'command failed: exit status 23\n' if result.returncode else b''))
    print('human wait progress, deliberately not JSON')
    sys.exit(0 if result.returncode == 0 else 1)
else: sys.exit(9)
"#).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    Client { program: Some(program) }
}

#[tokio::test]
async fn workflow_ci_lost_ack_attaches_once_and_cancel_is_exact() {
    let dir = tempfile::tempdir().unwrap();
    repository(dir.path()).await;
    let intent = prepare(
        &run(dir.path()),
        "activity",
        "printf hello",
        &json!({"targetWorker":"requested-worker"}),
    )
    .await
    .unwrap();
    let client = fake(dir.path(), &intent, true);
    let job = client.submit(&intent, &dir.path().join("submit.json")).await.unwrap();
    binding(&job, &intent, None).unwrap();
    let attached = client.submit(&intent, &dir.path().join("again.json")).await.unwrap();
    assert_eq!(job["id"], attached["id"]);
    client.cancel(&intent, Some(&attached)).await.unwrap();
    let terminal: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("job.json")).unwrap()).unwrap();
    let before = std::fs::read(dir.path().join("calls.jsonl")).unwrap();
    client.cancel(&intent, Some(&terminal)).await.unwrap();
    assert_eq!(std::fs::read(dir.path().join("calls.jsonl")).unwrap(), before);
    let mut stopping = terminal;
    stopping["linux_pool"] = json!({"stall_stopping":true});
    client.cancel(&intent, Some(&stopping)).await.unwrap();
    let calls: Vec<Value> = std::fs::read_to_string(dir.path().join("calls.jsonl"))
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect();
    assert_eq!(calls.iter().filter(|call| call[0] == "submit").count(), 3);
    assert_eq!(calls.iter().filter(|call| call[0] == "status").count(), 1);
    assert_eq!(calls.iter().filter(|call| call[0] == "cancel").count(), 2);
    assert_eq!(
        calls.last().unwrap(),
        &json!([
            "cancel",
            "a".repeat(24),
            "--request-key",
            intent.request_key,
            "--command-digest",
            format!("sha256:{}", "b".repeat(64))
        ])
    );
    assert_eq!(std::fs::read_to_string(dir.path().join("created")).unwrap(), "one job");
}

#[tokio::test]
async fn workflow_ci_replay_preserves_source_target_and_refuses_conflicting_binding() {
    let dir = tempfile::tempdir().unwrap();
    repository(dir.path()).await;
    std::fs::create_dir(dir.path().join("subdir")).unwrap();
    let mut spec = run(&dir.path().join("subdir"));
    let intent =
        prepare(&spec, "activity", "pwd", &json!({"targetWorker":"first-worker"})).await.unwrap();
    assert_eq!(intent.repo, "https://github.com/example/project.git");
    assert!(!serde_json::to_string(&intent).unwrap().contains("credential"));
    let store = Store::new(dir.path().join("runs"));
    spec = store.start(spec).unwrap();
    let activity = ActivityRecord {
        id: "activity".into(),
        kind: "machine".into(),
        fingerprint: "immutable".into(),
        child: Child::CiMachine { intent: intent.clone() },
        policy: Value::Null,
        outcome: None,
    };
    store.register_activity(&spec.id, spec.generation, "owner", activity.clone()).unwrap();
    commit(dir.path()).await;
    git(dir.path(), &["remote", "set-url", "origin", "https://github.com/changed/source.git"])
        .await
        .unwrap();
    let paused = store.pause(&spec.id, "owner").unwrap();
    store.paused(&spec.id, paused.generation).unwrap();
    let resumed = store.resume(&spec.id, "owner", false).unwrap();
    let saved = store.activity(&spec.id, resumed.generation, "owner", "activity").unwrap().unwrap();
    assert_eq!(saved.child, activity.child);
    assert_ne!(git(dir.path(), &["rev-parse", "HEAD"]).await.unwrap(), intent.source_ref);
    let Child::CiMachine { intent: pinned } = saved.child else { unreachable!() };
    let client = fake(dir.path(), &pinned, false);
    let first = client.submit(&pinned, &dir.path().join("receipt.json")).await.unwrap();
    binding(&first, &pinned, None).unwrap();
    let mut changed = pinned.clone();
    changed.target_worker = "other-worker".into();
    assert!(client.submit(&changed, &dir.path().join("conflict.json")).await.is_err());
    let mut missing = first.clone();
    missing.as_object_mut().unwrap().remove("command_digest");
    assert!(binding(&missing, &pinned, None).is_err());
    let mut conflict = first.clone();
    conflict["command_digest"] = json!(format!("sha256:{}", "c".repeat(64)));
    assert!(binding(&conflict, &pinned, Some(&first)).is_err());
    let mut moved = first.clone();
    moved["target_worker"] = json!("fallback-worker");
    moved["pin_requested"] = json!("first-worker");
    binding(&moved, &pinned, Some(&first)).unwrap();
}

#[tokio::test]
async fn workflow_ci_full_log_preserves_output_and_exact_nonzero_status() {
    for status in [0, 23] {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let nested = dir.path().join("sub dir ' ");
        std::fs::create_dir(&nested).unwrap();
        let command = format!("printf 'complete output'; printf ' stderr' >&2; exit {status}");
        let intent = prepare(&run(&nested), "activity", &command, &json!({})).await.unwrap();
        let client = fake(dir.path(), &intent, false);
        let job = client.submit(&intent, &dir.path().join("submit.json")).await.unwrap();
        let receipt = dir.path().join("terminal.json");
        let log = dir.path().join("full.log");
        let waited = client
            .call(&[
                "wait".into(),
                job["id"].as_str().unwrap().into(),
                "--receipt".into(),
                receipt.to_str().unwrap().into(),
                "--full-log".into(),
                log.to_str().unwrap().into(),
            ])
            .await
            .unwrap();
        let result = finish_wait(waited.status.code(), &receipt, &log, &intent, &job).await;
        let view = if status == 0 { result.unwrap() } else { result.unwrap_err().data.unwrap() };
        assert_eq!(view["text"], "complete output stderr");
        assert_eq!(view["exitCode"], status);
        std::fs::write(&log, "truncated output").unwrap();
        let incomplete = finish_wait(waited.status.code(), &receipt, &log, &intent, &job)
            .await
            .unwrap_err()
            .data
            .unwrap();
        assert_eq!(incomplete["text"], "truncated output");
        assert!(incomplete["exitCode"].is_null());
    }
}

#[tokio::test]
async fn workflow_ci_unavailable_client_never_executes_command_locally() {
    let dir = tempfile::tempdir().unwrap();
    repository(dir.path()).await;
    let marker = dir.path().join("must-not-exist");
    let intent = prepare(
        &run(dir.path()),
        "activity",
        &format!("touch {}", quote(marker.to_str().unwrap())),
        &json!({}),
    )
    .await
    .unwrap();
    let client = Client { program: Some(dir.path().join("missing-client")) };
    assert!(client.submit(&intent, &dir.path().join("receipt.json")).await.is_err());
    assert!(!marker.exists());
    for url in [
        "https://github.com.evil/example/project",
        "file:///tmp/repo",
        "https://github.com/example/project?token=secret",
    ] {
        assert!(github_repo(url).is_err());
    }
}
