//! R-LIFECYCLE stage 1 (handoff/rewrites/R-LIFECYCLE/DESIGN.md section 7):
//! an app session's owner stops the moment its app has left and nothing else
//! keeps it, and never while a client or a live terminal does.
//!
//! The app connects with a role-main `client-hello`; this test plays that
//! client. Before the stage, the owner of `cmux-app-*` ran until reboot after
//! its app quit (STATUS 1370, 8519).
//!
//! R-LIFECYCLE ORPHANS: the rule is on by default, for the app session and
//! for the app's Chief session (`cmux-chief-*`). Behind its switch it never
//! reached an app: a quit, a crash or a kill of an app with no terminal left
//! both owners running (fleet repro on build 3a43a131, 2026-11-04).

#![cfg(any(target_vendor = "apple", target_os = "linux"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::terminal_host_runtime::{
    TerminalHostRecord, load_terminal_host_records, request_terminal_host_pty_custody,
    terminal_host_root,
};

/// How long an owner may take to stop once nothing keeps it. The stop is an
/// event (the last client's departure or the last terminal's exit), so it
/// takes milliseconds; the rest is room for a loaded runner.
const STOP_BOUND: Duration = Duration::from_secs(10);

/// How long a kept owner is watched to prove it stays.
const KEPT_FOR: Duration = Duration::from_secs(3);

/// An app session owner this test started with `server ensure`, under its own
/// scratch root, with the stage's switch on.
struct Owner {
    root: PathBuf,
    session: String,
    socket: PathBuf,
    identity: Option<(u32, u64)>,
    /// More environment for `ensure` (the owner it starts inherits it).
    env: Vec<(&'static str, &'static str)>,
    /// `CMUX_TUI_OWNER_KEEPERS` for `ensure`; `None`: unset (the default).
    switch: Option<&'static str>,
}

impl Owner {
    fn ensure(name: &str) -> Self {
        Self::ensure_with(name, Vec::new())
    }

    fn ensure_with(name: &str, env: Vec<(&'static str, &'static str)>) -> Self {
        Self::ensure_session(&format!("cmux-app-okp-{name}"), name, env, Some("1"))
    }

    /// An owner of `session` started with the switch as `switch` (`None`:
    /// unset, as the app starts it).
    fn ensure_session(
        session: &str,
        name: &str,
        env: Vec<(&'static str, &'static str)>,
        switch: Option<&'static str>,
    ) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 1_000_000;
        let root = PathBuf::from(format!("/tmp/okp-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("state")).unwrap();
        let mut owner = Self {
            root,
            session: session.to_string(),
            socket: PathBuf::new(),
            identity: None,
            env,
            switch,
        };
        let output = owner
            .command()
            .args(["server", "ensure", "--terminal-reap-grace-seconds", "1"])
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().rev().find(|line| line.trim_start().starts_with('{'));
        let endpoint: serde_json::Value =
            line.and_then(|line| serde_json::from_str(line).ok()).unwrap_or_else(|| {
                panic!("ensure: {stdout} {}", String::from_utf8_lossy(&output.stderr))
            });
        let pid = endpoint["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()).unwrap();
        let started = cmux_tui_core::server::Starter::current(pid)
            .unwrap_or_else(|| panic!("no start time for the owner {pid}"));
        owner.identity = Some((pid, started.started_ms));
        owner.socket = PathBuf::from(endpoint["socket"].as_str().unwrap());
        owner
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--session", &self.session, "--json"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", &self.root)
            .env("CMUX_TUI_STATE_DIR", self.root.join("state"))
            .env("CMUX_TUI_CONFIG", self.root.join("home/no-config.toml"))
            .envs(self.switch.map(|value| ("CMUX_TUI_OWNER_KEEPERS", value)))
            .envs(self.env.iter().copied());
        command
    }

    /// The host records of this session's terminals (`path`, record).
    fn host_records(&self) -> Vec<(PathBuf, TerminalHostRecord)> {
        let root = terminal_host_root(&self.root.join("state"), &self.session);
        load_terminal_host_records(&root).unwrap_or_default()
    }

    /// The host record of the session's one terminal once it runs, or once
    /// it runs an incarnation other than `not`.
    fn wait_for_host(&self, not: Option<&str>, bound: Duration) -> (PathBuf, TerminalHostRecord) {
        let deadline = Instant::now() + bound;
        loop {
            let found = self
                .host_records()
                .into_iter()
                .find(|(_, record)| not.is_none_or(|old| record.incarnation != old));
            if let Some(found) = found {
                return found;
            }
            assert!(
                Instant::now() < deadline,
                "no terminal host {} within {bound:?}",
                not.map_or("started".to_string(), |old| format!("other than {old}"))
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Whether the owner this test started still runs (its pid with its own
    /// start time, so a reused pid never counts).
    fn running(&self) -> bool {
        let (pid, started_ms) = self.identity.unwrap();
        cmux_tui_core::server::Starter::current(pid).map(|it| it.started_ms) == Some(started_ms)
    }

    /// Fails unless the owner stops within `STOP_BOUND`.
    fn assert_stops(&self, why: &str) {
        let deadline = Instant::now() + STOP_BOUND;
        while self.running() {
            assert!(
                Instant::now() < deadline,
                "the owner still ran {STOP_BOUND:?} after {why}: nothing kept it"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Fails if the owner stops within `KEPT_FOR`.
    fn assert_kept(&self, by: &str) {
        let deadline = Instant::now() + KEPT_FOR;
        while Instant::now() < deadline {
            assert!(self.running(), "the owner stopped while {by} kept it");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.command().args(["server", "stop", "--force", "--end-terminals"]).output();
        if let Some((pid, _)) = self.identity {
            if self.running() {
                // SAFETY: the owner this test started (pid and start time).
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
            let deadline = Instant::now() + Duration::from_secs(10);
            while self.running() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            assert!(
                !self.running() || std::thread::panicking(),
                "the test's owner {pid} did not end"
            );
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// One connection to the owner, answered line by line.
struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self { stream, reader, next: 1 }
    }

    /// The app's connection: `client-hello` role main as its first line.
    fn app(socket: &Path) -> Self {
        let mut client = Self::connect(socket);
        let hello = client.request(serde_json::json!({"cmd": "client-hello", "role": "main"}));
        assert_eq!(hello["ok"], true, "client-hello: {hello}");
        client
    }

    /// One `cmux.protocol/2` request, which must succeed; returns its
    /// `result`.
    fn request_v2(
        &mut self,
        operation: &str,
        params: serde_json::Value,
        idempotency_key: Option<&str>,
    ) -> serde_json::Value {
        let id = format!("okp-{}", self.next);
        self.next += 1;
        let mut value = serde_json::json!({
            "protocol": "cmux.protocol/2", "type": "request", "id": id,
            "operation": operation, "params": params,
        });
        if let Some(key) = idempotency_key {
            value["idempotency_key"] = serde_json::json!(key);
        }
        writeln!(self.stream, "{value}").unwrap();
        loop {
            let mut line = String::new();
            let read = self.reader.read_line(&mut line).unwrap();
            assert!(read > 0, "the owner closed the connection before answering {value}");
            let Ok(reply) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            if reply["id"] == serde_json::json!(id) {
                assert_eq!(reply["ok"], true, "{operation}: {reply}");
                return reply["result"].clone();
            }
        }
    }

    fn request(&mut self, mut value: serde_json::Value) -> serde_json::Value {
        let id = self.next;
        self.next += 1;
        value["id"] = serde_json::json!(id);
        writeln!(self.stream, "{value}").unwrap();
        loop {
            let mut line = String::new();
            let read = self.reader.read_line(&mut line).unwrap();
            assert!(read > 0, "the owner closed the connection before answering {value}");
            let reply: serde_json::Value = match serde_json::from_str(&line) {
                Ok(reply) => reply,
                Err(_) => continue,
            };
            if reply["id"] == serde_json::json!(id) {
                return reply;
            }
        }
    }
}

/// One module, so `owner_keepers` names every test of the stage (with the
/// core's `server::owner_keepers` unit tests) in one fleet filter.
mod owner_keepers {
    use super::*;

    #[test]
    fn an_app_owner_with_nothing_kept_stops_when_its_app_leaves() {
        let owner = Owner::ensure("idle");
        let app = Client::app(&owner.socket);
        owner.assert_kept("the app's connection");
        drop(app);
        owner.assert_stops("its app's last connection closed with no terminal");
    }

    #[test]
    fn an_owner_no_app_ever_reached_is_left_running() {
        // A probe's or a script's `ensure` (no role-main hello) leaves the owner
        // as before: the process that ran `ensure` may connect later.
        let owner = Owner::ensure("no-app");
        let plain = Client::connect(&owner.socket);
        drop(plain);
        owner.assert_kept("its never-armed rule");
    }

    #[test]
    fn a_live_terminal_keeps_the_owner_until_its_shell_exits() {
        let owner = Owner::ensure("terminal");
        let mut app = Client::app(&owner.socket);
        let done = owner.root.join("done");
        // The shell lives until the test creates `done`, then exits by itself.
        let script = format!("while [ ! -e '{}' ]; do sleep 0.1; done", done.display());
        let created = app.request(serde_json::json!({
            "cmd": "create-terminal", "detached": true, "argv": ["/bin/sh", "-c", script],
        }));
        assert_eq!(created["ok"], true, "create-terminal: {created}");
        drop(app);
        owner.assert_kept("a live terminal");
        fs::write(&done, b"").unwrap();
        owner.assert_stops("its last terminal's shell exited");
    }

    #[test]
    fn a_client_that_arrives_keeps_the_owner_and_its_departure_stops_it() {
        let owner = Owner::ensure("returning");
        let app = Client::app(&owner.socket);
        // A second client (a CLI call) connects while the app is still there. An
        // answered request proves the owner registered it (a bare connect is only
        // queued in the kernel).
        let mut cli = Client::connect(&owner.socket);
        let identified = cli.request(serde_json::json!({"cmd": "identify"}));
        assert_eq!(identified["ok"], true, "identify: {identified}");
        drop(app);
        owner.assert_kept("a connected CLI client");
        drop(cli);
        owner.assert_stops("its last client left");
    }

    #[test]
    fn a_terminal_whose_host_is_lost_keeps_the_owner_through_its_respawn() {
        // The respawn of a lost host waits a backoff (0, 2, 10, 30, 60 s);
        // here it waits RESPAWN_HOLD. Its row is exited meanwhile: only the
        // respawn's mark says a new shell is on its way.
        const RESPAWN_HOLD: &str = "6000";
        let owner =
            Owner::ensure_with("respawn", vec![("CMUX_TUI_TEST_RESPAWN_DELAY_MS", RESPAWN_HOLD)]);
        let mut app = Client::app(&owner.socket);
        // A terminal in a tab: a lost host respawns only a placed terminal.
        let created = app.request(serde_json::json!({"cmd": "new-workspace", "name": "respawn"}));
        assert_eq!(created["ok"], true, "new-workspace: {created}");
        let (record_path, record) = owner.wait_for_host(None, STOP_BOUND);
        drop(app);
        owner.assert_kept("a live terminal");
        // Lose the shell with its host: stop the host so it records no exit,
        // end the shell, then end the host (a host loss, which respawns).
        let shell = request_terminal_host_pty_custody(&record, &record_path).unwrap().child_pid;
        signal(record.host_pid, libc::SIGSTOP);
        signal(shell, libc::SIGKILL);
        signal(record.host_pid, libc::SIGKILL);
        owner.assert_kept("a terminal whose new shell waits its backoff");
        // The shell comes back with no app connected, as it did before the
        // keepers rule.
        owner.wait_for_host(Some(&record.incarnation), STOP_BOUND + STOP_BOUND);
        owner.assert_kept("the respawned terminal");
    }

    #[test]
    fn a_kept_tab_of_an_ended_command_keeps_the_owner_until_it_closes() {
        // `on_exit: keep` keeps the tab and the final screen of an ended
        // command. Only this owner holds that screen: a new owner detaches the
        // tab (`detach_exited_terminal_topology_only`), so the tab keeps it.
        let owner = Owner::ensure("kept-exit");
        let mut app = Client::app(&owner.socket);
        let here = |more: serde_json::Value| {
            let mut params = serde_json::json!({"machine": "current", "session": "current"});
            for (key, value) in more.as_object().into_iter().flatten() {
                params[key] = value.clone();
            }
            params
        };
        let created = app.request_v2(
            "workspace.create",
            here(serde_json::json!({"name": "Kept", "initial_content": "empty"})),
            Some("okp-kept-workspace"),
        );
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let run = app.request_v2(
            "workspace.run",
            here(serde_json::json!({
                "workspace": workspace, "argv": ["/bin/sh", "-c", "exit 3"], "on_exit": "keep",
            })),
            Some("okp-kept-run"),
        );
        let terminal = run["value"]["terminal_id"].as_str().unwrap().to_string();
        app.request_v2(
            "terminal.wait_exit",
            here(serde_json::json!({"terminal": terminal, "timeout_ms": "10000"})),
            None,
        );
        drop(app);
        owner.assert_kept("a kept tab of an ended command");
        let mut cli = Client::connect(&owner.socket);
        cli.request_v2(
            "terminal.close",
            here(serde_json::json!({"terminal": terminal})),
            Some("okp-kept-close"),
        );
        drop(cli);
        owner.assert_stops("its kept tab closed");
    }

    #[test]
    fn an_app_owner_started_as_the_app_starts_it_stops_when_its_app_leaves() {
        // The app's `ensure` sets no switch: the rule must hold by default.
        let owner = Owner::ensure_session("cmux-app-okp-default", "default", Vec::new(), None);
        let app = Client::app(&owner.socket);
        owner.assert_kept("the app's connection");
        drop(app);
        owner.assert_stops("its app's last connection closed with no terminal (no switch set)");
    }

    #[test]
    fn a_chief_owner_stops_when_its_app_leaves() {
        // The app's Home connects to its Chief session (`cmux-chief-<home
        // hash>`, ChiefConversationOwner.swift) with the same role-main hello.
        let owner = Owner::ensure_session("cmux-chief-0c4e0f2a", "chief", Vec::new(), None);
        let app = Client::app(&owner.socket);
        owner.assert_kept("the app's Home connection");
        drop(app);
        owner.assert_stops("its app's Home connection closed and nothing keeps the Chief owner");
    }

    #[test]
    fn the_switch_set_to_0_leaves_the_owner_running() {
        // `CMUX_TUI_OWNER_KEEPERS=0` (the app's `CMUX_NEXT_TUI_OWNER_KEEPERS=0`)
        // turns the rule off: the owner runs on as before it.
        let owner = Owner::ensure_session("cmux-app-okp-off", "off", Vec::new(), Some("0"));
        let app = Client::app(&owner.socket);
        drop(app);
        owner.assert_kept("its switched-off rule");
    }

    #[test]
    fn a_supervised_chief_brain_keeps_the_chief_owner_until_it_ends() {
        // The Chief owner runs the brains of the Chiefs that are not the
        // default (chief_brains.rs). Its stop SIGTERMs them, which cuts a
        // turn and drops a waiting start. A brain is connected only while its
        // link is up; in a reconnect gap, a start window or a restart backoff
        // it is not, so a running or pending brain itself keeps the owner
        // (review of #35218).
        use std::os::unix::fs::PermissionsExt;
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 1_000_000;
        // Short: a brain's socket lives under its home (103-byte limit).
        let files = PathBuf::from(format!("/tmp/okb-{}-{stamp}", std::process::id()));
        fs::create_dir_all(files.join("h")).unwrap();
        // A brain that never connects (its link is down) and exits 0 when
        // the test writes `quit` in its home: a brain that ends cleanly
        // waits for the next message and keeps nothing.
        let brain = files.join("brain.sh");
        fs::write(
            &brain,
            "#!/bin/sh\n[ \"$1\" = end-sessions ] && exit 0\necho $$ > \"$MUX_HOME/pid\"\n\
             while [ ! -e \"$MUX_HOME/quit\" ]; do sleep 0.1; done\nexit 0\n",
        )
        .unwrap();
        let acpmux = files.join("acpmux.sh");
        fs::write(&acpmux, "#!/bin/sh\nexit 1\n").unwrap();
        for script in [&brain, &acpmux] {
            fs::set_permissions(script, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let brains = serde_json::json!({
            "executable": brain, "home": files.join("h"),
            "app": {"bin_dir": "/usr/bin", "user_name": "Test Person", "chief_title": "Chief",
                    "acpmux_bin": acpmux},
        })
        .to_string();
        let brains: &'static str = Box::leak(brains.into_boxed_str());
        let owner = Owner::ensure_session(
            "cmux-chief-0b7a1e55",
            "brains",
            vec![("CMUX_TUI_CHIEF_BRAINS", brains)],
            None,
        );
        let app = Client::app(&owner.socket);
        let mut cli = Client::connect(&owner.socket);
        let created = cli.request_v2(
            "chief.profile.create",
            serde_json::json!({"machine": "current", "session": "current",
                               "display_name": "Scout", "role": "Researcher"}),
            Some("okp-brain-create"),
        );
        let chief = created["value"]["id"].as_str().unwrap().to_string();
        let tail = chief[chief.len() - 8..].to_ascii_lowercase();
        let brain_home = files.join("h/c").join(tail);
        let deadline = Instant::now() + STOP_BOUND;
        while !brain_home.join("pid").exists() {
            assert!(Instant::now() < deadline, "the Chief's brain never started");
            std::thread::sleep(Duration::from_millis(50));
        }
        drop(cli);
        drop(app);
        owner.assert_kept("a running supervised Chief brain whose link is down");
        fs::write(brain_home.join("quit"), b"").unwrap();
        owner.assert_stops("its only brain ended cleanly with nothing else to keep the owner");
        let _ = fs::remove_dir_all(&files);
    }

    #[test]
    fn a_signal_exit_within_the_shutdown_lead_keeps_the_owner_until_it_settles() {
        // A shell ended by a signal shortly before the owner begins a session
        // shutdown counts as lost with the session (session_shutdown.rs), so
        // its exit waits out the lead before its tab detaches. An owner that
        // stopped in that wait began a shutdown that covers the exit: the next
        // owner read it as a host loss and gave the person a new shell in a
        // tab whose shell they had just killed (review of #34188). Until the
        // exit settles, it keeps the owner. The 8 s lead is a debug-build
        // seam (`CMUX_TUI_TEST_SESSION_SHUTDOWN_LEAD_MS`): run this test in
        // the test (debug) profile, as cmux-tui-rust-check.sh does.
        let owner =
            Owner::ensure_with("settle", vec![("CMUX_TUI_TEST_SESSION_SHUTDOWN_LEAD_MS", "8000")]);
        let mut app = Client::app(&owner.socket);
        let created = app.request(serde_json::json!({"cmd": "new-workspace", "name": "settle"}));
        assert_eq!(created["ok"], true, "new-workspace: {created}");
        let (record_path, record) = owner.wait_for_host(None, STOP_BOUND);
        let shell = request_terminal_host_pty_custody(&record, &record_path).unwrap().child_pid;
        // The person kills the shell; its host records the signal exit.
        signal(shell, libc::SIGKILL);
        let deadline = Instant::now() + STOP_BOUND;
        loop {
            let resolved = app.request(
                serde_json::json!({"cmd": "resolve-terminal", "terminal_id": record.terminal_id}),
            );
            if resolved["data"]["lifecycle"] == "exited" {
                break;
            }
            assert!(Instant::now() < deadline, "the shell's exit was never committed: {resolved}");
            std::thread::sleep(Duration::from_millis(50));
        }
        drop(app);
        owner.assert_kept("a signal exit that has not settled");
        owner.assert_stops("the signal exit settled with nothing else to keep the owner");
    }
}

/// Sends `signal` to a terminal host or shell this test's owner started
/// (its own session's host record names it).
fn signal(pid: u32, signal: libc::c_int) {
    // SAFETY: `pid` is this test's own terminal host or its shell; the signal
    // is a constant.
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, signal) }, 0, "kill {pid}");
}
