//! Terminals whose shell the holder runs (`holder_runtime`): a new one, and
//! one a previous daemon of the session left running.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;

use cmux_holder::SpawnRequest;

use super::spawn::LocalSpawn;
use super::*;
use crate::holder_runtime::{HolderService, HolderTerminal, holder_local_launch};
use crate::terminal_host_runtime::TerminalHostIdentity;

/// What [`Surface::spawn_on_holder`] starts.
pub(crate) struct HolderSpawn {
    pub(crate) id: SurfaceId,
    pub(crate) opts: SurfaceOptions,
    pub(crate) mux: Weak<Mux>,
    pub(crate) host_root: PathBuf,
    /// The registry-reserved terminal id; `None` mints one.
    pub(crate) terminal_id: Option<crate::terminal_host::TerminalId>,
    /// VT replay the parser applies before the shell's first byte (Reopen
    /// Closed of an archived terminal; empty: none).
    pub(crate) seed: Vec<u8>,
    pub(crate) terminal_public_id: Option<TerminalPublicId>,
    pub(crate) resource_identity: Option<TabResourceIdentity>,
    pub(crate) kitty_reservation: Option<crate::mux::KittyImageBudgetReservation>,
    pub(crate) initial_kitty_limits: KittyGraphicsLimits,
    pub(crate) cell_pixels: (u16, u16),
}

/// A terminal a previous daemon left on the holder (`mux::holder_adoption`).
pub(crate) struct HolderAdoption {
    pub(crate) id: SurfaceId,
    pub(crate) opts: SurfaceOptions,
    pub(crate) mux: Weak<Mux>,
    pub(crate) host_root: PathBuf,
    pub(crate) identity: TerminalHostIdentity,
    pub(crate) terminal_public_id: Option<TerminalPublicId>,
    pub(crate) resource_identity: Option<TabResourceIdentity>,
    pub(crate) cell_pixels: (u16, u16),
}

impl Surface {
    /// Start a new session-owned terminal on the holder and parse it here.
    pub(crate) fn spawn_on_holder(spawn: HolderSpawn) -> anyhow::Result<Arc<Surface>> {
        let terminal_id = match spawn.terminal_id {
            Some(terminal_id) => terminal_id,
            None => crate::terminal_host::TerminalId::random()?,
        };
        let identity = TerminalHostIdentity {
            terminal_id: terminal_id.to_hex(),
            incarnation: crate::terminal_host::TerminalId::random()?.to_hex(),
        };
        let (argv, env, cwd) = holder_command(&spawn.opts);
        let request = SpawnRequest {
            id: *terminal_id.as_bytes(),
            cols: spawn.opts.cols,
            rows: spawn.opts.rows,
            px_w: spawn.opts.cols.saturating_mul(spawn.cell_pixels.0),
            px_h: spawn.opts.rows.saturating_mul(spawn.cell_pixels.1),
            cwd: cwd.clone().into_bytes(),
            argv: argv.iter().map(|arg| arg.clone().into_bytes()).collect(),
            env,
        };
        let service = HolderService::for_root(&spawn.host_root)?;
        let terminal = service.spawn(&request, &spawn.seed)?;
        crate::debug_spans::mark("surface.holder_spawned");
        let launched = Self::run_on_holder(
            &terminal,
            LocalSpawn {
                id: spawn.id,
                initial_geometry: geometry(&spawn.opts, spawn.cell_pixels),
                opts: spawn.opts,
                mux: spawn.mux,
                terminal_public_id: spawn.terminal_public_id,
                kitty_reservation: spawn.kitty_reservation,
                initial_kitty_limits: spawn.initial_kitty_limits,
                resource_identity: spawn.resource_identity,
                lifetime: PtyLifetime::SessionOwned,
                cell_pixels: spawn.cell_pixels,
                host_identity: Some(identity),
            },
            (argv, Some(cwd)),
        );
        if launched.is_err() {
            // The surface never existed: its shell must not outlive it.
            let _ = service.close(terminal.chan, 0);
            service.untrack(terminal.chan);
        }
        launched
    }

    /// Re-attach a terminal the holder still runs after a daemon restart:
    /// its kept output replays into a fresh parser. `None` when the holder
    /// does not run it.
    pub(crate) fn adopt_on_holder(
        adoption: HolderAdoption,
    ) -> anyhow::Result<Option<Arc<Surface>>> {
        let Some(terminal_id) =
            crate::terminal_host::TerminalId::from_hex(&adoption.identity.terminal_id)
        else {
            return Ok(None);
        };
        let service = HolderService::for_root(&adoption.host_root)?;
        let Some(terminal) = service.reattach(terminal_id.as_bytes())? else { return Ok(None) };
        let mut adoption = adoption;
        // The parser starts at the PTY's size, which the last daemon set.
        if let Some((cols, rows)) = pty_size(&terminal) {
            adoption.opts.cols = cols;
            adoption.opts.rows = rows;
        }
        let kitty_reservation = adoption
            .mux
            .upgrade()
            .map(|mux| mux.reserve_kitty_image_surface(adoption.id))
            .transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let terminal_public_id = adoption.terminal_public_id.or_else(|| {
            adoption.resource_identity.as_ref().and_then(|identity| match &identity.content_id {
                ContentPublicId::Terminal(terminal) => Some(terminal.clone()),
                ContentPublicId::Browser(_) => None,
            })
        });
        let command = adoption.opts.command.clone().unwrap_or_default();
        let cwd = adoption.opts.cwd.clone();
        Self::run_on_holder(
            &terminal,
            LocalSpawn {
                id: adoption.id,
                initial_geometry: geometry(&adoption.opts, adoption.cell_pixels),
                opts: adoption.opts,
                mux: adoption.mux,
                terminal_public_id,
                kitty_reservation,
                initial_kitty_limits,
                resource_identity: adoption.resource_identity,
                lifetime: PtyLifetime::SessionOwned,
                cell_pixels: adoption.cell_pixels,
                host_identity: Some(adoption.identity),
            },
            (command, cwd),
        )
        .map(Some)
    }

    fn run_on_holder(
        terminal: &Arc<HolderTerminal>,
        spawn: LocalSpawn,
        (command, cwd): (Vec<String>, Option<String>),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_local(spawn, holder_local_launch(terminal, command, cwd)?)
    }
}

fn pty_size(terminal: &HolderTerminal) -> Option<(u16, u16)> {
    use std::os::fd::AsRawFd;
    // SAFETY: zeroed winsize is a valid out-buffer for TIOCGWINSZ.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: TIOCGWINSZ writes one winsize into a live local.
    let ok =
        unsafe { libc::ioctl(terminal.custody.as_raw_fd(), libc::TIOCGWINSZ as _, &mut size) } == 0;
    (ok && size.ws_col > 0 && size.ws_row > 0).then_some((size.ws_col, size.ws_row))
}

fn geometry(opts: &SurfaceOptions, cell_pixels: (u16, u16)) -> PtyGeometry {
    PtyGeometry {
        cols: opts.cols,
        rows: opts.rows,
        cell_width: cell_pixels.0,
        cell_height: cell_pixels.1,
    }
}

/// The argv, full environment (`KEY=VALUE`) and directory of a new holder
/// shell: what the daemon-local PTY path runs (`construct.rs`), with the
/// daemon's environment spelled out because the holder passes exactly these.
fn holder_command(opts: &SurfaceOptions) -> (Vec<String>, Vec<Vec<u8>>, String) {
    let launch = match opts.command.clone().filter(|argv| !argv.is_empty()) {
        Some(argv) => {
            crate::shell_integration::ShellLaunch { command: argv, env: opts.extra_env.clone() }
        }
        None => crate::shell_integration::integrate_default_shell(
            vec![platform::default_shell()],
            opts.extra_env.clone(),
        ),
    };
    let mut env: BTreeMap<OsString, OsString> = std::env::vars_os().collect();
    env.insert("TERM".into(), opts.term.clone().into());
    env.insert("COLORTERM".into(), "truecolor".into());
    for (key, value) in &launch.env {
        if !crate::login_shell::is_marker(key) {
            env.insert(key.into(), value.into());
        }
    }
    let env = env
        .into_iter()
        .map(|(key, value)| {
            let mut entry = key.into_vec();
            entry.push(b'=');
            entry.extend(value.into_vec());
            entry
        })
        .collect();
    let cwd =
        opts.cwd.clone().or_else(platform::default_terminal_cwd).unwrap_or_else(|| "/".into());
    (launch.command, env, cwd)
}
