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
    // Arguments the frontend chose still follow its shell.
    let created = frontend.run(json!({
        "cmd": "new-tab", "pane": pane, "env": Frontend::env(), "shell_args": ["-l"],
    }));
    assert_eq!(frontend.argv(&created), vec![FRONTEND_SHELL.to_string(), "-l".to_string()]);
}

#[test]
fn a_frontend_without_the_capability_keeps_the_host_integration() {
    let frontend = Frontend::new(false);
    let first = frontend.mux.new_workspace(None, Some((60, 8))).unwrap().id;
    let pane = frontend.mux.with_state(|state| state.pane_of(first)).unwrap();
    let created = frontend.run(json!({"cmd": "new-tab", "pane": pane, "env": Frontend::env()}));
    // The default-shell launch, which the host integrates as before.
    assert_eq!(frontend.argv(&created), vec![crate::platform::default_shell()]);
}
