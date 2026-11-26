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

const TOKEN: &str = "sk-ant-api03-owner-key";

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
    json!({"env": {"ANTHROPIC_API_KEY": token}})
}

#[test]
fn the_owner_guest_advertises_bound_keys_without_endpoint_credentials() {
    let fake = FakeAcpmux::start("no-endpoint-capability");
    let mux = mux_with(&fake, "no-endpoint-capability");
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let capabilities = identify_capabilities(&mux);
    assert!(
        capabilities
            .contains(&agent_session_attach::agent_session_start::BOUND_CREDENTIALS_CAPABILITY)
    );
    assert!(!capabilities.contains(&AGENT_SESSION_START_ENDPOINT_CREDENTIALS_CAPABILITY));
}

#[test]
fn endpoint_launch_credentials_reach_acpmux_only_from_the_owner() {
    let credential = json!({"env": {"ANTHROPIC_AUTH_TOKEN": TOKEN}, "endpoint": {
        "kind": "anthropic", "baseUrl": "https://provider.example/v1", "models": ["m"]
    }});
    let mut owner = connect("endpoint-owner", AgentStartHost::OwnerCloud, false);
    let started = owner.start(credential.clone(), json!("owner"));
    assert_eq!(started["ok"], json!(true));
    assert!(!started.to_string().contains(TOKEN));
    let sent = owner.sent("session/new");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["params"]["_meta"]["acpmux"]["credentials"], credential);

    let mut phone = connect("endpoint-phone", AgentStartHost::OwnerCloud, true);
    assert_eq!(phone.start(credential, json!("owner"))["ok"], json!(false));
    assert!(phone.sent("session/new").is_empty());
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
fn the_owner_can_select_claude_auth_for_a_start() {
    for (field, meta_key, route) in [
        ("claude_machine_login", "claudeMachineLogin", "own"),
        ("claude_team_route", "claudeTeamRoute", "team"),
    ] {
        for (where_, host, phone, expected) in [
            ("owner", AgentStartHost::OwnerCloud, false, true),
            ("shared", AgentStartHost::TeamVm, false, route == "team"),
            ("phone", AgentStartHost::OwnerCloud, true, false),
        ] {
            let label = format!("claude-{route}-{where_}");
            let mut chat = connect(&label, host, phone);
            let mut start = json!({
                "cmd": "agent-session-start", "surface": chat.surface, "cwd": chat.cwd,
                "harness": "claude", "vm_kind": "owner"
            });
            start[field] = json!(true);
            let started = chat.client.request(start);
            assert_eq!(started["ok"], expected, "{started}");
            let sent = chat.sent("session/new");
            if expected {
                assert_eq!(sent.len(), 1);
                let meta = &sent[0]["params"]["_meta"]["acpmux"];
                assert_eq!(meta[meta_key], true);
                assert!(meta.get("credentials").is_none());
            } else {
                assert!(sent.is_empty(), "{label}: no agent starts");
            }
        }
    }
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
        if host == AgentStartHost::TeamVm {
            assert_code(&refused, "agent_session.personal_connection_on_team_vm");
        }
        assert!(chat.sent("session/new").is_empty(), "{label}: no agent starts");
    }
}

#[test]
fn the_owners_start_and_reattach_use_the_named_connection() {
    let mut chat = connect("cred-restore", AgentStartHost::OwnerCloud, false);
    let mut credential = env(TOKEN);
    credential["connection"] = json!(format!("anthropic-personal:{}", "a".repeat(64)));
    assert_eq!(chat.start(credential.clone(), json!("owner"))["ok"], json!(true));
    let sent = chat.sent("session/new");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["params"]["_meta"]["acpmux"]["credentials"], credential);

    let status = chat.client.request(json!({"cmd": "agent-session-credentials",
        "surface": chat.surface, "vm_kind": "owner"}));
    assert_eq!(status["ok"], json!(true));
    assert!(!status.to_string().contains(TOKEN));
    let sent = chat.sent("agent/credentials.update");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["params"], json!({"sessionId": SESSION}));
}

#[test]
fn the_owners_start_relays_a_claude_setup_token_to_acpmux() {
    let mut chat = connect("cred-claude-token", AgentStartHost::OwnerCloud, false);
    let token = "sk-ant-oat01-fixture";
    let credential = json!({"env": {"ANTHROPIC_AUTH_TOKEN": token}, "connection": "claude-token"});
    let started = chat.start(credential.clone(), json!("owner"));
    assert_eq!(started["ok"], true);
    assert!(!started.to_string().contains(token));
    let sent = chat.sent("session/new");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["params"]["_meta"]["acpmux"]["credentials"], credential);
}

#[test]
fn an_upgraded_guest_still_relays_legacy_claude_oauth_to_acpmux() {
    let mut chat = connect("cred-legacy-claude", AgentStartHost::OwnerCloud, false);
    let legacy = json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": "fixture"}});
    let started = chat.start(legacy.clone(), json!("owner"));
    assert_eq!(started["ok"], true, "{started}");
    assert!(!started.to_string().contains("fixture"));
    let sent = chat.sent("session/new");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["params"]["_meta"]["acpmux"]["credentials"], legacy);
}

#[test]
fn a_malformed_credential_is_a_bad_request() {
    for credentials in [
        json!({"env": {"PATH": "/evil"}}),
        json!({"env": {"CMUX_GROK_PLAN_ACCESS_TOKEN": "fixture"}}),
        json!({"env": {"CMUX_COPILOT_GITHUB_TOKEN": "fixture"}}),
        json!({"env": {"ANTHROPIC_API_KEY": TOKEN}, "connection": "-not-a-route"}),
        json!({"env": {"ANTHROPIC_API_KEY": TOKEN}, "connection": "anthropic-key:abc"}),
        json!({"env": {"ANTHROPIC_AUTH_TOKEN": "endpoint-only"}}),
        json!({"env": {"CMUX_BYO_API_KEY": "fixture"}}),
        json!({"env": {"CMUX_BYO_API_KEY": "fixture"}, "endpoint": {
            "kind": "anthropic", "baseUrl": "https://provider.example/v1", "models": ["m"]
        }}),
        json!({"env": {"ANTHROPIC_API_KEY": "a b"}}),
        json!({"env": {"ANTHROPIC_API_KEY": "x"}, "file": "/tmp/x"}),
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
            "session":SESSION,"env":{"ANTHROPIC_API_KEY":"sk-ant-api03-new"}});
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
    assert_eq!(updates[0]["params"]["env"]["ANTHROPIC_API_KEY"], json!("sk-ant-api03-new"));
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
fn a_legacy_chatgpt_refresh_resolves_an_owner_tab_to_its_own_session() {
    let mut chat = connect("cred-legacy-chatgpt", AgentStartHost::OwnerCloud, false);
    assert_eq!(chat.start(env(TOKEN), json!("owner"))["ok"], true);
    let token = json!({"CMUX_CHATGPT_ACCESS_TOKEN": "fixture-token"});
    let mut refresh = json!({"cmd":"agent-session-credentials","surface":chat.surface,"env":token});
    assert_eq!(chat.client.request(refresh.clone())["ok"], false);
    refresh["vm_kind"] = json!("owner");
    assert_eq!(chat.client.request(refresh)["ok"], true);
    let updates = chat.sent("agent/credentials.update");
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["params"], json!({"sessionId":SESSION,"env":token,"legacyRefresh":true}));
}

#[test]
fn credential_writes_refuse_a_surface_reused_by_another_chat() {
    let mut chat = connect("cred-reused-slot", AgentStartHost::OwnerCloud, false);
    assert_eq!(chat.start(env(TOKEN), json!("owner"))["ok"], true);
    let _ = chat.sent("session/new");

    // The old daemon used this same surface for a different durable chat.
    for env in [json!({"ANTHROPIC_API_KEY": TOKEN}), json!({})] {
        let frame = json!({"cmd":"agent-session-credentials","surface":chat.surface,
            "session":"chat-from-before-restart","vm_kind":"owner","env":env});
        assert_code(&chat.client.request(frame), "agent_session.unknown_tab");
    }
    for env in [json!({"ANTHROPIC_API_KEY": TOKEN}), json!({})] {
        let no_session = json!({"cmd":"agent-session-credentials","surface":chat.surface,
            "vm_kind":"owner","env":env});
        assert_code(&chat.client.request(no_session), "agent_session.bad_request");
    }
    assert!(chat.sent("agent/credentials.update").is_empty());
}

#[test]
fn the_owners_copilot_revocation_reaches_only_the_tabs_session() {
    let mut chat = connect("cred-copilot-remove", AgentStartHost::OwnerCloud, false);
    assert_eq!(chat.start(env(TOKEN), json!("owner"))["ok"], json!(true));
    let _ = chat.sent("session/new");
    let mut revoke = json!({"cmd":"agent-session-credentials","surface":chat.surface,"session":SESSION,"env":{}});
    assert_eq!(chat.client.request(revoke.clone())["ok"], json!(false));
    assert!(chat.sent("agent/credentials.update").is_empty());
    revoke["vm_kind"] = json!("owner");
    assert_eq!(chat.client.request(revoke)["ok"], json!(true));
    let updates = chat.sent("agent/credentials.update");
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["params"], json!({"sessionId":SESSION,"env":{}}));
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
fn a_guest_does_not_forward_native_keys_to_the_unbound_pool() {
    let mut chat = connect("prewarm-native-keys", AgentStartHost::OwnerCloud, false);
    for (harness, variable) in
        [("gemini", "GEMINI_API_KEY"), ("gemini", "GOOGLE_API_KEY"), ("grok", "XAI_API_KEY")]
    {
        let frame = json!({"cmd":"agent-session-prewarm","surface":chat.surface,"cwd":chat.cwd,
            "harness":harness,"vm_kind":"owner","credentials":{"env":{(variable):"fixture-key"}}});
        let reply = chat.client.request(frame);
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["data"]["accepted"], false, "{variable}");
    }
    assert!(chat.sent("_acpmux/prewarm").is_empty());
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

#[test]
fn a_prewarm_for_a_bound_tab_or_with_no_folder_is_refused() {
    let mut chat = connect("prewarm-bound", AgentStartHost::OwnerCloud, false);
    let mut no_folder = json!({"cmd":"agent-session-prewarm","surface":chat.surface,
        "harness":"claude","vm_kind":"owner"});
    assert_code(&chat.client.request(no_folder.clone()), "agent_session.bad_request");
    let started = chat.start(env(TOKEN), json!("owner"));
    assert_eq!(started["ok"], json!(true), "{started}");
    let _ = chat.sent("session/new");
    no_folder["cwd"] = json!(chat.cwd);
    assert_eq!(chat.client.request(no_folder)["ok"], json!(false), "a bound tab warms nothing");
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
        (with("bogus_param", json!(secret)), "bogus_param"),
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
