//! Wire tests for the shell a terminal-creating command starts:
//! `terminal-shell-args-v1` (`shell_args`) and
//! `terminal-frontend-shell-integration-v1`.
//!
//! `terminal-frontend-shell-integration-v1` (R92 bug 2): a frontend that
//! resolves Ghostty's shell integration itself (cmux-next reads the user's
//! `shell-integration` and `shell-integration-features` with libghostty and
//! puts the result in the terminal's `env`) echoes the capability, and the
//! session host then starts the terminal's `SHELL` exactly as given instead
//! of adding its own integration on top. Without it the host overwrote the
//! frontend's `ZDOTDIR` chain (losing a user `ZDOTDIR`) and integrated zsh
//! and fish even when the user's Ghostty config says `shell-integration =
//! none`.

use super::*;

const CAPABILITY: &str = "terminal-frontend-shell-integration-v1";
const FRONTEND_SHELL: &str = "/opt/frontend/bin/zsh";

struct Frontend {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
}

impl Frontend {
    fn new(echo: bool) -> Self {
        let mux = Mux::new_for_test("frontend-shell", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound, control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let frontend = Self { mux, client, writer };
        if echo {
            frontend.run(json!({"cmd": "set-client-info", "capabilities": [CAPABILITY]}));
        }
        frontend
    }

    fn run(&self, request: Value) -> Value {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&self.mux, self.client, command, &self.writer).unwrap()
    }

    fn argv(&self, created: &Value) -> Vec<String> {
        let surface = created["surface"].as_u64().expect("created surface");
        self.mux.surface(surface).and_then(|surface| surface.spawn_argv()).unwrap()
    }

    /// The frontend's env: its shell and the integration it resolved.
    fn env() -> Value {
        json!({"SHELL": FRONTEND_SHELL, "ZDOTDIR": "/frontend/ghostty/shell-integration/zsh",
               "GHOSTTY_ZSH_ZDOTDIR": "/home/user/.config/zsh"})
    }
}

#[test]
fn a_frontend_that_resolves_shell_integration_gets_its_shell_unchanged() {
    assert!(advertised_capabilities(false).contains(&CAPABILITY));
    let frontend = Frontend::new(true);
    let first = frontend.mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(first)).unwrap();
    let commands = [
        json!({"cmd": "new-tab", "pane": pane}),
        json!({"cmd": "split", "pane": pane, "dir": "right"}),
        json!({"cmd": "new-pane", "pane": pane}),
        json!({"cmd": "new-pane-right", "pane": pane, "width": 0.5}),
    ];
    for mut request in commands {
        request["env"] = Frontend::env();
        let created = frontend.run(request.clone());
        // An explicit argv is the caller's program: the host adds nothing.
        assert_eq!(frontend.argv(&created), vec![FRONTEND_SHELL.to_string()], "{request}");
    }
    let row = frontend.run(json!({
        "cmd": "new-row", "pane": pane, "height_permille": 400, "env": Frontend::env(),
    }));
    assert_eq!(frontend.argv(&row), vec![FRONTEND_SHELL.to_string()], "new-row");
    let key = frontend.mux.with_state(|state| state.workspaces[0].key.clone());
    let terminal = frontend.run(json!({
        "cmd": "create-terminal", "key": key, "cols": 60, "rows": 8, "env": Frontend::env(),
        "origin": "test", "mutation_id": "frontend-shell-create",
    }));
    assert_eq!(frontend.argv(&terminal), vec![FRONTEND_SHELL.to_string()], "create-terminal");
    // Arguments the frontend chose still follow its shell.
    let created = frontend.run(json!({
        "cmd": "new-tab", "pane": pane, "env": Frontend::env(), "shell_args": ["-l"],
    }));
    assert_eq!(frontend.argv(&created), vec![FRONTEND_SHELL.to_string(), "-l".to_string()]);
}

/// `new-screen` (`screen-terminal-env-v1`) takes the same spawn fields as
/// the other placement commands: the frontend's `env`, its chosen
/// `terminal_id` and `shell_args`, and the frontend flag. Before, the new
/// screen's terminal got none of them (R92: `shell-integration = none` and
/// the app environment were lost on new screens).
#[test]
fn new_screen_takes_the_frontend_spawn_fields() {
    let frontend = Frontend::new(true);
    frontend.mux.new_workspace(None, Some((60, 8))).unwrap();
    let workspace = frontend.mux.with_state(|state| state.workspaces[0].id);
    let terminal_id = "0123456789ab4def8123456789abcdef";
    let created = frontend.run(json!({
        "cmd": "new-screen", "workspace": workspace, "cols": 60, "rows": 8,
        "env": Frontend::env(), "terminal_id": terminal_id,
    }));
    assert_eq!(frontend.argv(&created), vec![FRONTEND_SHELL.to_string()]);
    assert_eq!(created["terminal_id"], terminal_id, "{created}");
    let with_args = frontend.run(json!({
        "cmd": "new-screen", "workspace": workspace, "env": Frontend::env(), "shell_args": ["-l"],
    }));
    assert_eq!(frontend.argv(&with_args), vec![FRONTEND_SHELL.to_string(), "-l".to_string()]);
}

/// The fresh terminal a drag of a pane's only tab leaves behind
/// (`respawn`) is created for the same frontend, so it follows the flag too.
#[test]
fn respawned_terminals_follow_the_frontend_flag() {
    let frontend = Frontend::new(true);
    let respawn = json!({"kind": "terminal", "env": Frontend::env()});
    let split = frontend.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(split).unwrap());
    frontend.run(json!({
        "cmd": "move-tab-to-split", "surface": split, "pane": pane, "edge": "right",
        "respawn": respawn,
    }));
    let fresh = frontend.mux.with_state(|state| state.panes[&pane].tabs[0]);
    assert_eq!(frontend.argv(&json!({"surface": fresh})), vec![FRONTEND_SHELL.to_string()]);

    let docked = frontend.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(docked).unwrap());
    frontend.run(json!({
        "cmd": "move-tab-to-column", "surface": docked, "pane": pane, "width": 0.4,
        "dock": {"edge": "right", "mode": "docked"}, "respawn": respawn,
    }));
    let fresh = frontend.mux.with_state(|state| state.panes[&pane].tabs[0]);
    assert_eq!(frontend.argv(&json!({"surface": fresh})), vec![FRONTEND_SHELL.to_string()]);
}

/// Without a `SHELL` in `env` the frontend resolved nothing for the shell
/// the host picks, so the host keeps its own integration.
#[test]
fn a_frontend_env_without_a_shell_keeps_the_host_integration() {
    let frontend = Frontend::new(true);
    let first = frontend.mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(first)).unwrap();
    let created = frontend.run(json!({"cmd": "new-tab", "pane": pane, "env": {"A": "1"}}));
    assert_eq!(frontend.argv(&created), vec![platform::default_shell()]);
    assert_eq!(shell_argv(&[], None, true), None);
}

#[test]
fn a_frontend_without_the_capability_keeps_the_host_integration() {
    let frontend = Frontend::new(false);
    let first = frontend.mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(first)).unwrap();
    let created = frontend.run(json!({"cmd": "new-tab", "pane": pane, "env": Frontend::env()}));
    // The default-shell launch, which the host integrates as before.
    assert_eq!(frontend.argv(&created), vec![platform::default_shell()]);
}

fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("shell-args", crate::SurfaceOptions::default())
}

fn run_json_command(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// The argv the created terminal was spawned with (the in-process test
/// runtime records it instead of running it).
fn spawned_argv(mux: &Arc<Mux>, created: &Value) -> Vec<String> {
    let surface = created["surface"].as_u64().expect("created surface");
    mux.surface(surface).and_then(|surface| surface.spawn_argv()).expect("terminal surface")
}

#[test]
fn cmux_next_shell_args_start_the_terminals_shell_with_arguments() {
    // A frontend passes Ghostty's shell-integration argv (bash --posix,
    // nushell --execute) for the shell it put in the terminal's SHELL.
    assert!(advertised_capabilities(false).contains(&TERMINAL_SHELL_ARGS_CAPABILITY));
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let commands = [
        ("new-tab", json!({})),
        ("split", json!({"dir":"right"})),
        ("new-pane", json!({})),
        ("new-pane-right", json!({"width":0.5})),
    ];
    for (command, extra) in commands {
        let mut request = json!({
            "cmd":command,
            "pane":pane,
            "cols":60,
            "rows":8,
            "env":{"SHELL":"/opt/homebrew/bin/bash"},
            "shell_args":["--posix"],
        });
        for (key, value) in extra.as_object().unwrap() {
            request[key] = value.clone();
        }
        let created = run_json_command(&mux, request).unwrap();
        assert_eq!(
            spawned_argv(&mux, &created),
            vec!["/opt/homebrew/bin/bash".to_string(), "--posix".to_string()],
            "{command}"
        );
    }

    let key = mux.with_state(|state| state.workspaces[0].key.clone());
    let created = run_json_command(
        &mux,
        json!({
            "cmd":"create-terminal",
            "key":key,
            "cols":60,
            "rows":8,
            "env":{"SHELL":"/opt/homebrew/bin/nu"},
            "shell_args":["--execute", "use ghostty *"],
            "origin":"test",
            "mutation_id":"shell-args-create",
        }),
    )
    .unwrap();
    assert_eq!(
        spawned_argv(&mux, &created),
        vec![
            "/opt/homebrew/bin/nu".to_string(),
            "--execute".to_string(),
            "use ghostty *".to_string()
        ]
    );
    for conflicting in [json!({"argv":["/bin/sh"]}), json!({"command":"true"})] {
        let mut request = json!({
            "cmd":"create-terminal",
            "key":key,
            "shell_args":["-l"],
            "origin":"test",
            "mutation_id":"shell-args-conflict",
        });
        for (field, value) in conflicting.as_object().unwrap() {
            request[field] = value.clone();
        }
        assert!(run_json_command(&mux, request).is_err(), "{conflicting}");
    }
}

#[test]
fn cmux_next_shell_args_without_a_shell_env_use_the_default_shell() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let created = run_json_command(
        &mux,
        json!({"cmd":"new-tab","pane":pane,"cols":60,"rows":8,"shell_args":["-l"]}),
    )
    .unwrap();
    assert_eq!(spawned_argv(&mux, &created), vec![platform::default_shell(), "-l".to_string()]);
    // No shell_args (or an empty list) keeps the plain default shell.
    let plain =
        run_json_command(&mux, json!({"cmd":"new-tab","pane":pane,"shell_args":[]})).unwrap();
    assert_eq!(spawned_argv(&mux, &plain), vec![platform::default_shell()]);
}
