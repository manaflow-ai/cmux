//! Install = deploy + pin (docs/app-store-platonic-ideal.md 8, 8a, 15): an
//! app with a manifest `deploy` block runs its container on a target the
//! person picks in the consent card, and its remote pane opens the running
//! instance.
//!
//! One runner for every target. A target only says how to reach a shell on
//! the machine; the same POSIX script then starts the container (docker or
//! podman, whichever the machine has), waits for the health path and prints
//! the instance URL:
//!
//! - `self-hosted:<ssh destination>`: a machine the customer runs (its own
//!   Linux VM or server, reached over SSH or Tailscale SSH). Nothing on this
//!   path calls cmux Cloud, so an enterprise adopts the store with no cmux
//!   Cloud account.
//! - `cloud-vm:<machine id>`: the person's cmux Cloud machine, reached with
//!   `cmux cloud exec`. Creating a machine for the app is not part of this
//!   slice: the target names an existing machine.
//!
//! The instance binds to the machine's tailnet address when it has one
//! (`tailscale ip -4`), else to 127.0.0.1, never to every interface: an
//! instance is private by default (P11).
//!
//! The install commits first and answers at once with the instance in state
//! `deploying`; a worker thread runs the script and records `running` with
//! the URL, or rolls the install back (container removed, install undone)
//! with the reason in the app's log. Every change is an `apps-changed`
//! event, so no client polls. Instances persist in
//! `<state>/apps-instances.json`, owned by this module.

use cmux_process::{Command, Stdio};
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::supervisor::{ApiError, Out, Supervisor, now_ms};
use crate::panic_free::{JsonFields as _, RecoverPoison as _};

/// Where an app's container runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(into = "String", try_from = "String")]
pub enum Target {
    /// A machine the customer runs, by SSH destination (`user@host`, an
    /// alias from `~/.ssh/config`, or a tailnet name).
    SelfHosted { host: String },
    /// The person's cmux Cloud machine, by id.
    CloudVm { machine: String },
    /// The team VM (named so the manifest check can refuse it; no runner yet).
    TeamVm { team: String },
}

impl Target {
    /// Parses `self-hosted:<host>`, `cloud-vm:<machine>` or `team-vm:<team>`.
    pub fn parse(text: &str) -> Result<Self, ApiError> {
        let bad = || {
            ApiError::new(
                "deploy.target_invalid",
                "deploy.target is self-hosted:<ssh host>, cloud-vm:<machine id> or team-vm:<team>",
            )
        };
        let (kind, value) = text.split_once(':').ok_or_else(bad)?;
        let host_ok = |v: &str| {
            !v.is_empty()
                && v.len() <= 253
                && !v.starts_with('-')
                && v.chars().all(|c| c.is_ascii_alphanumeric() || "._@-".contains(c))
        };
        let id_ok = |v: &str| {
            !v.is_empty()
                && v.len() <= 128
                && v.chars().all(|c| c.is_ascii_alphanumeric() || "_-".contains(c))
        };
        match kind {
            "self-hosted" if host_ok(value) => Ok(Self::SelfHosted { host: value.to_string() }),
            "cloud-vm" if id_ok(value) => Ok(Self::CloudVm { machine: value.to_string() }),
            "team-vm" if id_ok(value) => Ok(Self::TeamVm { team: value.to_string() }),
            _ => Err(bad()),
        }
    }

    /// The manifest `deploy.targets` name of this target.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::SelfHosted { .. } => "self-hosted",
            Self::CloudVm { .. } => "cloud-vm",
            Self::TeamVm { .. } => "team-vm",
        }
    }
}

impl From<Target> for String {
    fn from(target: Target) -> Self {
        match target {
            Target::SelfHosted { host } => format!("self-hosted:{host}"),
            Target::CloudVm { machine } => format!("cloud-vm:{machine}"),
            Target::TeamVm { team } => format!("team-vm:{team}"),
        }
    }
}

impl TryFrom<String> for Target {
    type Error = String;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        Self::parse(&text).map_err(|e| e.message)
    }
}

/// The manifest's `deploy.server`, checked again here (the validator already
/// refused shell characters; the runner never trusts a package twice-removed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerSpec {
    pub image: String,
    pub port: u16,
    pub health: String,
}

impl ServerSpec {
    pub fn from_manifest(manifest: &Value) -> Result<Self, ApiError> {
        let server = manifest.field("deploy").field("server");
        let bad = |what: &str| {
            ApiError::new("deploy.invalid", format!("deploy.server.{what} is invalid"))
        };
        let image = server["image"].as_str().ok_or_else(|| bad("image"))?;
        if image.is_empty()
            || image.len() > 255
            || !image.chars().all(|c| c.is_ascii_alphanumeric() || "._/:@-".contains(c))
        {
            return Err(bad("image"));
        }
        let port = server["port"]
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p > 0)
            .ok_or_else(|| bad("port"))?;
        let health = server["health"].as_str().ok_or_else(|| bad("health"))?;
        if !health.starts_with('/')
            || !health.chars().all(|c| c.is_ascii_alphanumeric() || "._~/-".contains(c))
        {
            return Err(bad("health"));
        }
        Ok(Self { image: image.to_string(), port, health: health.to_string() })
    }
}

/// The container name of an app: its namespace (`manaflow-ai/hello-deploy`
/// -> `cmux-app-manaflow_ai.hello_deploy`).
pub fn container_name(app: &str) -> String {
    format!("cmux-app-{}", cmux_app_manifest::app_namespace(app))
}

/// How many seconds the health check waits.
const HEALTH_TRIES: u32 = 60;

/// The runner: start the container, wait for health, print the URL.
pub fn deploy_script(app: &str, spec: &ServerSpec) -> String {
    let name = container_name(app);
    format!(
        r#"set -eu
# docker, else docker through passwordless sudo (a host whose operator keeps the docker group
# closed), else podman.
engine=""
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then engine="docker"
  elif sudo -n docker info >/dev/null 2>&1; then engine="sudo -n docker"; fi
fi
if [ -z "$engine" ] && command -v podman >/dev/null 2>&1; then engine="podman"; fi
if [ -z "$engine" ]; then echo "cmux-deploy: this machine has no docker or podman this user may run" >&2; exit 20; fi
bind="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
[ -n "$bind" ] || bind=127.0.0.1
$engine rm -f {name} >/dev/null 2>&1 || true
$engine run -d --restart unless-stopped --name {name} --label cmux.app={app} -p "$bind::{port}" {image} >/dev/null
hostport="$($engine port {name} {port}/tcp | head -n 1 | sed 's/.*://')"
tries=0
until curl -fsS -o /dev/null "http://127.0.0.1:$hostport{health}" 2>/dev/null || curl -fsS -o /dev/null "http://$bind:$hostport{health}" 2>/dev/null || wget -q -O /dev/null "http://$bind:$hostport{health}" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -ge {tries} ]; then
    echo "cmux-deploy: health check failed at {health}" >&2
    $engine logs --tail 20 {name} >&2 2>&1 || true
    $engine rm -f {name} >/dev/null 2>&1 || true
    exit 21
  fi
  sleep 1
done
echo "cmux-deploy-url=http://$bind:$hostport/"
"#,
        name = name,
        app = app,
        port = spec.port,
        image = spec.image,
        health = spec.health,
        tries = HEALTH_TRIES,
    )
}

/// Removes the app's container (best effort; absent is fine).
pub fn stop_script(app: &str) -> String {
    format!(
        "for engine in docker \"sudo -n docker\" podman; do $engine rm -f {} >/dev/null 2>&1 && break; done; exit 0\n",
        container_name(app)
    )
}

/// The URL the runner printed.
pub fn parse_url(output: &str) -> Option<String> {
    output.lines().rev().find_map(|line| line.strip_prefix("cmux-deploy-url=")).map(str::to_string)
}

/// A shell on the target machine that runs one script.
pub trait RemoteShell {
    fn run(&self, script: &str) -> Result<String, String>;
}

/// `ssh -o BatchMode=yes -- <host> sh -s` with the script on stdin: the
/// person's own SSH setup (keys, `~/.ssh/config`, Tailscale SSH) reaches the
/// self-hosted machine; cmux holds no credential for it.
pub struct Ssh {
    pub host: String,
}

impl RemoteShell for Ssh {
    fn run(&self, script: &str) -> Result<String, String> {
        run_with_stdin(
            Command::new("ssh").args([
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=20",
                "--",
                &self.host,
                "sh",
                "-s",
            ]),
            script,
        )
    }
}

/// `cmux cloud exec --target machine:<id> --command 'sh -c ...'`: the person's
/// cmux Cloud machine through the cmux app's own Cloud sign-in.
pub struct CloudExec {
    pub machine: String,
}

impl RemoteShell for CloudExec {
    fn run(&self, script: &str) -> Result<String, String> {
        let cli = std::env::current_exe().map_err(|e| e.to_string())?;
        let quoted = format!("sh -c '{}'", script.replace('\'', r"'\''"));
        run_with_stdin(
            Command::new(cli).args([
                "cloud",
                "exec",
                "--target",
                &format!("machine:{}", self.machine),
                "--command",
                &quoted,
            ]),
            "",
        )
    }
}

/// Runs `command` (a cmux_process child: only descriptors 0-2 pass, never a
/// PTY master or a ring of the daemon) with `input` on stdin; its stdout, or
/// the tail of its stderr when it fails.
fn run_with_stdin(command: &mut Command, input: &str) -> Result<String, String> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start the remote shell: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if output.status.success() {
        return Ok(stdout);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let tail: Vec<&str> = stderr.lines().rev().take(12).collect();
    Err(tail.into_iter().rev().collect::<Vec<_>>().join("\n"))
}

/// The shell of `target`, or why it has none.
pub fn shell_for(target: &Target) -> Result<Box<dyn RemoteShell + Send>, ApiError> {
    match target {
        Target::SelfHosted { host } => Ok(Box::new(Ssh { host: host.clone() })),
        Target::CloudVm { machine } => Ok(Box::new(CloudExec { machine: machine.clone() })),
        Target::TeamVm { .. } => Err(ApiError::new(
            "deploy.target_unsupported",
            "team-vm deploys are not available yet; use self-hosted or cloud-vm",
        )),
    }
}

/// An instance's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstanceState {
    Deploying,
    Running,
}

/// A running deployment of an app's server (`inst_…`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Instance {
    pub id: String,
    pub app: String,
    pub target: Target,
    pub state: InstanceState,
    pub url: Option<String>,
    pub started_ms: u64,
}

/// The instances of this machine's apps, one per app.
#[derive(Default)]
pub(super) struct Deployments {
    instances: Mutex<BTreeMap<String, Instance>>,
}

impl Deployments {
    fn file(dir: Option<&std::path::Path>) -> Option<PathBuf> {
        dir.map(|d| d.join("apps-instances.json"))
    }

    pub(super) fn load(dir: Option<&std::path::Path>) -> Self {
        let instances = Self::file(dir)
            .and_then(|f| std::fs::read(f).ok())
            .and_then(|raw| serde_json::from_slice::<BTreeMap<String, Instance>>(&raw).ok())
            .unwrap_or_default();
        Self { instances: Mutex::new(instances) }
    }

    fn save(&self, dir: Option<&std::path::Path>, instances: &BTreeMap<String, Instance>) {
        let Some(file) = Self::file(dir) else { return };
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let temp = file.with_extension("json.tmp");
        if let Ok(body) = serde_json::to_vec_pretty(instances)
            && std::fs::write(&temp, body).is_ok()
        {
            let _ = std::fs::rename(&temp, &file);
        }
    }

    /// The instance of `app`, as JSON (null without one).
    pub(super) fn json(&self, app: &str) -> Value {
        let instances = self.instances.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        instances.get(app).map_or(Value::Null, |i| json!(i))
    }
}

/// `cmux.apps.install` params (the page's `grant_optional` and an optional deploy).
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct InstallParams {
    pub app: String,
    pub idempotency_key: String,
    #[serde(default)]
    pub grant_optional: Option<bool>,
    #[serde(default)]
    pub deploy: Option<DeployRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DeployRequest {
    pub target: String,
}

impl Supervisor {
    /// After the install committed: checks the target against the manifest,
    /// records the instance as deploying, and starts the runner off the
    /// request. The caller checked origin user and installed the app.
    pub(super) fn deploy_checked(
        &self,
        app: &str,
        request: &DeployRequest,
    ) -> Result<(Target, ServerSpec), ApiError> {
        let manifest = {
            let inner = self.inner.lock().recover_poison();
            inner.catalog.packages.get(app).map(|p| p.manifest.clone())
        }
        .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        if manifest.get("deploy").is_none() {
            return Err(ApiError::new("deploy.none", "this app has nothing to deploy"));
        }
        let target = Target::parse(&request.target)?;
        let allowed = manifest
            .field("deploy")
            .field("targets")
            .as_array()
            .is_some_and(|targets| targets.iter().any(|t| t == target.kind()));
        if !allowed {
            return Err(ApiError::new(
                "deploy.target_not_allowed",
                format!("{app} does not deploy to {}", target.kind()),
            ));
        }
        shell_for(&target)?;
        Ok((target, ServerSpec::from_manifest(&manifest)?))
    }

    /// Records `app`'s instance as deploying and runs the runner on a worker
    /// thread; returns the instance as JSON.
    pub(super) fn deploy_start(
        &self,
        app: &str,
        key: &str,
        target: Target,
        spec: ServerSpec,
    ) -> Value {
        let instance = Instance {
            id: format!("inst_{:x}{:04x}", now_ms(), key.len()),
            app: app.to_string(),
            target: target.clone(),
            state: InstanceState::Deploying,
            url: None,
            started_ms: now_ms(),
        };
        self.instance_set(app, Some(instance.clone()), "deploying");
        let me = self.me.clone();
        let app = app.to_string();
        let key = key.to_string();
        let started = std::thread::Builder::new().name("cmux-app-deploy".into()).spawn(move || {
            let result = shell_for(&target).map_err(|e| e.message).and_then(|shell| {
                shell.run(&deploy_script(&app, &spec)).and_then(|out| {
                    parse_url(&out).ok_or_else(|| "the runner printed no URL".to_string())
                })
            });
            let Some(me) = me.upgrade() else { return };
            me.deploy_finished(&app, &key, &target, result);
        });
        if let Err(error) = started {
            self.deploy_finished(&instance.app, "spawn", &instance.target, Err(error.to_string()));
        }
        json!(instance)
    }

    fn deploy_finished(
        &self,
        app: &str,
        key: &str,
        target: &Target,
        result: Result<String, String>,
    ) {
        match result {
            Ok(url) => {
                let current = {
                    let instances = self.deployments.instances.lock().recover_poison();
                    instances.get(app).cloned()
                };
                // The app was removed while it deployed: its uninstall stops the container.
                let Some(mut instance) = current else { return };
                instance.state = InstanceState::Running;
                instance.url = Some(url.clone());
                self.instance_set(app, Some(instance), "running");
                self.app_log(
                    app,
                    "info",
                    format!("deployed to {}: {url}", String::from(target.clone())),
                );
            }
            Err(reason) => {
                self.app_log(
                    app,
                    "error",
                    format!(
                        "deploy to {} failed, install rolled back: {reason}",
                        String::from(target.clone())
                    ),
                );
                if let Ok(shell) = shell_for(target) {
                    let _ = shell.run(&stop_script(app));
                }
                self.instance_set(app, None, "failed");
                let _ = self.set(
                    0,
                    super::mirror::SetOp {
                        key: format!("{key}.rollback"),
                        app: app.to_string(),
                        origin: super::mirror::Origin::User,
                        installed: Some(false),
                        ..Default::default()
                    },
                );
            }
        }
    }

    /// On uninstall: drops the instance and removes its container off the request.
    pub(super) fn deploy_remove(&self, app: &str) {
        let removed = {
            let mut instances = self.deployments.instances.lock().recover_poison();
            instances.remove(app)
        };
        let Some(instance) = removed else { return };
        self.deployments.save(
            self.config.state_dir.as_deref(),
            &self.deployments.instances.lock().recover_poison(),
        );
        self.instance_changed(app, "removed");
        let app = app.to_string();
        let _ = std::thread::Builder::new().name("cmux-app-undeploy".into()).spawn(move || {
            if let Ok(shell) = shell_for(&instance.target) {
                let _ = shell.run(&stop_script(&app));
            }
        });
    }

    fn instance_set(&self, app: &str, instance: Option<Instance>, why: &str) {
        {
            let mut instances = self.deployments.instances.lock().recover_poison();
            match instance {
                Some(instance) => instances.insert(app.to_string(), instance),
                None => instances.remove(app),
            };
            self.deployments.save(self.config.state_dir.as_deref(), &instances);
        }
        self.instance_changed(app, why);
    }

    fn instance_changed(&self, app: &str, why: &str) {
        let revision = self.inner.lock().recover_poison().mirror.revision;
        self.emit(vec![Out::Broadcast(json!({
            "event": "apps-changed",
            "revision": revision,
            "transaction": format!("deploy-{why}"),
            "app": app,
        }))]);
    }

    fn app_log(&self, app: &str, level: &str, message: String) {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            self.log_locked(&mut inner, app, level, message)
        };
        self.emit(outs);
    }

    /// The instance of `app` for list rows (null without one).
    pub(super) fn instance_json(&self, app: &str) -> Value {
        self.deployments.json(app)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn targets_parse_and_refuse_option_like_hosts() {
        assert_eq!(
            Target::parse("self-hosted:ops@build-01.corp").unwrap(),
            Target::SelfHosted { host: "ops@build-01.corp".into() }
        );
        assert_eq!(
            Target::parse("cloud-vm:m_123").unwrap(),
            Target::CloudVm { machine: "m_123".into() }
        );
        for bad in
            ["self-hosted:-oProxyCommand=x", "self-hosted:a b", "cloud-vm:", "nowhere", "local:x"]
        {
            assert!(Target::parse(bad).is_err(), "{bad}");
        }
        assert_eq!(String::from(Target::parse("self-hosted:h").unwrap()), "self-hosted:h");
    }

    #[test]
    fn server_spec_refuses_shell_characters() {
        let manifest = |image: &str, health: &str| json!({"deploy": {"server": {"kind": "container", "image": image, "port": 80, "health": health}}});
        let spec =
            ServerSpec::from_manifest(&manifest("docker.io/traefik/whoami:v1.10", "/health"))
                .unwrap();
        assert_eq!(spec.port, 80);
        assert!(ServerSpec::from_manifest(&manifest("busybox; rm -rf /", "/health")).is_err());
        assert!(ServerSpec::from_manifest(&manifest("busybox", "/$(id)")).is_err());
    }

    #[test]
    fn the_runner_binds_privately_and_prints_the_url() {
        let spec = ServerSpec {
            image: "docker.io/traefik/whoami:v1.10".into(),
            port: 80,
            health: "/health".into(),
        };
        let script = deploy_script("manaflow-ai/hello-deploy", &spec);
        assert!(script.contains("--name cmux-app-manaflow_ai.hello_deploy"), "{script}");
        assert!(script.contains("-p \"$bind::80\""), "never every interface: {script}");
        assert!(script.contains("tailscale ip -4"), "{script}");
        assert!(
            script.contains("sudo -n docker info"),
            "a closed docker group falls back to sudo -n: {script}"
        );
        assert_eq!(
            parse_url("noise\ncmux-deploy-url=http://100.64.0.9:49153/\n"),
            Some("http://100.64.0.9:49153/".into())
        );
        assert_eq!(parse_url("nothing"), None);
        assert!(
            stop_script("manaflow-ai/hello-deploy")
                .contains("rm -f cmux-app-manaflow_ai.hello_deploy")
        );
    }

    #[test]
    fn team_vm_has_no_runner_yet() {
        assert!(shell_for(&Target::TeamVm { team: "t".into() }).is_err());
        assert!(shell_for(&Target::SelfHosted { host: "h".into() }).is_ok());
    }
}
