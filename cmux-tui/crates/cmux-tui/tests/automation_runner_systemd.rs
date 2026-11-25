//! `cmux automation runner install` on Linux: a systemd user unit that keeps
//! the runner running, started now and at boot (linger on), where it used to
//! try launchd and fail ("Could not load the launchd agent"), so nothing ran
//! on schedule on a Linux machine. `systemctl` and `loginctl` here are fakes
//! that log their arguments.
#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Env {
    dir: PathBuf,
}

fn fake(dir: &Path, name: &str, body: &str) {
    let path = dir.join("bin").join(name);
    fs::write(&path, format!("#!/bin/sh\necho \"{name} $*\" >> \"$FAKE_LOG\"\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

impl Env {
    /// `linger`: what the fake `loginctl show-user` answers until `enable-linger` runs.
    fn new(label: &str, linger: &str, enable_linger_ok: bool) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-automation-systemd-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        fake(&dir, "systemctl", "exit 0");
        let state = dir.join("linger");
        fs::write(&state, linger).unwrap();
        let enable = if enable_linger_ok {
            format!("echo yes > '{}'; exit 0", state.display())
        } else {
            "exit 1".to_string()
        };
        fake(
            &dir,
            "loginctl",
            &format!(
                "case \"$1\" in show-user) cat '{}';; enable-linger) {enable};; esac",
                state.display()
            ),
        );
        Self { dir }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(self.dir.join("bin/cmux"))
            .args(args)
            .current_dir(&self.dir)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("USER", "someone")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_RUNTIME_DIR")
            .env("PATH", format!("{}:/usr/bin:/bin", self.dir.join("bin").display()))
            .env("FAKE_LOG", self.dir.join("calls.log"))
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join("store"))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> (bool, Value) {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.run(&all);
        let v = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "cmux {args:?} printed no JSON ({e}): {}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        });
        (out.status.success(), v)
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.dir.join("calls.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn unit(&self) -> PathBuf {
        self.dir.join(".config/systemd/user/cmux-automations.service")
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn install_writes_a_user_unit_enables_it_now_and_turns_linger_on() {
    let env = Env::new("install", "no", true);
    let (ok, v) = env.json(&["automation", "runner", "install"]);
    assert!(ok, "{v}");
    assert_eq!(v["installed"], true, "{v}");
    assert_eq!(v["linger"], true, "{v}");
    assert_eq!(v["unit"].as_str().map(PathBuf::from), Some(env.unit()));

    let unit = fs::read_to_string(env.unit()).unwrap();
    let exe = fs::canonicalize(env!("CARGO_BIN_EXE_cmux-tui")).unwrap();
    assert!(unit.contains(&format!("ExecStart=\"{}\" automation runner", exe.display())), "{unit}");
    assert!(unit.contains("Restart=always"), "{unit}");
    assert!(unit.contains("WantedBy=default.target"), "{unit}");
    assert!(
        unit.contains(&format!("\"CMUX_AUTOMATIONS_DIR={}\"", env.dir.join("store").display())),
        "{unit}"
    );
    assert!(unit.contains("\"PATH="), "{unit}");

    let calls = env.calls();
    assert!(calls.contains(&"systemctl --user daemon-reload".to_string()), "{calls:?}");
    assert!(
        calls.contains(&"systemctl --user enable cmux-automations.service".to_string()),
        "{calls:?}"
    );
    assert!(
        calls.contains(&"systemctl --user restart cmux-automations.service".to_string()),
        "{calls:?}"
    );
    assert!(calls.contains(&"loginctl enable-linger someone".to_string()), "{calls:?}");
    assert!(!calls.iter().any(|c| c.contains("launchctl")), "{calls:?}");
}

#[test]
fn linger_already_on_is_left_alone_and_linger_refused_is_said() {
    let on = Env::new("linger-on", "yes", true);
    let (ok, v) = on.json(&["automation", "runner", "install"]);
    assert!(ok, "{v}");
    assert!(
        !on.calls().iter().any(|c| c.starts_with("loginctl enable-linger")),
        "{:?}",
        on.calls()
    );

    let refused = Env::new("linger-refused", "no", false);
    let out = refused.run(&["automation", "runner", "install"]);
    let text =
        String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    // Installed and running now; the one root step for boot is named.
    assert!(out.status.success(), "{text}");
    assert!(text.contains("sudo loginctl enable-linger someone"), "{text}");
}

#[test]
fn uninstall_disables_it_and_removes_the_unit() {
    let env = Env::new("uninstall", "yes", true);
    assert!(env.json(&["automation", "runner", "install"]).0);
    assert!(env.unit().exists());
    let (ok, v) = env.json(&["automation", "runner", "uninstall"]);
    assert!(ok, "{v}");
    assert!(!env.unit().exists());
    assert!(
        env.calls()
            .contains(&"systemctl --user disable --now cmux-automations.service".to_string()),
        "{:?}",
        env.calls()
    );
}
