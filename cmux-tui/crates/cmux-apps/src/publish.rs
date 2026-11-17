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
    let mut env: Vec<(String, String)> =
        parent.iter().filter(|(k, _)| PASSED_THROUGH.contains(&k.as_str())).cloned().collect();
    env.push(("HOME".to_owned(), home.display().to_string()));
    if let Some(port) = port {
        env.push(("PORT".to_owned(), port.to_string()));
    }
    for (key, value) in service_env {
        if key == "PORT" || key == "HOME" {
            continue;
        }
        env.retain(|(k, _)| k != key);
        env.push((key.clone(), value.clone()));
    }
    env
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
    // 1. What to run, and where.
    let inferred = match (req.port, &req.cmd) {
        (Some(port), None) => {
            Some(host.listeners.holder(port).map_err(|e| Failure::new("app.infer", e))?)
        }
        (Some(port), Some(_)) if req.dir.is_none() => host.listeners.holder(port).ok(),
        (None, None) => {
            return Err(Failure::new(
                "usage.invalid",
                "pass --port P to infer the command from what runs there, or --cmd CMD",
            ));
        }
        _ => None,
    };
    let command = req
        .cmd
        .clone()
        .or_else(|| inferred.as_ref().map(|i| i.command.clone()))
        .unwrap_or_default();
    let dir = req
        .dir
        .clone()
        .or_else(|| inferred.as_ref().map(|i| i.dir.clone()))
        .unwrap_or_else(|| req.cwd.clone());
    let repo = host.git.toplevel(&dir).map_err(|e| {
        Failure::new(
            "app.source",
            format!("{} is not in a git repository ({e}); pass --dir DIR", dir.display()),
        )
    })?;
    let path = dir.strip_prefix(&repo).unwrap_or(Path::new("")).display().to_string();
    let base = req.name.clone().unwrap_or_else(|| {
        dir.file_name()
            .or(repo.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    });
    let slug = slugify(&base).ok_or_else(|| {
        Failure::new("usage.invalid", format!("can't make an app name from {base:?}; pass NAME"))
    })?;
    let name = req.name.clone().unwrap_or_else(|| slug.clone());
    if req.include_dirty && req.git_ref != "HEAD" {
        return Err(Failure::new(
            "usage.invalid",
            "--include-dirty pins the work tree; it can't go with --ref",
        ));
    }
    // The platform must take this machine's word before anything is staged.
    host.platform.ready().map_err(|e| Failure::new("app.platform", e.to_string()))?;
    let machine =
        host.platform.machine().map_err(|e| Failure::new("app.platform", e.to_string()))?;
    let mut app = state::load(host.fs, &host.apps_root, &slug)
        .map_err(|e| Failure::new("app.state", e))?
        .unwrap_or_else(|| AppState::new(&name, &slug));
    let n = app.next_n();

    // 2. Pin the source to a commit.
    let dirty = req.git_ref == "HEAD"
        && host.git.dirty(&repo).map_err(|e| Failure::new("app.source", e))?;
    let commit = if dirty && !req.include_dirty {
        return Err(Failure::new(
            "app.dirty",
            format!(
                "{} has uncommitted changes; commit them, or pass --include-dirty to publish the tree as it is",
                repo.display()
            ),
        ));
    } else if dirty {
        let refname = format!("refs/cmux/apps/{slug}/v{n}");
        host.git
            .snapshot(&repo, &refname, &format!("cmux app publish {slug} v{n}"))
            .map_err(|e| Failure::new("app.source", e))?
    } else {
        host.git.resolve(&repo, &req.git_ref).map_err(|e| Failure::new("app.source", e))?
    };

    let mut version = Version {
        n,
        platform_n: None,
        commit: commit.clone(),
        command: command.clone(),
        path: path.clone(),
        port: 0,
        pid: None,
        run_as: host.procs.run_as(),
        state: VersionState::Starting,
        error: None,
        log_tail: None,
        created_at_ms: host.clock.now_ms(),
    };
    let record = |app: &mut AppState, version: &Version| {
        app.put(version.clone());
        state::save(host.fs, &host.apps_root, app).map_err(|e| Failure::new("app.state", e))
    };
    record(&mut app, &version)?;

    // 3. Stage.
    let vdir = state::version_dir(&host.apps_root, &slug, n);
    let tree = vdir.join("src");
    let fail = |app: &mut AppState,
                mut version: Version,
                code: &'static str,
                message: String,
                log: &Path| {
        version.state = VersionState::Failed;
        version.error = Some(message.clone());
        version.log_tail = Some(state::tail(host.fs, log, LOG_TAIL));
        record(app, &version)?;
        Err(Failure { code, message, version: Some(version) })
    };
    let setup_log = vdir.join("setup.log");
    if let Err(e) = host.git.archive(&repo, &commit, &tree) {
        return fail(
            &mut app,
            version,
            "app.stage",
            format!("git archive {commit}: {e}"),
            &setup_log,
        );
    }
    let workdir = if path.is_empty() { tree.clone() } else { tree.join(&path) };
    let service = match service(host.fs, &tree, &slug) {
        Ok(service) => service,
        Err(e) => return fail(&mut app, version, "app.stage", e, &setup_log),
    };
    if let Some(setup) = &service.setup {
        let env = app_env(&host.parent_env, &vdir, None, &service.env);
        let launch = Launch { command: setup, dir: &workdir, env: &env, log: &setup_log };
        if let Err(e) = host.procs.run(&launch, req.setup_limit) {
            return fail(
                &mut app,
                version,
                "app.stage",
                format!("setup `{setup}`: {e}"),
                &setup_log,
            );
        }
    }

    // 4. Start.
    let log = vdir.join("app.log");
    let port = match host.procs.free_port() {
        Ok(port) => port,
        Err(e) => return fail(&mut app, version, "app.start", format!("no free port: {e}"), &log),
    };
    version.port = port;
    let env = app_env(&host.parent_env, &vdir, Some(port), &service.env);
    let pid = match host.procs.spawn_detached(&Launch {
        command: &command,
        dir: &workdir,
        env: &env,
        log: &log,
    }) {
        Ok(pid) => pid,
        Err(e) => return fail(&mut app, version, "app.start", format!("`{command}`: {e}"), &log),
    };
    version.pid = Some(pid);
    record(&mut app, &version)?;

    // 5. Probe.
    if let Err(e) = probe(host, pid, port, req.probe_timeout) {
        host.procs.stop(pid);
        return fail(&mut app, version, "app.probe_failed", e, &log);
    }

    // 6. Promote. The attempt id is this version's number and start time on this machine.
    let attempt = format!("v{n}.{}", version.created_at_ms);
    let promoted = host.platform.ensure_app(&name, &slug).and_then(|_| {
        host.platform.promote(&slug, &Promote { commit, command, machine, port }, &attempt)
    });
    let moved = match promoted {
        Ok(moved) => moved,
        Err(e) => {
            host.procs.stop(pid);
            return fail(&mut app, version, "app.promote_failed", e.to_string(), &log);
        }
    };
    version.platform_n = moved.version.get("n").and_then(Value::as_u64).map(|n| n as u32);
    app.put(version.clone());
    app.make_live(n, &moved.url);
    state::save(host.fs, &host.apps_root, &app).map_err(|e| Failure::new("app.state", e))?;
    let version = app.version(n).cloned().unwrap_or(version);

    let mut warnings = vec![];
    if version.run_as.is_none() {
        warnings.push(
            "no unprivileged app user on this machine: the app runs as the publishing user"
                .to_owned(),
        );
    }
    if req.share_team {
        let team = moved.app.get("team").and_then(Value::as_str).unwrap_or_default();
        if let Err(e) = host.platform.share_team(&slug, team) {
            warnings.push(format!("published, but not shared with the team: {e}"));
        }
    }
    Ok(Published { app, version, url: moved.url, inferred, warnings })
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
    let mut app = state::load(host.fs, &host.apps_root, slug)
        .map_err(|e| Failure::new("app.state", e))?
        .ok_or_else(|| {
            Failure::new("app.not_found", format!("no app {slug} was published on this machine"))
        })?;
    let live = app
        .live
        .ok_or_else(|| Failure::new("app.no_live", format!("{slug} has no live version")))?;
    let target = match to {
        Some(n) => app
            .version(n)
            .cloned()
            .ok_or_else(|| Failure::new("app.no_version", format!("{slug} has no v{n}")))?,
        None => app
            .newest_first()
            .into_iter()
            .find(|v| v.n < live && v.state == VersionState::Retired)
            .cloned()
            .ok_or_else(|| {
                Failure::new(
                    "app.no_version",
                    format!("{slug} has no retired version before v{live}"),
                )
            })?,
    };
    if target.n == live {
        return Err(Failure::new("app.no_version", format!("v{} is already live", target.n)));
    }
    if target.state == VersionState::Failed || target.platform_n.is_none() {
        return Err(Failure::new(
            "app.no_version",
            format!("v{} never went live; pick a version that did", target.n),
        ));
    }
    host.platform.ready().map_err(|e| Failure::new("app.platform", e.to_string()))?;
    let mut target = target;
    if !target.pid.is_some_and(|pid| host.procs.alive(pid)) {
        if !host.procs.port_free(target.port) {
            return Err(Failure::new(
                "app.start",
                format!("port {} of v{} is taken by another process", target.port, target.n),
            ));
        }
        let vdir = state::version_dir(&host.apps_root, slug, target.n);
        let tree = vdir.join("src");
        let workdir = if target.path.is_empty() { tree.clone() } else { tree.join(&target.path) };
        let service = service(host.fs, &tree, slug).map_err(|e| Failure::new("app.stage", e))?;
        let env = app_env(&host.parent_env, &vdir, Some(target.port), &service.env);
        let log = vdir.join("app.log");
        let launch = Launch { command: &target.command, dir: &workdir, env: &env, log: &log };
        let pid = host.procs.spawn_detached(&launch).map_err(|e| Failure::new("app.start", e))?;
        if let Err(e) = probe(host, pid, target.port, timeout) {
            host.procs.stop(pid);
            return Err(Failure { code: "app.probe_failed", message: e, version: Some(target) });
        }
        target.pid = Some(pid);
        app.put(target.clone());
        state::save(host.fs, &host.apps_root, &app).map_err(|e| Failure::new("app.state", e))?;
    }
    let moved = host.platform.rollback(slug, target.platform_n).map_err(|e| Failure {
        code: "app.rollback_failed",
        message: e.to_string(),
        version: Some(target.clone()),
    })?;
    app.make_live(target.n, &moved.url);
    state::save(host.fs, &host.apps_root, &app).map_err(|e| Failure::new("app.state", e))?;
    let version = app.version(target.n).cloned().unwrap_or(target);
    Ok(RolledBack { app, version, url: moved.url })
}
