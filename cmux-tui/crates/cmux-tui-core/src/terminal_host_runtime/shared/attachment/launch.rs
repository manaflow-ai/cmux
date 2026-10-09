//! Launch and adoption entry points of a daemon-side attachment: a new host
//! (through the platform's `launch_terminal_host_from`), a one-shot owner
//! connection, and a surface adoption bounded by the Kitty graphics quota.

use super::super::super::sys::launch_terminal_host_from;
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
