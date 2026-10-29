//! Ctrl-C reaches the program in a daemon terminal (dogfood chrome-parity-v1 on
//! macOS 27: "ctrl c is broken").
//!
//! A real daemon, started as the app starts it (with the macOS default
//! open-file soft limit, which it raises, so its shells go through the
//! original-limit launcher), runs a shell on a terminal host. Input 0x03 (what
//! Ctrl-C sends, raw through `send` and encoded through `send-key ctrl+c`)
//! must end the foreground program with SIGINT: the trap in the shell writes
//! a marker and the loop stops. A terminal whose program ignores SIGINT, is
//! not in the PTY's foreground group, or has no controlling terminal, reads
//! 0x03 as a plain byte and keeps running.
//!
//! The login-shell case is the one the app hits on macOS: `/bin/sh` takes its
//! terminal as controlling terminal itself, zsh (macOS's default shell) does
//! not, so only a spawn that gives the shell its controlling terminal makes
//! Ctrl-C and job control work there.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The macOS default soft limit: the daemon raises its own, and gives its
/// shells this one back.
const SOFT_LIMIT: libc::rlim_t = 256;

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

impl Daemon {
    fn start() -> Self {
        Self::start_with_shell("/bin/sh")
    }

    /// A daemon whose terminals without an argv run `shell` (`SHELL`), with a
    /// private home so no rc file of the host's account runs.
    fn start_with_shell(shell: &str) -> Self {
        Self::start_as(shell, None, None)
    }

    /// As [`Daemon::start_with_shell`]; `account_home`: the daemon's HOME is
    /// the account's own, as the app's daemon has it, so its shells start
    /// through login(1) on macOS (`login_shell::wrap` skips a launch whose
    /// HOME is not the account's). ZDOTDIR stays private, so no zsh startup
    /// file of the account runs. `features`: the daemon's
    /// `CMUX_ENABLE_FEATURES`.
    fn start_as(shell: &str, account_home: Option<&Path>, features: Option<&str>) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-ctrlc-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        let socket = dir.join("mux.sock");
        let home = account_home.map_or_else(|| dir.join("home"), Path::to_path_buf);
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            // The app's daemon is a release build, where the blocking detector
            // only records; a debug build would panic on its connection threads.
            .env("CMUX_DAEMON_BLOCKING", "record")
            .env("SHELL", shell)
            .env("HOME", &home)
            .env("ZDOTDIR", dir.join("home"))
            .env_remove("CMUX_ENABLE_FEATURES")
            .env_remove("CMUX_DISABLE_FEATURES")
            .env_remove("CMUX_TUI_NO_LOGIN_SHELL")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(fs::File::create(dir.join("daemon.log")).unwrap());
        // SAFETY: getrlimit/setrlimit are async-signal-safe and only change
        // the daemon child's own soft limit (never above its hard limit).
        unsafe {
            command.pre_exec(|| {
                let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
                if libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                limit.rlim_cur = SOFT_LIMIT.min(limit.rlim_max);
                if libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        if let Some(features) = features {
            command.env("CMUX_ENABLE_FEATURES", features);
        }
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            // test harness: wait for the daemon's socket
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End every terminal through the owner; never signal a host.
        if let Some(identify) = try_request(&self.socket, &json!({"cmd": "identify"})) {
            let _ = try_request(
                &self.socket,
                &json!({
                    "cmd": "shutdown-daemon",
                    "pid": identify["data"]["pid"],
                    "generation": identify["data"]["generation"],
                    "end_terminals": true,
                }),
            );
        }
        let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            // test harness: bounded wait for the daemon's exit
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn try_request(path: &Path, value: &Value) -> Option<Value> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(60)))).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn request(path: &Path, value: Value) -> Value {
    let response = try_request(path, &value).unwrap_or_else(|| {
        let log = path.with_file_name("daemon.log");
        let log = fs::read_to_string(&log).unwrap_or_default();
        let tail: String =
            log.chars().rev().take(4000).collect::<Vec<_>>().into_iter().rev().collect();
        panic!("{value}: no response; daemon log tail:\n{tail}")
    });
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

fn wait_for_file(path: &Path, what: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        if let Ok(text) = fs::read_to_string(path)
            && text.ends_with('\n')
        {
            return text;
        }
        assert!(Instant::now() < deadline, "{what}: {} never written", path.display());
        // test harness: poll a file the terminal's shell writes
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// A terminal whose shell traps SIGINT into `marker` and otherwise loops in a
/// foreground `sleep`; `ready` is written once the trap is set. Returns the
/// surface and what `ready` says about the shell's terminal.
fn trapping_terminal(daemon: &Daemon, name: &str) -> (u64, PathBuf, String) {
    let ready = daemon.dir.join(format!("{name}.ready"));
    let marker = daemon.dir.join(format!("{name}.int"));
    // `ps` reports the shell's session, its terminal's foreground group and its
    // own group: the 0x03 reaches the shell only when the last two are equal.
    let script = format!(
        "trap 'echo got-sigint > \"{marker}\"; exit 0' INT; \
         ps -o sess=,tpgid=,pgid=,tty= -p $$ > \"{ready}.ps\"; echo ready > \"{ready}\"; \
         while :; do sleep 1; done",
        marker = marker.display(),
        ready = ready.display(),
    );
    request(&daemon.socket, json!({"cmd": "new-workspace", "name": name, "cols": 80, "rows": 24}));
    let tree = request(&daemon.socket, json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.iter().find(|workspace| workspace["name"] == name))
        .and_then(|workspace| workspace["key"].as_str())
        .unwrap_or_else(|| panic!("no workspace {name}: {tree}"))
        .to_owned();
    let created = request(
        &daemon.socket,
        json!({"cmd": "create-terminal", "key": key, "argv": ["/bin/sh", "-c", script],
            "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"));
    wait_for_file(&ready, "the shell's trap");
    let terminal =
        fs::read_to_string(daemon.dir.join(format!("{name}.ready.ps"))).unwrap_or_default();
    (surface, marker, terminal.trim().to_string())
}

fn assert_interrupted(marker: &Path, how: &str, terminal: &str) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !marker.exists() {
        assert!(
            Instant::now() < deadline,
            "{how} did not interrupt the terminal's program (session, foreground group, group, \
             tty: {terminal})"
        );
        // test harness: poll the marker the SIGINT trap writes
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn ctrl_c_interrupts_the_program_in_a_daemon_terminal() {
    let daemon = Daemon::start();

    let (surface, marker, terminal) = trapping_terminal(&daemon, "raw");
    request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "\u{3}"}));
    assert_interrupted(&marker, "raw 0x03 through send", &terminal);

    let (surface, marker, terminal) = trapping_terminal(&daemon, "key");
    request(&daemon.socket, json!({"cmd": "send-key", "surface": surface, "keys": ["ctrl+c"]}));
    assert_interrupted(&marker, "send-key ctrl+c", &terminal);
}

/// The text a terminal shows now.
fn screen(daemon: &Daemon, surface: u64) -> String {
    let reply = request(&daemon.socket, json!({"cmd": "read-screen", "surface": surface}));
    reply["text"].as_str().map(str::to_owned).unwrap_or_else(|| reply.to_string())
}

/// Waits until a line of the screen is `needle` (the program's output, not
/// the echoed command line that names it).
fn wait_for_screen(daemon: &Daemon, surface: u64, needle: &str, what: &str) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let text = screen(daemon, surface);
        if text.lines().any(|line| line.trim_end() == needle) {
            return;
        }
        assert!(Instant::now() < deadline, "{what}: the screen never showed {needle:?}:\n{text}");
        // test harness: poll the terminal's screen
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The terminal the app opens: the user's login shell with cmux's shell
/// integration (no argv), zsh where the host has it (macOS's default shell).
/// Ctrl-C interrupts its foreground `sleep`: `$?` at the next prompt is 130
/// (128 + SIGINT).
#[test]
fn ctrl_c_interrupts_a_foreground_command_in_the_login_shell() {
    let shell = login_shell();
    let daemon = Daemon::start_with_shell(shell);
    ctrl_c_ends_a_foreground_sleep_in_a_new_terminal(&daemon, shell, false);
}

/// zsh where the host has it (macOS's default shell), else bash.
fn login_shell() -> &'static str {
    ["/bin/zsh", "/usr/bin/zsh", "/bin/bash"]
        .into_iter()
        .find(|shell| Path::new(shell).exists())
        .expect("a zsh or bash")
}

/// The 53 switches of the chrome-parity-v1 dogfood launch (every switch but
/// perfLabCanary and perfLabKillProbe), as `open -n --env
/// CMUX_ENABLE_FEATURES=...` gave them; the daemon resolves the ones it
/// declares and ignores the rest.
#[cfg(target_os = "macos")]
const DOGFOOD_V1_FEATURES: &str = "agentPageRendererSharing,automationBurstSnap,cefLayerHosting,\
cefPrefetchBehindFence,cefPumpInputPolicy,cefTimerSlack,chromiumHostIdleExit,chromiumHostWidgets,\
chromiumSpareAfterFirstTab,cmuxPageRendererSharing,coldScrollbackCompression,controlSocketEarlyBind,\
daemonRequestQos,energySaver,frameRateClasses,frozenGrowthDiscard,intentPrewarmHover,\
memoryAgentAndControlCaches,memoryAppCaches,memoryBrowserCaches,memoryDiscardAgentPagesOverBudget,\
memoryDiscardConversations,memoryDiscardInternalPages,memoryDiscardPageTabs,\
memoryDiscardParkedIdleTimeout,memoryDiscardParkedWorkspaces,memoryDiscardRemoteTabs,\
memoryFileHomeCaches,memoryHiddenFrameLRU,memoryImageCaches,memorySaverBackgroundActivity,\
memoryTerminalLastFrames,newTabParksHidden,occludedWindowDiscard,overlayTopLayer,pageLifecycle,\
pageProcessGroups,pageRendererAtFirstShow,pagesSpareWindow,pointerFrameDrags,pointerFrameHover,\
pointerFrameRemoteInput,recentlyAudibleProtection,renderStarvationGuard,rendererlessSpareWindow,\
sentryHandlersFirst,sidebarRowsNearViewport,stripPanResampling,taskManagerMemorySaved,\
terminalGPURelease,terminalPointerFrames,topPageDiscard,vsyncHub";

/// The PTY chain the app's terminal has on macOS: the daemon's HOME is the
/// account's, so the shell starts as `/usr/bin/login -flp USER /bin/bash
/// ... exec -l zsh` (setuid login(1), which forks the shell), not as the
/// direct PTY child. Ctrl-C still ends its foreground `sleep`, with the
/// dogfood launch's switches off and on.
#[cfg(target_os = "macos")]
#[test]
fn ctrl_c_interrupts_a_foreground_command_in_a_shell_started_through_login() {
    let home = account_home();
    let shell = login_shell();
    for features in [None, Some(DOGFOOD_V1_FEATURES)] {
        let daemon = Daemon::start_as(shell, Some(&home), features);
        ctrl_c_ends_a_foreground_sleep_in_a_new_terminal(&daemon, shell, true);
    }
}

/// This account's home directory (passwd), whatever HOME the runner set.
#[cfg(target_os = "macos")]
fn account_home() -> PathBuf {
    let mut buffer = vec![0 as libc::c_char; 4096];
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    // SAFETY: getpwuid_r writes into `entry` and `buffer` only.
    let status = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    assert!(status == 0 && !result.is_null(), "no passwd entry for this account");
    // SAFETY: getpwuid_r filled `entry`; its home is a NUL-terminated
    // string in `buffer`.
    let home = unsafe { std::ffi::CStr::from_ptr(entry.assume_init().pw_dir) };
    PathBuf::from(home.to_str().expect("a UTF-8 home directory"))
}

/// Opens a terminal with no argv (the app's default terminal) and checks that
/// Ctrl-C ends a foreground `sleep` in it (`$?` is 130 at the next prompt).
/// `via_login`: the terminal is the app's (a terminal host, created with the
/// frontend's terminal id and shell), and the shell's parent must be
/// login(1), the app's chain on macOS.
fn ctrl_c_ends_a_foreground_sleep_in_a_new_terminal(daemon: &Daemon, shell: &str, via_login: bool) {
    request(
        &daemon.socket,
        json!({"cmd": "new-workspace", "name": "login", "cols": 80, "rows": 24}),
    );
    let tree = request(&daemon.socket, json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.iter().find(|workspace| workspace["name"] == "login"))
        .and_then(|workspace| workspace["key"].as_str())
        .unwrap_or_else(|| panic!("no workspace login: {tree}"))
        .to_owned();
    let surface = if via_login {
        hosted_shell_terminal(daemon, &key, shell)
    } else {
        let created = request(
            &daemon.socket,
            json!({"cmd": "create-terminal", "key": key, "cols": 80, "rows": 24}),
        );
        created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"))
    };
    request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "echo SHELL-UP\r"}));
    wait_for_screen(daemon, surface, "SHELL-UP", "the login shell");
    if via_login {
        // The echoed command line is not the exact line `VIA-LOGIN`.
        request(
            &daemon.socket,
            json!({"cmd": "send", "surface": surface,
                "text": "case \"$(ps -o comm= -p $PPID)\" in *login) echo VIA-LOGIN;; *) echo NOT-VIA-LOGIN;; esac\r"}),
        );
        wait_for_screen(daemon, surface, "VIA-LOGIN", "the shell's parent is login(1)");
    }
    request(
        &daemon.socket,
        json!({"cmd": "send", "surface": surface,
            "text": "echo SLEEP-START; sleep 600\r"}),
    );
    wait_for_screen(daemon, surface, "SLEEP-START", "the foreground sleep");
    // test harness: let the shell hand the terminal to `sleep`
    std::thread::sleep(Duration::from_millis(500));
    request(&daemon.socket, json!({"cmd": "send-key", "surface": surface, "keys": ["ctrl+c"]}));
    // An interactive shell drops the rest of a list a SIGINT ended: ask for
    // the status at the next prompt (queued input waits for it).
    request(
        &daemon.socket,
        json!({"cmd": "send", "surface": surface, "text": "echo AFTER-EXIT=$?\r"}),
    );
    wait_for_screen(daemon, surface, "AFTER-EXIT=130", &format!("Ctrl-C in {shell}"));
}

/// A new tab in workspace `key`'s pane as the app makes one: the frontend's
/// terminal id (so a terminal host runs it and starts its shell through
/// login(1) on macOS) and its shell (`SHELL`, an interactive `-i`). Returns
/// the surface.
#[cfg(target_os = "macos")]
fn hosted_shell_terminal(daemon: &Daemon, key: &str, shell: &str) -> u64 {
    let tree = request(&daemon.socket, json!({"cmd": "list-workspaces"}));
    let pane = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.iter().find(|workspace| workspace["key"] == key))
        .and_then(|workspace| workspace["screens"].as_array())
        .and_then(|screens| screens.iter().find_map(|screen| screen["panes"].as_array()?.first()))
        .map(|pane| pane["id"].clone())
        .unwrap_or_else(|| panic!("no pane in workspace {key}: {tree}"));
    let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), 0x2c_u64);
    let created = request(
        &daemon.socket,
        json!({"cmd": "new-tab", "pane": pane, "terminal_id": terminal_id, "cols": 80,
            "rows": 24, "env": {"SHELL": shell}, "shell_args": ["-i"]}),
    );
    created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"))
}

#[cfg(not(target_os = "macos"))]
fn hosted_shell_terminal(_daemon: &Daemon, _key: &str, _shell: &str) -> u64 {
    unreachable!("login(1) starts only on macOS")
}

/// `extra.shell_idle` on the app's real launch path (review 2 of
/// cp/daemon-foreground-state): the shell starts through login(1) on macOS,
/// so the daemon's foreground check takes its `login_session_shell` branch.
/// At its prompt with no input the shell reads idle (a failure here makes the
/// app ask on every close: the feature silently useless); a typed command
/// takes it away.
#[cfg(target_os = "macos")]
#[test]
fn shell_idle_the_apps_login_shell_at_its_prompt_reads_idle() {
    let home = account_home();
    let shell = login_shell();
    let daemon = Daemon::start_as(shell, Some(&home), None);
    request(
        &daemon.socket,
        json!({"cmd": "new-workspace", "name": "idle", "cols": 80, "rows": 24}),
    );
    let tree = request(&daemon.socket, json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.iter().find(|workspace| workspace["name"] == "idle"))
        .and_then(|workspace| workspace["key"].as_str())
        .unwrap_or_else(|| panic!("no workspace idle: {tree}"))
        .to_owned();
    let surface = hosted_shell_terminal(&daemon, &key, shell);
    let extra = || {
        let reply = try_request(
            &daemon.socket,
            &json!({"protocol": "cmux.protocol/2", "type": "request", "id": "idle-list",
                "operation": "terminal.list", "params": {"machine": "current", "session": "current"}}),
        )
        .unwrap_or_default();
        reply["result"]
            .as_array()
            .and_then(|terminals| terminals.first())
            .map(|t| t["extra"].clone())
            .unwrap_or_default()
    };
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let extra = extra();
        if extra["shell_idle"]["since_ms"].is_string() {
            assert_eq!(extra["foreground_check"]["own"], true, "{extra}");
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the login shell at its prompt never read idle: {extra}"
        );
        // test harness: poll the daemon's terminal record
        std::thread::sleep(Duration::from_millis(100));
    }
    request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "sleep 600\r"}));
    let extra = extra();
    assert!(extra.get("shell_idle").is_none(), "a typed command still reads idle: {extra}");
}
