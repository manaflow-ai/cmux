//! A Cloud machine whose cmux-tui is older than this client (cx-rppd.13), end
//! to end on one Linux box with real processes: the link CLIs that Move to
//! Cloud, Bring Back Local and local access run name it `machine_outdated`
//! before anything moves, instead of failing on a verb the old daemon does
//! not know, and a chat refused that way is not frozen: it moves to a current
//! machine right after.
//!
//! The older machine is this same binary under debug-only seams: it
//! reports another build (`CMUX_TEST_DAEMON_BUILD_ID`, cmux-tui daemon_build.rs),
//! another build time when a journey asks (`CMUX_TEST_DAEMON_BUILD_TIME`, main.rs) and
//! leaves the newer capabilities out of `identify`
//! (`CMUX_TEST_DAEMON_HIDE_CAPABILITIES`, cmux-tui-core capabilities.rs), as
//! a Cloud VM that baked a cmux-tui from before those verbs does. The
//! machines are shaped like the Cloud move journey's (cloud_move_journey.rs).
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const OLD_BUILD: &str = "0000000000000000000000000000000000000old";
const NEWER_VERBS: &str = "fs-v1,agent-transfer-v1,access-request-v1";

/// A short folder under /tmp: a socket path must stay under SUN_LEN.
fn journey_root(tag: &str) -> (PathBuf, Cleanup) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    (root.clone(), Cleanup(root))
}

/// The environment of a personal Cloud VM (cloud_move_journey.rs), plus `extra`.
fn cloud_vm(
    root: &Path,
    id: &str,
    extra: Vec<(&'static str, String)>,
) -> Vec<(&'static str, String)> {
    let mut env = vec![
        ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
        ("CMUX_VM_ID", id.to_owned()),
        ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
    ];
    env.extend(extra);
    env
}

fn sync_push(mac: &Machine, socket: &Path, local: &Path, remote: &Path) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(socket)
            .arg(local)
            .arg(remote),
    )
}

fn agent_move(mac: &Machine, surface: u64, to: &Machine, cwd: &Path, pump: &Path) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&to.socket)
            .arg("--cwd")
            .arg(cwd)
            .args(["--vm-kind", "owner"])
            .arg("--state-dir")
            .arg(pump),
    )
}

fn assert_outdated(answer: &Value, missing: &str) {
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(answer["error_code"], json!("machine_outdated"), "{answer}");
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.contains(missing) && error.contains(OLD_BUILD), "{answer}");
}

/// Move to Cloud onto an older machine: the folder copy and the chat move are
/// each refused as `machine_outdated` with nothing written there, a moved
/// chat's file request triage on it is too, and the chat stays live on the
/// Mac: it moves to a current machine right after.
#[test]
fn machine_gate_refuses_an_older_machine_before_anything_moves() {
    let (root, _cleanup) = journey_root("mgo");
    let mac = Machine::start(&root, "mac", Vec::new());
    let old = Machine::start(
        &root,
        "old",
        cloud_vm(
            &root,
            "vm-machine-gate-old",
            vec![
                ("CMUX_TEST_DAEMON_BUILD_ID", OLD_BUILD.to_owned()),
                ("CMUX_TEST_DAEMON_HIDE_CAPABILITIES", NEWER_VERBS.to_owned()),
            ],
        ),
    );
    let current = Machine::start(&root, "new", cloud_vm(&root, "vm-machine-gate-new", Vec::new()));

    // The folder copy: refused, nothing written on the older machine.
    let project = mac.home().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("notes.txt"), "stays here\n").unwrap();
    let there = old.home().join("work/app");
    let (ok, pushed) = sync_push(&mac, &old.socket, &project, &there);
    assert!(!ok, "{pushed}");
    assert_outdated(&pushed, "fs-v1");
    assert!(!there.exists(), "the push wrote to the older machine");

    // The chat move: refused before the chat froze on the Mac.
    let mut acpmux = mac.acpmux();
    let created = acpmux.call("session/new", json!({"cwd": project, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, "before the move", "p-gate-1"));
    let surface = bound_agent_tab(&mac, &session);
    let pump = root.join("pump");
    let (ok, moved) = agent_move(&mac, surface, &old, &there, &pump);
    assert!(!ok, "{moved}");
    assert_outdated(&moved, "agent-transfer-v1");
    assert_eq!(moved["side"], json!("target"), "{moved}");
    let events = acpmux.events(&session);
    assert!(!events.iter().any(|e| e["kind"] == "transferred"), "the chat moved: {events:?}");

    // A moved chat's file requests on the older machine: refused the same way.
    let (ok, triage) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "access", "triage", "--socket"])
            .arg(&old.socket)
            .args(["--machine", "vm-machine-gate-old", "--session", &session]),
    );
    assert!(!ok, "{triage}");
    assert_outdated(&triage, "access-request-v1");

    // A revoke is never gated: it always ends the grants on this Mac.
    let (ok, revoked) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "access", "revoke", "--socket"])
            .arg(&old.socket)
            .args(["--machine", "vm-machine-gate-old", "--session", &session, "--all"]),
    );
    assert!(ok, "a revoke was refused on the older machine: {revoked}");
    assert_eq!(revoked["revoked"], json!(0), "{revoked}");

    // The chat was never frozen: it moves to a current machine.
    let synced = current.home().join("work/app");
    let (ok, pushed) = sync_push(&mac, &current.socket, &project, &synced);
    assert!(ok, "sync push to the current machine: {pushed}");
    let (ok, moved) = agent_move(&mac, surface, &current, &synced, &pump);
    assert!(ok && moved["ok"] == json!(true), "agent move to the current machine: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");
}

/// A machine of this client's own build that does not serve a verb (here a
/// host without the Cloud records, so no `fs-v1`) is not called outdated:
/// updating it would change nothing, so the verb's own refusal stands.
#[test]
fn machine_gate_leaves_a_same_build_machine_to_its_own_refusal() {
    let (root, _cleanup) = journey_root("mgs");
    let mac = Machine::start(&root, "mac", Vec::new());
    let plain = Machine::start(&root, "plain", Vec::new());
    let project = mac.home().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("notes.txt"), "stays here\n").unwrap();
    let (ok, pushed) = sync_push(&mac, &plain.socket, &project, &plain.home().join("work/app"));
    assert!(!ok, "{pushed}");
    assert_ne!(pushed["error_code"], json!("machine_outdated"), "{pushed}");
    let code = pushed["error_code"].as_str().unwrap_or_default();
    assert!(code.starts_with("fs."), "not the daemon's own fs refusal: {pushed}");
}

// ----- Update Machine (`cmux link machine update`) -----

/// What the older machine leaves out for the update journeys: the verbs a
/// hostrun8-era image lacks. It still serves `fs-v1` and detached
/// terminals, which the update reaches it through.
const LACKS_FOR_UPDATE: &str = "agent-transfer-v1,access-request-v1";

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A Cloud machine as its image lays it out: the daemon binary at
/// `~/.cmux/bin/cmux-tui`, run in the foreground (`server start`) by a
/// supervisor that starts it again whenever it exits, as cmux-devbox-boot
/// and cmux-host do. While that binary is the older build, the supervisor
/// starts it under the older-machine seams.
struct SupervisedVm {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    stop: PathBuf,
    /// The supervisor this test started (stopped by its own pid only).
    supervisor: Option<std::process::Child>,
    env: Vec<(&'static str, String)>,
}

impl SupervisedVm {
    fn start(root: &Path, old: &[u8], with_acpmux: bool) -> Self {
        Self::start_lacking(root, old, with_acpmux, LACKS_FOR_UPDATE)
    }

    /// While the binary is the older build, its daemon leaves `lacks` (a
    /// comma list) out of `identify`.
    fn start_lacking(root: &Path, old: &[u8], with_acpmux: bool, lacks: &str) -> Self {
        Self::start_built_at(root, old, with_acpmux, lacks, "")
    }

    /// As `start_lacking`, and while the binary is the older build its daemon
    /// reports `old_time` as its `build_time` (empty: the binary's own).
    fn start_built_at(
        root: &Path,
        old: &[u8],
        with_acpmux: bool,
        lacks: &str,
        old_time: &str,
    ) -> Self {
        let dir = root.join("vm");
        for sub in ["home/work", "home/.cmux/bin", "acpmux", "state"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        let fake = json!({"argv": ["python3", FAKE_AGENT], "family": "fake",
                          "env": {"FAKE_SESSION_PREFIX": "fake-session-"}});
        let config = json!({"harnesses": {"fake": fake}, "defaultHarness": "fake",
                            "webAskingModes": {"fake": ["normal"]}});
        fs::write(dir.join("acpmux/config.json"), config.to_string()).unwrap();
        let bin = dir.join("home/.cmux/bin/cmux-tui");
        fs::write(&bin, old).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let script = dir.join("supervise.sh");
        fs::write(
            &script,
            r#"while [ ! -e "$STOP" ]; do
  if [ "$(sha256sum "$BIN" | cut -d ' ' -f 1)" = "$OLD_SHA" ]; then
    CMUX_TEST_DAEMON_BUILD_ID="$OLD_BUILD" CMUX_TEST_DAEMON_HIDE_CAPABILITIES="$LACKS" \
      CMUX_TEST_DAEMON_BUILD_TIME="$OLD_TIME" \
      "$BIN" --socket "$SOCK" --session "$SESSION" server start
  else
    "$BIN" --socket "$SOCK" --session "$SESSION" server start
  fi
  sleep 0.2
done
"#,
        )
        .unwrap();
        let mut vm = Self {
            socket: dir.join("mux.sock"),
            session: "machine-update-journey-vm".to_owned(),
            stop: dir.join("stop"),
            supervisor: None,
            env: cloud_vm(root, "vm-machine-update", Vec::new()),
            dir,
        };
        let log = fs::File::create(vm.dir.join("supervisor.log")).unwrap();
        let supervisor = vm
            .command("sh")
            .arg(&script)
            .env("BIN", &bin)
            .env("SOCK", &vm.socket)
            .env("SESSION", &vm.session)
            .env("STOP", &vm.stop)
            .env("OLD_SHA", sha256_hex(old))
            .env("OLD_BUILD", OLD_BUILD)
            .env("LACKS", lacks)
            .env("OLD_TIME", old_time)
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap();
        vm.supervisor = Some(supervisor);
        wait_until(60, "the machine daemon", || vm.identify());
        if with_acpmux {
            let started = vm
                .command(bin.to_str().unwrap())
                .args(["acp", "daemon", "start"])
                .output()
                .unwrap();
            assert!(started.status.success(), "acp: {}", String::from_utf8_lossy(&started.stderr));
        }
        vm
    }

    fn home(&self) -> PathBuf {
        self.dir.join("home")
    }

    fn bin(&self) -> PathBuf {
        self.home().join(".cmux/bin/cmux-tui")
    }

    /// `program` with the machine's environment, as its supervisor runs.
    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        command
            .env("HOME", self.home())
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_AGENT_START_HOST")
            .env_remove("CMUX_TEST_DAEMON_BUILD_ID")
            .env_remove("CMUX_TEST_DAEMON_HIDE_CAPABILITIES")
            .env_remove("CMUX_TEST_DAEMON_BUILD_TIME")
            .stdin(std::process::Stdio::null());
        for (key, value) in &self.env {
            command.env(key, value);
        }
        command
    }

    fn rpc(&self, request: Value) -> Value {
        use std::io::{BufRead as _, Write as _};
        let stream = std::os::unix::net::UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(std::time::Duration::from_secs(60))).unwrap();
        let mut reader = std::io::BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the daemon closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message.get("event").is_none() {
                return message;
            }
        }
    }

    /// `identify`'s data, once the daemon answers.
    fn identify(&self) -> Option<Value> {
        use std::io::{BufRead as _, Write as _};
        let stream = std::os::unix::net::UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).ok()?;
        let mut reader = std::io::BufReader::new(stream);
        writeln!(reader.get_mut(), "{}", json!({"id": 1, "cmd": "identify"})).ok()?;
        let mut line = String::new();
        reader.read_line(&mut line).ok()?;
        let answer: Value = serde_json::from_str(&line).ok()?;
        (answer["ok"] == json!(true)).then(|| answer["data"].clone())
    }

    fn acpmux(&self) -> Acpmux {
        Acpmux::connect(&self.dir.join("acpmux/acpmux.sock"))
    }
}

impl Drop for SupervisedVm {
    fn drop(&mut self) {
        let _ = fs::write(&self.stop, "");
        let bin = self.bin();
        let program = bin.to_str().unwrap_or_default().to_owned();
        let _ = self
            .command(&program)
            .args([
                "server",
                "stop",
                "--json",
                "--end-terminals",
                "--session",
                &self.session,
                "--socket",
            ])
            .arg(&self.socket)
            .output();
        let _ = self.command(&program).args(["acp", "daemon", "shutdown", "--end-agents"]).output();
        let Some(mut supervisor) = self.supervisor.take() else { return };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while std::time::Instant::now() < deadline {
            if matches!(supervisor.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        // The supervisor this test started, by its own pid.
        let _ = supervisor.kill();
        let _ = supervisor.wait();
    }
}

/// A Mac's bundled `cmux`: this binary, copied with the signed manifest a
/// release bundles beside it (`cmux-tui-ssh/manifest.json`, naming this
/// build) and the Linux build it pins. `pin` is the checksum the manifest
/// carries (the shipped build's own when None).
fn mac_client(root: &Path, pin: Option<&str>) -> PathBuf {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = root.join("mac-bin");
    let ssh = dir.join("cmux-tui-ssh");
    fs::create_dir_all(&ssh).unwrap();
    let client = dir.join("cmux-tui");
    fs::copy(bin(), &client).unwrap();
    fs::set_permissions(&client, fs::Permissions::from_mode(0o755)).unwrap();
    let shipped = fs::read(bin()).unwrap();
    fs::write(ssh.join("cmux-tui-x86_64-unknown-linux-musl"), &shipped).unwrap();
    let probe = Command::new(bin()).args(["remote-probe", "--json"]).output().unwrap();
    let probe: Value = serde_json::from_slice(&probe.stdout).unwrap();
    let identity =
        probe["build_identity"].as_str().expect("remote-probe names this build").to_owned();
    let pin = pin.map_or_else(|| sha256_hex(&shipped), str::to_owned);
    let manifest = json!({"commit": identity,
                          "binaries": {"cmux-tui-x86_64-unknown-linux-musl": pin}});
    fs::write(ssh.join("manifest.json"), manifest.to_string()).unwrap();
    client
}

fn machine_update(client: &Path, root: &Path, vm: &SupervisedVm) -> (bool, Value) {
    run_json(
        Command::new(client)
            .env("XDG_CACHE_HOME", root.join("mac-cache"))
            .args(["link", "machine", "update", "--socket"])
            .arg(&vm.socket),
    )
}

/// `cmux link machine update --socket S --to-bundled` (Update Everything).
fn machine_update_to_bundled(client: &Path, root: &Path, vm: &SupervisedVm) -> (bool, Value) {
    run_json(
        Command::new(client)
            .env("XDG_CACHE_HOME", root.join("mac-cache"))
            .args(["link", "machine", "update", "--socket"])
            .arg(&vm.socket)
            .arg("--to-bundled"),
    )
}

/// `cmux link machine update --socket S --to-bundled --if-older` (the app's
/// automatic update).
fn machine_update_if_older(client: &Path, root: &Path, vm: &SupervisedVm) -> (bool, Value) {
    run_json(
        Command::new(client)
            .env("XDG_CACHE_HOME", root.join("mac-cache"))
            .args(["link", "machine", "update", "--socket"])
            .arg(&vm.socket)
            .args(["--to-bundled", "--if-older"]),
    )
}

fn triage(vm: &SupervisedVm, root: &Path) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", root.join("mac-state"))
            .args(["link", "access", "triage", "--socket"])
            .arg(&vm.socket)
            .args(["--machine", "vm-machine-update", "--session", "fake-session-none"]),
    )
}

/// Update Machine on an older machine: the gate names it outdated, the
/// update installs this client's pinned build in place (the old one kept as
/// `cmux-tui.prev`) and the supervisor's restart runs it, and a live
/// terminal and a live chat on the machine both survive the swap and the
/// restart. The gate then lets the verb through; a second update changes
/// nothing.
#[test]
fn machine_update_swaps_in_the_pinned_build_and_keeps_terminals_and_chats() {
    let (root, _cleanup) = journey_root("mgu");
    let shipped = fs::read(bin()).unwrap();
    let mut old = shipped.clone();
    old.extend_from_slice(b"\0cmux-tui built before the move verbs\0");
    let vm = SupervisedVm::start(&root, &old, true);
    let before = vm.identify().unwrap();
    assert_eq!(before["build_id"], json!(OLD_BUILD), "{before}");

    // What must survive: a terminal and a chat with a finished turn.
    let pid_file = root.join("terminal.pid");
    let shell = format!("echo $$ > '{}'; exec sleep 900", pid_file.display());
    let terminal = vm.rpc(json!({"id": 2, "cmd": "create-terminal", "detached": true,
                                 "argv": ["sh", "-c", shell]}));
    assert_eq!(terminal["ok"], true, "{terminal}");
    let terminal_id = terminal["data"]["terminal_id"].as_str().unwrap().to_owned();
    let incarnation = |vm: &SupervisedVm| {
        let listed = vm.rpc(json!({"id": 3, "cmd": "list-terminals"}));
        let terminals = listed["data"]["terminals"].as_array().cloned().unwrap_or_default();
        terminals
            .iter()
            .find(|t| t["terminal_id"] == json!(terminal_id))
            .map(|t| (t["terminal_incarnation"].clone(), t["exit"].clone()))
    };
    let pid: i32 = wait_until(20, "the terminal's process", || {
        fs::read_to_string(&pid_file).ok().and_then(|text| text.trim().parse().ok())
    });
    let listed = incarnation(&vm).expect("the terminal is listed");
    let mut acpmux = vm.acpmux();
    let created =
        acpmux.call("session/new", json!({"cwd": vm.home().join("work"), "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, "before the update", "p-update-1"));

    // The gate names the older machine.
    let (ok, refused) = triage(&vm, &root);
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], json!("machine_outdated"), "{refused}");

    // Update Machine.
    let client = mac_client(&root, None);
    let (ok, updated) = machine_update(&client, &root, &vm);
    let log = fs::read_to_string(vm.dir.join("supervisor.log")).unwrap_or_default();
    assert!(ok && updated["updated"] == json!(true), "update: {updated}\n{log}");
    assert_eq!(updated["previous_build"], json!(OLD_BUILD), "{updated}");

    // The machine runs the pinned build from its supervisor's path, the old
    // one kept beside it, nothing staged left.
    let after = vm.identify().expect("the updated daemon serves");
    assert_eq!(after["build_id"], updated["build"], "{after}");
    assert_ne!(after["pid"], before["pid"], "the daemon did not restart");
    assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&shipped));
    let kept = fs::read(vm.home().join(".cmux/bin/cmux-tui.prev")).unwrap();
    assert_eq!(sha256_hex(&kept), sha256_hex(&old), "the previous build is not kept");
    let mut left: Vec<String> = fs::read_dir(vm.home().join(".cmux/bin"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    // The update lock stays, empty: removing it would let two updates race.
    assert_eq!(
        left,
        [".cmux-tui.update.lock", "cmux-tui", "cmux-tui.prev"],
        "leftovers next to the binary"
    );

    // The terminal and the chat survived the swap and the restart.
    assert_eq!(incarnation(&vm), Some(listed), "the terminal did not survive");
    // SAFETY: signal 0 only checks that the process exists.
    assert!(unsafe { libc::kill(pid, 0) } == 0, "its process is gone");
    let mut acpmux = vm.acpmux();
    assert!(acpmux.summary(&session).is_some(), "the chat is gone");
    acpmux.call("session/prompt", prompt(&session, "after the update", "p-update-2"));
    let events = acpmux.events(&session);
    assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, "echo: after the update"), 1);

    // The gate lets the verb through now, and a second update does nothing.
    let (ok, triaged) = triage(&vm, &root);
    assert!(ok, "triage after the update: {triaged}");
    let (ok, again) = machine_update(&client, &root, &vm);
    assert!(ok && again["updated"] == json!(false), "{again}");
}

/// Update Everything (cx-1mbnu): a machine of another build that serves every
/// verb the gate needs is left alone by a plain update, and updated in place
/// to this client's own build with `--to-bundled`, keeping its chat; once it
/// runs that build, `--to-bundled` changes nothing.
#[test]
fn machine_update_to_bundled_updates_a_machine_of_another_build_that_serves_every_verb() {
    let (root, _cleanup) = journey_root("mgb");
    let shipped = fs::read(bin()).unwrap();
    let mut old = shipped.clone();
    old.extend_from_slice(b"\0cmux-tui of another build\0");
    let vm = SupervisedVm::start_lacking(&root, &old, true, "");
    let before = vm.identify().unwrap();
    assert_eq!(before["build_id"], json!(OLD_BUILD), "{before}");
    let mut acpmux = vm.acpmux();
    let created =
        acpmux.call("session/new", json!({"cwd": vm.home().join("work"), "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();

    let client = mac_client(&root, None);
    let (ok, plain) = machine_update(&client, &root, &vm);
    assert!(ok && plain["updated"] == json!(false), "a plain update: {plain}");
    assert_eq!(vm.identify().unwrap()["pid"], before["pid"], "a plain update restarted it");

    let (ok, updated) = machine_update_to_bundled(&client, &root, &vm);
    let log = fs::read_to_string(vm.dir.join("supervisor.log")).unwrap_or_default();
    assert!(ok && updated["updated"] == json!(true), "update: {updated}\n{log}");
    assert_eq!(updated["previous_build"], json!(OLD_BUILD), "{updated}");
    let after = vm.identify().expect("the updated daemon serves");
    assert_eq!(after["build_id"], updated["build"], "{after}");
    assert_ne!(after["pid"], before["pid"], "the daemon did not restart");
    assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&shipped));
    assert!(vm.acpmux().summary(&session).is_some(), "the chat is gone");

    let (ok, again) = machine_update_to_bundled(&client, &root, &vm);
    assert!(ok && again["updated"] == json!(false), "{again}");
}

/// The app's automatic update (`--to-bundled --if-older`): a machine of
/// another build that serves every verb is updated when its build time is
/// older than this client's, and left alone, not restarted, when it is newer
/// (2026-10-27: no app update reached a VM on 8b3b1891 that served every
/// verb the app uses, because the app could not tell older from newer).
#[test]
fn machine_update_if_older_updates_only_an_older_machine() {
    let shipped = fs::read(bin()).unwrap();
    let mut old = shipped.clone();
    old.extend_from_slice(b"\0cmux-tui of another build\0");

    // Newer: built in 2100. Nothing changes.
    let (root, _cleanup) = journey_root("mgn");
    let vm = SupervisedVm::start_built_at(&root, &old, false, "", "4102444800");
    let before = vm.identify().unwrap();
    assert_eq!(before["build_id"], json!(OLD_BUILD), "{before}");
    let client = mac_client(&root, None);
    let (ok, newer) = machine_update_if_older(&client, &root, &vm);
    assert!(ok && newer["updated"] == json!(false) && newer["not_older"] == json!(true), "{newer}");
    assert_eq!(vm.identify().unwrap()["pid"], before["pid"], "a newer machine was restarted");
    assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&old));
    drop(vm);

    // Older: built in 1970. Updated in place to this client's build.
    let (root, _cleanup) = journey_root("mgl");
    let vm = SupervisedVm::start_built_at(&root, &old, false, "", "1");
    let before = vm.identify().unwrap();
    let client = mac_client(&root, None);
    let (ok, updated) = machine_update_if_older(&client, &root, &vm);
    let log = fs::read_to_string(vm.dir.join("supervisor.log")).unwrap_or_default();
    assert!(ok && updated["updated"] == json!(true), "update: {updated}\n{log}");
    let after = vm.identify().expect("the updated daemon serves");
    assert_eq!(after["build_id"], updated["build"], "{after}");
    assert_ne!(after["pid"], before["pid"], "the daemon did not restart");
    assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&shipped));
    drop(vm);

    // Older and too old to update in place (no fs-v1): unsupported, naming the build it was
    // judged on (the app's exec update holds the machine to it), and nothing restarted.
    let (root, _cleanup) = journey_root("mgu");
    let vm = SupervisedVm::start_built_at(&root, &old, false, "fs-v1", "1");
    let before = vm.identify().unwrap();
    let client = mac_client(&root, None);
    let (ok, unsupported) = machine_update_if_older(&client, &root, &vm);
    assert!(
        !ok && unsupported["error_code"] == json!("machine_update_unsupported"),
        "{unsupported}"
    );
    assert_eq!(unsupported["build"], before["build_commit"], "{unsupported}");
    assert_eq!(vm.identify().unwrap()["pid"], before["pid"], "an unsupported update restarted it");
}

/// A build that does not match the checksum this client's manifest pins is
/// refused before anything reaches the machine: its binary, its daemon and
/// the folder beside the binary stay as they were.
#[test]
fn machine_update_refuses_a_build_that_does_not_match_its_pin() {
    let (root, _cleanup) = journey_root("mgm");
    let mut old = fs::read(bin()).unwrap();
    old.extend_from_slice(b"\0cmux-tui built before the move verbs\0");
    let vm = SupervisedVm::start(&root, &old, false);
    let before = vm.identify().unwrap();
    let wrong = sha256_hex(b"not the shipped build");
    let client = mac_client(&root, Some(&wrong));
    let (ok, refused) = machine_update(&client, &root, &vm);
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], json!("machine_update_payload_rejected"), "{refused}");
    let after = vm.identify().expect("the old daemon still serves");
    assert_eq!(after["pid"], before["pid"], "the daemon restarted");
    assert_eq!(after["build_id"], json!(OLD_BUILD), "{after}");
    assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&old));
    let left: Vec<String> = fs::read_dir(vm.home().join(".cmux/bin"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left, ["cmux-tui"], "something was written next to the binary");
}

/// The machine side of the update checks everything before it changes
/// anything: run directly with a wrong checksum, a pid that is not the
/// daemon, an install path outside its own home, a result file elsewhere,
/// or while another update holds the lock, it refuses, and the machine's
/// binary and daemon stay as they were.
#[test]
fn machine_update_apply_step_refuses_before_changing_anything() {
    use std::os::unix::fs::PermissionsExt as _;
    use std::os::unix::io::AsRawFd as _;
    let (root, _cleanup) = journey_root("mga");
    let shipped = fs::read(bin()).unwrap();
    let mut old = shipped.clone();
    old.extend_from_slice(b"\0cmux-tui built before the move verbs\0");
    let vm = SupervisedVm::start(&root, &old, false);
    let before = vm.identify().unwrap();
    let folder = vm.home().join(".cmux/bin");
    let staged = folder.join(".cmux-tui.update-00000000000000aa");
    fs::write(&staged, &shipped).unwrap();
    fs::set_permissions(&staged, fs::Permissions::from_mode(0o755)).unwrap();
    let sha = sha256_hex(&shipped);
    let pid = before["pid"].as_u64().unwrap().to_string();
    let install = vm.bin();
    let result = folder.join(".cmux-tui.update-00000000000000bb.json");
    let apply = |sha: &str, install: &Path, pid: &str, result: &Path| {
        let output = vm
            .command(staged.to_str().unwrap())
            .env("CMUX_TUI_SOCKET", &vm.socket)
            .arg("__machine-update-apply")
            .args(["--sha256", sha, "--install"])
            .arg(install)
            .args(["--daemon-pid", pid, "--result"])
            .arg(result)
            .output()
            .unwrap();
        let outcome: Option<Value> =
            fs::read_to_string(result).ok().and_then(|text| serde_json::from_str(&text).ok());
        let _ = fs::remove_file(result);
        (output.status.code(), outcome)
    };
    let unchanged = |why: &str| {
        let now = vm.identify().expect("the old daemon still serves");
        assert_eq!(now["pid"], before["pid"], "{why}: the daemon restarted");
        assert_eq!(now["build_id"], json!(OLD_BUILD), "{why}: {now}");
        assert_eq!(sha256_hex(&fs::read(vm.bin()).unwrap()), sha256_hex(&old), "{why}");
        assert!(staged.exists(), "{why}: the staged build moved");
        assert!(!folder.join("cmux-tui.prev").exists(), "{why}: a previous build was kept");
    };

    let wrong = sha256_hex(b"another build");
    let (code, outcome) = apply(&wrong, &install, &pid, &result);
    assert_eq!(
        (code, outcome.as_ref().map(|o| o["state"].clone())),
        (Some(1), Some(json!("failed"))),
        "{outcome:?}"
    );
    unchanged("a wrong checksum");

    let not_daemon = std::process::id().to_string();
    let (code, outcome) = apply(&sha, &install, &not_daemon, &result);
    assert_eq!(
        (code, outcome.as_ref().map(|o| o["state"].clone())),
        (Some(1), Some(json!("failed"))),
        "{outcome:?}"
    );
    unchanged("a pid that is not the daemon");

    let elsewhere = root.join("elsewhere/.cmux/bin");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("cmux-tui"), &old).unwrap();
    let elsewhere_result = elsewhere.join(".cmux-tui.update-00000000000000cc.json");
    let (code, outcome) = apply(&sha, &elsewhere.join("cmux-tui"), &pid, &elsewhere_result);
    assert_eq!((code, outcome), (Some(1), None), "an outcome was written outside its home");
    unchanged("an install path outside its home");
    assert_eq!(fs::read(elsewhere.join("cmux-tui")).unwrap(), old);
    let written: Vec<_> =
        fs::read_dir(&elsewhere).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(written, ["cmux-tui"], "files were written outside its home");

    // A process of the installed binary that is not the daemon serving
    // this machine (a second daemon on another socket).
    let other_socket = vm.dir.join("other.sock");
    let mut other = vm
        .command(vm.bin().to_str().unwrap())
        .env("CMUX_TUI_STATE_DIR", vm.dir.join("other-state"))
        .arg("--socket")
        .arg(&other_socket)
        .args(["--session", "machine-update-other", "server", "start"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    wait_until(60, "the second daemon", || {
        std::os::unix::net::UnixStream::connect(&other_socket).ok()
    });
    let (code, outcome) = apply(&sha, &install, &other.id().to_string(), &result);
    // The test's own child, by its own pid.
    let _ = other.kill();
    let _ = other.wait();
    assert_eq!(
        (code, outcome.as_ref().map(|o| o["state"].clone())),
        (Some(1), Some(json!("failed"))),
        "{outcome:?}"
    );
    unchanged("a pid of the binary that is not the serving daemon");

    let (code, outcome) =
        apply(&sha, &install, &pid, &root.join(".cmux-tui.update-00000000000000dd.json"));
    assert_eq!((code, outcome), (Some(64), None), "a result file elsewhere was accepted");
    unchanged("a result file elsewhere");

    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(folder.join(".cmux-tui.update.lock"))
        .unwrap();
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let (code, outcome) = apply(&sha, &install, &pid, &result);
    assert_eq!(
        (code, outcome.as_ref().map(|o| o["state"].clone())),
        (Some(1), Some(json!("busy"))),
        "{outcome:?}"
    );
    unchanged("another update holding the lock");
}
