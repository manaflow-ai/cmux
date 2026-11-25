//! Two apps of one user on two HOMEs reach their own owners.
//!
//! The app starts its owner with `TMPDIR` fixed to the user's temp directory,
//! so the derived socket (`<base>/cmux-tui-<uid>/<session>.sock`) was the same
//! for every app of the user. A second app on another HOME (the fresh-HOME
//! launch check, an isolated profile) found the first app's owner and was
//! refused with `server.different_state`. An app on another HOME carries a
//! runtime scope (`CMUX_TUI_RUNTIME_SCOPE`, cmux-daemon-launch-core
//! `runtime_scope`): its owner's directory is `cmux-tui-<uid>-<scope>`. The
//! app on the account's own HOME has no scope and keeps the unscoped path.
//! Real owner processes, started the way the app starts them (derived socket,
//! no `--socket`).

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct World {
    dir: PathBuf,
    session: String,
}

impl World {
    fn new(name: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = PathBuf::from("/tmp").join(format!("cmux-rs-{}-{stamp}-{n}", std::process::id()));
        for sub in ["t", "a/home", "b/home"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { session: format!("rs-{name}-{n}"), dir }
    }

    /// `cmux-tui server <action>` as the app on `app`'s HOME runs it: the same
    /// `TMPDIR` for every app, the app's own HOME (and so its own state root),
    /// and the app's runtime scope when it has one.
    fn server(&self, app: &str, scope: Option<&str>, action: &str) -> Output {
        let home = self.dir.join(app).join("home");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--session", &self.session, "--json", "server", action])
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("TMPDIR", self.dir.join("t"))
            .env("CMUX_TUI_CONFIG", self.dir.join(app).join("config.json"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .env("LC_ALL", "C")
            .env_remove("XDG_RUNTIME_DIR")
            .env_remove("XDG_STATE_HOME")
            .env_remove("CMUX_TUI_STATE_DIR")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        match scope {
            Some(scope) => command.env("CMUX_TUI_RUNTIME_SCOPE", scope),
            None => command.env_remove("CMUX_TUI_RUNTIME_SCOPE"),
        };
        command.output().unwrap()
    }

    fn socket(output: &Output) -> PathBuf {
        assert!(
            output.status.success(),
            "ensure failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let answer: Value = serde_json::from_slice(&output.stdout).unwrap();
        PathBuf::from(answer["socket"].as_str().unwrap())
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = self.server("a", None, "stop");
        let _ = self.server("b", Some("0badcafe"), "stop");
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn an_app_on_another_home_starts_its_own_owner_beside_the_first_apps() {
    let world = World::new("two");
    let uid = unsafe { libc::getuid() };

    // The account's own app: no scope, the path every app of the user had.
    let first = World::socket(&world.server("a", None, "ensure"));
    assert_eq!(
        first,
        world.dir.join("t").join(format!("cmux-tui-{uid}")).join(format!("{}.sock", world.session))
    );

    // An app on another HOME, same session, same TMPDIR, same uid: its own socket and owner.
    let second = World::socket(&world.server("b", Some("0badcafe"), "ensure"));
    assert_eq!(
        second,
        world
            .dir
            .join("t")
            .join(format!("cmux-tui-{uid}-0badcafe"))
            .join(format!("{}.sock", world.session))
    );
    assert_ne!(first, second);

    // Each reaches its own: status names its own socket, and neither is refused.
    assert_eq!(World::socket(&world.server("a", None, "status")), first);
    assert_eq!(World::socket(&world.server("b", Some("0badcafe"), "status")), second);
    assert_eq!(World::socket(&world.server("b", Some("0badcafe"), "ensure")), second);
}

#[test]
fn without_a_scope_the_second_home_is_refused_by_the_first_owner() {
    // The failure the scope removes: same session and TMPDIR, another state root.
    let world = World::new("bug");
    let _first = World::socket(&world.server("a", None, "ensure"));
    let refused = world.server("b", None, "ensure");
    assert!(!refused.status.success());
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&refused.stdout),
        String::from_utf8_lossy(&refused.stderr)
    );
    assert!(text.contains("server.different_state"), "{text}");
}
