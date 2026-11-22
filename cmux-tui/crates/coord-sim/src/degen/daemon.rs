//! A scratch acpmux daemon: its own state folder, HOME, socket and PATH, the stand-in agent
//! (acpmux's `tests/fake_agent.py`) as its only harness. Started, stopped and killed here by the pid
//! this process got when it started it; never another daemon.

use super::run::{Run, round};
use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How to start a daemon: the binary and the stand-in agent.
#[derive(Clone)]
pub struct Recipe {
    pub acpmux: PathBuf,
    pub fake: PathBuf,
    pub python: PathBuf,
}

impl Recipe {
    pub fn from_args(args: &[String]) -> Result<Recipe, String> {
        let acpmux = match crate::flag(args, "--acpmux") {
            Some(p) => PathBuf::from(p),
            None => std::env::var_os("COORD_SIM_ACPMUX").map(PathBuf::from).ok_or(
                "--acpmux BIN (or COORD_SIM_ACPMUX) is required: the acpmux binary to start as the scratch daemon",
            )?,
        };
        let fake = match crate::flag(args, "--fake-agent") {
            Some(p) => PathBuf::from(p),
            None => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../acpmux/tests/fake_agent.py"),
        };
        let abs =
            |p: PathBuf| std::fs::canonicalize(&p).map_err(|e| format!("{}: {e}", p.display()));
        let python =
            which("python3").ok_or("python3 is not on PATH (the stand-in agent needs it)")?;
        Ok(Recipe { acpmux: abs(acpmux)?, fake: abs(fake)?, python })
    }
}

fn which(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .and_then(|p| std::env::split_paths(&p).map(|d| d.join(name)).find(|c| c.is_file()))
}

/// A scratch root: `<tmp>/csd-<pid>-<tag>`, short so the socket path fits.
pub struct Scratch {
    pub root: PathBuf,
    /// The daemon's state folder (`ACPMUX_HOME`).
    pub home: PathBuf,
    pub socket: PathBuf,
    recipe: Recipe,
}

pub fn private_dir(p: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(p).map_err(|e| format!("{}: {e}", p.display()))?;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("{}: {e}", p.display()))
}

/// A file only its owner may read or write: the daemon refuses a config others may write.
pub fn private_file(p: &Path, text: &str) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(p, text).map_err(|e| format!("{}: {e}", p.display()))?;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("{}: {e}", p.display()))
}

impl Scratch {
    /// `home` set: the daemon's state folder lives there (a small filesystem), not under the root.
    pub fn new(recipe: &Recipe, tag: &str, home: Option<PathBuf>) -> Result<Scratch, String> {
        let base = std::env::var_os("COORD_SIM_SCRATCH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        let root = base.join(format!("csd-{}-{tag}", std::process::id()));
        if root.exists() {
            // Ours: this pid and tag.
            let _ = std::fs::remove_dir_all(&root);
        }
        for d in ["", "home", "bin", "tmp", "work"] {
            private_dir(&root.join(d))?;
        }
        std::os::unix::fs::symlink(&recipe.python, root.join("bin/python3"))
            .map_err(|e| e.to_string())?;
        let home = home.unwrap_or_else(|| root.join("amx"));
        private_dir(&home)?;
        let config = json!({"harnesses": {"fake": {"argv": ["python3", recipe.fake]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all"});
        private_file(&home.join("config.json"), &config.to_string())?;
        Ok(Scratch { socket: root.join("s.sock"), root, home, recipe: recipe.clone() })
    }

    /// An `acpmux` command in the hermetic environment: nothing from the host but what is set here.
    pub fn cmd(&self) -> Command {
        // umask 077: the daemon refuses a state folder group or others may write, whatever the
        // caller's umask. `exec` keeps the pid: the one this process kills is acpmux's own.
        let mut c = Command::new("/bin/sh");
        c.arg("-c").arg("umask 077; exec \"$@\"").arg("sh").arg(&self.recipe.acpmux);
        c.env_clear()
            .current_dir(self.root.join("work"))
            .env("PATH", format!("{}:/usr/bin:/bin", self.root.join("bin").display()))
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", self.root.join("tmp"))
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .env("ACPMUX_SESSION_CPU_CLASS", "normal")
            .env("ACPMUX_SPARE_HARNESS", "0")
            .env("ACPMUX_TEST_SESSION_TMP_BASE", self.root.join("tmp"))
            .env("ACPMUX_TEST_OWNER_PID", format!("{}", std::process::id()))
            .env("FLEET_ORIGIN", "coord-sim")
            .stdin(Stdio::null());
        c
    }

    /// `acpmux ARGS` against this daemon, its output, and how long it took.
    pub fn cli(&self, args: &[&str]) -> Result<(std::process::Output, f64), String> {
        let t = Instant::now();
        let out = self
            .cmd()
            .args(args)
            .output()
            .map_err(|e| format!("acpmux {}: {e}", args.join(" ")))?;
        Ok((out, t.elapsed().as_secs_f64() * 1000.0))
    }

    /// `acpmux --json ARGS`, parsed; Err with stderr when it failed.
    pub fn cli_json(&self, args: &[&str]) -> Result<Value, String> {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let (out, _) = self.cli(&all)?;
        if !out.status.success() {
            return Err(format!(
                "acpmux {}: {} {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            ));
        }
        serde_json::from_slice(&out.stdout).map_err(|e| format!("acpmux {}: {e}", args.join(" ")))
    }

    /// A session made with `new -d -n NAME`: its id.
    pub fn new_session(&self, name: &str) -> Result<String, String> {
        let v = self.cli_json(&["new", "-d", "-n", name])?;
        v.get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or(format!("new {name}: no sessionId: {v}"))
    }

    pub fn start(&self) -> Result<Daemon, String> {
        Daemon::start(self)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        if std::env::var_os("COORD_SIM_KEEP_SCRATCH").is_none() {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

pub struct Daemon {
    child: Option<Child>,
    pub pid: u32,
    pub ready_ms: f64,
}

impl Daemon {
    fn start(s: &Scratch) -> Result<Daemon, String> {
        let n = count_logs(&s.root) + 1;
        let log = s.root.join(format!("daemon-{n}.log"));
        // Its ready line (and its stdout log) go to a file this process reads: no pipe to drain.
        let out = s.root.join(format!("daemon-{n}.out"));
        let err = std::fs::File::create(&log).map_err(|e| e.to_string())?;
        let ready = std::fs::File::create(&out).map_err(|e| e.to_string())?;
        let t = Instant::now();
        let mut cmd = s.cmd();
        cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn"]);
        let mut child = cmd
            .stdin(Stdio::null())
            .current_dir(s.root.join("work"))
            .stdout(ready)
            .stderr(err)
            .spawn()
            .map_err(|e| format!("start daemon: {e}"))?;
        let pid = child.id();
        loop {
            let text = std::fs::read_to_string(&out).unwrap_or_default();
            if text.contains("\"ready\":true") {
                break;
            }
            let gone = matches!(child.try_wait(), Ok(Some(_)) | Err(_));
            if gone || t.elapsed() > Duration::from_secs(300) {
                let _ = child.kill();
                let _ = child.wait();
                let text = std::fs::read_to_string(&log).unwrap_or_default();
                let tail: String =
                    text.chars().rev().take(2000).collect::<Vec<_>>().into_iter().rev().collect();
                return Err(format!("daemon not ready (exited: {gone}): {tail}"));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(Daemon { child: Some(child), pid, ready_ms: t.elapsed().as_secs_f64() * 1000.0 })
    }

    pub fn alive(&mut self) -> bool {
        matches!(self.child.as_mut().map(|c| c.try_wait()), Some(Ok(None)))
    }

    /// Waits up to `within` for the daemon to exit on its own (nothing is sent to it): the ms it
    /// took, or None while it still runs.
    pub fn wait_exit(&mut self, within: Duration) -> Option<f64> {
        let t = Instant::now();
        loop {
            match self.child.as_mut().map(|c| c.try_wait()) {
                Some(Ok(None)) => {}
                _ => {
                    self.child = None;
                    return Some(t.elapsed().as_secs_f64() * 1000.0);
                }
            }
            if t.elapsed() > within {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGTERM to this daemon's own pid, then waits for it to exit (SIGKILL after `within`).
    pub fn term(&mut self, within: Duration) -> Result<f64, String> {
        let t = Instant::now();
        let Some(mut child) = self.child.take() else { return Ok(0.0) };
        let _ = Command::new("kill").args(["-TERM", &self.pid.to_string()]).status();
        loop {
            if let Ok(Some(_)) = child.try_wait() {
                break;
            }
            if t.elapsed() > within {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "daemon {} did not exit {} s after SIGTERM: killed",
                    self.pid,
                    within.as_secs()
                ));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(t.elapsed().as_secs_f64() * 1000.0)
    }

    /// Stops the daemon and every agent it runs: `daemon shutdown --end-agents`, then this pid.
    pub fn stop(&mut self, s: &Scratch) {
        if self.child.is_none() {
            return;
        }
        let _ = s
            .cmd()
            .args(["daemon", "shutdown", "--end-agents"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = self.term(Duration::from_secs(10));
    }
}

fn count_logs(root: &Path) -> usize {
    std::fs::read_dir(root)
        .map(|d| {
            d.filter_map(Result::ok)
                .filter(|e| e.file_name().to_string_lossy().starts_with("daemon-"))
                .count()
        })
        .unwrap_or(0)
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// One sample of the daemon's own gauges (`gauges` in `_acpmux/status`: it reads its own memory):
/// resident and peak bytes, and the bytes queued per connection (`server/queue_gauge.rs`).
#[derive(Default, Clone, Debug)]
pub struct ProcSample {
    pub rss_kb: u64,
    pub hwm_kb: u64,
    pub queues: Value,
}

pub fn sample(conn: &mut super::rpc::Conn) -> Result<ProcSample, String> {
    let s = conn.call("_acpmux/status", json!({}), Duration::from_secs(10))?;
    let g = s.get("gauges").cloned().unwrap_or(Value::Null);
    let kb =
        |k: &str| g.pointer(&format!("/memory/{k}")).and_then(Value::as_u64).unwrap_or(0) / 1024;
    Ok(ProcSample {
        rss_kb: kb("rssBytes"),
        hwm_kb: kb("peakRssBytes"),
        queues: g.get("queues").cloned().unwrap_or(Value::Null),
    })
}

/// Samples the daemon on `socket` every 100 ms into proc.ndjson (connecting again after a restart),
/// on a thread of the case's scope: stopped when dropped, joined by the scope.
pub struct Sampler<'s> {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::ScopedJoinHandle<'s, (u64, u64)>>,
    /// The most bytes the daemon held queued for all connections at once, and its overrun count
    /// (readers it disconnected for being past their bound).
    pub max_queued: Arc<AtomicU64>,
    pub overruns: Arc<AtomicU64>,
}

impl Drop for Sampler<'_> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl<'s> Sampler<'s> {
    pub fn start<'e>(sc: &'s std::thread::Scope<'s, 'e>, run: &Run, socket: &Path) -> Sampler<'s> {
        let stop = Arc::new(AtomicBool::new(false));
        let (max_queued, overruns) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
        let (mq, ov) = (max_queued.clone(), overruns.clone());
        let (s, run, socket) = (stop.clone(), run.clone(), socket.to_path_buf());
        let handle = sc.spawn(move || {
            let (mut peak, mut first) = (0u64, 0u64);
            let mut conn: Option<super::rpc::Conn> = None;
            while !s.load(Ordering::SeqCst) {
                if conn.is_none() {
                    conn = super::rpc::Conn::connect(&socket).ok();
                }
                let got = conn.as_mut().map(sample);
                match got {
                    Some(Ok(x)) => {
                        peak = peak.max(x.rss_kb).max(x.hwm_kb);
                        if first == 0 {
                            first = x.rss_kb;
                        }
                        mq.fetch_max(
                            x.queues.get("bytes").and_then(Value::as_u64).unwrap_or(0),
                            Ordering::SeqCst,
                        );
                        ov.fetch_max(
                            x.queues.get("overruns").and_then(Value::as_u64).unwrap_or(0),
                            Ordering::SeqCst,
                        );
                        run.procs.write(&json!({"t_ms": round(run.t_ms()), "rss_kb": x.rss_kb,
                            "hwm_kb": x.hwm_kb, "queues": x.queues}));
                    }
                    Some(Err(_)) => conn = None,
                    None => {}
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            (first, peak)
        });
        Sampler { stop, handle: Some(handle), max_queued, overruns }
    }

    /// (first RSS, peak RSS) in KB.
    pub fn finish(mut self) -> (u64, u64) {
        self.stop.store(true, Ordering::SeqCst);
        self.handle.take().and_then(|h| h.join().ok()).unwrap_or((0, 0))
    }
}
