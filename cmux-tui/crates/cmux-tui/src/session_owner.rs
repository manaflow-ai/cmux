use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, IsTerminal, Write};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context;
#[cfg(windows)]
use cmux_tui_core::platform;
use cmux_tui_core::platform::transport;
use wait_timeout::ChildExt;
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, DETACHED_PROCESS,
};

use crate::session::RemoteSession;

const OWNER_READY_PREFIX: &str = "cmux-tui: headless, control socket at ";
const OWNER_START_TIMEOUT: Duration = Duration::from_secs(30);
const OWNER_STOP_GRACE: Duration = Duration::from_secs(2);

pub(crate) fn connect_or_start<F>(
    raw_args: &[String],
    socket_path: &Path,
    session: &str,
    owner_options_requested: bool,
    configure_owner: F,
) -> anyhow::Result<Arc<RemoteSession>>
where
    F: FnOnce(&mut Command),
{
    require_interactive_terminal()?;

    if let Some(remote) = connect_existing(socket_path, session)? {
        if owner_options_requested {
            anyhow::bail!(
                "session {session:?} is already running; stop it before changing owner options"
            );
        }
        return Ok(remote);
    }

    #[cfg(target_os = "linux")]
    if std::env::var_os("LISTEN_FDS").is_some() {
        anyhow::bail!(
            "socket-activated sessions must start with `cmux server start` before a TUI attaches"
        );
    }

    let log_path = owner_log_path(socket_path);
    cmux_tui_core::server::prepare_server_socket_directory(socket_path)?;
    let mut child = spawn_owner(raw_args, socket_path, &log_path, configure_owner)?;
    let stdout = child.stdout.take().expect("detached owner stdout is piped");
    let (output, output_thread) = match start_output_reader(stdout) {
        Ok(reader) => reader,
        Err(error) => {
            return match terminate_starting_owner(&mut child) {
                Ok(()) => Err(error),
                Err(cleanup) => Err(anyhow::anyhow!(
                    "cannot read session owner readiness: {error}; cleanup failed: {cleanup}"
                )),
            };
        }
    };
    if let Err(error) = wait_for_owner_ready(&mut child, output, socket_path, &log_path) {
        return Err(error);
    }
    start_owner_reaper(child, output_thread);

    connect_existing(socket_path, session)?.ok_or_else(|| {
        anyhow::anyhow!(
            "session owner reported readiness but {} is unavailable; inspect {}",
            socket_path.display(),
            log_path.display()
        )
    })
}

pub(crate) fn announce_ready(socket_path: &Path) {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    // The owner must survive if its creating TUI disappears before it reads
    // this one-shot readiness message.
    let _ = writeln!(stdout, "{OWNER_READY_PREFIX}{}", socket_path.display());
    let _ = stdout.flush();
}

fn require_interactive_terminal() -> anyhow::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        anyhow::bail!(
            "interactive mode requires a terminal; use `cmux server start` for headless mode"
        );
    }
    Ok(())
}

fn connect_existing(
    socket_path: &Path,
    session: &str,
) -> anyhow::Result<Option<Arc<RemoteSession>>> {
    let stream = match transport::connect(socket_path) {
        Ok(stream) => stream,
        Err(_) => return Ok(None),
    };
    RemoteSession::connect_local_owner_stream(stream, session)
        .with_context(|| format!("cannot attach to session owner at {}", socket_path.display()))
        .map(Some)
}

fn spawn_owner<F>(
    raw_args: &[String],
    socket_path: &Path,
    log_path: &Path,
    configure_owner: F,
) -> anyhow::Result<Child>
where
    F: FnOnce(&mut Command),
{
    let log = open_owner_log(log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("--headless")
        .args(raw_args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log));
    configure_detached_process(&mut command);
    configure_owner(&mut command);
    command.spawn().with_context(|| {
        format!(
            "cannot start independent session owner for {}; inspect {}",
            socket_path.display(),
            log_path.display()
        )
    })
}

fn open_owner_log(path: &Path) -> anyhow::Result<File> {
    #[cfg(unix)]
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    #[cfg(not(unix))]
    let log = OpenOptions::new().create(true).append(true).open(path)?;

    let metadata = log.metadata()?;
    if !metadata.is_file() {
        anyhow::bail!("session owner log is not a regular file: {}", path.display());
    }
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.nlink() != 1 {
            anyhow::bail!("session owner log has unsafe ownership: {}", path.display());
        }
        log.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(windows)]
    platform::restrict_file(path)?;
    Ok(log)
}

fn owner_log_path(socket_path: &Path) -> PathBuf {
    suffixed_path(socket_path, ".owner.log")
}

fn suffixed_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name =
        path.file_name().map_or_else(|| OsString::from("cmux-tui"), |name| name.to_os_string());
    name.push(suffix);
    path.with_file_name(name)
}

enum OwnerOutput {
    Line(String),
    Closed(io::Result<()>),
}

fn start_output_reader(
    stdout: ChildStdout,
) -> anyhow::Result<(Receiver<OwnerOutput>, JoinHandle<()>)> {
    let (sender, receiver) = mpsc::channel();
    let thread = std::thread::Builder::new()
        .name("session-owner-ready".into())
        .spawn(move || {
            let mut reader = BufReader::new(stdout);
            let result = loop {
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(0) => break Ok(()),
                    Ok(_) => {
                        if sender.send(OwnerOutput::Line(line)).is_err() {
                            return;
                        }
                    }
                    Err(error) => break Err(error),
                }
            };
            let _ = sender.send(OwnerOutput::Closed(result));
        })
        .context("cannot start session owner readiness reader")?;
    Ok((receiver, thread))
}

fn wait_for_owner_ready(
    child: &mut Child,
    output: Receiver<OwnerOutput>,
    socket_path: &Path,
    log_path: &Path,
) -> anyhow::Result<()> {
    let expected = format!("{OWNER_READY_PREFIX}{}", socket_path.display());
    let deadline = Instant::now() + OWNER_START_TIMEOUT;
    loop {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            let cleanup = terminate_starting_owner(child);
            return match cleanup {
                Ok(()) => Err(anyhow::anyhow!(
                    "session owner did not become ready; inspect {}",
                    log_path.display()
                )),
                Err(cleanup) => Err(anyhow::anyhow!(
                    "session owner did not become ready and cleanup failed: {cleanup}; inspect {}",
                    log_path.display()
                )),
            };
        };
        match output.recv_timeout(remaining) {
            Ok(OwnerOutput::Line(line)) if line.trim_end_matches(['\r', '\n']) == expected => {
                return Ok(());
            }
            Ok(OwnerOutput::Line(_)) => {}
            Ok(OwnerOutput::Closed(Ok(()))) => {
                let status = child.wait()?;
                anyhow::bail!(
                    "session owner exited {status} before readiness; inspect {}",
                    log_path.display()
                );
            }
            Ok(OwnerOutput::Closed(Err(error))) => {
                let _ = terminate_starting_owner(child);
                return Err(error).context("cannot read session owner readiness");
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = terminate_starting_owner(child);
                anyhow::bail!("session owner readiness reader stopped unexpectedly");
            }
        }
    }
}

fn start_owner_reaper(mut child: Child, output_thread: JoinHandle<()>) {
    let result = std::thread::Builder::new().name("session-owner-reaper".into()).spawn(move || {
        let _ = child.wait();
        let _ = output_thread.join();
    });
    if let Err(error) = result {
        eprintln!("cmux-tui: cannot start session owner reaper: {error}");
    }
}

fn terminate_starting_owner(child: &mut Child) -> io::Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    #[cfg(unix)]
    signal_owner_group(child, libc::SIGTERM)?;
    #[cfg(not(unix))]
    child.kill()?;
    if child.wait_timeout(OWNER_STOP_GRACE)?.is_some() {
        return Ok(());
    }
    #[cfg(unix)]
    signal_owner_group(child, libc::SIGKILL)?;
    #[cfg(not(unix))]
    child.kill()?;
    child.wait().map(|_| ())
}

#[cfg(unix)]
fn signal_owner_group(child: &Child, signal: libc::c_int) -> io::Result<()> {
    let process_group = libc::pid_t::try_from(child.id())
        .map_err(|_| io::Error::other("session owner PID does not fit pid_t"))?;
    if unsafe { libc::kill(-process_group, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
}

#[cfg(unix)]
fn configure_detached_process(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

#[cfg(windows)]
fn configure_detached_process(command: &mut Command) {
    command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
}

#[cfg(all(not(unix), not(windows)))]
fn configure_detached_process(_: &mut Command) {}
