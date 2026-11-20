//! A settings write that names a settings file of its own (`CMUX_NEXT_CONFIG_FILE`,
//! `--app-socket`, or both) never lands in the default file: the case found on
//! 2026-11-19 on Leo's NIGHTLY, where
//! `CMUX_NEXT_CONFIG_FILE=/tmp/x/cfg.json cmux --app-socket /nonexistent settings set ...`
//! exited 0 and wrote his `~/.config/cmux/cmux-next.json`. A real owner here
//! serves the default file below the fixture's home, as the person's daemon
//! does; each write is refused and the default file keeps its exact bytes.

// The owner's launch reads the OS on these two, as in ensure_settings_file.rs.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT: &str = "{\n  \"tabs\": {\n    \"barPosition\": \"top\"\n  }\n}\n";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = PathBuf::from("/tmp").join(format!("cmux-nf-{}-{stamp}-{n}", std::process::id()));
        fs::create_dir_all(dir.join("home/.config/cmux")).unwrap();
        fs::create_dir_all(dir.join("side")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(dir.join("home/.config/cmux/cmux-next.json"), DEFAULT).unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir }
    }

    /// The default settings file below this fixture's home: the person's.
    fn default_file(&self) -> PathBuf {
        self.dir.join("home/.config/cmux/cmux-next.json")
    }

    /// A settings file of its own, as a side instance has.
    fn side_file(&self) -> PathBuf {
        self.dir.join("side/cmux-next.json")
    }

    /// A `cmux-tui` process with this fixture's home and no settings file
    /// variable, reaching the fixture's owner.
    fn cmux(&self) -> Command {
        let home = self.dir.join("home");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .env("LC_ALL", "C")
            .env("CMUX_TUI_SOCKET", &self.socket)
            .env_remove("CMUX_NEXT_CONFIG_FILE")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        command
    }

    /// An owner for this fixture's session serving the default file.
    fn start_owner(&self) {
        let out = self
            .cmux()
            .args(["server", "ensure", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    }

    /// `cmux --socket <owner> [--app-socket APP] WORDS…` with `CMUX_NEXT_CONFIG_FILE`
    /// naming the side file when `named`.
    fn write(&self, named: bool, app_socket: Option<&str>, words: &[&str]) -> Output {
        let mut command = self.cmux();
        if named {
            command.env("CMUX_NEXT_CONFIG_FILE", self.side_file());
        }
        command.arg("--socket").arg(&self.socket);
        if let Some(app) = app_socket {
            command.arg("--app-socket").arg(self.dir.join(app));
        }
        command.args(words).output().unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self
            .cmux()
            .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn assert_refused(out: &Output, what: &str) {
    assert!(
        !out.status.success(),
        "{what} exited 0\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn a_write_naming_its_own_file_never_lands_in_the_default_file() {
    let fixture = Fixture::new("named-file-write");
    fixture.start_owner();
    let before = fs::read(fixture.default_file()).unwrap();

    let cases: [(&str, bool, Option<&str>, &[&str]); 7] = [
        // The reported case: both named, the app socket answers nothing.
        (
            "both, no app",
            true,
            Some("nonexistent.sock"),
            &["settings", "set", "appearance.themeFile", "probe-x"],
        ),
        (
            "both, no app (reset)",
            true,
            Some("nonexistent.sock"),
            &["settings", "reset", "tabs.barPosition"],
        ),
        // Only the variable: the owner serves the default file, so the pinned write is refused.
        ("variable only", true, None, &["settings", "set", "tabs.barPosition", "bottom"]),
        (
            "variable only (edit)",
            true,
            None,
            &["settings", "edit", r#"[{"op":"set","key":"tabs.barPosition","value":"bottom"}]"#],
        ),
        // Only the app socket, which answers nothing.
        (
            "app socket only",
            false,
            Some("nonexistent.sock"),
            &["settings", "set", "tabs.barPosition", "bottom"],
        ),
        ("theme use, app socket", false, Some("nonexistent.sock"), &["theme", "use", "probe-x"]),
        (
            "customize use, app socket",
            false,
            Some("nonexistent.sock"),
            &["customize", "use", "probe-x"],
        ),
    ];
    for (what, named, app, words) in cases {
        let out = fixture.write(named, app, words);
        assert_refused(&out, what);
        assert_eq!(
            fs::read(fixture.default_file()).unwrap(),
            before,
            "{what} changed the default file"
        );
    }
    // The control: the same owner still writes its own (default) file when no
    // other file is named, so the refusals above are the pin, not a broken owner.
    let out = fixture.write(false, None, &["settings", "set", "tabs.barPosition", "bottom"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let text = fs::read_to_string(fixture.default_file()).unwrap();
    assert!(text.contains("\"barPosition\": \"bottom\""), "the owner's own write:\n{text}");
}
