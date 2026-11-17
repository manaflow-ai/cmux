//! Publish and rollback: infer, pin source, stage, start, probe, then promote. Nothing reaches
//! the platform until the version answered its probe on this machine.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use crate::infer::Inferred;
use crate::io::{Clock, Fs, Git, Launch, Listeners, Probe, Procs};
use crate::platform::{PlatformApi, Promote};
use crate::slug::slugify;
use crate::state::{self, AppState, Version, VersionState};

pub const PROBE_TIMEOUT: Duration = Duration::from_secs(60);
pub const SETUP_LIMIT: Duration = Duration::from_secs(600);
const PROBE_INTERVAL: Duration = Duration::from_millis(500);
const LOG_TAIL: usize = 64 * 1024;
/// The caller's variables an app process gets; everything else (`CMUX_*`, Cloud, agent, GitHub
/// and MCP credentials) stays out.
const PASSED_THROUGH: [&str; 3] = ["PATH", "LANG", "TZ"];

/// The machine a publish runs on.
pub struct Host<'a> {
    pub fs: &'a dyn Fs,
    pub git: &'a dyn Git,
    pub procs: &'a dyn Procs,
    pub clock: &'a dyn Clock,
    pub probe: &'a dyn Probe,
    pub platform: &'a dyn PlatformApi,
    /// Who listens on a port (this machine's agent answers, for the caller's own processes).
    pub listeners: &'a dyn Listeners,
    /// The apps store: `apps` under cmux's state root.
    pub apps_root: PathBuf,
    /// The caller's environment, read only for [`PASSED_THROUGH`].
    pub parent_env: Vec<(String, String)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublishRequest {
    pub name: Option<String>,
    pub port: Option<u16>,
    pub cmd: Option<String>,
    pub dir: Option<PathBuf>,
    pub git_ref: String,
    pub include_dirty: bool,
    pub share_team: bool,
    /// The caller's working directory, for a `--cmd` with no `--dir` and no `--port`.
    pub cwd: PathBuf,
    pub probe_timeout: Duration,
    pub setup_limit: Duration,
}

impl PublishRequest {
    pub fn new(cwd: PathBuf) -> PublishRequest {
        PublishRequest {
            name: None,
            port: None,
            cmd: None,
            dir: None,
            git_ref: "HEAD".to_owned(),
            include_dirty: false,
            share_team: false,
            cwd,
            probe_timeout: PROBE_TIMEOUT,
            setup_limit: SETUP_LIMIT,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Published {
    pub app: AppState,
    pub version: Version,
    pub url: String,
    pub inferred: Option<Inferred>,
    pub warnings: Vec<String>,
}

/// A refused or failed publish or rollback. `version` is the recorded version when one was made.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
    pub version: Option<Version>,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Failure {
        Failure { code, message: message.into(), version: None }
    }

    /// A refusal of the command line (exit 2), not a failure while running it.
    pub fn is_usage(&self) -> bool {
        self.code == "usage.invalid"
    }
}

/// The whole environment of an app process: [`PASSED_THROUGH`], `HOME`, `PORT` and the
/// literal values of the app's `service.env`.
pub fn app_env(
    parent: &[(String, String)],
    home: &Path,
    port: Option<u16>,
    service_env: &[(String, String)],
) -> Vec<(String, String)> {
    unimplemented!("red: app_env")
}

/// `.cmux/apps/<slug>/app.json`'s `service`: its `setup` command and literal `env` strings.
struct Service {
    setup: Option<String>,
    env: Vec<(String, String)>,
}

fn service(fs: &dyn Fs, tree: &Path, slug: &str) -> Result<Service, String> {
    let path = state::spec_file(tree, slug);
    let Ok(bytes) = fs.read(&path) else { return Ok(Service { setup: None, env: vec![] }) };
    let spec: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!(".cmux/apps/{slug}/app.json: {e}"))?;
    let service = spec.get("service").cloned().unwrap_or(Value::Null);
    let setup = service.get("setup").and_then(Value::as_str).map(str::to_owned);
    let env = service
        .get("env")
        .and_then(Value::as_object)
        .map(|map| {
            map.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned()))).collect()
        })
        .unwrap_or_default();
    Ok(Service { setup, env })
}

pub fn publish(host: &Host<'_>, req: &PublishRequest) -> Result<Published, Failure> {
    unimplemented!("red: publish")
}

/// `GET /` on the version's port until it answers 2xx or 3xx, the process exits, or `timeout`.
fn probe(host: &Host<'_>, pid: u32, port: u16, timeout: Duration) -> Result<(), String> {
    let deadline = host.clock.now_ms() + timeout.as_millis() as u64;
    loop {
        let last = match host.probe.get(port, "/") {
            Ok(status) if (200..400).contains(&status) => return Ok(()),
            Ok(status) => format!("GET / answered {status}"),
            Err(e) => e,
        };
        if !host.procs.alive(pid) {
            return Err(format!("the process exited before it answered on port {port} ({last})"));
        }
        if host.clock.now_ms() >= deadline {
            return Err(format!(
                "no 2xx or 3xx on port {port} within {} s ({last})",
                timeout.as_secs()
            ));
        }
        host.clock.sleep(PROBE_INTERVAL);
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RolledBack {
    pub app: AppState,
    pub version: Version,
    pub url: String,
}

/// `live` back to `to`, else the newest retired version before it. That version's process is
/// restarted on its own port first when it no longer runs, and must pass its probe again.
pub fn rollback(
    host: &Host<'_>,
    slug: &str,
    to: Option<u32>,
    timeout: Duration,
) -> Result<RolledBack, Failure> {
    unimplemented!("red: rollback")
}
