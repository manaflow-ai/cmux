//! `remote-link` to a session that another daemon of the machine already
//! owns (a Chief brain runs `cmux-tui --headless --socket <its own>` on the
//! default state root, so it holds `main`). Before the fix the mux owner the
//! link started exited on the held session lock and the app showed "Cannot
//! Connect ... in use by another cmux daemon" on every try. The link now keeps
//! the session in a private state root of its own and connects; later links
//! keep using it.

#![cfg(unix)]

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
}

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros() % 1_000_000;
        let key = format!("{}-{index}-{stamp}", std::process::id());
        let dir = PathBuf::from("/tmp").join(format!("cmux-rlsiu-{key}"));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(dir.join("home"), fs::Permissions::from_mode(0o700)).unwrap();
        Self { session: format!("rlsiu-{key}"), dir }
    }

    fn remote_root(&self) -> PathBuf {
        self.dir.join("remote")
    }

    fn brain_socket(&self) -> PathBuf {
        self.dir.join("brain.sock")
    }

    fn command(&self) -> Command {
        let mut command = Command::new(bin());
        let home = self.dir.join("home");
        command
            .env("HOME", &home)
            .env("XDG_STATE_HOME", home.join("state"))
            .env("XDG_CONFIG_HOME", home.join("config"))
            .env_remove("XDG_RUNTIME_DIR")
            .env("CMUX_TUI_STATE_DIR", self.dir.join("default-state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_REMOTE_STATE_DIR", self.remote_root())
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET");
        command
    }

    /// A Chief brain: an owner of the session on the default state root at a
    /// socket of its own, as `deploy/brain/install.sh` runs it.
    fn start_brain(&self) {
        let output = self
            .command()
            .args(["server", "ensure", "--json", "--session", &self.session, "--socket"])
            .arg(self.brain_socket())
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "brain ensure: {output:?}");
    }

    fn link(&self) -> Child {
        self.command()
            .args(["remote-link", "--stdio", "--session", &self.session])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for root in [self.remote_root(), self.remote_root().join("private")] {
            let _ = self
                .command()
                .args(["remote", "stop", "--session", &self.session, "--state-dir"])
                .arg(root)
                .stdin(Stdio::null())
                .output();
        }
        for socket in
            find_named(&self.remote_root(), "mux.sock").into_iter().chain([self.brain_socket()])
        {
            let _ = self
                .command()
                .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
                .arg(&socket)
                .stdin(Stdio::null())
                .output();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn find_named(root: &Path, name: &str) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.file_name().is_some_and(|file| file == name) {
                found.push(path);
            }
        }
    }
    found
}

/// Waits until the link's sidecar listens or the link exits; the link's
/// stderr when it exited.
fn wait_linked(fixture: &Fixture, link: &mut Child) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(status) = link.try_wait().unwrap() {
            let mut stderr = String::new();
            use std::io::Read as _;
            link.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
            return Err(format!("link exited {status}: {stderr}"));
        }
        if !find_named(&fixture.remote_root(), "link.sock").is_empty() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err("the link neither connected nor exited in 30 s".into())
}

#[test]
fn a_session_another_daemon_owns_still_links() {
    let fixture = Fixture::new();
    fixture.start_brain();

    let mut link = fixture.link();
    let linked = wait_linked(&fixture, &mut link);
    let _ = link.kill();
    let _ = link.wait();
    linked.expect("remote-link to a session a brain owns must connect");

    let private = fixture.remote_root().join("private");
    assert!(
        !find_named(&private, "workspace-registry.sqlite3").is_empty(),
        "the link's mux owner keeps no registry in the private root"
    );

    // A later link keeps the private root and its sidecar.
    let mut again = fixture.link();
    let linked = wait_linked(&fixture, &mut again);
    let _ = again.kill();
    let _ = again.wait();
    linked.expect("a second link must reuse the private session");
    assert_eq!(find_named(&private, "mux.sock").len(), 1, "one private mux owner");
}
