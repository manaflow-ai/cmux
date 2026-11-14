//! A Cloud machine's ssh backup carrier reaches the same remote daemon as its
//! relay carrier. The session host runs `cmux-tui server start --session cloud
//! --remote-ws … --relay …` under a cleared environment (cmux-host
//! `daemon_spec`), and the relay sessions land on the remote daemon inside it.
//! The ssh key's forced command (cmux-platform#1032, cmux-host
//! `ssh_carrier_command`) is `cmux-tui remote-link --stdio --session cloud
//! --mux-socket /tmp/cmux-tui-<uid>/cloud.sock`, run by sshd as the same user
//! with a login environment (pam can set `XDG_RUNTIME_DIR`). It must attach to
//! that same in-process daemon: a second sidecar would have its own clients
//! and no acpmux bridge, so a relay→ssh failover could not resume the acpmux
//! sessions by seq.
//!
//! Linux only: Cloud machines are Linux, and the fixture reads the session
//! host's state from the Linux remote-state path (macOS keeps it under
//! Application Support).

#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

struct Fixture {
    dir: PathBuf,
    session: String,
    host: Option<Child>,
}

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros() % 1_000_000;
        // Short names: the session host's admin.sock sits under
        // <dir>/home/.local/state/cmux/remote/sessions/<base64 session>/, and a
        // path past the 107-byte Linux socket limit is relocated (cmux-remote
        // daemon_paths), which this test's readiness wait would not find. Hex
        // keeps the worst case (7-digit pid) near 90 bytes.
        let key = format!("{:x}-{index:x}-{stamp:x}", std::process::id());
        let dir = PathBuf::from("/tmp").join(format!("cs-{key}"));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::create_dir_all(dir.join("login-runtime")).unwrap();
        for path in [dir.clone(), dir.join("home"), dir.join("login-runtime")] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let fixture = Self { session: format!("c{key}"), dir, host: None };
        let admin = fixture.session_state().join("admin.sock");
        assert!(
            admin.as_os_str().len() <= 100,
            "fixture socket path too long: {}",
            admin.display()
        );
        fixture
    }

    fn home(&self) -> PathBuf {
        self.dir.join("home")
    }

    /// The session host's environment: only `HOME` and the fixture's
    /// config, as cmux-host's cleared environment gives it (no runtime,
    /// temp or state directory variables).
    fn host_command(&self) -> Command {
        let mut command = Command::new(bin());
        command
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", self.home())
            .env("XDG_CONFIG_HOME", self.home().join("config"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("workspace-state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// sshd's forced command environment for the same user: the same `HOME`,
    /// plus the login session's own runtime and temp directories.
    fn login_command(&self) -> Command {
        let mut command = self.host_command();
        command
            .env("XDG_RUNTIME_DIR", self.dir.join("login-runtime"))
            .env("TMPDIR", self.dir.join("login-runtime"));
        command
    }

    /// The remote state the session host keeps its daemon in.
    fn session_state(&self) -> PathBuf {
        use base64::Engine as _;
        let encoded =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(self.session.as_bytes());
        self.home().join(".local/state/cmux/remote/sessions").join(encoded)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut host) = self.host.take() {
            let _ = host.kill();
            let _ = host.wait();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

fn runtime(state: &Path) -> serde_json::Value {
    serde_json::from_slice(&fs::read(state.join("runtime.json")).unwrap()).unwrap()
}

#[test]
fn ssh_forced_command_attaches_to_the_session_hosts_remote_daemon() {
    let mut fixture = Fixture::new();
    // The session host's mux socket: cmux-host's `session_socket` with this
    // test's session name in place of `cloud`.
    let mux_socket = PathBuf::from(format!("/tmp/cmux-tui-{}/{}.sock", uid(), fixture.session));
    let host = fixture
        .host_command()
        .args(["server", "start", "--session", &fixture.session, "--remote-ws", "127.0.0.1:0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    fixture.host = Some(host);

    let state = fixture.session_state();
    let deadline = Instant::now() + Duration::from_secs(30);
    while !(mux_socket.exists()
        && state.join("link.sock").exists()
        && state.join("admin.sock").exists()
        && state.join("runtime.json").exists())
    {
        if let Some(status) = fixture.host.as_mut().unwrap().try_wait().unwrap() {
            let mut stderr = String::new();
            use std::io::Read as _;
            let _ =
                fixture.host.as_mut().unwrap().stderr.take().unwrap().read_to_string(&mut stderr);
            panic!("session host exited {status}: {stderr}");
        }
        assert!(
            Instant::now() < deadline,
            "session host did not serve {} and {}",
            mux_socket.display(),
            state.display()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    let before = runtime(&state);
    assert_eq!(before["link_socket"], state.join("link.sock").display().to_string());

    let link = fixture
        .login_command()
        .args(["remote-link", "--stdio", "--session", &fixture.session, "--mux-socket"])
        .arg(&mux_socket)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(link.status.success(), "ssh forced command did not attach: {link:?}");

    // No second remote daemon: remote-link opens `daemon.log` only to start
    // one, and a started one would rewrite runtime.json with its own
    // lifecycle and identity.
    assert!(!state.join("daemon.log").exists(), "remote-link started a second remote daemon");
    let after = runtime(&state);
    assert_eq!(after["lifecycle_id"], before["lifecycle_id"]);
    assert_eq!(after["daemon_fingerprint"], before["daemon_fingerprint"]);
    assert!(fixture.host.as_mut().unwrap().try_wait().unwrap().is_none(), "session host exited");
}
