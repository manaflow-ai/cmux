//! `cmux link offload` (RFD 0007 step 7, "Offload"): one local command runs on a Cloud machine
//! over this folder's view, and what it writes is published back here.
//!
//! The machine is a headless `cmux-tui` daemon with a home and state folder of its own, as in
//! `projection_roundtrip_matrix.rs`; the Mac is the same binary with its own. The command reads a
//! file only the Mac has (it arrives through the view), writes an output file and deletes one,
//! prints to stdout and exits with a code of its own. Afterwards the Mac's folder has the output,
//! lacks the deleted file, and the offload's exit code is the command's.
#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

struct Side {
    home: PathBuf,
    state: PathBuf,
}

impl Side {
    fn make(at: &Path) -> Self {
        let side = Self { home: at.join("home"), state: at.join("state") };
        fs::create_dir_all(&side.home).unwrap();
        fs::create_dir_all(&side.state).unwrap();
        side
    }

    fn cmux(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .env("HOME", &self.home)
            .env("SHELL", "/bin/sh")
            .env("CMUX_TUI_STATE_DIR", &self.state)
            .env("CMUX_TUI_CONFIG", self.state.join("config.json"))
            .env("CMUX_PROJECTED_FOLDERS", "1")
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_TEST_CLOUD_ETC")
            .stdin(Stdio::null());
        command
    }
}

/// The Cloud machine: a headless daemon of its own, stopped on drop.
struct Machine {
    side: Side,
    socket: PathBuf,
    session: String,
    root: PathBuf,
}

impl Machine {
    fn start(root: &Path) -> Self {
        let at = root.join("vm");
        let side = Side::make(&at);
        let acpmux = at.join("acpmux");
        fs::create_dir_all(&acpmux).unwrap();
        fs::set_permissions(&acpmux, fs::Permissions::from_mode(0o700)).unwrap();
        let etc = at.join("etc-cmux");
        fs::create_dir_all(&etc).unwrap();
        fs::write(etc.join("image-stamp"), "cmux-vm inputs=link-offload\n").unwrap();
        fs::write(etc.join("vm-kind"), "owner\n").unwrap();
        for file in ["image-stamp", "vm-kind"] {
            fs::set_permissions(etc.join(file), fs::Permissions::from_mode(0o644)).unwrap();
        }
        fs::set_permissions(&etc, fs::Permissions::from_mode(0o755)).unwrap();
        let machine = Self {
            side,
            socket: at.join("m.sock"),
            session: format!("link-offload-{}", std::process::id()),
            root: root.to_path_buf(),
        };
        let ensure = machine.server("ensure").output().unwrap();
        assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
        machine
    }

    fn server(&self, action: &str) -> Command {
        let at = self.side.home.parent().unwrap();
        let mut command = self.side.cmux();
        command
            .env("ACPMUX_HOME", at.join("acpmux"))
            .env("CMUX_TEST_CLOUD_ETC", at.join("etc-cmux"))
            .env("CMUX_VM_ID", "vm-link-offload")
            .env("CMUX_CODEROUTER_URL", "http://127.0.0.1:9")
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

#[test]
fn an_offloaded_command_reads_the_view_and_its_writes_come_back() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("offload-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let mac = Side::make(&root.join("mac"));
    let local = mac.home.join("Projects/app");
    fs::create_dir_all(local.join("src")).unwrap();
    fs::write(local.join("src/input.txt"), "made on the mac\n").unwrap();
    fs::write(local.join("stale.txt"), "the command deletes this\n").unwrap();
    let machine = Machine::start(&root);

    let output = mac
        .cmux()
        .args(["link", "offload", "--socket"])
        .arg(&machine.socket)
        .arg("--cwd")
        .arg(&local)
        .args(["--", "sh", "-c"])
        .arg(
            "mkdir -p out && tr a-z A-Z < src/input.txt > out/result.txt && rm stale.txt \
             && echo ran-on-the-machine && exit 3",
        )
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("mount failed") {
        eprintln!("skipping: this host may not mount FUSE: {stderr}");
        return;
    }
    let summary = stderr
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or_else(|| panic!("no summary line: {stdout}{stderr}"));
    eprintln!("OFFLOAD_SUMMARY {summary}");
    assert_eq!(output.status.code(), Some(3), "{stdout}{stderr}");
    assert!(stdout.contains("ran-on-the-machine"), "{stdout}{stderr}");
    assert_eq!(summary["exit"], 3, "{summary}");
    assert!(summary.get("published").is_some(), "{summary}");
    assert_eq!(
        fs::read_to_string(local.join("out/result.txt")).unwrap_or_default(),
        "MADE ON THE MAC\n",
        "{summary}"
    );
    assert!(!local.join("stale.txt").exists(), "{summary}");
    assert_eq!(fs::read_to_string(local.join("src/input.txt")).unwrap(), "made on the mac\n");
}
