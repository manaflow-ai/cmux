//! Terminals whose shell the holder runs (`holder_runtime`): a new one, and
//! one a previous daemon of the session left running.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
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
        let HolderCommand { spawn_argv, argv, env, cwd } = holder_command(&spawn.opts);
        let request = SpawnRequest {
            id: *terminal_id.as_bytes(),
            cols: spawn.opts.cols,
            rows: spawn.opts.rows,
            px_w: spawn.opts.cols.saturating_mul(spawn.cell_pixels.0),
            px_h: spawn.opts.rows.saturating_mul(spawn.cell_pixels.1),
            cwd: cwd.clone().into_bytes(),
            argv: spawn_argv.into_iter().map(String::into_bytes).collect(),
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
        let kitty_reservation = match adoption
            .mux
            .upgrade()
            .map(|mux| mux.reserve_kitty_image_surface(adoption.id))
            .transpose()
        {
            Ok(reservation) => reservation,
            Err(error) => {
                // The shell stays on the holder for the next start (QUIT P0: a
                // start never ends a shell a person still has).
                service.detach(terminal.chan);
                service.untrack(terminal.chan);
                return Err(error);
            }
        };
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
        let adopted = Self::run_on_holder(
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
        );
        if adopted.is_err() {
            // No surface shows it: leave the shell on the holder, which lists
            // it to the next start again (QUIT P0: a start never ends a shell
            // a person still has; the row keeps it, `adopt_from_holder_or_end`).
            service.detach(terminal.chan);
            service.untrack(terminal.chan);
        }
        adopted.map(Some)
    }

    fn run_on_holder(
        terminal: &Arc<HolderTerminal>,
        spawn: LocalSpawn,
        (command, cwd): (Vec<String>, Option<String>),
    ) -> anyhow::Result<Arc<Surface>> {
        let surface = Self::spawn_local(spawn, holder_local_launch(terminal, command, cwd)?)?;
        let weak = Arc::downgrade(&surface);
        terminal.set_replay(Box::new(move |max_bytes, at_point| match weak.upgrade() {
            Some(surface) => match surface.as_pty() {
                Some(pty) => holder_prologue(pty, max_bytes, at_point),
                None => {
                    at_point();
                    Vec::new()
                }
            },
            None => {
                at_point();
                Vec::new()
            }
        }));
        Ok(surface)
    }
}

/// A VT replay of the daemon's parsed screen (screen, modes, title,
/// directory and the newest history that fits in `max_bytes`) plus its
/// OSC 9;4 progress, ending with the incomplete sequence the parser is
/// inside: a new holder's prologue after a holder crash, or a snapshot the
/// holder keeps for a restarted daemon. Empty when it does not fit: a later
/// restart then shows only the output since.
///
/// `at_point` runs under the terminal lock, at the instant the replay
/// shows: the reader confirms each chunk under the same lock
/// (`HolderSink::confirm_parsed`), so what it reads there matches the
/// replay byte for byte.
fn holder_prologue(pty: &PtySurface, max_bytes: usize, at_point: &mut dyn FnMut()) -> Vec<u8> {
    let (replay, progress) = {
        let mut term = pty.term.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        at_point();
        // The reader updates the progress under the terminal lock too.
        let progress = pty
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .osc_progress()
            .to_owned();
        (term.vt_replay_bounded(max_bytes), progress)
    };
    let Ok(replay) = replay else { return Vec::new() };
    let mut bytes = replay.bytes;
    if !progress.is_empty() {
        bytes.extend_from_slice(format!("\x1b]9;{progress}\x1b\\").as_bytes());
    }
    // Last, right before the live stream that completes it: an escape
    // sequence or UTF-8 character the holder's crash cut in two.
    bytes.extend_from_slice(&replay.pending_sequence);
    if bytes.len() > max_bytes { Vec::new() } else { bytes }
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

/// What a new holder shell runs.
struct HolderCommand {
    /// The argv the holder starts: the frontend's shell through login(1)
    /// on macOS, as the hosted path starts it (`login_shell`).
    spawn_argv: Vec<String>,
    /// The launch command the surface records (the shell's own argv).
    argv: Vec<String>,
    /// The full environment, `KEY=VALUE`.
    env: Vec<Vec<u8>>,
    cwd: String,
}

/// The argv, full environment and directory of a new holder shell: what
/// the hosted path runs (`terminal_host_runtime::spawn_host_runtime`), with
/// the daemon's environment spelled out because the holder passes exactly
/// these.
fn holder_command(opts: &SurfaceOptions) -> HolderCommand {
    let launch =
        crate::shell_integration::shell_launch(opts.command.clone(), opts.extra_env.clone());
    let env = holder_environment(&launch, opts, std::env::vars_os().collect());
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
    // A frontend's shell starts through login(1) (`login_shell`): a login
    // shell, a utmpx record, and "Last login" as the first paint. The
    // holder's CLOSE signals every process group on the PTY, so the shell
    // under login(1) ends with it.
    let spawn_argv = crate::login_shell::wrap(&launch.command, &launch.env)
        .unwrap_or_else(|| launch.command.clone());
    HolderCommand { spawn_argv, argv: launch.command, env, cwd }
}

/// The holder child's environment: the daemon's own, then the terminal
/// identity, then the launch's injected values, less
/// [`cmux_pty::UNSET_IN_TERMINAL_CHILDREN`]. The holder gets
/// the whole environment spelled out, so the removal happens here rather than
/// through `PtyCommand::env_remove` as on the other two child paths.
fn holder_environment(
    launch: &crate::shell_integration::ShellLaunch,
    opts: &SurfaceOptions,
    inherited: BTreeMap<OsString, OsString>,
) -> BTreeMap<OsString, OsString> {
    let mut env = inherited;
    env.insert("TERM".into(), opts.term.clone().into());
    env.insert("COLORTERM".into(), "truecolor".into());
    for (key, value) in &launch.env {
        if !crate::login_shell::is_marker(key) {
            env.insert(key.into(), value.into());
        }
    }
    for key in crate::shell_integration::keys_to_unset_in_child(&launch.env) {
        env.remove(OsStr::new(key));
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frontend's shell on the holder starts through login(1), as on the
    /// hosted path: a login shell whose `$0` starts with `-`, with
    /// `.zprofile`, a utmpx record and "Last login" as its first paint. The
    /// surface still records the shell's own argv, and the marker never
    /// reaches the shell.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_marked_frontend_shell_starts_through_login_as_on_the_hosted_path() {
        let shell = vec!["/bin/zsh".to_string()];
        let opts = SurfaceOptions {
            command: Some(shell.clone()),
            extra_env: vec![(crate::login_shell::MARKER.to_string(), "1".to_string())],
            ..SurfaceOptions::default()
        };
        let Some(expected) = crate::login_shell::wrap(&shell, &opts.extra_env) else {
            // An isolated HOME or no /usr/bin/login: the hosted path does
            // not wrap either.
            eprintln!("login(1) start not available here; nothing to compare");
            return;
        };
        let command = holder_command(&opts);
        assert_eq!(command.spawn_argv, expected);
        assert_eq!(command.spawn_argv[0], "/usr/bin/login");
        assert_eq!(command.spawn_argv.last(), Some(&"/bin/zsh".to_string()));
        assert_eq!(command.argv, shell, "the recorded command stays the shell's");
        let marker = format!("{}=", crate::login_shell::MARKER);
        assert!(
            !command.env.iter().any(|entry| entry.starts_with(marker.as_bytes())),
            "the marker reaches the shell"
        );
    }

    #[test]
    fn inherited_terminal_version_is_not_kept_for_holder_children() {
        let launch = crate::shell_integration::ShellLaunch {
            command: vec!["/bin/zsh".to_string()],
            env: vec![("TERM_PROGRAM_VERSION".to_string(), "1.3.2".to_string())],
        };
        let inherited =
            BTreeMap::from([(OsString::from("TERM_PROGRAM_VERSION"), OsString::from("1.3.2"))]);

        let environment = holder_environment(&launch, &SurfaceOptions::default(), inherited);

        assert!(!environment.contains_key(OsStr::new("TERM_PROGRAM_VERSION")));
        assert_eq!(environment.get(OsStr::new("COLORTERM")), Some(&OsString::from("truecolor")));
    }
}
