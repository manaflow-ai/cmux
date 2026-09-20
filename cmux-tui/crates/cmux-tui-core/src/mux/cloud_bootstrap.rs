//! Cloud reserves its initial workspace before accepting clients, but starts
//! the shell only after attach preparation has installed the machine's grant.

use super::*;

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
    pub fn start_cloud_initial_terminal(self: &Arc<Self>, welcome: bool) -> anyhow::Result<()> {
        let options = self.surface_options.lock().unwrap().clone();
        self.start_cloud_initial_terminal_with_renderer(welcome, || render_cloud_welcome(&options))
    }

    fn start_cloud_initial_terminal_with_renderer(
        self: &Arc<Self>,
        welcome: bool,
        render: impl FnOnce() -> anyhow::Result<Vec<u8>>,
    ) -> anyhow::Result<()> {
        let _bootstrap = self.lock_initial_bootstrap();
        let reservation = self.workspace_registry.lock().unwrap().cloud_bootstrap()?;
        let Some(mut reservation) = reservation.filter(|entry| !entry.finished) else {
            return Ok(());
        };
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
            return Ok(());
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
            return Ok(());
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
        let resolution =
            self.workspace_registry.lock().unwrap().resolve_resource_creation(&correlation)?;
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
                if error
                    .downcast_ref::<ResourceError>()
                    .is_some_and(|error| error.code == "cloud.bootstrap_occupied") =>
            {
                self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        self.emit_resource_topology_legacy_events(operation, &commit);
        self.workspace_registry.lock().unwrap().finish_cloud_bootstrap(reservation)?;
        Ok(())
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
        .map(|(_, value)| value.as_str())
        .unwrap_or(default);
    let mut value = String::new();
    std::fs::File::open(path).ok()?.take(257).read_to_string(&mut value).ok()?;
    (value.len() <= 256).then(|| value.trim().to_owned()).filter(|value| !value.is_empty())
}

fn cloud_instance(options: &SurfaceOptions) -> Option<String> {
    cloud_file(options, "CMUX_CLOUD_WELCOME_INSTANCE_PATH", "/etc/cmux/daemon-instance-id")
}

pub(super) fn cloud_welcome_output_allowed(options: &SurfaceOptions, instance: &Value) -> bool {
    let identity = cloud_file(
        options,
        "CMUX_CLOUD_WELCOME_IDENTITY_PATH",
        "/etc/cmux/.cloud-welcome-machine-id",
    );
    let grant =
        cloud_file(options, "CMUX_CLOUD_WELCOME_PENDING_PATH", "/etc/cmux/.cloud-welcome-pending");
    cloud_welcome_enabled(options)
        && identity.is_some()
        && identity == grant
        && instance.as_str().is_some_and(|identity| !identity.is_empty())
        && cloud_instance(options).as_deref() == instance.as_str()
}

#[cfg(unix)]
fn render_cloud_welcome(options: &SurfaceOptions) -> anyhow::Result<Vec<u8>> {
    use std::process::Command;
    let mut command = Command::new("/usr/local/bin/cmux");
    command
        .args(["welcome", "--bootstrap"])
        .envs(options.extra_env.iter().map(|(key, value)| (key, value)))
        .env("COLUMNS", options.cols.to_string());
    let output = match renderer::capture(&mut command, Duration::from_secs(2)) {
        Ok(output) => output,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    // Older guest shims reject this private preparation mode. Their shell must
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
