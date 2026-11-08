//! `cmux automation` watch triggers, conditions and `test`, through the real
//! binary: a line appended to a log starts a run with that line as its event
//! (cmuxterm-hq docs/automation-triggers.md).
#![cfg(unix)]

use std::fs;
use std::io::Write as _;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-automation-trig-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        Self { dir }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new(self.dir.join("bin/cmux"));
        c.args(args)
            .current_dir(&self.dir)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join("store"))
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

    fn json(&self, args: &[&str]) -> (bool, Value) {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.run(&all);
        let v = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "cmux {args:?} printed no JSON ({e}): {}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        });
        (out.status.success(), v)
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
        // SAFETY: SIGTERM to the runner this test started; its handler stops the watch commands.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

#[test]
fn a_log_line_starts_one_run_with_the_line_as_its_event_and_test_explains_it() {
    let env = Env::new("watch");
    let log = env.dir.join("app.log");
    fs::write(&log, "boot ok\n").unwrap();
    let seen = env.dir.join("seen.txt");
    let watch = format!("tail -n 0 -F {} | grep --line-buffered FATAL", log.display());
    let body = format!("cat \"$CMUX_AUTOMATION_EVENT_FILE\" >> {}", seen.display());
    let (ok, created) = env.json(&[
        "automation",
        "create",
        "crash-fix",
        "--watch",
        &watch,
        "--debounce",
        "1s",
        "--command",
        &body,
        "--folder",
        env.dir.to_str().unwrap(),
    ]);
    assert!(ok, "{created}");
    assert_eq!(created["trigger"]["type"], "watch");
    assert_eq!(created["gate"]["cooldown_seconds"], 600, "a watch gets a cooldown by default");
    assert_eq!(created["gate"]["max_runs_per_day"], 24);

    // --debounce alone changes the watch it belongs to; on a timer it is refused.
    let (ok, edited) = env.json(&["automation", "edit", "crash-fix", "--debounce", "2s"]);
    assert!(ok, "{edited}");
    assert_eq!(edited["trigger"]["debounce_seconds"], 2, "{edited}");
    let (ok, _) = env.json(&["automation", "edit", "crash-fix", "--debounce", "1s"]);
    assert!(ok);
    env.json(&["automation", "create", "timer", "--every", "1h", "--command", "true"]);
    let out = env.run(&["automation", "edit", "timer", "--debounce", "2s"]);
    assert_eq!(out.status.code(), Some(2), "{}", String::from_utf8_lossy(&out.stderr));

    // The dry run starts nothing and shows the event it would carry.
    let (would, t) = env.json(&["automation", "test", "crash-fix", "--event", "FATAL db timeout"]);
    assert!(would, "{t}");
    assert_eq!(t["would_run"], true);
    assert_eq!(t["guard"]["verdict"], "go");
    assert_eq!(t["event"], "FATAL db timeout");

    let runner = Runner(
        env.command(&["--json", "automation", "runner"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    // The runner starts the watch within its first pass; give tail a moment to open the file.
    std::thread::sleep(Duration::from_secs(2));
    let mut f = fs::OpenOptions::new().append(true).open(&log).unwrap();
    writeln!(f, "INFO fine\nFATAL db timeout\nFATAL db timeout again").unwrap();
    drop(f);

    let deadline = Instant::now() + Duration::from_secs(30);
    while !seen.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    let text = fs::read_to_string(&seen).unwrap_or_default();
    assert_eq!(text, "FATAL db timeout\nFATAL db timeout again\n", "one event for the burst");

    // A second burst inside the cooldown is dropped and counted.
    let mut f = fs::OpenOptions::new().append(true).open(&log).unwrap();
    writeln!(f, "FATAL again").unwrap();
    drop(f);
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut dropped = 0;
    while dropped == 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(300));
        dropped = env.json(&["automation", "show", "crash-fix"]).1["dropped_events"]
            .as_u64()
            .unwrap_or(0);
    }
    assert_eq!(dropped, 1);
    drop(runner);

    let (_, history) = env.json(&["automation", "history", "crash-fix"]);
    let runs = history["runs"].as_array().unwrap();
    assert_eq!(runs.len(), 1, "{history}");
    assert_eq!(runs[0]["trigger"], "watch");
    assert_eq!(runs[0]["state"], "succeeded");

    // In the cooldown, test says why it would not run, and exits 1.
    let (would, t) = env.json(&["automation", "test", "crash-fix"]);
    assert!(!would);
    assert_eq!(t["guard"]["verdict"], "cooldown");
}

#[test]
fn a_condition_decides_and_its_output_joins_the_prompt() {
    let env = Env::new("cond");
    let (ok, _) = env.json(&[
        "automation",
        "create",
        "errors-up",
        "--every",
        "10m",
        "--if",
        "read line; case \"$line\" in *spike*) echo \"rate 4x: $line\";; *) exit 1;; esac",
        "--prompt",
        "Find why the error rate jumped and open a fix PR.",
    ]);
    assert!(ok);
    let (would, t) =
        env.json(&["automation", "test", "errors-up", "--event", "spike in db errors"]);
    assert!(would, "{t}");
    assert_eq!(t["condition"]["result"], "go");
    let prompt = t["prompt"].as_str().unwrap();
    assert!(prompt.contains("Find why the error rate jumped"), "{prompt}");
    assert!(prompt.contains("rate 4x: spike in db errors"), "{prompt}");
    assert!(prompt.contains("not instructions"), "{prompt}");

    let (would, t) = env.json(&["automation", "test", "errors-up", "--event", "all quiet"]);
    assert!(!would);
    assert_eq!(t["condition"]["result"], "no");

    // A manual run goes through the condition too, and records why it skipped.
    let (_, run) = env.json(&["automation", "run", "errors-up", "--event", "all quiet", "--wait"]);
    let id = run["id"].as_str().unwrap().to_string();
    let (_, history) = env.json(&["automation", "history", "errors-up"]);
    let row = history["runs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == id.as_str())
        .unwrap()
        .clone();
    assert_eq!(
        (row["state"].as_str(), row["reason"].as_str()),
        (Some("skipped"), Some("condition_false"))
    );
}
