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

impl Chat {
    fn prewarm(&mut self, credentials: Value, vm_kind: Value) -> Value {
        let mut frame = json!({"cmd":"agent-session-prewarm","surface":self.surface,"cwd":self.cwd,
            "harness":"claude","model":"claude-sonnet-4-5","credentials":credentials});
        if !vm_kind.is_null() {
            frame["vm_kind"] = vm_kind;
        }
        self.client.request(frame)
    }
}

/// cmux#45953: the owner's app warms the agent its coming start will run. acpmux gets the start's
/// own folder, agent, model, workspace and credential, so the start that follows takes that agent;
/// the prewarm binds nothing, so the start still runs and binds the tab after it.
#[test]
fn the_owners_prewarm_hints_the_starts_own_agent_and_binds_nothing() {
    let mut chat = connect("prewarm-owner", AgentStartHost::OwnerCloud, false);
    let warmed = chat.prewarm(env(TOKEN), json!("owner"));
    assert_eq!(warmed["ok"], json!(true), "{warmed}");
    assert_eq!(warmed["data"]["accepted"], json!(true), "{warmed}");
    assert!(!warmed.to_string().contains(TOKEN), "the answer never carries it");
    let hints = chat.sent("_acpmux/prewarm");
    assert_eq!(hints.len(), 1, "{hints:?}");
    let hint = &hints[0]["params"];
    assert_eq!(hint["cwd"], json!(chat.cwd), "the folder acpmux's trust answer checked");
    assert_eq!(hint["harness"], json!("claude"));
    assert_eq!(hint["model"], json!("claude-sonnet-4-5"));
    assert_eq!(hint["credentials"], env(TOKEN));
    // Nothing started or bound: the start runs as before.
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "the tab is still unbound: {started}");
    let new = chat.sent("session/new");
    assert_eq!(new.len(), 1, "{new:?}");
    // The start's `session/new` names what the hint named, so acpmux's keys match.
    let meta = &new[0]["params"]["_meta"]["acpmux"];
    assert_eq!(new[0]["params"]["cwd"], hint["cwd"]);
    assert_eq!(meta["harness"], hint["harness"]);
    assert_eq!(meta["credentials"], hint["credentials"]);
    assert_eq!(meta.get("workspaceId"), hint.get("workspaceId"));
}

#[test]
fn a_prewarm_is_refused_anywhere_but_the_owners_own_cloud_vm() {
    for (label, host, phone, vm_kind) in [
        ("prewarm-mac", AgentStartHost::Allowed, false, json!("owner")),
        ("prewarm-team", AgentStartHost::TeamVm, false, json!("owner")),
        ("prewarm-phone", AgentStartHost::OwnerCloud, true, json!("owner")),
        ("prewarm-no-word", AgentStartHost::OwnerCloud, false, Value::Null),
    ] {
        let mut chat = connect(label, host, phone);
        let refused = chat.prewarm(env(TOKEN), vm_kind.clone());
        assert_eq!(refused["ok"], json!(false), "{label}: {refused}");
        // With no credential too: the hint serves the owner's own Cloud start only.
        let refused = chat.prewarm(Value::Null, vm_kind);
        assert_eq!(refused["ok"], json!(false), "{label}: {refused}");
        assert!(chat.sent("_acpmux/prewarm").is_empty(), "{label}: nothing warms");
    }
}

/// A prewarm with no folder is the owner's own Cloud start's alone (it warms the chat's own
/// `~/chats/<id>`, agent_session_trust_tests.rs): anywhere else it names no folder and is refused.
#[test]
fn a_prewarm_for_a_bound_tab_or_with_no_folder_off_the_owners_vm_is_refused() {
    let mut mac = connect("prewarm-no-folder-mac", AgentStartHost::Allowed, false);
    let no_folder = json!({"cmd":"agent-session-prewarm","surface":mac.surface,
        "harness":"claude","vm_kind":"owner"});
    assert_eq!(mac.client.request(no_folder)["ok"], json!(false), "no folder off the owner's VM");
    assert!(mac.sent("_acpmux/prewarm").is_empty());
    let mut chat = connect("prewarm-bound", AgentStartHost::OwnerCloud, false);
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let _ = chat.sent("session/new");
    let bound = json!({"cmd":"agent-session-prewarm","surface":chat.surface,
        "harness":"claude","vm_kind":"owner","cwd":chat.cwd});
    assert_eq!(chat.client.request(bound)["ok"], json!(false), "a bound tab warms nothing");
    assert!(chat.sent("_acpmux/prewarm").is_empty());
}

/// ask-c30064eeff: a Codex Cloud start from the CLI failed `agent_session.bad_request` with no
/// word of which param was refused. A start's or a refresh's bad request names the param in
/// `data.field` (a serde unknown or missing field by its name), and never any value it carried.
#[test]
fn a_bad_request_names_the_refused_param_and_never_its_value() {
    let mut chat = connect("bad-field", AgentStartHost::OwnerCloud, false);
    let base = json!({"cmd":"agent-session-start","surface":chat.surface,"cwd":chat.cwd,
        "harness":"codex","vm_kind":"owner"});
    let with = |key: &str, value: Value| {
        let mut frame = base.clone();
        frame[key] = value;
        frame
    };
    let secret = "sk-proj-secretvalue";
    for (frame, field) in [
        (with("credentials", json!({"env": {"PATH": secret}})), "credentials"),
        (with("credentials", json!({"env": {"OPENAI_API_KEY": secret}, "extra": secret})), "extra"),
        (with("cwd", json!("relative/folder")), "cwd"),
        (with("model", json!("bad model")), "model"),
        (with("harness", json!("codex agent")), "harness"),
        (with("permission_mode", json!("everything")), "permission_mode"),
        (with("person_instance", json!("a/b")), "person_instance"),
        // An unknown param is ignored, not refused (cmux#49712), so it is no row here.
    ] {
        let refused = chat.client.request(frame.clone());
        assert_code(&refused, "agent_session.bad_request");
        assert_eq!(refused["data"]["field"], json!(field), "{frame}: {refused}");
        assert!(refused["error"].as_str().unwrap_or("").contains(field), "{refused}");
        assert!(!refused.to_string().contains(secret), "never the value: {refused}");
    }
    let mut missing = base.clone();
    missing.as_object_mut().unwrap().remove("surface");
    let refused = chat.client.request(missing);
    assert_eq!(refused["data"]["field"], json!("surface"), "{refused}");
    // A wrong type names no field (serde's text carries the value): no value either.
    let refused = chat.client.request(with("model", json!(424_242)));
    assert_code(&refused, "agent_session.bad_request");
    assert!(!refused.to_string().contains("424242"), "{refused}");
    // The refresh verb names its param the same way.
    let refresh = json!({"cmd":"agent-session-credentials","surface":chat.surface,
        "env":{"PATH":secret},"vm_kind":"owner"});
    let refused = chat.client.request(refresh);
    assert_code(&refused, "agent_session.bad_request");
    assert_eq!(refused["data"]["field"], json!("env"), "{refused}");
    assert!(!refused.to_string().contains(secret), "{refused}");
    assert!(chat.sent("session/new").is_empty(), "no agent starts");
}
