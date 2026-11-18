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

/// cmux#45774: a Codex CLI ChatGPT login's access token (the Mac's `codex login`) is a credential
/// the owner's start relays, as a ChatGPT plan token is; a daemon that refused it left a Cloud Codex
/// with no sign-in ("Missing environment variable: `OPENAI_API_KEY`").
#[test]
fn a_codex_cli_login_token_is_relayed_with_the_agent_launch() {
    let codex = json!({"env": {"CMUX_CODEX_ACCESS_TOKEN": "eyJhbGciOi.eyJleHAiOjF9.c2ln"}});
    let mut chat = connect("cred-codex-login", AgentStartHost::OwnerCloud, false);
    let started = chat.start(codex.clone(), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let new = chat.sent("session/new");
    assert_eq!(new.len(), 1, "{new:?}");
    assert_eq!(new[0]["params"]["_meta"]["acpmux"]["credentials"], codex);
}

/// cmux#45774: the owner's own Cloud VM says it takes `CMUX_CODEX_ACCESS_TOKEN`
/// (`agent-session-start-codex-login-v1`) beside the credential capability. A daemon before it
/// refused a start carrying that token as a bad request, which the app reads from a daemon without the
/// word as one a machine update cures; a Mac or SSH host lists neither.
#[test]
fn the_owners_cloud_vm_says_it_takes_the_codex_login_credential() {
    let capabilities = |label: &str, host: AgentStartHost| -> Vec<Value> {
        let mut chat = connect(label, host, false);
        chat.client.request(json!({"cmd":"identify"}))["data"]["capabilities"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    };
    let owner = capabilities("cred-codex-cap-owner", AgentStartHost::OwnerCloud);
    assert!(owner.contains(&json!(AGENT_SESSION_START_CREDENTIALS_CAPABILITY)), "{owner:?}");
    assert!(owner.contains(&json!(AGENT_SESSION_START_CODEX_LOGIN_CAPABILITY)), "{owner:?}");
    let mac = capabilities("cred-codex-cap-mac", AgentStartHost::Allowed);
    assert!(!mac.contains(&json!(AGENT_SESSION_START_CODEX_LOGIN_CAPABILITY)), "{mac:?}");
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
