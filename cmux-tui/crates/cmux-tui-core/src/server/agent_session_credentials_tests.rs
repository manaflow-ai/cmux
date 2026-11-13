//! The owner's model credential on a Cloud chat (agent_session_start.rs
//! `AGENT_SESSION_START_CREDENTIALS_CAPABILITY`): relayed to acpmux with the start and with each
//! refresh only from the owner's own app on the owner's own Cloud VM; refused on a Mac or SSH
//! host, a team VM, a phone's channel, without the caller's owner word, and for a malformed env.

use super::agent_session_attach_tests::{
    Client, FakeAcpmux, Fixture, PhoneFloor, SESSION, assert_code, mux_with, run, terminal_pane,
};
use super::*;
use crate::server::AgentStartHost;
use serde_json::{Value, json};

const TOKEN: &str = "sk-ant-oat01-owner-token";

struct Chat {
    _mux: Arc<Mux>,
    fake: FakeAcpmux,
    client: Client,
    surface: u64,
    cwd: String,
}

fn connect(label: &str, host: AgentStartHost, phone: bool) -> Chat {
    let floor = PhoneFloor {
        strict: true,
        family: "claude",
        mode: Arc::new(Mutex::new("default".to_owned())),
        stuck: false,
        table_gate: None,
    };
    let fake = FakeAcpmux::start_with(
        label,
        Fixture { start_folder_trusted: Some(true), phone: Some(floor), ..Default::default() },
    );
    let mux = mux_with(&fake, label);
    mux.set_agent_start_host(Arc::new(move || host));
    let (_, pane) = terminal_pane(&mux);
    let store = agent_session_attach::agent_session_start::store_host(&mux);
    let surface = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":store,"harness":"claude"}}),
    )["surface"]
        .as_u64()
        .unwrap();
    let mut client = Client::connect(&mux, label);
    let stamped = client.request(json!({"cmd":"carrier-role","vmk":"owner"}));
    assert_eq!(stamped["ok"], json!(true), "{stamped}");
    if phone {
        let info = client.request(json!({"cmd":"set-client-info","kind":"ios",
            "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
        assert_eq!(info["ok"], json!(true), "{info}");
    }
    let directory = PathBuf::from(format!("/tmp/cmux-cred-{label}-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let cwd = directory.to_string_lossy().into_owned();
    Chat { _mux: mux, fake, client, surface, cwd }
}

impl Chat {
    fn start(&mut self, credentials: Value, vm_kind: Value) -> Value {
        let mut start = json!({"cmd":"agent-session-start","surface":self.surface,"cwd":self.cwd,
            "harness":"claude","credentials":credentials});
        if !vm_kind.is_null() {
            start["vm_kind"] = vm_kind;
        }
        self.client.request(start)
    }

    /// The frames the daemon sent acpmux for `method`, until the fake goes quiet.
    fn sent(&self, method: &str) -> Vec<Value> {
        let mut frames = Vec::new();
        while let Ok(frame) = self.fake.frames.recv_timeout(Duration::from_millis(300)) {
            if frame["method"] == json!(method) {
                frames.push(frame);
            }
        }
        frames
    }
}

fn env(token: &str) -> Value {
    json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": token}})
}

#[test]
fn the_owners_start_relays_the_credential_to_acpmux_with_the_agent_launch() {
    let mut chat = connect("cred-owner", AgentStartHost::OwnerCloud, false);
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    assert!(!started.to_string().contains(TOKEN), "the answer never carries it");
    let new = chat.sent("session/new");
    assert_eq!(new.len(), 1, "{new:?}");
    assert_eq!(new[0]["params"]["_meta"]["acpmux"]["credentials"], env(TOKEN));
}

#[test]
fn a_credential_is_refused_anywhere_but_the_owners_own_cloud_vm() {
    for (label, host, phone, vm_kind) in [
        ("cred-mac", AgentStartHost::Allowed, false, json!("owner")),
        ("cred-team", AgentStartHost::TeamVm, false, json!("owner")),
        ("cred-phone", AgentStartHost::OwnerCloud, true, json!("owner")),
        ("cred-no-word", AgentStartHost::OwnerCloud, false, Value::Null),
    ] {
        let mut chat = connect(label, host, phone);
        let refused = chat.start(env(TOKEN), vm_kind);
        assert_eq!(refused["ok"], json!(false), "{label}: {refused}");
        assert!(chat.sent("session/new").is_empty(), "{label}: no agent starts");
    }
}

#[test]
fn a_malformed_credential_is_a_bad_request() {
    for credentials in [
        json!({"env": {"PATH": "/evil"}}),
        json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": "a b"}}),
        json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": "x"}, "file": "/tmp/x"}),
    ] {
        let mut chat = connect("cred-bad", AgentStartHost::OwnerCloud, false);
        assert_code(&chat.start(credentials, json!("owner")), "agent_session.bad_request");
    }
}

#[test]
fn the_owners_refresh_reaches_the_tabs_own_session_only_from_the_owner() {
    let mut chat = connect("cred-refresh", AgentStartHost::OwnerCloud, false);
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let _ = chat.sent("session/new");
    let refresh = |vm_kind: Value, surface: u64| {
        let mut frame = json!({"cmd":"agent-session-credentials","surface":surface,
            "env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-new"}});
        if !vm_kind.is_null() {
            frame["vm_kind"] = vm_kind;
        }
        frame
    };
    let answer = chat.client.request(refresh(json!("owner"), chat.surface));
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert_eq!(answer["data"]["restart"], json!("now"));
    let updates = chat.sent("agent/credentials.update");
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["params"]["sessionId"], json!(SESSION), "the tab's own session");
    assert_eq!(updates[0]["params"]["env"]["CLAUDE_CODE_OAUTH_TOKEN"], json!("sk-ant-oat01-new"));
    // Without the owner word, or for a tab with no session here, nothing reaches acpmux.
    let refused = chat.client.request(refresh(Value::Null, chat.surface));
    assert_eq!(refused["ok"], json!(false), "{refused}");
    assert_code(
        &chat.client.request(refresh(json!("owner"), 999_999)),
        "agent_session.unknown_tab",
    );
    assert!(chat.sent("agent/credentials.update").is_empty());
}

#[test]
fn the_connection_and_expiry_ride_with_the_credential() {
    let mut chat = connect("cred-ref", AgentStartHost::OwnerCloud, false);
    let credentials = json!({"env": {"CMUX_CHATGPT_ACCESS_TOKEN": TOKEN},
        "connection": "chatgpt-1", "expires_at": 1_900_000_000u64});
    let started = chat.start(credentials.clone(), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let new = chat.sent("session/new");
    assert_eq!(new[0]["params"]["_meta"]["acpmux"]["credentials"], credentials);
    let answer =
        chat.client.request(json!({"cmd":"agent-session-credentials","surface":chat.surface,
        "env":{"CMUX_CHATGPT_ACCESS_TOKEN":"eyJ.new.sig"},"connection":"chatgpt-1",
        "expires_at":1_900_003_600u64,"vm_kind":"owner"}));
    assert_eq!(answer["ok"], json!(true), "{answer}");
    let updates = chat.sent("agent/credentials.update");
    assert_eq!(updates[0]["params"]["connection"], json!("chatgpt-1"));
    assert_eq!(updates[0]["params"]["expires_at"], json!(1_900_003_600u64));
    assert_code(
        &chat.start(
            json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": TOKEN}, "connection": "a b"}),
            json!("owner"),
        ),
        "agent_session.bad_request",
    );
}

#[test]
fn the_owners_app_reads_whether_the_tabs_chat_runs_on_a_credential() {
    let mut chat = connect("cred-status", AgentStartHost::OwnerCloud, false);
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let _ = chat.sent("session/new");
    let status = |vm_kind: Value, surface: u64| {
        let mut frame = json!({"cmd":"agent-session-credential-status","surface":surface});
        if !vm_kind.is_null() {
            frame["vm_kind"] = vm_kind;
        }
        frame
    };
    let answer = chat.client.request(status(json!("owner"), chat.surface));
    assert_eq!(answer["ok"], json!(true), "{answer}");
    // The fake lists the tab's own SESSION as lost and another session beside it.
    assert_eq!(
        answer["data"]["credential"],
        json!({"connection": "chatgpt-1", "expires_at": 1_900_000_000u64, "chatgpt": true, "lost": true})
    );
    assert_eq!(chat.sent("agent/credentials.list").len(), 1);
    assert_eq!(chat.client.request(status(Value::Null, chat.surface))["ok"], json!(false));
    assert_code(&chat.client.request(status(json!("owner"), 999_999)), "agent_session.unknown_tab");
    assert!(chat.sent("agent/credentials.list").is_empty(), "a refused read asks acpmux nothing");
}

#[test]
fn a_teammates_view_never_reads_or_sets_the_owners_credential() {
    let chat = connect("cred-teammate", AgentStartHost::OwnerCloud, false);
    // A teammate's proxied link to the owner's machine (the share relay binds its author).
    let mut teammate = Client::connect(&chat._mux, "cred-teammate-link");
    let author = json!({"id":"tailnet:p@example.com", "login":"p@example.com", "node":"n"});
    let bound = teammate.request(json!({"cmd":"agent-session-proxy-bind", "author":author}));
    assert_eq!(bound["ok"], json!(true), "{bound}");
    for cmd in ["agent-session-credentials", "agent-session-credential-status"] {
        let mut frame = json!({"cmd": cmd, "surface": chat.surface, "vm_kind": "owner"});
        if cmd == "agent-session-credentials" {
            frame["env"] = json!({"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-x"});
        }
        let refused = teammate.request(frame);
        assert_eq!(refused["ok"], json!(false), "{cmd}: {refused}");
    }
    while let Ok(frame) = chat.fake.frames.recv_timeout(Duration::from_millis(300)) {
        let method = frame["method"].as_str().unwrap_or_default();
        assert!(!method.starts_with("agent/credentials."), "{method} reached acpmux");
    }
}
