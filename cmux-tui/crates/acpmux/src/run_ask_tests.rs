use super::*;
use std::process::Command;

/// A `run` ask as the store serves it once its person accepted it.
fn ask() -> Value {
    json!({
        "id": 7, "thread": 3, "type": "run", "state": "accepted", "body": "",
        "asker": {"org": "o1", "person": "p1", "holder": {"kind": "agent", "id": "a", "name": "a"}},
        "to": {"org": "o2", "person": "p2"},
        "created_at": "2026-11-24T00:00:00Z", "updated_at": "2026-11-24T00:00:00Z",
        "receipt": null, "receipts": [],
        "repo": "octo/app", "ref": "main", "command": "cargo test -p app",
        "limits": {"timeout_s": 120, "vcpu": 2}, "result": null,
    })
}

fn with(key: &str, value: Value) -> Value {
    let mut a = ask();
    a[key] = value;
    a
}

fn refused(a: &Value) -> String {
    validate(a).expect_err("refused").0
}

#[test]
fn an_accepted_run_is_read_with_its_limits() {
    let run = validate(&ask()).unwrap();
    assert_eq!(
        run,
        RunAsk {
            id: Some(7),
            repo: "octo/app".into(),
            git_ref: "main".into(),
            command: "cargo test -p app".into(),
            timeout_s: Some(120),
            vcpu: Some(2),
        }
    );
    let bare = json!({"type": "run", "state": "accepted", "to": {"person": "p2"},
        "repo": "o/n", "ref": "0123abc", "command": "make"});
    assert_eq!(validate(&bare).unwrap().timeout_s, None);
}

#[test]
fn anything_but_an_accepted_run_is_refused() {
    assert!(refused(&with("type", json!("question"))).contains("not a run"));
    for state in ["open", "declined", "done"] {
        assert!(refused(&with("state", json!(state))).contains("accepted"), "{state}");
    }
    assert!(refused(&with("result", json!({"exit": 0}))).contains("already"));
    assert!(refused(&with("to", json!({}))).contains("to.person"));
    assert!(parse("not json").unwrap_err().0.contains("not JSON"));
}

#[test]
fn unknown_fields_such_as_env_script_or_secret_are_refused() {
    for key in ["env", "script", "secret", "setup"] {
        assert!(refused(&with(key, json!("x"))).contains(key), "{key}");
    }
    assert!(refused(&with("limits", json!({"timeout_s": 5, "memory": 1}))).contains("memory"));
}

#[test]
fn the_command_is_one_line_within_the_store_bound() {
    for bad in ["", "   ", "make\nrm -rf x", "make\ttest", "a\u{7}"] {
        assert!(refused(&with("command", json!(bad))).contains("command"), "{bad:?}");
    }
    assert!(refused(&with("command", json!("x".repeat(MAX_COMMAND + 1)))).contains("at most"));
    assert!(validate(&with("command", json!("x".repeat(MAX_COMMAND)))).is_ok());
    assert!(refused(&with("command", json!(["make"]))).contains("string"));
}

#[test]
fn repo_is_owner_slash_name() {
    for bad in ["octo", "octo/app/x", "/app", "octo/", "octo/a b", "../app", "octo/..", "a:b/c"] {
        assert!(refused(&with("repo", json!(bad))).contains("repo"), "{bad}");
    }
    assert!(validate(&with("repo", json!("manaflow-ai/cmux.next_1"))).is_ok());
}

#[test]
fn ref_is_one_plain_commit_or_branch() {
    for bad in
        ["-x", "+main", "main:other", "a b", "main~1", "HEAD^", "a..b", "x@{1}", "re*", "/a", "a/"]
    {
        assert!(refused(&with("ref", json!(bad))).contains("ref"), "{bad}");
    }
    for good in ["main", "lane/run-ask", "0123456789abcdef0123456789abcdef01234567", "v1.2"] {
        assert!(validate(&with("ref", json!(good))).is_ok(), "{good}");
    }
}

#[test]
fn limits_are_within_a_day_and_64_vcpu() {
    for bad in [
        json!({"timeout_s": 0}),
        json!({"timeout_s": 86_401}),
        json!({"vcpu": 65}),
        json!({"vcpu": -1}),
        json!({"vcpu": 1.5}),
        json!({"timeout_s": "60"}),
    ] {
        assert!(refused(&with("limits", bad.clone())).contains(" is 1 to "), "{bad}");
    }
    assert!(refused(&with("limits", json!(60))).contains("limits"));
    let max = validate(&with("limits", json!({"timeout_s": 86_400, "vcpu": 64}))).unwrap();
    assert_eq!((max.timeout_s, max.vcpu), (Some(86_400), Some(64)));
}

fn run(timeout_s: Option<u64>, vcpu: Option<u64>) -> RunAsk {
    RunAsk { timeout_s, vcpu, ..validate(&ask()).unwrap() }
}

#[test]
fn a_light_run_stays_here_and_a_heavy_one_goes_to_the_scheduler() {
    let light = plan(&run(None, None), 8).unwrap();
    assert_eq!((light.place, light.timeout_s), (Place::Local, LOCAL_MAX_TIMEOUT_S));
    assert_eq!(plan(&run(Some(600), Some(8)), 8).unwrap().place, Place::Local);

    let cores = plan(&run(Some(60), Some(9)), 8).unwrap();
    assert_eq!(cores.place, Place::Scheduler);
    assert!(cores.why.contains("9 vCPU"), "{}", cores.why);

    let long = plan(&run(Some(601), None), 64).unwrap();
    assert_eq!((long.place, long.timeout_s), (Place::Scheduler, 601));
    assert!(long.why.contains("601 s"), "{}", long.why);

    assert_eq!(plan(&run(Some(SCHEDULER_MAX_TIMEOUT_S), None), 8).unwrap().place, Place::Scheduler);
    assert!(
        plan(&run(Some(SCHEDULER_MAX_TIMEOUT_S + 1), None), 8).unwrap_err().0.contains("scheduler")
    );
}

#[test]
fn the_scheduler_argv_runs_the_command_at_the_commit() {
    let sha = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(
        scheduler_argv("cmux-ci", sha, 900, "cargo test -p app"),
        ["cmux-ci", "test", "--at", sha, "--timeout", "900", "--", "sh", "-c", "cargo test -p app"]
    );
    assert_eq!(scheduler_argv("x", sha, 99_999, "make")[5], SCHEDULER_MAX_TIMEOUT_S.to_string());
    assert_eq!(github_url("octo/app"), "https://github.com/octo/app.git");
}

#[test]
fn the_tail_keeps_the_end_on_a_whole_character() {
    assert_eq!(tail(b"hello", 10), "hello");
    assert_eq!(tail(b"hello world", 5), "world");
    // "é" is two bytes; a cut through it starts at the next character.
    assert_eq!(tail("aébc".as_bytes(), 3), "bc");
    assert_eq!(tail(&[b'a', 0xff, b'b'], 2), "\u{fffd}b");
    let big = vec![b'x'; TAIL_BYTES * 3];
    assert_eq!(tail(&big, TAIL_BYTES).len(), TAIL_BYTES);
}

/// A bare repo with one commit on `main` holding `hello.txt`, as a `file://` remote; its commit.
fn bare_remote(root: &Path) -> (String, String) {
    let sh = |dir: &Path, script: &str| {
        let out = Command::new("sh").arg("-c").arg(script).current_dir(dir).output().unwrap();
        assert!(out.status.success(), "{script}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let work = root.join("work");
    std::fs::create_dir(&work).unwrap();
    sh(
        &work,
        "git init -q -b main . && printf 'hi from the ref\\n' > hello.txt && git add hello.txt \
        && git -c user.name=t -c user.email=t@t commit -qm one",
    );
    sh(root, "git clone -q --bare work remote.git");
    let sha = sh(&work, "git rev-parse HEAD");
    (format!("file://{}", root.join("remote.git").display()), sha)
}

fn local(timeout_s: u64) -> Plan {
    Plan { place: Place::Local, timeout_s, why: String::new() }
}

#[test]
fn a_local_run_fetches_the_ref_runs_the_command_and_cleans_up() {
    let root = tempfile::tempdir().unwrap();
    let (remote, sha) = bare_remote(root.path());
    for git_ref in ["main", sha.as_str()] {
        let ask = RunAsk {
            git_ref: git_ref.into(),
            command: "cat hello.txt; echo oops >&2; exit 3".into(),
            ..run(None, None)
        };
        let result = execute(&ask, &local(30), &remote, "unused").unwrap();
        assert_eq!(result.exit, 3, "{git_ref}: {result:?}");
        assert_eq!(result.tail, "hi from the ref\noops\n", "{git_ref}");
        assert!(result.artifacts.is_empty());
        assert_eq!(
            result.to_json(),
            json!({"exit": 3, "tail": "hi from the ref\noops\n", "artifacts": []})
        );
    }
}

#[test]
fn a_local_run_sees_only_the_kept_variables() {
    let root = tempfile::tempdir().unwrap();
    let (remote, _) = bare_remote(root.path());
    let ask = RunAsk { command: "env | cut -d= -f1".into(), ..run(None, None) };
    let result = execute(&ask, &local(30), &remote, "unused").unwrap();
    assert_eq!(result.exit, 0);
    // The shell sets PWD, SHLVL, OLDPWD and _ itself.
    let extra: Vec<&str> = result
        .tail
        .lines()
        .filter(|name| !KEPT_ENV.contains(name) && !["PWD", "SHLVL", "OLDPWD", "_"].contains(name))
        .collect();
    assert!(extra.is_empty(), "{extra:?}");
}

#[test]
fn the_run_folder_is_removed_afterwards() {
    let root = tempfile::tempdir().unwrap();
    let (remote, _) = bare_remote(root.path());
    let note = root.path().join("where");
    let ask = RunAsk { command: format!("pwd > {}", note.display()), ..run(None, None) };
    assert_eq!(execute(&ask, &local(30), &remote, "unused").unwrap().exit, 0);
    let ran_in = std::fs::read_to_string(&note).unwrap();
    let ran_in = Path::new(ran_in.trim());
    assert!(ran_in.ends_with("src"), "{}", ran_in.display());
    assert!(!ran_in.parent().unwrap().exists(), "{} is left behind", ran_in.display());
    assert!(root.path().join("remote.git").exists());
}

#[test]
fn a_run_past_its_timeout_ends_with_124_and_its_output() {
    let root = tempfile::tempdir().unwrap();
    let (remote, _) = bare_remote(root.path());
    let ask = RunAsk { command: "echo started; sleep 30".into(), ..run(None, None) };
    let started = std::time::Instant::now();
    let result = execute(&ask, &local(1), &remote, "unused").unwrap();
    assert_eq!(result.exit, TIMED_OUT_EXIT);
    assert!(result.tail.starts_with("started\n"), "{:?}", result.tail);
    assert!(result.tail.contains("timed out after 1 s"), "{:?}", result.tail);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
}

#[test]
fn a_long_output_keeps_only_its_tail() {
    let root = tempfile::tempdir().unwrap();
    let (remote, _) = bare_remote(root.path());
    let ask = RunAsk { command: "seq 1 200000; echo last".into(), ..run(None, None) };
    let result = execute(&ask, &local(30), &remote, "unused").unwrap();
    assert_eq!(result.exit, 0);
    assert!(result.tail.len() <= TAIL_BYTES, "{}", result.tail.len());
    assert!(
        result.tail.ends_with("200000\nlast\n"),
        "{:?}",
        &result.tail[result.tail.len() - 20..]
    );
}

#[test]
fn a_heavy_run_hands_the_scheduler_the_fetched_commit() {
    let root = tempfile::tempdir().unwrap();
    let (remote, sha) = bare_remote(root.path());
    let fake = root.path().join("fake-scheduler");
    std::fs::write(
        &fake,
        "#!/bin/sh\necho \"$@\"; git remote get-url origin; test -f hello.txt && exit 5\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let plan = Plan { place: Place::Scheduler, timeout_s: 900, why: String::new() };
    let result = execute(&run(Some(900), None), &plan, &remote, fake.to_str().unwrap()).unwrap();
    assert_eq!(result.exit, 5, "{result:?}");
    // It runs in the fetched checkout, whose origin names the repo for the scheduler.
    assert_eq!(
        result.tail,
        format!("test --at {sha} --timeout 900 -- sh -c cargo test -p app\n{remote}\n")
    );
}

#[test]
fn a_ref_the_remote_lacks_is_an_error_naming_it() {
    let root = tempfile::tempdir().unwrap();
    let (remote, _) = bare_remote(root.path());
    let ask = RunAsk { git_ref: "no-such-branch".into(), ..run(None, None) };
    let error = execute(&ask, &local(30), &remote, "unused").unwrap_err();
    assert!(format!("{error:#}").contains("octo/app@no-such-branch"), "{error:#}");
}
