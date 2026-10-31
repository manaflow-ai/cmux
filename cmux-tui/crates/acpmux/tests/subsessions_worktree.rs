//! `start_session` with `worktree: true` (`subsession_worktree.rs`): the
//! child runs in a new git worktree of its folder's repository, laid out as
//! `git.worktree.create` lays one out (`~/.cmux/worktrees/<project>/<name>` on
//! `cmux/<name>`, its base in `branch.<branch>.cmuxBase`), so the app's Apply
//! and Remove work on it. The daemon runs that git outside the agent's
//! sandbox, so nothing the agent wrote in its repository runs there: no
//! hook, and no checkout filter, transport or helper from its config (the
//! files are checked out without that config; the child's own git, in its
//! sandbox, uses it from then on).
//!
//! Stand-in agents (fake_agent.py). One test function: HOME and the settings
//! file are read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let params = json!({"protocolVersion": 1,
            "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
        let r = c.call("initialize", params).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

#[tokio::test]
async fn a_worktree_start_runs_nothing_the_agent_wrote_in_its_repository() {
    let root = std::env::temp_dir().join(format!("acpmux-subwt-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
    }
    let repo = root.join("Shop App");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    // A hook the agent could write in its own repository.
    let hook_ran = root.join("hook-ran");
    let hook = repo.join(".git/hooks/post-checkout");
    std::fs::create_dir_all(hook.parent().unwrap()).unwrap();
    std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", hook_ran.display())).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    // The person trusts the scratch folder: a child may start in a folder
    // outside its parent's own only where the person trusts it.
    let trust = acpmux::trust::Paths::current().unwrap();
    acpmux::trust::set(&trust, &root.to_string_lossy(), "trusted").unwrap();

    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": repo, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let mut p = Client::as_session(&hub, &parent).await;

    // The child runs in its own worktree on its own branch, its base recorded.
    let started =
        p.ok(START, json!({"prompt": "echo child", "name": "Child task", "worktree": true})).await;
    let wt = home.join(".cmux/worktrees/shop-app/child-task");
    assert_eq!(started["worktree"]["root"], json!(wt), "{started}");
    assert_eq!(started["worktree"]["branch"], "cmux/child-task", "{started}");
    let child = started["sessionId"].as_str().unwrap().to_owned();
    let info = app.ok("_acpmux/info", json!({"sessionId": child})).await;
    let canonical = |p: &Path| std::fs::canonicalize(p).unwrap();
    assert_eq!(canonical(info["cwd"].as_str().unwrap().as_ref()), canonical(&wt), "{info}");
    assert_eq!(git(&repo, &["config", "branch.cmux/child-task.cmuxBase"]), "main");
    assert!(
        !hook_ran.exists(),
        "the repository's post-checkout hook ran outside the agent's sandbox"
    );

    // A second start with the same name takes the next free one.
    let again =
        p.ok(START, json!({"prompt": "echo again", "name": "Child task", "worktree": true})).await;
    assert_eq!(again["worktree"]["branch"], "cmux/child-task-2", "{again}");

    // Checkout filters in the repository's own config, directly and through
    // an include: the worktree is made with the files as committed, and
    // neither filter runs. A child started from a subfolder starts in the
    // same subfolder of its worktree.
    std::fs::create_dir_all(repo.join("web/src")).unwrap();
    std::fs::write(repo.join(".gitattributes"), "*.txt filter=agent\n*.md filter=included\n")
        .unwrap();
    std::fs::write(repo.join("a.txt"), "a\n").unwrap();
    std::fs::write(repo.join("web/src/b.md"), "b\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "attributes"]);
    let filter_ran = root.join("filter-ran");
    let smudge = format!("sh -c 'touch \"{}\"; echo filtered'", filter_ran.display());
    git(&repo, &["config", "filter.agent.smudge", &smudge]);
    git(&repo, &["config", "filter.agent.required", "true"]);
    let included = root.join("included.gitconfig");
    std::fs::write(&included, format!("[filter \"included\"]\n\tprocess = {smudge}\n")).unwrap();
    git(&repo, &["config", "include.path", &included.to_string_lossy()]);
    let filtered = p
        .ok(
            START,
            json!({"prompt": "echo x", "name": "Filtered", "worktree": true, "cwd": repo.join("web")}),
        )
        .await;
    assert!(!filter_ran.exists(), "the repository's smudge filter ran outside the agent's sandbox");
    let fwt = home.join(".cmux/worktrees/shop-app/filtered");
    assert_eq!(filtered["worktree"]["root"], json!(fwt), "{filtered}");
    assert_eq!(std::fs::read_to_string(fwt.join("a.txt")).unwrap(), "a\n");
    assert_eq!(std::fs::read_to_string(fwt.join("web/src/b.md")).unwrap(), "b\n");
    let child = filtered["sessionId"].as_str().unwrap().to_owned();
    let info = app.ok("_acpmux/info", json!({"sessionId": child})).await;
    assert_eq!(canonical(info["cwd"].as_str().unwrap().as_ref()), canonical(&fwt.join("web")));
    // Its index is the commit's: nothing staged, nothing missing.
    let staged = git(&fwt, &["diff", "--cached", "--name-only"]);
    assert_eq!(staged, "", "the worktree's index differs from its commit");
    assert!(!filter_ran.exists(), "the repository's smudge filter ran outside the agent's sandbox");

    // A partial clone (`--filter=blob:none`) without the commit's files, as
    // one cloned without a checkout: they are fetched from its promisor
    // remote, without the clone's own config (its upload-pack would mark).
    let origin = root.join("origin");
    std::fs::create_dir_all(origin.join("web")).unwrap();
    git(&origin, &["init", "-q"]);
    git(&origin, &["config", "uploadpack.allowFilter", "true"]);
    git(&origin, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    std::fs::write(origin.join("web/page.txt"), "page\n").unwrap();
    git(&origin, &["add", "."]);
    git(&origin, &["commit", "-q", "-m", "page"]);
    let url = format!("file://{}", origin.display());
    let partial = root.join("partial");
    git(&root, &["clone", "-q", "--filter=blob:none", "--no-checkout", &url, "partial"]);
    let missing = git(&partial, &["rev-list", "--objects", "--missing=print", "HEAD"]);
    assert!(missing.lines().any(|l| l.starts_with('?')), "the clone has every object: {missing}");
    let upload_ran = root.join("upload-ran");
    let upload = format!("touch '{}'; git-upload-pack", upload_ran.display());
    git(&partial, &["config", "remote.origin.uploadpack", &upload]);
    std::fs::create_dir_all(partial.join("web")).unwrap();
    // The fetch writes into the clone's objects from a throwaway git
    // directory whose refs reach none of them: an automatic maintenance or
    // gc there would prune the clone's own objects (its unpushed work).
    let trace = root.join("git-trace");
    // SAFETY: only this test's git runs meanwhile (stand-in agents run none).
    unsafe { std::env::set_var("GIT_TRACE", &trace) };
    let lazy = p
        .ok(
            START,
            json!({"prompt": "echo x", "name": "Partial", "worktree": true, "cwd": partial.join("web")}),
        )
        .await;
    unsafe { std::env::remove_var("GIT_TRACE") };
    let traced = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(traced.contains("fetch"), "the missing files were not fetched: {traced}");
    for line in traced.lines().filter(|l| l.contains("run_command:")) {
        assert!(
            !["maintenance", "repack", " gc"].iter().any(|w| line.contains(w)),
            "git maintenance ran against the clone's objects: {line}"
        );
    }
    let pwt = home.join(".cmux/worktrees/partial/partial");
    assert_eq!(lazy["worktree"]["root"], json!(pwt), "{lazy}");
    assert_eq!(std::fs::read_to_string(pwt.join("web/page.txt")).unwrap(), "page\n");
    let child = lazy["sessionId"].as_str().unwrap().to_owned();
    let info = app.ok("_acpmux/info", json!({"sessionId": child})).await;
    assert_eq!(canonical(info["cwd"].as_str().unwrap().as_ref()), canonical(&pwt.join("web")));
    assert_eq!(git(&pwt, &["diff", "--cached", "--name-only"]), "");
    assert!(!upload_ran.exists(), "the clone's own upload-pack config ran");

    // A folder that is no repository gets no worktree either.
    let plain = root.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let refused = p.call(START, json!({"prompt": "echo x", "cwd": plain, "worktree": true})).await;
    assert_eq!(refused["error"]["data"]["reason"], "subsessions.worktree_refused", "{refused}");

    let _ = std::fs::remove_dir_all(&root);
}
