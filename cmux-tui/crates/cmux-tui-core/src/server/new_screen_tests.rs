//! `new-screen` from a page origin: R5 (plans/cmux-next/
//! workspace-create-extension.md) says a page never chooses what a terminal
//! runs, where, or with which environment, so `cwd`, `env` and `shell_args`
//! on a page relay connection are `origin.forbidden` and create nothing.

use super::*;

struct Connection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
}

impl Connection {
    fn new(role: Option<&str>) -> Self {
        let mux = Mux::new_for_test("new-screen-origin", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound, control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        if let Some(role) = role {
            origin_gate::set_role_for_test(&mux, client, role);
        }
        mux.new_workspace(None, Some((60, 8))).unwrap();
        Self { mux, client, writer }
    }

    fn new_screen(&self, field: Option<(&str, Value)>) -> anyhow::Result<Value> {
        let workspace = self.mux.with_state(|state| state.workspaces[0].id);
        let mut request = json!({"cmd": "new-screen", "workspace": workspace});
        if let Some((name, value)) = field {
            request[name] = value;
        }
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&self.mux, self.client, command, &self.writer)
    }

    fn screens(&self) -> usize {
        self.mux.with_state(|state| state.workspaces[0].screens.len())
    }
}

fn spawn_fields() -> [(&'static str, Value); 3] {
    [
        ("cwd", json!(std::env::temp_dir().to_string_lossy())),
        ("env", json!({"SHELL": "/bin/sh", "FOO": "page"})),
        ("shell_args", json!(["-c", "true"])),
    ]
}

#[test]
fn a_page_origin_cannot_send_new_screen_spawn_fields() {
    let page = Connection::new(Some("page_relay"));
    for (name, value) in spawn_fields() {
        let before = page.screens();
        let error = page.new_screen(Some((name, value))).expect_err(name);
        assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"), "{name}");
        assert!(error.to_string().contains(name), "{name}: {error}");
        assert_eq!(page.screens(), before, "{name}: a refused new-screen created a screen");
    }
    // With no spawn fields a page may still open a screen.
    page.new_screen(None).unwrap();
}

#[test]
fn main_and_legacy_connections_keep_the_new_screen_spawn_fields() {
    for role in [None, Some("main")] {
        let connection = Connection::new(role);
        for (name, value) in spawn_fields() {
            connection.new_screen(Some((name, value))).unwrap_or_else(|error| {
                panic!("{role:?} {name}: {error}");
            });
        }
    }
}
