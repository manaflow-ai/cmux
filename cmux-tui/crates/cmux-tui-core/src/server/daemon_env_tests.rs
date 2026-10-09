//! Wire tests for the daemon-owned terminal environment: a caller `env` on
//! a terminal-creating command never replaces a value the daemon owns, and
//! the `claude` shim directory stays first on a caller `PATH`. Each test
//! starts a real child that writes its environment to a file.

use std::collections::BTreeMap;

use super::*;

const CAPABILITY: &str = "terminal-frontend-shell-integration-v1";
const SHIM_DIR: &str = "/daemon/cmux-tui/shims";
const DAEMON_PATH: &str = "/daemon/cmux-tui/shims:/usr/bin:/bin";

/// The values the daemon sets at startup (`main.rs`,
/// `agent_browser_provider.rs`), so the children start from the daemon env.
fn daemon_options() -> crate::SurfaceOptions {
    let extra_env = [
        ("CMUX_TUI_SOCKET", "/daemon/cmux-tui.sock"),
        ("CMUX_MUX_SOCKET", "/daemon/cmux-tui.sock"),
        ("CMUX_TUI_HOOK", "/daemon/cmux-tui-hook"),
        ("CMUX_TUI_AGENT_BROWSER_PROVIDER", "1"),
        ("AGENT_BROWSER_PROVIDER", "cmux"),
        ("AGENT_BROWSER_PLUGINS", "[{\"name\":\"cmux\"}]"),
        ("PATH", DAEMON_PATH),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value.to_string()))
    .collect();
    crate::SurfaceOptions {
        extra_env,
        claude_shim_dir: Some(SHIM_DIR.to_string()),
        ..crate::SurfaceOptions::default()
    }
}

struct Spawned {
    env: BTreeMap<String, String>,
    session_id: String,
}

/// Create a terminal with `command` and the caller `env`, and return the
/// environment its child saw.
fn spawn_with_env(command: &str, caller_env: &[(&str, &str)]) -> Spawned {
    // A real-runtime mux: the test runtime starts no child process.
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let mux = Mux::new(format!("daemon-env-{}-{nanos}", std::process::id()), daemon_options());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let run = |request: Value| {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&mux, client, command, &writer).unwrap()
    };
    run(json!({"cmd": "set-client-info", "capabilities": [CAPABILITY]}));
    let first = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();

    let dir = std::env::temp_dir().join(format!("cmux-daemon-env-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("env");
    // The child stays alive after it writes: a child that exits at once can
    // close its screen before the create command has answered (a separate
    // mux create race), and these tests check only the environment.
    let script = format!(
        "/usr/bin/env > '{out}.tmp' && /bin/mv '{out}.tmp' '{out}' && exec /bin/sleep 60",
        out = out.display()
    );
    let mut env = serde_json::Map::new();
    env.insert("SHELL".into(), Value::String("/bin/sh".into()));
    for (key, value) in caller_env {
        env.insert((*key).into(), Value::String((*value).into()));
    }
    let request = match command {
        "create-terminal" => {
            let key = mux.with_state(|state| state.workspaces[0].key.clone());
            json!({"cmd": "create-terminal", "key": key, "cols": 80, "rows": 24, "env": env,
                   "shell_args": ["-c", script], "origin": "test",
                   "mutation_id": "daemon-env-create"})
        }
        "new-screen" => {
            let workspace = mux.with_state(|state| state.workspaces[0].id);
            json!({"cmd": "new-screen", "workspace": workspace, "cols": 80, "rows": 24,
                   "env": env, "shell_args": ["-c", script]})
        }
        _ => json!({"cmd": "new-tab", "pane": pane, "env": env, "shell_args": ["-c", script]}),
    };
    run(request);

    // A safety bound for a child that starts late under full-suite load.
    let deadline = Instant::now() + Duration::from_secs(30);
    let text = loop {
        if let Ok(text) = std::fs::read_to_string(&out) {
            break text;
        }
        assert!(Instant::now() < deadline, "the child never wrote its environment");
        std::thread::sleep(Duration::from_millis(10));
    };
    let _ = std::fs::remove_dir_all(&dir);
    let env = text
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect();
    Spawned { env, session_id: mux.session_public_id().as_str().to_string() }
}

const CALLER_VALUE: &str = "caller-chosen-value";

/// A caller value for `key` does not reach the child; returns what did.
fn child_value_with_caller(key: &str) -> (Option<String>, Spawned) {
    let spawned = spawn_with_env("new-tab", &[(key, CALLER_VALUE)]);
    let value = spawned.env.get(key).cloned();
    assert_ne!(value.as_deref(), Some(CALLER_VALUE), "a caller {key} reached the child");
    (value, spawned)
}

macro_rules! daemon_value_wins {
    ($name:ident, $key:literal, $daemon:literal) => {
        #[test]
        fn $name() {
            let (value, _) = child_value_with_caller($key);
            assert_eq!(value.as_deref(), Some($daemon), "{}", $key);
        }
    };
}

macro_rules! daemon_absence_wins {
    ($name:ident, $key:literal) => {
        #[test]
        fn $name() {
            // The daemon does not set this key on a terminal, so the child
            // sees only what the daemon process itself inherited (normally
            // nothing; a test run inside a wrapper may have a value).
            let (value, _) = child_value_with_caller($key);
            assert_eq!(value, std::env::var($key).ok(), "{}", $key);
        }
    };
}

daemon_value_wins!(caller_cmux_tui_socket_is_dropped, "CMUX_TUI_SOCKET", "/daemon/cmux-tui.sock");
daemon_value_wins!(caller_cmux_mux_socket_is_dropped, "CMUX_MUX_SOCKET", "/daemon/cmux-tui.sock");
daemon_value_wins!(caller_cmux_tui_hook_is_dropped, "CMUX_TUI_HOOK", "/daemon/cmux-tui-hook");
daemon_value_wins!(
    caller_agent_browser_provider_marker_is_dropped,
    "CMUX_TUI_AGENT_BROWSER_PROVIDER",
    "1"
);
daemon_value_wins!(caller_agent_browser_provider_is_dropped, "AGENT_BROWSER_PROVIDER", "cmux");
daemon_value_wins!(
    caller_agent_browser_plugins_is_dropped,
    "AGENT_BROWSER_PLUGINS",
    "[{\"name\":\"cmux\"}]"
);
daemon_absence_wins!(caller_cmux_sidebar_is_dropped, "CMUX_SIDEBAR");
daemon_absence_wins!(caller_claude_wrapper_marker_is_dropped, "CMUX_TUI_CLAUDE_WRAPPER_ACTIVE");

#[test]
fn caller_cmux_tui_terminal_id_is_dropped() {
    let (value, _) = child_value_with_caller("CMUX_TUI_TERMINAL_ID");
    assert!(value.is_some_and(|value| !value.is_empty()));
}

#[test]
fn caller_cmux_tui_session_id_is_dropped() {
    let (value, spawned) = child_value_with_caller("CMUX_TUI_SESSION_ID");
    assert_eq!(value, Some(spawned.session_id));
}

#[test]
fn caller_agent_browser_session_is_dropped() {
    let (value, spawned) = child_value_with_caller("AGENT_BROWSER_SESSION");
    let terminal = spawned.env.get("CMUX_TUI_TERMINAL_ID").cloned().unwrap_or_default();
    assert_eq!(value, Some(format!("cmux-{terminal}")));
}

/// `create-terminal` takes the same merge as `new-tab`.
#[test]
fn create_terminal_drops_a_caller_socket() {
    let spawned = spawn_with_env("create-terminal", &[("CMUX_TUI_SOCKET", CALLER_VALUE)]);
    let socket = spawned.env.get("CMUX_TUI_SOCKET").map(String::as_str);
    assert_eq!(socket, Some("/daemon/cmux-tui.sock"));
}

/// `new-screen` (`screen-terminal-env-v1`) takes the same merge as
/// `new-tab`: a caller value for a daemon-owned key never reaches the child,
/// and the shim directory stays first on a caller PATH.
#[test]
fn new_screen_drops_a_caller_owned_key_and_keeps_the_shim_first() {
    let caller = [("CMUX_TUI_SOCKET", CALLER_VALUE), ("PATH", "/opt/caller/bin:/usr/bin:/bin")];
    let spawned = spawn_with_env("new-screen", &caller);
    let socket = spawned.env.get("CMUX_TUI_SOCKET").map(String::as_str);
    assert_eq!(socket, Some("/daemon/cmux-tui.sock"));
    assert_eq!(
        spawned.env.get("PATH").map(String::as_str),
        Some("/daemon/cmux-tui/shims:/opt/caller/bin:/usr/bin:/bin")
    );
}

/// The app sends its login-shell PATH, which does not hold the shim
/// directory. The child PATH starts with the shim directory, then has the
/// caller's entries in order.
#[test]
fn the_shim_directory_stays_first_on_a_caller_path() {
    let spawned = spawn_with_env("new-tab", &[("PATH", "/opt/caller/bin:/usr/bin:/bin")]);
    assert_eq!(
        spawned.env.get("PATH").map(String::as_str),
        Some("/daemon/cmux-tui/shims:/opt/caller/bin:/usr/bin:/bin")
    );
}

/// A caller PATH that already holds the shim directory later gets it moved
/// to the front, with no second copy.
#[test]
fn a_caller_path_with_the_shim_gets_no_second_copy() {
    let spawned =
        spawn_with_env("new-tab", &[("PATH", "/opt/caller/bin:/daemon/cmux-tui/shims:/usr/bin")]);
    assert_eq!(
        spawned.env.get("PATH").map(String::as_str),
        Some("/daemon/cmux-tui/shims:/opt/caller/bin:/usr/bin")
    );
}

/// A frontend that resolved Ghostty's shell integration gives the argv, so
/// its integration keys reach the child unchanged.
#[test]
fn frontend_integration_keys_reach_the_child_unchanged() {
    let keys = [
        ("GHOSTTY_ZSH_ZDOTDIR", "/home/user/.config/zsh"),
        ("GHOSTTY_BASH_ENV", "/home/user/.env.sh"),
        ("GHOSTTY_BASH_INJECT", "1 posix"),
        ("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1"),
        ("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", "/frontend/shell-integration"),
    ];
    let spawned = spawn_with_env("new-tab", &keys);
    for (key, value) in keys {
        assert_eq!(spawned.env.get(key).map(String::as_str), Some(value), "{key}");
    }
}
