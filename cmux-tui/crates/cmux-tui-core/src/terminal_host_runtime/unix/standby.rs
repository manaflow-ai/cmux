//! A terminal-host process started ahead of its terminal (R81).

use super::*;

/// A terminal-host process started before its terminal exists (R81: a
/// new tab then skips the process start, most of its launch). It has run
/// only `exec` and waits on its bootstrap pipe: no identity, no PTY, no
/// child, no timers, so it uses no CPU. Dropping it exact-kills it; a
/// daemon exit closes its pipe, and the host exits.
pub(crate) struct StandbyTerminalHost {
    pub(super) process: SpawnedHostProcess,
    pub(super) stdin: std::process::ChildStdin,
    pub(super) stdout: std::process::ChildStdout,
    pub(super) host_pid: u32,
}

impl StandbyTerminalHost {
    pub(crate) fn spawn() -> anyhow::Result<Self> {
        // Exec the daemon's own running build (open inode on Linux): after an
        // in-place binary upgrade, resolving the executable path yields
        // "<path> (deleted)" and exec fails, which broke every new tab/split
        // on a long-lived daemon. This also guarantees daemon and host can
        // never run skewed builds.
        let binary = crate::platform::self_exe_for_spawn()
            .context("resolve cmux-tui terminal-host binary")?;
        let mut command = Command::new(binary);
        command
            .args(["__terminal-host", "--bootstrap-stdio"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // A host outlives its daemon, so it must not retain a daemon log
            // pipe whose EOF is itself used as a lifecycle signal.
            .stderr(Stdio::null());
        // A durable host must not share the daemon's controlling terminal,
        // session, or process group. Otherwise a shell hangup or group
        // interrupt intended for the daemon can also kill every hosted PTY.
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state in
        // the post-fork child. A freshly forked child is not a process-group
        // leader, so failure is an actual launch error and must be surfaced.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        let child = command.spawn().context("spawn terminal-host process")?;
        let mut process = SpawnedHostProcess { child: Some(child) };
        let host_pid = process.child_mut().id();
        // A Cloud daemon's unit stop must not end its hosts (host_scope.rs).
        host_scope::place_host(host_pid);
        let stdin =
            process.child_mut().stdin.take().context("open terminal-host bootstrap stdin")?;
        let stdout =
            process.child_mut().stdout.take().context("open terminal-host bootstrap stdout")?;
        Ok(Self { process, stdin, stdout, host_pid })
    }

    /// A stand-in for tests: `cat` also waits on its stdin and exits at EOF.
    #[cfg(test)]
    pub(crate) fn spawn_stand_in() -> anyhow::Result<Self> {
        let mut command = Command::new("cat");
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        let mut process = SpawnedHostProcess { child: Some(command.spawn()?) };
        let host_pid = process.child_mut().id();
        let stdin = process.child_mut().stdin.take().context("stand-in stdin")?;
        let stdout = process.child_mut().stdout.take().context("stand-in stdout")?;
        Ok(Self { process, stdin, stdout, host_pid })
    }

    /// The process id, for tests.
    #[cfg(test)]
    pub(crate) fn pid(&self) -> u32 {
        self.host_pid
    }

    /// False once the process has exited (killed, or crashed before use).
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(self.process.child_mut().try_wait(), Ok(None))
    }
}

/// [`launch_terminal_host_with_identity`] on `standby`, a host process
/// started ahead of its terminal ([`StandbyTerminalHost`]), or on a fresh
/// process when `standby` is `None`. The terminal's directory, command,
/// environment and size reach the host only now, in its Launch frame.
pub(crate) fn launch_terminal_host_from(
    options: &SurfaceOptions,
    root: &Path,
    default_colors: DefaultColors,
    cell_pixels: (u16, u16),
    kitty_graphics_limits: KittyGraphicsLimits,
    terminal_id: TerminalId,
    standby: Option<StandbyTerminalHost>,
) -> anyhow::Result<HostAttachment> {
    let launch_publication_lock = reserve_terminal_host_publication(root)?;
    crate::debug_spans::mark("host.publication_reserved");
    let owner_token = CapabilityToken::random()?;
    let terminal_hex = encode_hex(terminal_id.as_bytes());
    // macOS limits sockaddr_un paths to roughly one hundred bytes and
    // TMPDIR is commonly already longer than that. Keep the transport
    // endpoint short; the private durable record still carries its full
    // canonical identity and owner capability.
    let uid = fs::metadata(root)?.uid();
    let endpoint_root = PathBuf::from("/tmp").join(format!("cmux-th-{uid}"));
    prepare_endpoint_dir(&endpoint_root)?;
    let endpoint = endpoint_root.join(format!("{terminal_hex}.sock"));
    let record_path =
        crate::platform::normalize_filesystem_path(root.join(format!("{terminal_hex}.json")));
    if record_path.exists() || endpoint.exists() {
        anyhow::bail!("terminal host identity already exists");
    }
    let shell_launch = match options.command.clone().filter(|command| !command.is_empty()) {
        Some(command) => {
            crate::shell_integration::ShellLaunch { command, env: options.extra_env.clone() }
        }
        None => crate::shell_integration::integrate_default_shell(
            vec![crate::platform::default_shell()],
            options.extra_env.clone(),
        ),
    };
    let command = shell_launch.command;
    let launch = HostLaunch {
        endpoint: endpoint.to_string_lossy().into_owned(),
        record_path: record_path.to_string_lossy().into_owned(),
        term: options.term.clone(),
        cols: options.cols,
        rows: options.rows,
        cell_pixels,
        scrollback: options.scrollback,
        cwd: options.cwd.clone().or_else(crate::platform::default_terminal_cwd),
        command,
        extra_env: shell_launch.env,
        default_colors,
        kitty_graphics_limits,
    };

    let StandbyTerminalHost { process, mut stdin, mut stdout, host_pid } = match standby {
        Some(standby) => standby,
        None => StandbyTerminalHost::spawn()?,
    };
    crate::debug_spans::mark("host.process_ready");

    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token,
    };
    write_frame(&mut stdin, &bootstrap.into_frame(1))?;
    let ready_frame = read_required_frame(&mut stdout, "bootstrap ready")?;
    if ready_frame.kind != MessageKind::Ready {
        anyhow::bail!("terminal host returned {:?} instead of Ready", ready_frame.kind);
    }
    let ready = HostReady::decode(&ready_frame.payload)?;
    crate::debug_spans::mark("host.bootstrap_ready");
    if ready.terminal_id != terminal_id {
        anyhow::bail!("terminal host changed terminal identity during bootstrap");
    }

    let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode()?);
    launch_frame.request_id = 2;
    write_frame(&mut stdin, &launch_frame)?;
    let launched_frame = read_required_frame(&mut stdout, "launch ready")?;
    if launched_frame.request_id != 2 {
        anyhow::bail!("terminal host did not acknowledge launch");
    }
    if launched_frame.kind == MessageKind::LaunchFailed {
        let failure = decode_host_launch_failure(&launched_frame.payload)?;
        return Err(failure.into());
    }
    if launched_frame.kind != MessageKind::Ready {
        anyhow::bail!("terminal host did not acknowledge launch");
    }
    let launched = HostReady::decode(&launched_frame.payload)?;
    if launched.terminal_id != terminal_id || launched.incarnation != ready.incarnation {
        anyhow::bail!("terminal host identity changed while launching PTY");
    }
    drop(stdin);
    drop(stdout);
    crate::debug_spans::mark("host.launch_ready");

    let record: TerminalHostRecord = serde_json::from_slice(
        &fs::read(&record_path).context("read terminal-host discovery record")?,
    )?;
    validate_terminal_host_record(&record_path, &record)?;
    if record.terminal_id != terminal_hex
        || record.incarnation != ready.incarnation.to_hex()
        || record.owner_token != encode_hex(owner_token.as_bytes())
        || record.host_pid != host_pid
    {
        anyhow::bail!("terminal-host discovery record changed during launch");
    }
    drop(launch_publication_lock);
    crate::debug_spans::mark("host.record_validated");
    // Keep the exact-kill guard armed through record validation and a
    // successful authenticated Snapshot. Returning Err after disarming it
    // would leave a live published host while the mux marks its registry
    // row Exited.
    let mut attachment = connect_record(record, record_path, OwnerIntent::Surface)?;
    crate::debug_spans::mark("host.connected");
    attachment.launch_process = Some(process);
    debug_assert_eq!(
        attachment.launch_activation_pending,
        attachment.protocol_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION
    );
    Ok(attachment)
}
