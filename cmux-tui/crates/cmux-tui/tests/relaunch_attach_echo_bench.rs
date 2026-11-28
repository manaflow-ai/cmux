//! Relaunch attach to first echo, against a real headless daemon: what the
//! daemon costs between the app's new connection to an already-running
//! `cmux-tui` and the first keystroke's echo in a restored terminal.
//!
//! A relaunched app connects to the daemon that kept running and, for each
//! visible restored terminal, opens one connection as
//! `TerminalAttachment.open` does: `identify` and `set-client-info` (the
//! app's advertised capabilities) in one write, then `attach-surface` by
//! identity (`expected_generation` + `expected_terminal_id`, no surface id)
//! at the view's size, as a byte replay or a GHOSTSNP snapshot. Once the
//! reply is in it sends one key (`send`, base64 bytes) and waits for the
//! PTY's echo as an `output` event. Every phase is timed from the connect.
//!
//! The daemon is the `cmux-tui` binary run `--headless --state DIR`, so each
//! terminal runs in its own terminal host process, as in the app. It makes N
//! workspaces of one shell each, waits for every prompt, then attaches as a
//! new client. Repetition `i` attaches terminal `i % N`: at N = 1 the same
//! terminal again, at N = 120 a terminal no client attached before. Only the
//! attached terminal should cost anything; a phase that grows with N is a
//! bug.
//!
//! A view whose size differs from the terminal's (`CMUX_ATTACH_ECHO_BENCH_VIEWS`,
//! default `80x24,120x40,60x20` against 80x24 terminals) makes the attach
//! resize the terminal's host first: the daemon waits for the host's resize
//! acknowledgement (`settle_hosted_viewer_size`) before it builds the
//! replay. Each timed mismatch attach finds the terminal at 80x24: at N = 1 an
//! untimed attach at 80x24 puts it back after each one.
//!
//! Off by default. Run on the fleet:
//! `CMUX_ATTACH_ECHO_BENCH=1 cargo test -p cmux-tui --release --test relaunch_attach_echo_bench -- --ignored --nocapture`
//! Knobs: `CMUX_ATTACH_ECHO_BENCH_SIZES` (default `1,120`),
//! `CMUX_ATTACH_ECHO_BENCH_REPS` (default 12), `CMUX_ATTACH_ECHO_BENCH_SHELLS`
//! (`sh,bash-norc,bash-rc`), `CMUX_ATTACH_ECHO_BENCH_MODES` (`bytes,snapshot`),
//! `CMUX_ATTACH_ECHO_BENCH_VIEWS` (`COLSxROWS` list).
//! Each table row prints medians and p90 in ms; `ATTACH-ECHO` lines carry the
//! same numbers for scripts.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Value, json};

const COLS: u16 = 80;
const ROWS: u16 = 24;
const PROMPT: &str = "READY$ ";
const KEY: u8 = b'Q';

/// `DaemonCapability.advertised` of the macOS app (DaemonEndpoint.swift):
/// every capability but the four it does not advertise.
const APP_CAPABILITIES: &[&str] = &[
    "workspace-registry-v1",
    "viewport-splits-v1",
    "viewport-column-resize-v1",
    "layout-undo-v1",
    "view-attachment-lease-v1",
    "view-attachment-detach-v1",
    "attach-initial-size",
    "workspace-groups-v1",
    "workspace-metadata-v1",
    "workspace-name-source-v1",
    "tab-metadata-v1",
    "frontend-browser-tabs-v1",
    "frontend-browser-tab-keys-v1",
    "frontend-browser-history-v1",
    "frontend-browser-tab-profile-v1",
    "tab-drag-v1",
    "tab-workspace-name-v1",
    "notification-ack-v1",
    "feed-local-owner-v1",
    "feed-client-v1",
    "tab-groups-v1",
    "saved-tab-groups-v1",
    "workspace-pin-v1",
    "workspace-checklist-v1",
    "notification-mark-unread-v1",
    "tab-mark-unread-v1",
    "tab-attention-v1",
    "tab-attention-request-id-v1",
    "workspace-description-v1",
    "workspace-status-v1",
    "screen-metadata-v1",
    "screen-groups-v1",
    "state-resources-v1",
    "window-records-v1",
    "terminal-env-v1",
    "terminal-placement-env-v1",
    "split-client-keys-v1",
    "split-client-split-id-v1",
    "split-around-v1",
    "split-divider-visibility-v1",
    "split-before-v1",
    "row-client-keys-v1",
    "conversation-tab-split-v1",
    "frontend-browser-tab-split-v1",
    "workspace-first-tab-v1",
    "frontend-browser-tab-workspace-v1",
    "terminal-input-while-creating-v1",
    "creating-input-cancel-v1",
    "terminal-reap-v1",
    "resume-command",
    "terminal-last-command-v1",
    "terminal-reaper-active-v1",
    "end-terminals-keep-layout-v1",
    "batch-close-v1",
    "send-expect-foreground-v1",
    "close-reason-v1",
    "close-workspace-if-empty-v1",
    "browser-host-provider-v1",
    "remote-host-v1",
    "computer-use-v1",
    "frontend-browser-activate-v1",
    "frontend-browser-insert-after-v1",
    "loopback-forward-v1",
    "browser-runtime-v1",
    "notification-source-v1",
    "terminal-shell-args-v1",
    "launch-snapshot-v1",
    "profiles-v1",
    "personal-remote-localhost-v1",
    "session-identity-v1",
    "remote-terminal-tabs-v1",
    "dock-columns-v1",
    "edge-docks-v1",
    "dock-column-role-v1",
    "dock-column-split-down-v1",
    "pinned-dock-v1",
    "pinned-dock-alone-v1",
    "rows-v1",
    "column-move-v1",
    "column-left-v1",
    "floating-panes-v1",
    "tab-column-respawn-v1",
    "tab-column-client-pane-v1",
    "tab-restart-v1",
    "tab-restart-kept-layout-v1",
    "tab-park-v1",
    "detached-terminals-v1",
    "create-terminal-workspace-v1",
    "personal-terminals-v1",
    "browser-profiles-v1",
    "bookmarks-v1",
    "bookmark-icon-v1",
    "history-v1",
    "history-clear-until-v1",
    "local-conversations-v1",
    "conversation-draft-events-v1",
    "attach-visibility-v1",
    "subscribe-scroll-on-attach-v1",
    "screen-device-identity-v1",
    "tree-selection-deltas-v1",
    "chief-live-v1",
    "cloud-chief-live-v1",
    "conversation-runs-v1",
    "conversation-run-answers-v1",
    "cloud-conversation-runs-v1",
    "cloud-conversation-typing-v1",
    "workspace-kind-v1",
    "workspace-agent-folder-v1",
    "workspace-agent-start-v1",
    "conversation-tabs-v1",
    "agent-session-tabs-v1",
    "closed-conversation-tabs-v1",
    "agent-session-attach-v1",
    "agent-session-content-v1",
    "cloud_chat_relay.v1",
    "agent-session-fork-v1",
    "agent-session-side-v1",
    "agent-session-observe-v1",
    "agent-session-start-v1",
    "agent-session-start-no-cwd-v1",
    "agent-session-trust-v1",
    "agent-session-start-keyed-reason-v1",
    "agent-session-start-vm-kind-v1",
    "agent-session-start-model-v1",
    "agent-session-start-permission-mode-v1",
    "agent-session-start-mode-v1",
    "agent-session-trust-vm-kind-v1",
    "agent-session-folders-v1",
    "agent-session-children-v1",
    "agent-session-settings-v1",
    "agent-session-login-v1",
    "agent-session-login-machine-v1",
    "agent-session-context-v1",
    "agent-session-steer-v1",
    "agent-session-queue-decision-v1",
    "agent-session-member-v1",
    "agent-session-btw-v1",
    "page-tabs-v1",
    "page-tab-route-v1",
    "app-screens-v1",
    "conversation-search-v1",
    "conversation-threads-v1",
    "conversation-thread-v1",
    "conversation-inbox-state-v1",
    "home-inbox-v1",
    "chief-events-v1",
    "cloud-conversations-v1",
    "cloud-host-replica-v1",
    "cloud-attachments-v1",
    "cloud-selfhost-v1",
    "page-credential-v1",
    "page-credential-scoped-v1",
    "ws-listen-v1",
    "ws-listen-origins-v1",
    "personal-mixed-order-v1",
    "workspace-group-icon-v1",
    "workspace-group-pin-v1",
    "screen-group-icon-v1",
    "tab-group-icon-v1",
    "session-icon-v1",
    "local-attachments-v1",
    "link-preview-v1",
    "chief-inspect-v1",
    "terminal-pending-sequence-v1",
    "terminal-command-history-v1",
    "sidebar-layout-v1",
    "sidebar-doc-v1",
    "palette-usage-v1",
    "browser-devices-v1",
    "browser-fit-v1",
    "browser-fit-width-v1",
    "keybindings-v1",
    "settings-edit-v2",
    "icon-assets-v1",
    "project-list-v1",
    "tab-split-respawn-v1",
    "tab-split-keep-focus-v1",
    "workspace-create-focus-v1",
    "attach-identity-v1",
    "creation-receipts-v1",
    "creation-attempt-keys-v1",
    "terminal-color-overrides-v1",
    "terminal-snapshot-history-v1",
    "terminal-snapshot-local-history-v1",
    "terminal-clipboard-read-v1",
    "origin-claim-v1",
    "page-router-v1",
    "session-journal-v1",
    "terminal-resources-v1",
    "machine-identity-v1",
    "agent-cli-app-provider-v1",
    "agent-cli-app-invalidation-v1",
    "app-provider-changed-v1",
    "agent-inventory-watch-admission-v1",
    "stash-v1",
    "stash-workspaces-v1",
    "layout-bulk-v1",
    "layout-bulk-bare-v1",
    "classic-import-v1",
    "diff-comments-send-v1",
    "git-fingerprint-v1",
    "layout-sizes-batch-v1",
];

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_string())
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

/// One JSON-lines connection; every line read is stamped with its arrival.
struct Conn {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Conn {
    fn connect(path: &Path) -> std::io::Result<Self> {
        let stream = UnixStream::connect(path)?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        Ok(Self { writer: stream.try_clone()?, reader: BufReader::new(stream) })
    }

    fn write_lines(&mut self, lines: &[Value]) {
        let mut out = String::new();
        for line in lines {
            out.push_str(&line.to_string());
            out.push('\n');
        }
        self.writer.write_all(out.as_bytes()).unwrap();
    }

    fn next(&mut self) -> (Instant, Value) {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).expect("daemon read");
        assert!(read > 0, "daemon closed the connection");
        (Instant::now(), serde_json::from_str(&line).expect("daemon sent a JSON line"))
    }

    /// The reply to request `id`, its `data`; panics on an error reply.
    fn call(&mut self, id: u64, request: Value) -> Value {
        let mut request = request;
        request["id"] = json!(id);
        self.write_lines(&[request.clone()]);
        loop {
            let (_, line) = self.next();
            if line.get("id").and_then(Value::as_u64) == Some(id) {
                assert_eq!(line["ok"], json!(true), "{request} failed: {line}");
                return line.get("data").cloned().unwrap_or(Value::Null);
            }
        }
    }
}

struct Daemon {
    root: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl Daemon {
    fn start(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root =
            PathBuf::from("/tmp").join(format!("cmux-rae-{label}-{}-{stamp}", std::process::id()));
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let socket = root.join("s.sock");
        let log = std::fs::File::create(root.join("daemon.log")).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--session"])
            .arg(format!("rae{}", std::process::id()))
            .arg("--socket")
            .arg(&socket)
            .arg("--state")
            .arg(root.join("state"))
            .stdin(Stdio::null())
            .stdout(log.try_clone().unwrap())
            .stderr(log);
        for (key, _) in std::env::vars() {
            if key.starts_with("CMUX") {
                command.env_remove(key);
            }
        }
        command
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("XDG_STATE_HOME", home.join(".local/state"))
            .env("XDG_DATA_HOME", home.join(".local/share"))
            .env("XDG_CACHE_HOME", home.join(".cache"))
            .env("CMUX_TUI_CONFIG", root.join("config.json"))
            .env("SHELL", "/bin/sh");
        let child = command.spawn().expect("start cmux-tui --headless");
        let mut daemon = Self { root, socket, child };
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            if let Some(status) = daemon.child.try_wait().unwrap() {
                panic!("daemon exited {status}: {}", daemon.log_tail());
            }
            if let Ok(mut conn) = Conn::connect(&daemon.socket) {
                conn.call(1, json!({"cmd": "identify"}));
                break;
            }
            assert!(Instant::now() < deadline, "no daemon socket: {}", daemon.log_tail());
            // Bounded startup wait for a child process's socket (60 s deadline above).
            std::thread::sleep(Duration::from_millis(50));
        }
        daemon
    }

    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    fn log_tail(&self) -> String {
        let text = std::fs::read_to_string(self.root.join("daemon.log")).unwrap_or_default();
        let skip = text.chars().count().saturating_sub(3000);
        text.chars().skip(skip).collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // No panics here: a drop during a failed assert's unwind would abort.
        if let Ok(stream) = UnixStream::connect(&self.socket) {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut writer = stream.try_clone().ok();
            let mut reader = BufReader::new(stream);
            let mut reply = |id: u64| -> Option<Value> {
                for _ in 0..1000 {
                    let mut line = String::new();
                    reader.read_line(&mut line).ok().filter(|read| *read > 0)?;
                    let value: Value = serde_json::from_str(&line).ok()?;
                    if value.get("id").and_then(Value::as_u64) == Some(id) {
                        return Some(value);
                    }
                }
                None
            };
            if let Some(writer) = writer.as_mut()
                && writeln!(writer, "{}", json!({"id": 1, "cmd": "identify"})).is_ok()
                && let Some(identity) = reply(1)
            {
                let identity = &identity["data"];
                let _ = writeln!(
                    writer,
                    "{}",
                    json!({"id": 2, "cmd": "shutdown-daemon", "pid": identity["pid"],
                           "generation": identity["generation"], "end_terminals": true})
                );
                // The connection stays open until the daemon answers.
                if reply(2).is_none() {
                    eprintln!("shutdown-daemon got no answer: {}", self.log_tail());
                }
            }
        }
        let deadline = Instant::now() + Duration::from_secs(60);
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                break;
            }
            // Bounded wait for our own child to exit after shutdown-daemon.
            std::thread::sleep(Duration::from_millis(50));
        }
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// The shell argv and env of a bench terminal.
fn shell(kind: &str, home: &Path) -> (Vec<String>, Value) {
    let env = json!({"PS1": PROMPT, "ENV": ""});
    match kind {
        "sh" => (vec!["/bin/sh".into()], env),
        "bash-norc" => {
            (vec!["bash".into(), "--norc".into(), "--noprofile".into(), "-i".into()], env)
        }
        "bash-rc" => {
            // A distribution's interactive rc (Debian/Ubuntu skeleton, with
            // bash-completion when installed), the prompt set last.
            let mut rc = std::fs::read_to_string("/etc/skel/.bashrc").unwrap_or_default();
            rc.push_str(
                "\n[ -f /usr/share/bash-completion/bash_completion ] && \
                 . /usr/share/bash-completion/bash_completion\n",
            );
            rc.push_str(&format!("PS1='{PROMPT}'\n"));
            std::fs::write(home.join(".bashrc"), rc).unwrap();
            (vec!["bash".into(), "-i".into()], env)
        }
        other => panic!("unknown shell {other}"),
    }
}

struct Terminal {
    surface: u64,
    terminal_id: String,
}

fn grow(daemon: &Daemon, n: usize, kind: &str) -> (Vec<Terminal>, Duration) {
    let (argv, env) = shell(kind, &daemon.home());
    let mut conn = Conn::connect(&daemon.socket).unwrap();
    // The replies name each terminal's `term_` id, which the app's attach sends.
    let capabilities: Vec<&str> =
        APP_CAPABILITIES.iter().copied().chain(["terminal-public-ids-v1"]).collect();
    conn.call(
        2,
        json!({"cmd": "set-client-info", "name": "attach bench setup", "kind": "frontend",
               "capabilities": capabilities}),
    );
    let started = Instant::now();
    let mut terminals = Vec::with_capacity(n);
    for i in 0..n {
        let created = conn.call(
            10 + i as u64,
            json!({
                "cmd": "create-terminal", "create_workspace": true, "workspace_name": format!("w{i}"),
                // A workspace key is a UUID; the one-request workspace needs a mutation.
                "key": format!("018f6e21-7b70-7e70-8000-{:012x}", i + 1),
                "origin": "cmux-next", "mutation_id": format!("attach-bench-{i}"),
                "argv": argv, "env": env, "cols": COLS, "rows": ROWS,
            }),
        );
        terminals.push(Terminal {
            surface: created["surface"].as_u64().expect("created terminal has a surface"),
            terminal_id: created["terminal_resource_id"]
                .as_str()
                .unwrap_or_else(|| panic!("no terminal_resource_id: {created}"))
                .to_string(),
        });
    }
    for (i, terminal) in terminals.iter().enumerate() {
        conn.call(
            100_000 + i as u64,
            json!({"cmd": "wait-for", "surface": terminal.surface,
                   "pattern": regex_escape(PROMPT.trim_end()), "timeout_ms": 30_000}),
        );
    }
    (terminals, started.elapsed())
}

fn regex_escape(text: &str) -> String {
    text.chars()
        .flat_map(|c| if "\\.+*?()|[]{}^$".contains(c) { vec!['\\', c] } else { vec![c] })
        .collect()
}

/// Milliseconds from the connect start of one attach.
#[derive(Clone, Copy, Default)]
struct Phases {
    connect: f64,
    hello: f64,
    initial: f64,
    reply: f64,
    echo: f64,
    /// `echo` minus `reply`: the key's own round trip once attached.
    key_to_echo: f64,
    initial_kb: f64,
    /// The grid the initial `vt-state` was built at (0 when not a `vt-state`).
    replay_cols: u64,
    replay_rows: u64,
}

fn ms(from: Instant, to: Instant) -> f64 {
    to.duration_since(from).as_secs_f64() * 1000.0
}

fn attach_once(
    daemon: &Daemon,
    terminal: &Terminal,
    snapshot: Option<u16>,
    (cols, rows): (u16, u16),
) -> Phases {
    let start = Instant::now();
    let mut conn = Conn::connect(&daemon.socket).unwrap();
    let connected = Instant::now();
    conn.write_lines(&[
        json!({"id": 1, "cmd": "identify"}),
        json!({"id": 2, "cmd": "set-client-info", "name": "cmux-next-terminal", "kind": "frontend",
               "capabilities": APP_CAPABILITIES}),
    ]);
    let mut identity = None;
    let mut client_info = false;
    let mut hello = connected;
    while identity.is_none() || !client_info {
        let (at, line) = conn.next();
        match line.get("id").and_then(Value::as_u64) {
            Some(1) => identity = Some(line["data"].clone()),
            Some(2) => client_info = true,
            _ => continue,
        }
        assert_eq!(line["ok"], json!(true), "hello failed: {line}");
        hello = at;
    }
    let identity = identity.unwrap();
    let supports = |capability: &str| {
        identity["capabilities"]
            .as_array()
            .is_some_and(|all| all.iter().any(|item| item.as_str() == Some(capability)))
    };
    assert!(supports("attach-identity-v1"), "daemon lacks attach-identity-v1");
    let mut attach = json!({
        "id": 3, "cmd": "attach-surface", "mode": "bytes", "cols": cols, "rows": rows,
        "expected_generation": identity["generation"], "expected_terminal_id": terminal.terminal_id,
    });
    if let Some(version) = snapshot.filter(|_| supports("terminal-snapshot-history-v1")) {
        attach["snapshot"] = json!("ghostsnp");
        attach["snapshot_version"] = json!(version);
    }
    conn.write_lines(&[attach]);
    let mut initial = None;
    let mut initial_bytes = 0;
    let (mut replay_cols, mut replay_rows) = (0, 0);
    let replied = loop {
        let (at, line) = conn.next();
        let event = line.get("event").and_then(Value::as_str).unwrap_or_default();
        if initial.is_none() && matches!(event, "vt-state" | "snapshot") {
            initial = Some(at);
            initial_bytes = line.to_string().len();
            replay_cols = line.get("cols").and_then(Value::as_u64).unwrap_or(0);
            replay_rows = line.get("rows").and_then(Value::as_u64).unwrap_or(0);
        }
        if line.get("id").and_then(Value::as_u64) == Some(3) {
            assert_eq!(line["ok"], json!(true), "attach failed: {line}");
            break at;
        }
    };
    let initial = initial.unwrap_or(replied);
    let key = base64::engine::general_purpose::STANDARD.encode([KEY]);
    conn.write_lines(&[json!({"id": 4, "cmd": "send", "surface": terminal.surface, "bytes": key})]);
    let echoed = loop {
        let (at, line) = conn.next();
        if line.get("event").and_then(Value::as_str) == Some("output")
            && line
                .get("data")
                .and_then(Value::as_str)
                .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok())
                .is_some_and(|bytes| bytes.contains(&KEY))
        {
            break at;
        }
        if line.get("id").and_then(Value::as_u64) == Some(4) {
            assert_eq!(line["ok"], json!(true), "send failed: {line}");
        }
    };
    // Erase the key (^U) so the next attach finds the same prompt.
    let erase = base64::engine::general_purpose::STANDARD.encode([0x15]);
    conn.write_lines(&[
        json!({"id": 5, "cmd": "send", "surface": terminal.surface, "bytes": erase}),
    ]);
    loop {
        let (_, line) = conn.next();
        if line.get("id").and_then(Value::as_u64) == Some(5) {
            break;
        }
    }
    Phases {
        connect: ms(start, connected),
        hello: ms(start, hello),
        initial: ms(start, initial),
        reply: ms(start, replied),
        echo: ms(start, echoed),
        key_to_echo: ms(replied, echoed),
        initial_kb: initial_bytes as f64 / 1024.0,
        replay_cols,
        replay_rows,
    }
}

fn percentile(values: &[f64], p: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[rank.min(sorted.len() - 1)]
}

#[test]
#[ignore = "bench: CMUX_ATTACH_ECHO_BENCH=1 ... -- --ignored --nocapture"]
fn relaunch_attach_echo_bench() {
    if std::env::var("CMUX_ATTACH_ECHO_BENCH").as_deref() != Ok("1") {
        eprintln!("relaunch_attach_echo_bench: set CMUX_ATTACH_ECHO_BENCH=1 to run");
        return;
    }
    let sizes: Vec<usize> = env_list("CMUX_ATTACH_ECHO_BENCH_SIZES", "1,120")
        .iter()
        .map(|s| s.parse().unwrap())
        .collect();
    let reps: usize = std::env::var("CMUX_ATTACH_ECHO_BENCH_REPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(12);
    let shells = env_list("CMUX_ATTACH_ECHO_BENCH_SHELLS", "sh,bash-norc,bash-rc");
    let modes = env_list("CMUX_ATTACH_ECHO_BENCH_MODES", "bytes,snapshot");
    let views: Vec<(u16, u16)> = env_list("CMUX_ATTACH_ECHO_BENCH_VIEWS", "80x24,120x40,60x20")
        .iter()
        .map(|view| {
            let (cols, rows) = view.split_once('x').expect("a view is COLSxROWS");
            (cols.parse().unwrap(), rows.parse().unwrap())
        })
        .collect();
    let version = ghostty_vt::snapshot_version();
    let mut table = String::from(
        "| shell | N | mode | view | n | connect | hello | replay in | attach reply | echo | key to echo | replay KB |\n\
         |---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    for kind in &shells {
        if kind.starts_with("bash") && Command::new("bash").arg("-c").arg(":").status().is_err() {
            eprintln!("no bash: skipping {kind}");
            continue;
        }
        for &n in &sizes {
            let daemon = Daemon::start(&format!("{kind}-{n}"));
            let (terminals, grow_time) = grow(&daemon, n, kind);
            eprintln!("{kind} N={n}: {n} terminals at their prompt in {grow_time:?}");
            for mode in &modes {
                let snapshot = match mode.as_str() {
                    "bytes" => None,
                    "snapshot" if version != 0 => Some(version),
                    "snapshot" => {
                        eprintln!("snapshot: this host cannot encode GHOSTSNP; skipped");
                        continue;
                    }
                    other => panic!("unknown mode {other}"),
                };
                for (v, &view) in views.iter().enumerate() {
                    let label = format!("{}x{}", view.0, view.1);
                    let mismatch = view != (COLS, ROWS);
                    // Each (mode, view) times its own terminals when N allows, so a
                    // mismatch attach finds a terminal no view resized before.
                    let offset = (v * modes.len() + usize::from(mode == "snapshot")) * (reps + 1);
                    let attach = |i: usize| {
                        let terminal = &terminals[(offset + i) % n];
                        let phases = attach_once(&daemon, terminal, snapshot, view);
                        if mismatch && n < (views.len() * modes.len()) * (reps + 1) {
                            // A terminal comes again: put it back at its own size (untimed).
                            attach_once(&daemon, terminal, snapshot, (COLS, ROWS));
                        }
                        phases
                    };
                    // One untimed attach warms the daemon's code paths.
                    attach(reps);
                    let runs: Vec<Phases> = (0..reps).map(attach).collect();
                    if mode == "bytes" {
                        for run in &runs {
                            assert_eq!(
                                (run.replay_cols, run.replay_rows),
                                (u64::from(view.0), u64::from(view.1)),
                                "the replay was not built at the view's grid"
                            );
                        }
                    }
                    let pick = |f: fn(&Phases) -> f64| -> Vec<f64> { runs.iter().map(f).collect() };
                    let cell = |values: Vec<f64>| {
                        format!("{:.2} / {:.2}", percentile(&values, 0.5), percentile(&values, 0.9))
                    };
                    let columns = [
                        cell(pick(|p| p.connect)),
                        cell(pick(|p| p.hello)),
                        cell(pick(|p| p.initial)),
                        cell(pick(|p| p.reply)),
                        cell(pick(|p| p.echo)),
                        cell(pick(|p| p.key_to_echo)),
                        format!("{:.1}", percentile(&pick(|p| p.initial_kb), 0.5)),
                    ];
                    table.push_str(&format!(
                        "| {kind} | {n} | {mode} | {label} | {reps} | {} |\n",
                        columns.join(" | ")
                    ));
                    println!(
                        "ATTACH-ECHO shell={kind} n={n} mode={mode} view={label} reps={reps} \
                         hello_p50={:.2} initial_p50={:.2} initial_p90={:.2} reply_p50={:.2} \
                         reply_p90={:.2} echo_p50={:.2} echo_p90={:.2} key_to_echo_p50={:.2} \
                         key_to_echo_p90={:.2}",
                        percentile(&pick(|p| p.hello), 0.5),
                        percentile(&pick(|p| p.initial), 0.5),
                        percentile(&pick(|p| p.initial), 0.9),
                        percentile(&pick(|p| p.reply), 0.5),
                        percentile(&pick(|p| p.reply), 0.9),
                        percentile(&pick(|p| p.echo), 0.5),
                        percentile(&pick(|p| p.echo), 0.9),
                        percentile(&pick(|p| p.key_to_echo), 0.5),
                        percentile(&pick(|p| p.key_to_echo), 0.9),
                    );
                    for (i, run) in runs.iter().enumerate() {
                        println!(
                            "ATTACH-ECHO-RUN shell={kind} n={n} mode={mode} view={label} i={i} \
                             connect={:.2} hello={:.2} initial={:.2} reply={:.2} echo={:.2} grid={}x{}",
                            run.connect,
                            run.hello,
                            run.initial,
                            run.reply,
                            run.echo,
                            run.replay_cols,
                            run.replay_rows
                        );
                    }
                }
            }
        }
    }
    println!("\nRelaunch attach to first echo, ms from connect, median / p90\n\n{table}");
}
