//! Cloud reserves its initial workspace before accepting clients, but starts
//! the shell only at the first interactive machine-open request.

use super::*;
use serde_json::json;

#[cfg(unix)]
mod renderer;

impl Mux {
    /// Returns false for a pre-existing registry, whose sessions keep the
    /// existing bootstrap behavior. A fresh Cloud workspace has a durable key
    /// before any client can race to create its first terminal.
    pub fn reserve_cloud_initial_workspace(self: &Arc<Self>) -> anyhow::Result<bool> {
        let _bootstrap = self.lock_initial_bootstrap();
        let reservation = self.workspace_registry.lock().unwrap().reserve_cloud_bootstrap(
            &Self::new_workspace_key()?,
            &TerminalId::random()?.to_hex(),
        )?;
        let Some(reservation) = reservation else { return Ok(false) };
        let created = self
            .workspace_registry
            .lock()
            .unwrap()
            .cloud_bootstrap_workspace_created(&reservation.workspace_key)?;
        if !reservation.finished && !created {
            self.create_empty_workspace_with_mutation(
                None,
                Some(reservation.workspace_key.clone()),
                None,
                None,
                &WorkspaceMutation::new(
                    format!("cloud-workspace-{}", reservation.operation_id),
                    "cloud-bootstrap",
                )?,
            )?;
        }
        Ok(true)
    }

    /// Local control-plane preparation only: no caller-supplied command or
    /// workspace selector. The stored identities own retries and concurrency.
    pub fn start_cloud_initial_terminal(self: &Arc<Self>, welcome: bool) -> anyhow::Result<Value> {
        self.open_cloud_initial_terminal(welcome, None, None)
    }

    /// First interactive open, over the existing machine-owned control link.
    /// The daemon's durable reservation, not a name or count, selects the target.
    pub fn open_cloud_initial_terminal(
        self: &Arc<Self>,
        welcome: bool,
        machine_id: Option<&str>,
        workspace: Option<&str>,
    ) -> anyhow::Result<Value> {
        let options = self.surface_options.lock().unwrap().clone();
        self.open_cloud_initial_terminal_with_renderer(welcome, machine_id, workspace, || {
            render_cloud_welcome(&options)
        })
    }

    #[cfg(test)]
    fn start_cloud_initial_terminal_with_renderer(
        self: &Arc<Self>,
        welcome: bool,
        render: impl FnOnce() -> anyhow::Result<Vec<u8>>,
    ) -> anyhow::Result<()> {
        self.open_cloud_initial_terminal_with_renderer(welcome, None, None, render).map(|_| ())
    }

    fn open_cloud_initial_terminal_with_renderer(
        self: &Arc<Self>,
        welcome: bool,
        machine_id: Option<&str>,
        requested_workspace: Option<&str>,
        render: impl FnOnce() -> anyhow::Result<Vec<u8>>,
    ) -> anyhow::Result<Value> {
        let _bootstrap = self.lock_initial_bootstrap();
        let reservation = self.workspace_registry.lock().unwrap().cloud_bootstrap()?;
        let Some(mut reservation) = reservation else {
            return Ok(json!({"created_path": null}));
        };
        let selected = self.with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.key == reservation.workspace_key)
                .map(|workspace| (workspace.id, workspace.public_id.to_string()))
        });
        if requested_workspace
            .is_some_and(|requested| selected.as_ref().is_none_or(|(_, id)| requested != id))
        {
            return Ok(json!({"created_path": null}));
        }
        if let Some(machine_id) = machine_id {
            anyhow::ensure!(
                !machine_id.is_empty() && machine_id.len() <= 256,
                "invalid Cloud machine identity"
            );
            if reservation.machine_id.as_deref().is_some_and(|bound| bound != machine_id) {
                // A restore/fork does not inherit the original machine's grant.
                // Ordinary terminal creation remains available in the copied graph.
                return Ok(json!({"created_path": null}));
            }
            reservation.machine_id = Some(machine_id.to_owned());
        }
        if reservation.finished {
            if reservation.created_path.is_none() {
                let occupied = self.with_state(|state| {
                    state.surfaces.keys().any(|surface| {
                        self.created_resource_path_in_state(state, *surface).ok().is_some_and(
                            |path| {
                                selected.as_ref().is_some_and(|(_, id)| path["workspace_id"] == *id)
                            },
                        )
                    })
                });
                return Ok(json!({"created_path": null, "occupied": occupied}));
            }
            if let Some(id) =
                reservation.created_path.as_ref().and_then(|path| path["terminal_id"].as_str())
            {
                let id = TerminalPublicId::parse(id)?;
                let live = self.with_state(|state| state.terminal_catalog.get(&id).cloned());
                match live {
                    Some(terminal) if !terminal.is_dead() => {}
                    Some(_) => return Ok(json!({"created_path": null})),
                    None => {
                        let topology =
                            self.workspace_registry.lock().unwrap().resource_topology_snapshot()?;
                        anyhow::ensure!(
                            !topology.tabs.iter().any(|tab| {
                                tab.content_id == ContentPublicId::Terminal(id.clone())
                            }),
                            "initial Cloud terminal restoration is pending"
                        );
                        return Ok(json!({"created_path": null}));
                    }
                }
            }
            let (_, generation) = self.registry_identity();
            return Ok(json!({
                "created_path": reservation.created_path,
                "generation": generation,
                "revision": reservation.created_revision.map(|revision| revision.to_string()),
            }));
        }
        let workspace = self.with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.key == reservation.workspace_key)
                .map(|workspace| workspace.id)
        });
        let Some(workspace) = workspace else {
            // An explicitly deleted starter workspace must never be recreated.
            self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
            return Ok(json!({"created_path": null}));
        };
        // Share ordinary terminal creation's handoff guard, including the
        // user-content check, so another creator cannot fill the starter slot
        // between that check and the durable creation.
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        if self
            .workspace_registry
            .lock()
            .unwrap()
            .cloud_bootstrap_has_other_terminal(&reservation)?
        {
            // A caller already supplied initial content. Never overwrite it or
            // type into it, even if the account still has an unused grant.
            self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
            return Ok(json!({"created_path": null, "occupied": true}));
        }
        let options = self.surface_options.lock().unwrap().clone();
        let command = options.command.clone();
        let welcome = welcome && command.is_none() && cloud_welcome_enabled(&options);
        if reservation.prepared_output.is_none() {
            // A renderer failure leaves the reservation pending and creates no
            // terminal. Once prepared, retries use exactly the same bytes.
            let output = if welcome { render()? } else { Vec::new() };
            anyhow::ensure!(output.len() <= 16 * 1024, "Cloud welcome exceeds its output budget");
            reservation.prepared_instance = if !output.is_empty() {
                Some(
                    cloud_instance(&options)
                        .context("Cloud welcome platform identity is not ready")?,
                )
            } else {
                cloud_instance(&options)
            };
            reservation.prepared_output = Some(output);
            self.workspace_registry.lock().unwrap().save_cloud_bootstrap(&reservation)?;
        }
        // A copied pending registry must not transfer the original machine's
        // grant, and suppression still applies to a prepared-but-unstarted shell.
        let initial_output = reservation.prepared_output.clone().unwrap_or_default();
        let correlation = format!("cloud-terminal-{}", reservation.operation_id);
        // Reconcile an interrupted prior attempt before choosing the mutation
        // id. A raw registry lookup can return an old `do_not_retry`/stale
        // receipt and prevent the durable creation helper from selecting the
        // fresh attempt key required after a proven non-application.
        let resolution = self.resource_creation_resolution(&correlation)?;
        let mutation =
            match (resolution["idempotency_key"].as_str(), resolution["recovery"].as_str()) {
                (Some(_), Some("retry_new_idempotency_key")) => {
                    WorkspaceMutation::local("cloud-bootstrap")
                }
                (Some(id), _) => WorkspaceMutation::new(id, "cloud-bootstrap")?,
                (None, _) => WorkspaceMutation::new(&correlation, "cloud-bootstrap")?,
            };
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .context("initial Cloud workspace disappeared")?;
        let mut fields = Map::new();
        fields.insert("correlation_key".into(), Value::String(correlation));
        fields.insert("initial_output".into(), Value::String(String::from_utf8(initial_output)?));
        fields.insert(
            "cloud_welcome_instance".into(),
            serde_json::to_value(&reservation.prepared_instance)?,
        );
        let operation = if let Some(command) = command {
            fields.insert("argv".into(), serde_json::to_value(command)?);
            ResourceOperation::WorkspaceRun
        } else {
            ResourceOperation::TabCreateTerminal
        };
        // Use the same durable creation/effect pipeline as ordinary terminals.
        // It owns terminal identities, lost replies, rollback, and adoption.
        let commit = match self
            .commit_resource_topology_operation(operation, selectors, fields, None, &mutation)
        {
            Ok(commit) => commit,
            Err(error)
                if error.downcast_ref::<ResourceError>().is_some_and(|error| {
                    error.code == "operation.failed"
                        && error.details["reason"] == "cloud_bootstrap_occupied"
                }) =>
            {
                self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
                return Ok(json!({"created_path": null, "occupied": true}));
            }
            Err(error) => return Err(error),
        };
        self.emit_resource_topology_legacy_events(operation, &commit);
        reservation.created_path = Some(commit.result.clone());
        reservation.created_revision = Some(commit.revision);
        self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
        let (_, generation) = self.registry_identity();
        Ok(
            json!({"created_path": commit.result, "generation": generation, "revision": commit.revision.to_string()}),
        )
    }
}

fn cloud_welcome_enabled(options: &SurfaceOptions) -> bool {
    let value = |name: &str| {
        options
            .extra_env
            .iter()
            .rev()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
            .or_else(|| std::env::var(name).ok())
    };
    value("CMUX_CLOUD_WELCOME").as_deref() != Some("0")
        && value("CMUX_CLOUD_WELCOME_SHOWN").is_none_or(|value| value.is_empty())
}

fn cloud_file(options: &SurfaceOptions, name: &str, default: &str) -> Option<String> {
    use std::io::Read;
    let path = options
        .extra_env
        .iter()
        .rev()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.clone())
        .or_else(|| std::env::var(name).ok())
        .unwrap_or_else(|| default.to_owned());
    let mut value = String::new();
    std::fs::File::open(&path).ok()?.take(257).read_to_string(&mut value).ok()?;
    (value.len() <= 256).then(|| value.trim().to_owned()).filter(|value| !value.is_empty())
}

fn cloud_instance(options: &SurfaceOptions) -> Option<String> {
    cloud_file(options, "CMUX_CLOUD_WELCOME_INSTANCE_PATH", "/etc/cmux/daemon-instance-id")
}

pub(super) fn cloud_welcome_output_allowed(options: &SurfaceOptions, instance: &Value) -> bool {
    cloud_welcome_enabled(options)
        && instance.as_str().is_some_and(|identity| !identity.is_empty())
        && cloud_instance(options).as_deref() == instance.as_str()
}

#[cfg(unix)]
fn render_cloud_welcome(options: &SurfaceOptions) -> anyhow::Result<Vec<u8>> {
    use std::process::Command;
    let renderer = options
        .extra_env
        .iter()
        .rev()
        .find(|(key, _)| key == "CMUX_CLOUD_WELCOME_CLI")
        .map(|(_, value)| value.clone())
        .or_else(|| std::env::var("CMUX_CLOUD_WELCOME_CLI").ok())
        .unwrap_or_else(|| "/usr/local/bin/cmux".to_owned());
    let mut command = Command::new(renderer);
    command
        .args(["welcome"])
        .envs(options.extra_env.iter().map(|(key, value)| (key, value)))
        .env("COLUMNS", options.cols.to_string());
    let output = match renderer::capture(&mut command, Duration::from_secs(2)) {
        Ok(output) => output,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    // Older guest shims reject the welcome command. Their shell must
    // remain usable; no new terminal command is typed as a fallback.
    if matches!(output.status.code(), Some(2 | 127)) {
        return Ok(Vec::new());
    }
    anyhow::ensure!(output.status.success(), "Cloud welcome rendering failed");
    let text = String::from_utf8(output.stdout).context("Cloud welcome is not UTF-8")?;
    // This output enters the terminal parser directly, before PTY output, so
    // apply the newline translation a normal PTY would otherwise provide.
    Ok(text.replace("\n", "\r\n").into_bytes())
}

#[cfg(not(unix))]
fn render_cloud_welcome(_options: &SurfaceOptions) -> anyhow::Result<Vec<u8>> {
    Ok(Vec::new())
}

#[cfg(test)]
mod tests;
