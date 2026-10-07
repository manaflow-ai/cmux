//! NEW-TERMINAL-INHERITS-CWD: a terminal created without an explicit folder
//! starts where the user is, through every raw creation command the app, the
//! CLI and MCP send (`new-tab`, `split`, `new-pane`, `new-pane-right`).
//!
//! The test mux runs no real child process, so a source terminal "moves" by
//! an OSC 7 report (`set_test_pwd`); the foreground-process step has its own
//! unit test in `mux/new_terminal_cwd.rs`.

use std::path::PathBuf;

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// A fresh canonical folder (the temp dir may be a symlink, as `/var` is on macOS).
fn folder(name: &str) -> String {
    let root = std::env::temp_dir().join(format!(
        "cmux-new-terminal-cwd-{name}-{}-{}",
        std::process::id(),
        crate::resource::WorkspacePublicId::random().unwrap()
    ));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::canonicalize(&root).unwrap().to_str().unwrap().to_string()
}

struct Fixture {
    mux: Arc<Mux>,
    workspace: WorkspaceId,
    folders: Vec<String>,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
        let workspace =
            mux.create_empty_workspace(Some(name.into()), None, None).unwrap().workspace;
        Self { mux, workspace, folders: Vec::new() }
    }

    fn folder(&mut self, name: &str) -> String {
        let path = folder(name);
        self.folders.push(path.clone());
        path
    }

    /// A terminal launched in `launch` whose shell reported `now` (OSC 7).
    fn moved_terminal(&self, launch: &str, now: &str) -> (Arc<crate::surface::Surface>, PaneId) {
        let created = run(
            &self.mux,
            json!({"cmd":"create-terminal","workspace":self.workspace,"cwd":launch,"cols":80,"rows":24}),
        )
        .unwrap();
        let surface = self.mux.surface(created["surface"].as_u64().unwrap()).unwrap();
        surface.set_test_pwd(Some(format!("file://localhost{now}")));
        let pane = self.mux.with_state(|state| state.pane_of(surface.id)).unwrap();
        (surface, pane)
    }

    /// A new pane right of `pane` (it starts with a terminal tab).
    fn split_pane(&self, pane: PaneId) -> PaneId {
        let surface = self.mux.split(pane, SplitDir::Right, None).unwrap();
        self.mux.with_state(|state| state.pane_of(surface.id)).unwrap()
    }

    /// An agent chat tab in `pane`, selected.
    fn agent_chat(&self, pane: PaneId) -> SurfaceId {
        let created = run(
            &self.mux,
            json!({"cmd":"new-conversation-tab","pane":pane,
                   "agent_session":{"host":"install:mac-test"}}),
        )
        .unwrap();
        created["surface"].as_u64().unwrap()
    }

    fn set_workspace_folder(&self, path: &str) {
        let selectors = self.mux.resource_selectors_for_workspace(Some(self.workspace)).unwrap();
        self.mux
            .state_set_agent_folder(
                &WorkspaceMutation::local("new-terminal-cwd-test"),
                None,
                &selectors,
                Some(path.into()),
            )
            .unwrap();
    }

    /// The launch folder of the terminal a raw command created.
    fn created_cwd(&self, request: Value) -> Option<String> {
        let created = run(&self.mux, request).unwrap();
        let surface = self.mux.surface(created["surface"].as_u64().unwrap()).unwrap();
        surface.spawn_cwd().map(|cwd| canonical(&cwd))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.mux.shutdown();
        for path in &self.folders {
            let _ = std::fs::remove_dir_all(path);
        }
    }
}

fn canonical(path: &str) -> String {
    std::fs::canonicalize(PathBuf::from(path))
        .map(|path| path.to_str().unwrap().to_string())
        .unwrap_or_else(|_| path.to_string())
}

#[test]
fn new_tab_starts_in_the_source_terminals_current_folder() {
    let mut f = Fixture::new("cwd-new-tab");
    let (launch, now) = (f.folder("launch"), f.folder("now"));
    let (_, pane) = f.moved_terminal(&launch, &now);
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":pane}));
    assert_eq!(cwd.as_deref(), Some(now.as_str()), "new-tab must start where the shell is now");
}

#[test]
fn split_and_new_pane_start_in_the_source_terminals_current_folder() {
    let mut f = Fixture::new("cwd-split");
    let (launch, now) = (f.folder("launch"), f.folder("now"));
    let (_, pane) = f.moved_terminal(&launch, &now);
    for request in [
        json!({"cmd":"split","pane":pane,"dir":"right"}),
        json!({"cmd":"split","pane":pane,"dir":"down"}),
        json!({"cmd":"new-pane","pane":pane}),
        json!({"cmd":"new-pane-right","pane":pane}),
    ] {
        let cwd = f.created_cwd(request.clone());
        assert_eq!(cwd.as_deref(), Some(now.as_str()), "{request}");
    }
}

#[test]
fn an_explicit_cwd_still_wins() {
    let mut f = Fixture::new("cwd-explicit");
    let (launch, now, asked) = (f.folder("launch"), f.folder("now"), f.folder("asked"));
    let (_, pane) = f.moved_terminal(&launch, &now);
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":pane,"cwd":asked}));
    assert_eq!(cwd.as_deref(), Some(asked.as_str()));
}

/// The coordinator's agent-home rule: a folderless workspace never sends a new
/// terminal to an agent chat's folder; beside a chat it takes the workspace's
/// last terminal folder.
#[test]
fn beside_an_agent_chat_a_new_tab_starts_in_the_last_terminal_folder() {
    let mut f = Fixture::new("cwd-agent-chat");
    let (launch, now) = (f.folder("launch"), f.folder("now"));
    let (_, terminal_pane) = f.moved_terminal(&launch, &now);
    let chat_pane = f.split_pane(terminal_pane);
    f.agent_chat(chat_pane);
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":chat_pane}));
    assert_eq!(cwd.as_deref(), Some(now.as_str()), "the last terminal folder of the workspace");
}

#[test]
fn a_folderless_workspace_with_only_an_agent_chat_starts_in_the_default_folder() {
    let f = Fixture::new("cwd-chat-only");
    let created = run(
        &f.mux,
        json!({"cmd":"new-conversation-tab","workspace":f.workspace,
               "agent_session":{"host":"install:mac-test"}}),
    )
    .unwrap();
    let chat = created["surface"].as_u64().unwrap();
    let pane = f.mux.with_state(|state| state.pane_of(chat)).unwrap();
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":pane}));
    assert_eq!(cwd, None, "no folder: the host's default (home), never an agent folder");
}

#[test]
fn the_workspace_folder_comes_before_the_last_terminal_folder() {
    let mut f = Fixture::new("cwd-workspace-folder");
    let (launch, now, chosen) = (f.folder("launch"), f.folder("now"), f.folder("chosen"));
    let (_, terminal_pane) = f.moved_terminal(&launch, &now);
    let chat_pane = f.split_pane(terminal_pane);
    f.agent_chat(chat_pane);
    f.set_workspace_folder(&chosen);
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":chat_pane}));
    assert_eq!(cwd.as_deref(), Some(chosen.as_str()));
    // A focused terminal still comes first.
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":terminal_pane}));
    assert_eq!(cwd.as_deref(), Some(now.as_str()));
}

/// Ghostty `*-inherit-working-directory = false`, sent as `inherit_cwd: false`.
#[test]
fn inherit_cwd_false_skips_the_terminal_folders() {
    let mut f = Fixture::new("cwd-no-inherit");
    let (launch, now, chosen) = (f.folder("launch"), f.folder("now"), f.folder("chosen"));
    let (_, pane) = f.moved_terminal(&launch, &now);
    for request in [
        json!({"cmd":"new-tab","pane":pane,"inherit_cwd":false}),
        json!({"cmd":"split","pane":pane,"dir":"right","inherit_cwd":false}),
        json!({"cmd":"new-pane-right","pane":pane,"inherit_cwd":false}),
    ] {
        assert_eq!(f.created_cwd(request.clone()), None, "{request}");
    }
    f.set_workspace_folder(&chosen);
    let cwd = f.created_cwd(json!({"cmd":"new-tab","pane":pane,"inherit_cwd":false}));
    assert_eq!(cwd.as_deref(), Some(chosen.as_str()), "the workspace folder is not inheritance");
}
