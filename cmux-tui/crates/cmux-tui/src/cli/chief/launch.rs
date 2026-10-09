//! `cmux chief` with no app running: start the Chief home's conversation
//! owner (a headless cmux-tui session daemon, `ensure_owner` as `server
//! ensure` does) and its brain (`optchat-chief host`), the way the app's
//! Home does (HomeBrainHost.swift), so the app that opens Home later finds
//! the same owner and brain and starts no second one.
//!
//! One brain per home: the brain holds `state/host.lock`; while it is held,
//! nothing is started and no new agent token is minted (that would cut the
//! running brain off until it reconnects). Nothing starts for an explicit
//! `--socket` or `--session`: the CLI then only connects.

use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use serde_json::{Value, json};

use super::home::ChiefHome;
use super::link::{Link, LinkError};
use super::messages::messages;
use crate::local_owner::{ENSURE_DEADLINE, EnsureError, Ensured, OwnerSpec, ensure_owner};

/// The app's Chief conversation create request (HomeChiefName.swift and
/// optchat-chief daemon.rs): the same key and fields, so whoever creates it
/// first, the others find or replay one conversation.
const CREATE_KEY: &str = "home-chief";
const CHIEF_TITLE: &str = "Chief";

/// Starts what `home` lacks; the owner socket to connect to.
pub(super) fn ensure(home: &ChiefHome) -> Result<PathBuf, String> {
    let m = messages();
    let socket = home.socket().map_err(|e| e.to_string())?;
    let session = home.session();
    std::fs::create_dir_all(home.state_dir()).map_err(|e| e.to_string())?;
    let spec = OwnerSpec {
        session: session.clone(),
        socket: socket.clone(),
        socket_is_derived: true,
        state: Some(home.state_dir()),
        term: None,
        initial_host_colors: None,
        terminal_reap_grace: Some(std::time::Duration::from_secs(30)),
        install_key: None,
    };
    match ensure_owner(&spec, Some(&session), Instant::now() + ENSURE_DEADLINE) {
        Ok(Ensured::Running(_)) => {}
        Ok(Ensured::Started(owner)) => {
            eprintln!(
                "cmux: {}",
                m.started_daemon
                    .replace("{session}", &session)
                    .replace("{pid}", &owner.pid.to_string())
            );
        }
        Err(error) => return Err(m.daemon_failed.replace("{why}", ensure_error(&error))),
    }
    if brain_running(&home.host_lock()) {
        return Ok(socket);
    }
    let brain = brain_binary().ok_or_else(|| m.no_brain.to_owned())?;
    let mut link = Link::connect(&socket, true).map_err(|e| e.to_string())?;
    let user = full_name();
    ensure_conversation(&mut link, &user).map_err(|e| e.to_string())?;
    let token = link
        .command("conversation-agent-token", json!({"participant": "agent_mux"}))
        .map_err(|e| e.to_string())?;
    let token = token.get("token").and_then(Value::as_str).unwrap_or_default();
    write_token(&home.token_file(), token).map_err(|e| e.to_string())?;
    let pid = spawn_brain(&brain, home, &socket, &user).map_err(|e| e.to_string())?;
    eprintln!(
        "cmux: {}",
        m.started_brain
            .replace("{home}", &home.root.display().to_string())
            .replace("{pid}", &pid.to_string())
    );
    Ok(socket)
}

fn ensure_error(error: &EnsureError) -> &'static str {
    match error {
        EnsureError::Spawn(_) => "it could not be started",
        EnsureError::NotReady => "it did not become ready in time",
        EnsureError::WrongOwner => "another program serves its socket",
        EnsureError::DifferentSession => "another session serves its socket",
        EnsureError::InvalidIdentity | EnsureError::UnsupportedProtocol => {
            "it speaks another protocol version"
        }
    }
}

/// Whether a brain holds the home's lock (`flock`, as optchat-chief's
/// lock.rs takes it). A missing or unlockable file means no brain.
pub(super) fn brain_running(lock: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let Ok(file) = OpenOptions::new().read(true).open(lock) else { return false };
        // SAFETY: flock on a descriptor this function owns; it is released
        // when `file` drops.
        let taken = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        taken != 0
    }
    #[cfg(not(unix))]
    {
        let _ = lock;
        false
    }
}

/// `CMUX_CHIEF_BRAIN_BIN` (or the app's `CMUX_NEXT_MUX_HOST`), the
/// `optchat-chief` next to this `cmux` (an app bundle's `Resources/bin`),
/// else one on `PATH`.
pub(super) fn brain_binary() -> Option<PathBuf> {
    for key in ["CMUX_CHIEF_BRAIN_BIN", "CMUX_NEXT_MUX_HOST"] {
        if let Some(path) = std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from) {
            return path.is_file().then_some(path);
        }
    }
    sibling_or_path("optchat-chief")
}

fn sibling_or_path(name: &str) -> Option<PathBuf> {
    let beside = std::env::current_exe().ok().and_then(|exe| Some(exe.parent()?.join(name)));
    let on_path = std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).map(|dir| dir.join(name)).collect::<Vec<_>>())
        .unwrap_or_default();
    beside.into_iter().chain(on_path).find(|path| path.is_file())
}

/// The Chief conversation exists, created with the app's request if not.
fn ensure_conversation(link: &mut Link, user: &str) -> Result<(), LinkError> {
    let listed = link.call("conversation.list", json!({}), None)?;
    let conversations = listed.as_array().cloned().unwrap_or_default();
    if super::link::select_chief(&conversations).is_some() {
        return Ok(());
    }
    link.command(
        "conversation-create",
        json!({
            "idempotency_key": CREATE_KEY,
            "actor": "user_local",
            "title": CHIEF_TITLE,
            "participants": [
                {"id": "user_local", "kind": "human", "display_name": user},
                {"id": "agent_mux", "kind": "agent", "display_name": CHIEF_TITLE,
                 "agent_class": "mux", "acp_session": "mux"},
            ],
        }),
    )
    .map(|_| ())
}

/// Created 0600 from the start, so the token is never readable by others.
fn write_token(path: &Path, token: &str) -> std::io::Result<()> {
    use std::io::Write;
    let _ = std::fs::remove_file(path);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)?.write_all(token.as_bytes())
}

/// The brain detached in its own session, its output appended to
/// `host.log`, with the app's environment for it.
fn spawn_brain(brain: &Path, home: &ChiefHome, socket: &Path, user: &str) -> std::io::Result<u32> {
    let log = OpenOptions::new().create(true).append(true).open(home.host_log())?;
    let user_home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut path_dirs: Vec<PathBuf> = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf))
        .into_iter()
        .collect();
    path_dirs
        .extend(["bin", ".local/bin", ".bun/bin", ".cargo/bin"].iter().map(|d| user_home.join(d)));
    path_dirs.extend(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map(PathBuf::from),
    );
    let search_path = std::env::join_paths(path_dirs).map_err(std::io::Error::other)?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let mut command = Command::new(brain);
    command
        .arg("host")
        .arg("--daemon-socket")
        .arg(socket)
        .arg("--mux-home")
        .arg(&home.root)
        .env_clear()
        .env("PATH", search_path)
        .env("HOME", &user_home)
        .env("MUX_AGENT_TOKEN_FILE", home.token_file())
        .env("MUX_HOST_LOG", home.host_log())
        .env("MUX_USER_NAME", user)
        .env("MUX_CHIEF_TITLE", CHIEF_TITLE)
        .env("CMUX_SOCKET_PATH", home.root.join("state/app.sock"))
        .env("CMUX_APP_DAEMON_SOCKET", home.root.join("state/app-daemon.sock"))
        .env("ACPMUX_HOME", home.acpmux_home())
        .env("ACPMUX_SOCKET", home.acpmux_socket(uid))
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    if let Some(acpmux) = sibling_or_path("acpmux") {
        command.env("ACPMUX_BIN", acpmux);
    }
    for key in ["USER", "TMPDIR", "LANG", "MUX_HARNESS", "CMUX_MCP_COMMAND"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state in
        // the post-fork child: the brain outlives this CLI and its terminal.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    let mut child = command.spawn()?;
    let pid = child.id();
    // Reap it if it exits while this CLI still runs (a second brain exits 0).
    let _ = std::thread::Builder::new().name("chief-brain-reaper".into()).spawn(move || {
        let _ = child.wait();
    });
    Ok(pid)
}

/// The user's full name (`id -F` on macOS), else the login name: the name
/// the app and the brain give `user_local`.
fn full_name() -> String {
    let out = Command::new("/usr/bin/id").arg("-F").output();
    if let Ok(out) = out
        && out.status.success()
    {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        if !name.is_empty() {
            return name;
        }
    }
    std::env::var("USER").unwrap_or_else(|_| "user".into())
}
