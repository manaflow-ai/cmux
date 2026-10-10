//! Launch and adoption entry points of a daemon-side attachment: a new host
//! (on a standby process, `sys::StandbyTerminalHost`, or a fresh one), a
//! one-shot owner connection, and a surface adoption bounded by the Kitty
//! graphics quota.

use std::fs;
use std::path::PathBuf;

use super::super::super::sys::{
    self, StandbyTerminalHost, prepare_endpoint_dir, reserve_terminal_host_publication,
};
use super::super::codec::{HostLaunch, encode_hex, read_required_frame};
use super::super::host_state::kitty_graphics_limits_within;
use super::super::records::validate_terminal_host_record;
use super::*;

pub fn launch_terminal_host(
    options: &SurfaceOptions,
    root: &Path,
    default_colors: DefaultColors,
    cell_pixels: (u16, u16),
    kitty_graphics_limits: KittyGraphicsLimits,
) -> anyhow::Result<HostAttachment> {
    let terminal_id = TerminalId::random()?;
    launch_terminal_host_with_identity(
        options,
        root,
        default_colors,
        cell_pixels,
        kitty_graphics_limits,
        terminal_id,
    )
}

/// Launch using a registry-reserved stable UUID. The workspace registry
/// can commit identity/placement before process creation, eliminating the
/// launch-window orphan race without changing the host wire protocol.
pub fn launch_terminal_host_with_identity(
    options: &SurfaceOptions,
    root: &Path,
    default_colors: DefaultColors,
    cell_pixels: (u16, u16),
    kitty_graphics_limits: KittyGraphicsLimits,
    terminal_id: TerminalId,
) -> anyhow::Result<HostAttachment> {
    let (colors, kitty) = (default_colors, kitty_graphics_limits);
    launch_terminal_host_from(options, root, colors, cell_pixels, kitty, terminal_id, None)
}

/// A one-shot owner connection (for example to terminate a host no
/// surface adopted). It never takes clipboard reads; surfaces adopt with
/// [`adopt_terminal_host_with_kitty_limits`].
pub fn adopt_terminal_host(
    record: TerminalHostRecord,
    record_path: PathBuf,
) -> anyhow::Result<HostAttachment> {
    validate_terminal_host_record(&record_path, &record)?;
    let mut attachment = connect_record(record, record_path, OwnerIntent::OneShot)?;
    attachment.activate_launched_host()?;
    Ok(attachment)
}

pub(crate) fn adopt_current_terminal_host(
    record: TerminalHostRecord,
    record_path: PathBuf,
) -> anyhow::Result<HostAttachment> {
    validate_terminal_host_record(&record_path, &record)?;
    connect_current_record_with_timeout(
        record,
        record_path,
        HOST_HANDSHAKE_TIMEOUT,
        OwnerIntent::Surface,
    )
}

pub(crate) fn adopt_terminal_host_with_kitty_limits(
    record: TerminalHostRecord,
    record_path: PathBuf,
    ceiling: KittyGraphicsLimits,
) -> anyhow::Result<HostAttachment> {
    let ceiling = ceiling
        .validate()
        .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
    let connect = |record: TerminalHostRecord, record_path: PathBuf| {
        if record.record_version >= HOST_RECORD_VERSION {
            // Current records guarantee the current smart protocol. Keep
            // startup and reconnect head-of-line blocking to one bounded
            // handshake; only legacy records need version probing.
            adopt_current_terminal_host(record, record_path)
        } else {
            connect_record(record, record_path, OwnerIntent::Surface)
        }
    };
    let mut attachment = connect(record.clone(), record_path.clone())?;
    if kitty_graphics_limits_within(attachment.snapshot.kitty_state.limits, ceiling) {
        attachment.activate_launched_host()?;
        return Ok(attachment);
    }

    attachment.reconfigure_kitty_graphics_for_adoption(ceiling)?;
    attachment.activate_launched_host()?;
    attachment.disconnect();
    drop(attachment);

    let attachment = connect(record, record_path)?;
    anyhow::ensure!(
        kitty_graphics_limits_within(attachment.snapshot.kitty_state.limits, ceiling),
        "terminal host retained Kitty graphics state above its adoption quota"
    );
    Ok(attachment)
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
    let presentation = (default_colors, cell_pixels, kitty_graphics_limits);
    launch_terminal_host_seeded(options, root, presentation, terminal_id, standby, &[])
}

/// The default colors, cell pixel size and Kitty limits a host starts with.
pub(crate) type HostPresentation = (DefaultColors, (u16, u16), KittyGraphicsLimits);

/// [`launch_terminal_host_from`] whose host applies `seed` (VT replay) to
/// its parser before the child's first byte and never writes it to the PTY
/// (cx-6so.49 L2: a respawned terminal shows its previous screen).
pub(crate) fn launch_terminal_host_seeded(
    options: &SurfaceOptions,
    root: &Path,
    (default_colors, cell_pixels, kitty_graphics_limits): HostPresentation,
    terminal_id: TerminalId,
    standby: Option<StandbyTerminalHost>,
    seed: &[u8],
) -> anyhow::Result<HostAttachment> {
    let launch_publication_lock = reserve_terminal_host_publication(root)?;
    crate::debug_spans::mark("host.publication_reserved");
    let owner_token = CapabilityToken::random()?;
    let terminal_hex = encode_hex(terminal_id.as_bytes());
    // macOS limits sockaddr_un paths to roughly one hundred bytes and
    // TMPDIR is commonly already longer than that. Keep the transport
    // endpoint short; the private durable record still carries its full
    // canonical identity and owner capability.
    let uid = sys::file_owner(root)?;
    let endpoint_root = sys::endpoint_dir(uid);
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
        seed: seed.to_vec(),
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
