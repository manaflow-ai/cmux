//! Cloud reserves its initial workspace before accepting clients, but starts
//! the shell only after attach preparation has installed the machine's grant.

use super::*;

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
            reservation.prepared_output = Some(output);
            reservation.prepared_instance = cloud_instance(&options);
            self.workspace_registry.lock().unwrap().save_cloud_bootstrap(&reservation)?;
        }
        // A copied pending registry must not transfer the original machine's
        // grant, and suppression still applies to a prepared-but-unstarted shell.
        let initial_output = reservation.prepared_output.clone().unwrap_or_default();
        let mutation = WorkspaceMutation::new(
            format!("cloud-terminal-{}", reservation.operation_id),
            "cloud-bootstrap",
        )?;
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .context("initial Cloud workspace disappeared")?;
        let mut fields = Map::new();
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
        let commit =
            self.commit_resource_topology_operation(operation, selectors, fields, None, &mutation)?;
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
        && cloud_instance(options).as_deref() == instance.as_str()
}

fn render_cloud_welcome(options: &SurfaceOptions) -> anyhow::Result<Vec<u8>> {
    use std::process::{Command, Stdio};
    let output = match Command::new("/usr/local/bin/cmux")
        .args(["welcome", "--bootstrap"])
        .envs(options.extra_env.iter().map(|(key, value)| (key, value)))
        .env("COLUMNS", options.cols.to_string())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn mux() -> Arc<Mux> {
        let root = std::env::temp_dir()
            .join(format!("cmux-cloud-grant-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let files = [
            ("CMUX_CLOUD_WELCOME_INSTANCE_PATH", "instance", "original-instance"),
            ("CMUX_CLOUD_WELCOME_IDENTITY_PATH", "identity", "original-vm"),
            ("CMUX_CLOUD_WELCOME_PENDING_PATH", "pending", "original-vm"),
        ];
        let mut options = SurfaceOptions::default();
        options.extra_env.extend([
            ("CMUX_CLOUD_WELCOME".into(), "1".into()),
            ("CMUX_CLOUD_WELCOME_SHOWN".into(), String::new()),
        ]);
        for (key, file, value) in files {
            let path = root.join(file);
            std::fs::write(&path, value).unwrap();
            options.extra_env.push((key.into(), path.to_string_lossy().into_owned()));
        }
        Mux::new_for_test("cloud-bootstrap", options)
    }

    #[test]
    fn cloud_bootstrap_defers_shell_and_serializes_first_attachments() {
        let mux = mux();
        assert!(mux.reserve_cloud_initial_workspace().unwrap());
        let first = mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert!(state.surfaces.is_empty());
            state.workspaces[0].id
        });
        assert!(mux.rename_workspace(first, "my project".into()));
        let renders = Arc::new(AtomicUsize::new(0));
        let threads = (0..8)
            .map(|_| {
                let mux = mux.clone();
                let renders = renders.clone();
                std::thread::spawn(move || {
                    mux.start_cloud_initial_terminal_with_renderer(true, || {
                        renders.fetch_add(1, Ordering::Relaxed);
                        Ok(b"CLOUD-GUIDE\r\n".to_vec())
                    })
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().unwrap();
        }
        let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before.terminals.len(), 1);
        assert_eq!(renders.load(Ordering::Relaxed), 1);
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .unwrap();
        assert!(mux.reserve_cloud_initial_workspace().unwrap());
        let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before, after);
        let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
        assert_eq!(
            surface
                .with_terminal(|terminal| terminal.plain_text())
                .unwrap()
                .unwrap()
                .matches("CLOUD-GUIDE")
                .count(),
            1
        );
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, first);
            assert_eq!(state.workspaces[0].name, "my project");
        });
    }

    #[test]
    fn cloud_bootstrap_does_not_claim_preexisting_or_deleted_workspaces() {
        let existing = mux();
        let workspace = existing.create_empty_workspace(None, None, None).unwrap();
        assert!(existing.close_workspace(workspace.workspace));
        assert!(!existing.reserve_cloud_initial_workspace().unwrap());
        existing.start_cloud_initial_terminal(true).unwrap();
        assert!(existing.with_state(|state| state.workspaces.is_empty()));

        let deleted = mux();
        deleted.reserve_cloud_initial_workspace().unwrap();
        let first = deleted.with_state(|state| state.workspaces[0].id);
        assert!(deleted.close_workspace(first));
        // Simulate startup's reservation recovery before a later attach.
        assert!(deleted.reserve_cloud_initial_workspace().unwrap());
        assert!(deleted.with_state(|state| state.workspaces.is_empty()));
        deleted.start_cloud_initial_terminal(true).unwrap();
        deleted.reserve_cloud_initial_workspace().unwrap();
        assert!(deleted.with_state(|state| state.workspaces.is_empty()));
    }

    #[test]
    fn cloud_bootstrap_leaves_user_startup_content_untouched() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        let first = mux.with_state(|state| state.workspaces[0].id);
        mux.create_terminal_in_workspace(
            first,
            Some(vec!["user-command".into()]),
            None,
            None,
            None,
        )
        .unwrap();
        let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .unwrap();
        let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
        assert_eq!(before, after);
    }

    #[test]
    fn cloud_bootstrap_retries_failed_creation_without_an_extra_workspace() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        let first = mux.with_state(|state| state.workspaces[0].key.clone());
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
        assert!(
            mux.start_cloud_initial_terminal_with_renderer(
                true,
                || Ok(b"CLOUD-GUIDE\r\n".to_vec())
            )
            .is_err()
        );
        assert!(
            !mux.workspace_registry.lock().unwrap().cloud_bootstrap().unwrap().unwrap().finished
        );
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .unwrap();
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].key, first);
        });
        assert_eq!(
            mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap().terminals.len(),
            1
        );
    }

    #[test]
    fn cloud_bootstrap_retries_renderer_failure_before_creating_a_terminal() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        assert!(
            mux.start_cloud_initial_terminal_with_renderer(true, || {
                anyhow::bail!("fixture renderer failure")
            })
            .is_err()
        );
        assert!(mux.with_state(|state| state.surfaces.is_empty()));
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .unwrap();
        let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
        assert!(
            surface
                .with_terminal(|terminal| terminal.plain_text())
                .unwrap()
                .unwrap()
                .contains("CLOUD-GUIDE")
        );
        mux.start_cloud_initial_terminal_with_renderer(true, || panic!("must not render twice"))
            .unwrap();
    }

    #[test]
    fn cloud_bootstrap_preserves_explicit_argv_and_skips_ineligible_shells() {
        let mux = mux();
        let command = vec!["codex".into(), "exec".into(), "keep this input".into()];
        mux.surface_options.lock().unwrap().command = Some(command.clone());
        mux.reserve_cloud_initial_workspace().unwrap();
        mux.start_cloud_initial_terminal_with_renderer(true, || {
            panic!("agent startup must stay quiet")
        })
        .unwrap();
        let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
        assert_eq!(surface.spawn_argv(), Some(command));
        assert!(
            !surface
                .with_terminal(|terminal| terminal.plain_text())
                .unwrap()
                .unwrap()
                .contains("CLOUD-GUIDE")
        );

        let quiet = Mux::new_for_test("later-machine", SurfaceOptions::default());
        quiet.reserve_cloud_initial_workspace().unwrap();
        quiet
            .start_cloud_initial_terminal_with_renderer(false, || panic!("ineligible machine"))
            .unwrap();
    }

    #[test]
    fn cloud_bootstrap_rechecks_grant_and_suppression_after_preparation_failure() {
        for suppressed in [false, true] {
            let mux = mux();
            mux.reserve_cloud_initial_workspace().unwrap();
            mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
            assert!(
                mux.start_cloud_initial_terminal_with_renderer(true, || Ok(
                    b"CLOUD-GUIDE\r\n".to_vec()
                ))
                .is_err()
            );
            mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
            if suppressed {
                mux.surface_options
                    .lock()
                    .unwrap()
                    .extra_env
                    .push(("CMUX_CLOUD_WELCOME".into(), "0".into()));
            } else {
                // A fork can copy pending output, but the supervisor binds the
                // resumed daemon to a different platform instance before boot.
                let options = mux.surface_options.lock().unwrap();
                let path = &options
                    .extra_env
                    .iter()
                    .find(|(key, _)| key == "CMUX_CLOUD_WELCOME_INSTANCE_PATH")
                    .unwrap()
                    .1;
                std::fs::write(path, "forked-instance").unwrap();
            }
            mux.start_cloud_initial_terminal_with_renderer(suppressed, || {
                panic!("already prepared")
            })
            .unwrap();
            let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
            assert!(
                !surface
                    .with_terminal(|terminal| terminal.plain_text())
                    .unwrap()
                    .unwrap()
                    .contains("CLOUD-GUIDE")
            );
        }
    }
    #[test]
    fn cloud_bootstrap_targets_the_reserved_workspace_without_changing_focus() {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        let first = mux.with_state(|state| state.workspaces[0].id);
        let later = mux.new_workspace(Some("another project".into()), None).unwrap();
        let focused = mux.with_state(|state| state.workspaces[state.active_workspace].id);
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .unwrap();
        assert_eq!(mux.with_state(|state| state.workspaces[state.active_workspace].id), focused);
        assert!(
            !later
                .with_terminal(|terminal| terminal.plain_text())
                .unwrap()
                .unwrap()
                .contains("CLOUD-GUIDE")
        );
        let starter = mux.with_state(|state| {
            state.workspaces.iter().find(|workspace| workspace.id == first).unwrap().key.clone()
        });
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_snapshot()
                .unwrap()
                .terminals
                .iter()
                .filter(|terminal| terminal.workspace_key == starter)
                .count(),
            1
        );
    }
}
