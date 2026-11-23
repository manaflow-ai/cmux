//! `cmux automation create NAME --webhook`, through the real binary: the runner
//! opens a loopback listener, `webhook send` posts a signed delivery, the
//! automation runs once with the body as its event, a repeat delivery and a
//! filtered-out one start nothing, and a rotated secret locks the old one out.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Env {
    dir: PathBuf,
    addr: String,
}

impl Env {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-automation-hook-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        // A free loopback port for this test's runner.
        let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = probe.local_addr().unwrap().to_string();
        drop(probe);
        Self { dir, addr }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new(self.dir.join("bin/cmux"));
        c.args(args)
            .current_dir(&self.dir)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join("store"))
            .env("CMUX_AUTOMATION_WEBHOOK_ADDR", &self.addr)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .stdin(Stdio::null());
        c
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (Option<i32>, Value) {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.run(&all);
        // An error goes to stderr as JSON; either way the answer is one object.
        let v = serde_json::from_slice(&out.stdout)
            .or_else(|_| serde_json::from_slice(&out.stderr))
            .unwrap_or_else(|e| {
                panic!(
                    "cmux {args:?} printed no JSON ({e}): {}{}",
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                )
            });
        (out.status.code(), v)
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Runner(Child);

impl Drop for Runner {
    fn drop(&mut self) {
        // SAFETY: SIGTERM to the runner this test started.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

#[test]
fn a_signed_local_webhook_starts_one_run_with_its_body() {
    let env = Env::new("send");
    let seen = env.dir.join("seen.txt");
    let body = format!(
        "cat \"$CMUX_AUTOMATION_EVENT_FILE\" >> {}; echo >> {}",
        seen.display(),
        seen.display()
    );
    let (code, created) = env.json(&[
        "automation",
        "create",
        "deploy",
        "--webhook",
        "--match",
        "ref=refs/heads/main",
        "--dedupe",
        "10m",
        "--command",
        &body,
        "--folder",
        env.dir.to_str().unwrap(),
    ]);
    assert_eq!(code, Some(0), "{created}");
    assert_eq!(created["trigger"]["type"], "webhook");
    assert_eq!(created["trigger"]["dedupe_seconds"], 600);
    let id = created["id"].as_str().unwrap().to_string();
    let hook = &created["webhook"];
    assert_eq!(hook["url"], format!("http://{}/hooks/{id}", env.addr), "{created}");
    assert_eq!(hook["secret"].as_str().map(str::len), Some(64));
    assert_eq!(hook["listening"], false);
    // The secret is not in the definition, and `show` leaves it out unless asked.
    let store = fs::read_to_string(env.dir.join("store").join(&id).join("automation.json"))
        .unwrap_or_default();
    assert!(!store.contains(hook["secret"].as_str().unwrap()));
    let (_, shown) = env.json(&["automation", "webhook", "show", "deploy"]);
    assert!(shown.get("secret").is_none(), "{shown}");

    // An option without --webhook, and these verbs on a plain automation, are refused.
    let out =
        env.run(&["automation", "create", "x", "--hourly", "--match", "a=b", "--command", "true"]);
    assert_eq!(out.status.code(), Some(2), "{}", String::from_utf8_lossy(&out.stderr));
    env.json(&["automation", "create", "plain", "--manual", "--command", "true"]);
    let out = env.run(&["automation", "webhook", "show", "plain"]);
    assert_eq!(out.status.code(), Some(2));

    // No runner yet: nothing answers.
    let (code, _) = env.json(&["automation", "webhook", "send", "deploy"]);
    assert_eq!(code, Some(1));

    let _runner = Runner(
        env.command(&["--json", "automation", "runner"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let push = r#"{"ref":"refs/heads/main","after":"abc123"}"#;
    let send = |delivery: &str, body: &str| {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let (code, v) = env.json(&[
                "automation",
                "webhook",
                "send",
                "deploy",
                "--body",
                body,
                "--delivery",
                delivery,
            ]);
            if v.get("http_status").is_some() || Instant::now() > deadline {
                return (code, v);
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    };
    let (code, first) = send("d-1", push);
    assert_eq!(code, Some(0), "{first}");
    assert_eq!(first["http_status"], 202);
    assert_eq!(first["answer"]["status"], "accepted");
    let (_, again) = send("d-1", push);
    assert_eq!(again["answer"]["status"], "duplicate", "{again}");
    let (_, other) = send("d-2", r#"{"ref":"refs/heads/dev"}"#);
    assert_eq!(other["answer"]["status"], "ignored", "{other}");
    let (_, shown) = env.json(&["automation", "webhook", "show", "deploy"]);
    assert_eq!(shown["listening"], true, "{shown}");

    let deadline = Instant::now() + Duration::from_secs(30);
    while !fs::read_to_string(&seen).is_ok_and(|t| t.contains("abc123"))
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(200));
    }
    let text = fs::read_to_string(&seen).unwrap_or_default();
    assert!(text.contains("\"source\":\"webhook\""), "{text}");
    assert!(text.contains("\"delivery\":\"d-1\""), "{text}");
    assert_eq!(text.matches("abc123").count(), 1, "one run for one delivery: {text}");
    let (_, history) = env.json(&["automation", "history", "deploy"]);
    let runs = history["runs"].as_array().cloned().unwrap_or_default();
    assert!(runs.iter().any(|r| r["trigger"] == "webhook"), "{history}");

    // A rotated secret: the old one is refused at the door.
    let (code, rotated) = env.json(&["automation", "webhook", "rotate", "deploy"]);
    assert_eq!(code, Some(0), "{rotated}");
    assert_ne!(rotated["secret"], hook["secret"]);
    let old = hook["secret"].as_str().unwrap();
    let (status, _) =
        cmux_automations::webhook::send(&env.addr, &id, old, push.as_bytes(), &[]).unwrap();
    assert_eq!(status, 401);
    let (_, fresh) = send("d-3", push);
    assert_eq!(fresh["http_status"], 202, "{fresh}");
}
