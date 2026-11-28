//! A real chat on a real seed that is still filling (ignored: it clones from GitHub and
//! runs `claude`). It seeds `CMUX_DOGFOOD_MAC` (a checkout whose HEAD is pushed to
//! `CMUX_DOGFOOD_URL`) head-first, starts `claude -p` in the folder the moment the head
//! is marked, with `CMUX_DOGFOOD_HOOK` (cmux-git's `repo_sync_hook` example) as its
//! PreToolUse hook, and prints one JSON line of timings, each in seconds since the seed
//! started. `CMUX_DOGFOOD_REF` picks a pushed commit when the checkout's HEAD is not.
//! Run:
//!
//! ```text
//! CMUX_DOGFOOD_MAC=… CMUX_DOGFOOD_URL=https://github.com/manaflow-ai/cmux.git \
//! CMUX_DOGFOOD_HOOK=…/repo_sync_hook cargo test -p cmux-tui-core dogfood -- --ignored --nocapture
//! ```

use std::io::{BufRead, BufReader};
use std::process::Stdio;

use super::*;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

#[test]
#[ignore = "clones from GitHub and runs claude"]
fn dogfood_a_chat_works_before_the_checkout_lands() {
    let (source, url, hook) =
        (env("CMUX_DOGFOOD_MAC"), env("CMUX_DOGFOOD_URL"), env("CMUX_DOGFOOD_HOOK"));
    let home = Home::new("dogfood");
    // The Mac: a copy of the checkout at its pushed HEAD, with one edit of the person's.
    let mac = home.join("mac");
    git(&home.path, &["clone", "-q", "--shared", &source, mac.to_str().unwrap()]);
    if let Ok(pushed) = std::env::var("CMUX_DOGFOOD_REF") {
        git(&mac, &["checkout", "-q", "--detach", &pushed]);
    }
    let base = git(&mac, &["rev-parse", "HEAD"]);
    write(&mac.join("DOGFOOD.md"), "an edit of the person's\n");
    // A head with hooks that run at start is never marked (`harness_head::START_SETTINGS`):
    // the person's edit takes them out, so the chat can start at the head. A head that has
    // them waits for the whole checkout, as today.
    for settings in cmux_git::harness_head::START_SETTINGS {
        let _ = std::fs::remove_file(mac.join(settings));
    }
    // Nor is one whose links point out of it (`.claude/skills/x -> ../../skills/x`): it
    // takes them out too.
    for entry in git(&mac, &["ls-files", "-s"]).lines() {
        if let Some((mode, path)) = entry.split_once('\t')
            && mode.starts_with("120000 ")
            && cmux_git::harness_head::in_head(path, "")
        {
            let _ = std::fs::remove_file(mac.join(path));
        }
    }
    let world = World { home, remote: PathBuf::new(), mac, base: base.clone(), mirrors: None };
    let snapshot = world.snapshot("dogfood", &[&base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    let repo = url.trim_start_matches("https://github.com/").trim_end_matches(".git").to_owned();
    params["url"] = url.into();
    params["repo"] = repo.into();
    // `CMUX_DOGFOOD_TODAY`: today's seed, whole before the chat starts.
    let today = std::env::var_os("CMUX_DOGFOOD_TODAY").is_some();
    params["head_first"] = (!today).into();
    let service = GitSeedService::with_config(
        Roots::new([world.home.path.clone()]),
        Config {
            git: Git::default(),
            credentials: Some(vec![Credential::Anonymous]),
            mirrors: None,
        },
    );
    let started = Instant::now();
    let job = start(&service, &params).unwrap();
    let status = |job: &str| service.call("git.seed.status", &json!({ "job": job })).unwrap();
    loop {
        let now = status(&job);
        if today && now["state"] == "done" {
            break;
        }
        assert_eq!(now["state"], "running", "the seed ended before its head: {now}");
        if now["head_ready"] == true {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let head = started.elapsed().as_secs_f64();
    let log = world.home.join("hook.log");
    let settings = json!({ "hooks": { "PreToolUse": [{ "matcher": "",
        "hooks": [{ "type": "command", "command": hook, "timeout": 60 }] }] } });
    let prompt = "Read README.md and cmux-tui/AGENTS.md, then list the files under docs/cloud \
        with Glob, then run `git status --short` with Bash. Answer in one line.";
    let mut chat = Command::new("claude")
        .current_dir(&folder)
        .args(["-p", prompt, "--model", "haiku", "--output-format", "stream-json", "--verbose"])
        .args(["--allowedTools", "Read,Glob,Grep,LS,Bash(git status:*)"])
        .arg("--settings")
        .arg(settings.to_string())
        .env("CMUX_HOOK_LOG", &log)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("claude runs");
    let chat_started = std::time::SystemTime::now();
    let mut first_tool = None;
    for line in BufReader::new(chat.stdout.take().unwrap()).lines().map_while(Result::ok) {
        if first_tool.is_none() && line.contains("\"tool_use\"") {
            first_tool = Some(started.elapsed().as_secs_f64());
        }
    }
    let chat_ended = started.elapsed().as_secs_f64();
    let _ = chat.wait();
    let mut done = status(&job);
    while done["state"] == "running" {
        std::thread::sleep(Duration::from_millis(100));
        done = status(&job);
    }
    let whole = started.elapsed().as_secs_f64();
    assert_eq!(done["state"], "done", "{done}");
    // Each hook line in seconds since the seed started.
    let since_chat = |millis: u128| {
        let at = std::time::UNIX_EPOCH + Duration::from_millis(millis as u64);
        head + at.duration_since(chat_started).map_or(0.0, |d| d.as_secs_f64())
    };
    let tools: Vec<Value> = std::fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let mut parts = line.split(' ');
            let millis = parts.next()?.parse().ok()?;
            Some(json!({ "tool": parts.next()?, "outcome": parts.next()?,
                "s": (since_chat(millis) * 10.0).round() / 10.0 }))
        })
        .collect();
    println!(
        "{}",
        json!({ "head_s": head, "first_tool_use_s": first_tool, "tools": tools,
            "chat_ended_s": chat_ended, "whole_s": whole,
            "phases_ms": done["timings"]["phases"], "git_ms": done["timings"]["git"] })
    );
}
