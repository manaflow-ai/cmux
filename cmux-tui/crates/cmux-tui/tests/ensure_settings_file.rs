//! The settings file is part of an owner's launch: `server ensure` started
//! with CMUX_NEXT_CONFIG_FILE (as the app starts its daemon,
//! plans/cmux-next/settings-react.md section 7, item 1) starts a detached
//! owner that reads and writes that file and names it in `settings.snapshot`
//! (`path`). A client with a settings file of its own compares the two
//! before it sends a write, so the write never goes to another file. A
//! `server restart` from a client without the variable keeps the file, also
//! from another directory when the launch named the file by a relative path;
//! a restarting client that names a file of its own moves the owner to it.
//! A real owner process; the clients after the launch name no settings file
//! unless the test says so.
//!
//! The owner's terminal children do not get the variable, so a daemon that a
//! test starts in a terminal with only its own `HOME` writes its own default
//! file. A CLI reader in the terminal (`cmux settings validate`) asks the
//! owner for `path` instead, within a deadline, and reads the default file
//! when no owner answers.

// `server restart` reads the old owner's launch from the OS on these two.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        // Tests run in parallel threads of one process and can read the same
        // clock value: the counter keeps each fixture's directory its own.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = PathBuf::from("/tmp").join(format!("cmux-sf-{}-{stamp}-{n}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir }
    }

    /// The settings file the session's owner names (`settings.snapshot` `path`).
    fn owner_file(&self) -> Value {
        let mut snapshot = self.operation("settings.snapshot", json!({}), false);
        snapshot["path"].take()
    }

    /// The default settings file below this fixture's home, which no owner
    /// here may make.
    fn default_file(&self) -> PathBuf {
        self.dir.join("home/.config/cmux/cmux-next.json")
    }

    /// A `cmux-tui` process with this fixture's home and state and without
    /// a settings file variable: only the launch names the file.
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
            .env_remove("CMUX_NEXT_CONFIG_FILE")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        command
    }

    fn server(&self, action: &str) -> Command {
        let mut command = self.cmux();
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }

    /// `cmux --json raw operation <operation>`: the operation's result.
    fn operation(&self, operation: &str, params: Value, mutation: bool) -> Value {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut command = self.cmux();
        command.args(["--json", "--socket"]).arg(&self.socket).args([
            "raw",
            "operation",
            operation,
            "--params-json",
            &params.to_string(),
        ]);
        if mutation {
            command.arg("--mutation");
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{operation} failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    /// Starts the session's owner on the settings file `settings`.
    fn ensure_on(&self, settings: &std::path::Path) {
        let ensured =
            self.server("ensure").env("CMUX_NEXT_CONFIG_FILE", settings).output().unwrap();
        assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));
    }

    /// `cmux --json settings validate` with no file, as a process with the
    /// environment `env` over [`Self::cmux`]: the file the reader used, and
    /// whether that file exists.
    fn validated(&self, env: &[(&str, &std::path::Path)]) -> (Value, Value) {
        let mut command = self.cmux();
        command.envs(env.iter().copied()).args(["--json", "settings", "validate"]);
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "settings validate failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let mut answer: Value = serde_json::from_slice(&output.stdout).unwrap();
        (answer["file"].take(), answer["exists"].take())
    }

    /// Runs `script` with `/bin/sh` in a new terminal of the session's owner
    /// and returns what the script writes to `$OUT`. `$OUT` is a FIFO: the
    /// read ends when the script closes it, so nothing polls.
    fn in_terminal(&self, name: &str, script: &str) -> String {
        let fifo = self.dir.join(format!("{name}.fifo"));
        let made = Command::new("mkfifo").arg(&fifo).status().unwrap();
        assert!(made.success(), "mkfifo {}", fifo.display());
        let (sender, receiver) = std::sync::mpsc::channel();
        let reader = fifo.clone();
        std::thread::spawn(move || {
            let _ = sender.send(fs::read_to_string(reader));
        });
        let script = script.replace("$OUT", fifo.to_str().unwrap());
        let run = json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": name,
        });
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        writeln!(writer, "{run}").unwrap();
        let mut answer = String::new();
        BufReader::new(stream).read_line(&mut answer).unwrap();
        let created: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(created["ok"], true, "{created}");
        receiver
            .recv_timeout(Duration::from_secs(120))
            .unwrap_or_else(|_| panic!("the terminal never wrote {}", fifo.display()))
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.server("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn an_owner_ensured_with_a_settings_file_names_it_in_the_snapshot_and_writes_it() {
    let fixture = Fixture::new("ensure-settings-file");
    // Not the default place below the owner's HOME.
    let settings = fixture.dir.join("app").join("cmux-next.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "{\n  \"tabs\": {\n    \"barPosition\": \"top\"\n  }\n}\n").unwrap();
    let ensured =
        fixture.server("ensure").env("CMUX_NEXT_CONFIG_FILE", &settings).output().unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));

    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(settings.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "top", "{snapshot}");

    fixture.operation("settings.set", json!({"key": "tabs.barPosition", "value": "bottom"}), true);
    let text = fs::read_to_string(&settings).unwrap();
    assert!(text.contains("\"barPosition\": \"bottom\""), "the launch's file kept:\n{text}");
    let default = fixture.dir.join("home/.config/cmux/cmux-next.json");
    assert!(!default.exists(), "the owner made {}", default.display());

    // The next owner of this session keeps the file, though the client that
    // restarts it names none.
    let restarted = fixture.server("restart").output().unwrap();
    assert!(restarted.status.success(), "{}", String::from_utf8_lossy(&restarted.stderr));
    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(settings.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "bottom", "{snapshot}");
    assert!(!default.exists(), "the restarted owner made {}", default.display());
}

const TOP: &str = "{\n  \"tabs\": {\n    \"barPosition\": \"top\"\n  }\n}\n";
const BOTTOM: &str = "{\n  \"tabs\": {\n    \"barPosition\": \"bottom\"\n  }\n}\n";

/// `CMUX_NEXT_CONFIG_FILE=cfg.json cmux server ensure` in one directory,
/// then `server restart` in another: the client that ensured made the path
/// absolute, so the next owner keeps the first directory's file.
#[test]
fn a_relative_settings_file_stays_in_the_launch_directory_after_a_restart_from_another() {
    let fixture = Fixture::new("settings-file-relative");
    // As a process inside them names them (on macOS /tmp is a link).
    let root = fs::canonicalize(&fixture.dir).unwrap();
    let (first, second) = (root.join("first"), root.join("second"));
    fs::create_dir_all(&first).unwrap();
    fs::create_dir_all(&second).unwrap();
    let settings = first.join("cfg.json");
    fs::write(&settings, TOP).unwrap();

    let ensured = fixture
        .server("ensure")
        .current_dir(&first)
        .env("CMUX_NEXT_CONFIG_FILE", "cfg.json")
        .output()
        .unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));
    assert_eq!(fixture.owner_file(), json!(settings.to_str().unwrap()));

    let restarted = fixture.server("restart").current_dir(&second).output().unwrap();
    assert!(restarted.status.success(), "{}", String::from_utf8_lossy(&restarted.stderr));
    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(settings.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "top", "{snapshot}");

    fixture.operation("settings.set", json!({"key": "tabs.barPosition", "value": "bottom"}), true);
    let text = fs::read_to_string(&settings).unwrap();
    assert!(text.contains("\"barPosition\": \"bottom\""), "the launch's file kept:\n{text}");
    let moved = second.join("cfg.json");
    assert!(!moved.exists(), "the restarted owner made {}", moved.display());
    let default = fixture.default_file();
    assert!(!default.exists(), "an owner made {}", default.display());
}

/// A restarting client that names a settings file moves the owner to it
/// (its value wins over the carried one); an empty value names none, so that
/// restart keeps the owner's file.
#[test]
fn a_restarting_clients_settings_file_wins_and_an_empty_one_keeps_the_owners() {
    let fixture = Fixture::new("settings-file-client-wins");
    let (first, second) = (fixture.dir.join("first.json"), fixture.dir.join("second.json"));
    fs::write(&first, TOP).unwrap();
    fs::write(&second, BOTTOM).unwrap();

    let ensured = fixture.server("ensure").env("CMUX_NEXT_CONFIG_FILE", &first).output().unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));
    assert_eq!(fixture.owner_file(), json!(first.to_str().unwrap()));

    let restarted =
        fixture.server("restart").env("CMUX_NEXT_CONFIG_FILE", &second).output().unwrap();
    assert!(restarted.status.success(), "{}", String::from_utf8_lossy(&restarted.stderr));
    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(second.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "bottom", "{snapshot}");

    let restarted = fixture.server("restart").env("CMUX_NEXT_CONFIG_FILE", "").output().unwrap();
    assert!(restarted.status.success(), "{}", String::from_utf8_lossy(&restarted.stderr));
    assert_eq!(fixture.owner_file(), json!(second.to_str().unwrap()));
    let default = fixture.default_file();
    assert!(!default.exists(), "an owner made {}", default.display());
}

/// `cmux settings validate` with no file, run without the variable and with
/// the owner's socket in its environment (as in a terminal of that owner),
/// reads the owner's file. The reader's own variable still wins, and a
/// reader outside a cmux terminal asks nobody and reads the default file.
#[test]
fn a_cli_reader_with_the_owners_socket_reads_the_owners_settings_file() {
    let fixture = Fixture::new("settings-file-reader");
    let settings = fixture.dir.join("app").join("cmux-next.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, TOP).unwrap();
    fixture.ensure_on(&settings);

    let started = Instant::now();
    let (file, exists) = fixture.validated(&[("CMUX_TUI_SOCKET", fixture.socket.as_path())]);
    let with_ask = started.elapsed();
    assert_eq!(file, json!(settings.to_str().unwrap()));
    assert_eq!(exists, true);

    let own = fixture.dir.join("own.json");
    fs::write(&own, BOTTOM).unwrap();
    let (file, exists) = fixture.validated(&[
        ("CMUX_TUI_SOCKET", fixture.socket.as_path()),
        ("CMUX_NEXT_CONFIG_FILE", own.as_path()),
    ]);
    assert_eq!(file, json!(own.to_str().unwrap()), "the reader's own variable wins");
    assert_eq!(exists, true);

    let started = Instant::now();
    let (file, exists) = fixture.validated(&[]);
    let without_ask = started.elapsed();
    assert_eq!(file, json!(fixture.default_file().to_str().unwrap()));
    assert_eq!(exists, false);
    // What the ask costs a reader in a cmux terminal (shown with --nocapture).
    eprintln!("settings validate: {with_ask:?} with the owner ask, {without_ask:?} without");
}

/// With no owner at the socket its environment names, and with one that
/// accepts and never answers, the reader reads the default file and exits 0;
/// the silent owner costs it the ask's deadline, not a hang.
#[test]
fn a_cli_reader_without_a_reachable_owner_reads_the_default_file() {
    // No owner is started: the fixture's stop at the end finds none.
    let fixture = Fixture::new("settings-file-no-owner");
    let default = json!(fixture.default_file().to_str().unwrap());

    let gone = fixture.dir.join("gone.sock");
    let (file, exists) = fixture.validated(&[("CMUX_TUI_SOCKET", gone.as_path())]);
    assert_eq!(file, default, "no socket at the path");
    assert_eq!(exists, false);

    let silent = fixture.dir.join("silent.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&silent).unwrap();
    let started = Instant::now();
    let (file, exists) = fixture.validated(&[("CMUX_TUI_SOCKET", silent.as_path())]);
    let waited = started.elapsed();
    assert_eq!(file, default, "an owner that never answers");
    assert_eq!(exists, false);
    assert!(waited < Duration::from_secs(15), "the ask has a short deadline, took {waited:?}");
}

/// A terminal child of an owner started on a settings file has the owner's
/// socket and not the settings file variable, and `cmux settings validate`
/// in that terminal still reads the owner's file.
#[test]
fn a_terminal_child_has_no_settings_file_variable_and_its_cli_reads_the_owners_file() {
    let fixture = Fixture::new("settings-file-child");
    let settings = fixture.dir.join("app.json");
    fs::write(&settings, TOP).unwrap();
    fixture.ensure_on(&settings);

    let (env, validated) = (fixture.dir.join("env.out"), fixture.dir.join("validate.out"));
    let errors = fixture.dir.join("validate.err");
    let script = format!(
        "env > {env}; {bin} --json settings validate > {validated} 2> {errors}; echo $? > $OUT",
        env = env.display(),
        bin = env!("CARGO_BIN_EXE_cmux-tui"),
        validated = validated.display(),
        errors = errors.display(),
    );
    let status = fixture.in_terminal("child", &script);
    let env = fs::read_to_string(&env).unwrap();
    assert!(env.contains("CMUX_TUI_SOCKET="), "not a terminal of the owner:\n{env}");
    assert!(
        !env.lines().any(|line| line.starts_with("CMUX_NEXT_CONFIG_FILE=")),
        "the terminal child got the owner's settings file variable:\n{env}"
    );
    let validated = fs::read_to_string(&validated).unwrap();
    let errors = fs::read_to_string(&errors).unwrap_or_default();
    assert_eq!(status.trim(), "0", "stdout:\n{validated}\nstderr:\n{errors}");
    let answer: Value = serde_json::from_str(&validated).unwrap();
    assert_eq!(answer["file"], json!(settings.to_str().unwrap()), "{answer}");
}

/// The hazard the removal closes: in a terminal of an owner started on a
/// settings file, a second daemon started with only its own `HOME`, state
/// and socket writes its own default file, never the first owner's file.
#[test]
fn a_daemon_started_in_a_terminal_with_its_own_home_writes_its_own_default_file() {
    let outer = Fixture::new("settings-file-outer");
    let settings = outer.dir.join("app.json");
    fs::write(&settings, TOP).unwrap();
    outer.ensure_on(&settings);

    // Declared after `outer`, so its owner stops first.
    let inner = Fixture::new("settings-file-inner");
    let (ensured, set) = (inner.dir.join("ensure.out"), inner.dir.join("set.out"));
    let params = json!({
        "key": "tabs.barPosition",
        "value": "bottom",
        "machine": "current",
        "session": "current",
    });
    let script = format!(
        "export HOME={home} CFFIXED_USER_HOME={home} CMUX_TUI_STATE_DIR={state}; \
         {bin} server ensure --json --session {session} --socket {socket} > {ensured} 2>&1 && \
         {bin} --json --socket {socket} raw operation settings.set --params-json '{params}' \
         --mutation > {set} 2>&1; echo $? > $OUT",
        home = inner.dir.join("home").display(),
        state = inner.dir.join("state").display(),
        bin = env!("CARGO_BIN_EXE_cmux-tui"),
        session = inner.session,
        socket = inner.socket.display(),
        ensured = ensured.display(),
        set = set.display(),
    );
    let status = outer.in_terminal("inner", &script);
    assert_eq!(
        status.trim(),
        "0",
        "ensure:\n{}\nset:\n{}",
        fs::read_to_string(&ensured).unwrap_or_default(),
        fs::read_to_string(&set).unwrap_or_default()
    );

    let default = inner.default_file();
    assert_eq!(inner.owner_file(), json!(default.to_str().unwrap()));
    let text = fs::read_to_string(&default).unwrap();
    assert!(text.contains("\"barPosition\": \"bottom\""), "the inner owner's file:\n{text}");
    assert_eq!(fs::read_to_string(&settings).unwrap(), TOP, "the outer owner's file changed");
    assert_eq!(outer.owner_file(), json!(settings.to_str().unwrap()));
}
