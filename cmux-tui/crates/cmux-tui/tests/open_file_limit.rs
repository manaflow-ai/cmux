//! A terminal owner started with a small open-file soft limit (256, the macOS
//! default) runs hundreds of terminals, and the programs in those terminals
//! still see the limit the owner was started with. An owner started with a
//! raised limit and told the launch limit (`CMUX_TUI_HOST_NOFILE_SOFT`, as
//! the cmux app starts its daemon after it raised its own) gives that launch
//! limit to its terminals, and none of them sees the variable.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use std::os::unix::net::UnixStream;

const SOFT_LIMIT: libc::rlim_t = 256;
/// The variable that names the limit cmux was launched with
/// (`cmux_pty::LAUNCH_SOFT_LIMIT_ENV`, cmux-holder `NOFILE_SOFT_ENV`): spelled
/// out, as the app and older daemons spell it.
const LAUNCH_LIMIT_ENV: &str = "CMUX_TUI_HOST_NOFILE_SOFT";
/// The owner's terminal host model (cmux-tui-core `holder_runtime::enabled`).
const HOST_MODEL_ENV: &str = "CMUX_TUI_TERMINAL_HOST_MODEL";
const TERMINALS: usize = 300;
const CREATORS: usize = 8;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

/// How a test starts its owner.
struct Launch {
    /// The owner's soft limit at exec.
    soft: libc::rlim_t,
    /// `CMUX_TUI_HOST_NOFILE_SOFT` in the owner's environment.
    launch_limit: Option<libc::rlim_t>,
    /// `--ephemeral`: no state root, so no holder and no terminal hosts; the
    /// owner runs every terminal on its own PTYs.
    ephemeral: bool,
    /// `CMUX_TUI_TERMINAL_HOST_MODEL=holder`: the holder runs the shells,
    /// else one terminal host per terminal (the default).
    holder: bool,
}

/// The soft limit the cmux app gives the daemon it starts: as high as the
/// hard limit and (macOS) `kern.maxfilesperproc` allow, at most the
/// daemon's own ceiling.
fn raised_soft_limit() -> libc::rlim_t {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is valid writable storage for one rlimit.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) }, 0);
    let mut raised = limit.rlim_max.min(65_536);
    #[cfg(target_os = "macos")]
    {
        let mut value: libc::c_int = 0;
        let mut size = size_of::<libc::c_int>();
        // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
        let read = unsafe {
            libc::sysctlbyname(
                c"kern.maxfilesperproc".as_ptr(),
                (&raw mut value).cast(),
                &raw mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if read == 0 && value > 0 {
            raised = raised.min(value as libc::rlim_t);
        }
    }
    assert!(raised > 4 * SOFT_LIMIT, "this host cannot raise the limit above {raised}");
    raised
}

impl Daemon {
    fn start_with_soft_limit(soft: libc::rlim_t) -> Self {
        Self::start(Launch { soft, launch_limit: None, ephemeral: false, holder: false })
    }

    fn start(launch: Launch) -> Self {
        let Launch { soft, launch_limit, ephemeral, holder } = launch;
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-nofile-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command.args(["--headless", "--socket"]).arg(&socket);
        if ephemeral {
            command.arg("--ephemeral");
        } else {
            command.arg("--state").arg(dir.join("state"));
        }
        command
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env_remove(LAUNCH_LIMIT_ENV)
            .env_remove(HOST_MODEL_ENV)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(launch_limit) = launch_limit {
            command.env(LAUNCH_LIMIT_ENV, launch_limit.to_string());
        }
        if holder {
            command.env(HOST_MODEL_ENV, "holder");
        }
        // SAFETY: getrlimit/setrlimit are async-signal-safe and only change
        // the daemon child's own soft limit (never above its hard limit).
        unsafe {
            command.pre_exec(move || {
                let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
                if libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                limit.rlim_cur = soft.min(limit.rlim_max);
                if libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End every terminal through the owner; never signal a host.
        if let Some(identify) = try_request(&self.socket, &serde_json::json!({"cmd": "identify"})) {
            let _ = try_request_with_timeout(
                &self.socket,
                &serde_json::json!({
                    "cmd": "shutdown-daemon",
                    "pid": identify["data"]["pid"],
                    "generation": identify["data"]["generation"],
                    "end_terminals": true,
                }),
                test_timeout(Duration::from_secs(300)),
            );
        }
        let deadline = Instant::now() + test_timeout(Duration::from_secs(120));
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn try_request_with_timeout(
    path: &Path,
    value: &serde_json::Value,
    timeout: Duration,
) -> Option<serde_json::Value> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn try_request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    try_request_with_timeout(path, value, test_timeout(Duration::from_secs(60)))
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = try_request(path, &value).unwrap_or_else(|| panic!("{value}: no response"));
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

#[test]
fn cmux_next_owner_runs_300_terminals_with_a_256_open_file_soft_limit() {
    let daemon = Daemon::start_with_soft_limit(SOFT_LIMIT);
    request(&daemon.socket, serde_json::json!({"cmd": "new-workspace", "name": "nofile"}));
    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.last())
        .and_then(|workspace| workspace["key"].as_str())
        .expect("workspace key")
        .to_owned();

    // One terminal reports the limit its program sees.
    let probe = daemon.dir.join("probe-limit");
    let script = format!("ulimit -n > '{}'; exec cat", probe.display());
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "create-terminal", "key": key, "argv": ["/bin/sh", "-c", script]}),
    );

    let next = Arc::new(AtomicUsize::new(1));
    let creators = (0..CREATORS)
        .map(|_| {
            let socket = daemon.socket.clone();
            let key = key.clone();
            let next = next.clone();
            std::thread::spawn(move || {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= TERMINALS {
                        return Ok(());
                    }
                    let value = serde_json::json!({
                        "cmd": "create-terminal", "key": key, "argv": ["/bin/sh"],
                    });
                    match try_request(&socket, &value) {
                        Some(response) if response["ok"] == true => {}
                        other => return Err(format!("terminal {index}: {other:?}")),
                    }
                }
            })
        })
        .collect::<Vec<_>>();
    for creator in creators {
        creator.join().unwrap().unwrap();
    }

    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let seen = loop {
        if let Ok(text) = fs::read_to_string(&probe)
            && !text.trim().is_empty()
        {
            break text.trim().to_owned();
        }
        assert!(Instant::now() < deadline, "probe terminal never wrote {}", probe.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(seen, SOFT_LIMIT.to_string(), "a terminal program must see the original limit");

    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let tabs = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|workspace| workspace["key"] == key)
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .map(|pane| pane["tabs"].as_array().map_or(0, Vec::len))
        .sum::<usize>();
    assert!(tabs > TERMINALS, "expected more than {TERMINALS} tabs, found {tabs}");
}

/// The owner's first workspace key, after it creates one.
fn new_workspace(socket: &Path, name: &str) -> String {
    request(socket, serde_json::json!({"cmd": "new-workspace", "name": name}));
    let tree = request(socket, serde_json::json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.last())
        .and_then(|workspace| workspace["key"].as_str())
        .expect("workspace key")
        .to_owned()
}

/// What one terminal's program sees: its soft limit and the launch-limit
/// variable (`unset` when it has none).
fn terminal_sees(daemon: &Daemon) -> String {
    let key = new_workspace(&daemon.socket, "launch-limit");
    let probe = daemon.dir.join("probe-launch");
    let script = format!(
        "printf '%s %s\\n' \"$(ulimit -n)\" \"${{{LAUNCH_LIMIT_ENV}-unset}}\" > '{}'; exec cat",
        probe.display()
    );
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "create-terminal", "key": key, "argv": ["/bin/sh", "-c", script]}),
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        if let Ok(text) = fs::read_to_string(&probe)
            && text.ends_with('\n')
        {
            return text.trim().to_owned();
        }
        assert!(Instant::now() < deadline, "probe terminal never wrote {}", probe.display());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The cmux app raises its own limit before it starts its daemon, so the
/// daemon starts raised and its own raise changes nothing: before the
/// launch limit was recorded from `CMUX_TUI_HOST_NOFILE_SOFT`, the holder's
/// shells got 256 only because the holder read the variable the daemon left
/// in its environment, and every shell inherited the variable
/// (pl-cef-tab-nofile review 1). Terminal hosts removed it for their own
/// shells already; both models must keep doing so.
#[test]
fn an_owner_started_raised_gives_its_holder_shells_the_launch_limit_and_not_the_variable() {
    let daemon = Daemon::start(Launch {
        soft: raised_soft_limit(),
        launch_limit: Some(SOFT_LIMIT),
        ephemeral: false,
        holder: true,
    });
    assert_eq!(terminal_sees(&daemon), format!("{SOFT_LIMIT} unset"));
}

/// As above, with one terminal host per terminal (the default model).
#[test]
fn an_owner_started_raised_gives_its_hosted_shells_the_launch_limit_and_not_the_variable() {
    let daemon = Daemon::start(Launch {
        soft: raised_soft_limit(),
        launch_limit: Some(SOFT_LIMIT),
        ephemeral: false,
        holder: false,
    });
    assert_eq!(terminal_sees(&daemon), format!("{SOFT_LIMIT} unset"));
}

/// The owner's own PTYs (no state root: no holder, no terminal host) get
/// the launch limit through the owner's record
/// (`restore_open_file_limit_in_child`, the same record every
/// `UnixProcessScope` hook and plugin uses): before the fix they kept the
/// raised limit.
#[test]
fn an_owner_started_raised_gives_its_own_ptys_the_launch_limit_and_not_the_variable() {
    let daemon = Daemon::start(Launch {
        soft: raised_soft_limit(),
        launch_limit: Some(SOFT_LIMIT),
        ephemeral: true,
        holder: false,
    });
    assert_eq!(terminal_sees(&daemon), format!("{SOFT_LIMIT} unset"));
}
