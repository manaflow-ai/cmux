//! A phone's channel (`cloud-mobile-chat-v1` on a unix carrier stream) reaches only hostd's
//! Cloud ACP adapter's commands, a chat start included; everything else is refused.

use super::super::agent_session_attach_tests::{Client, FakeAcpmux, mux_with, run, terminal_pane};
use super::super::*;

fn phone(label: &str) -> (FakeAcpmux, Arc<Mux>, Client) {
    let fake = FakeAcpmux::start(label);
    let mux = mux_with(&fake, label);
    let mut client = Client::connect(&mux, label);
    assert_eq!(client.request(json!({"cmd":"carrier-role","vmk":"owner"}))["ok"], json!(true));
    let declared = client.request(json!({"cmd":"set-client-info","kind":"ios",
        "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
    assert_eq!(declared["ok"], json!(true), "{declared}");
    (fake, mux, client)
}

fn denied(reply: &Value) {
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(reply["error_code"], json!("remote_denied"), "{reply}");
}

fn store_tab(mux: &Arc<Mux>, client: &mut Client) -> Value {
    let (_, pane) = terminal_pane(mux);
    let host = agent_session_attach::agent_session_start::store_host(mux);
    client.request(json!({"cmd":"new-conversation-tab","pane":pane,
        "agent_session":{"host":host,"harness":"claude"}}))
}

#[test]
fn the_adapters_commands_pass_and_a_chat_starts_in_a_new_tab() {
    let (_fake, mux, mut client) = phone("phone-allowed");
    assert_eq!(client.request(json!({"cmd":"identify"}))["ok"], json!(true));
    assert_eq!(client.request(json!({"cmd":"list-workspaces"}))["ok"], json!(true));
    let workspace = client.request(json!({"cmd":"create-workspace","name":"Phone chat"}));
    assert_eq!(workspace["ok"], json!(true), "{workspace}");
    let tab = store_tab(&mux, &mut client);
    assert_eq!(tab["ok"], json!(true), "{tab}");
    // A start reaches its own handler, which holds it to the owner's signed role and the
    // phone floor (agent_session_start_phone_tests.rs): an unknown tab is its answer, not
    // the filter's.
    let surface = tab["data"]["surface"].clone();
    let started = client.request(json!({"cmd":"agent-session-start","surface":999_999,
        "cwd":"/tmp","harness":"claude","vm_kind":"owner"}));
    assert_eq!(started["ok"], json!(false), "{started}");
    assert_ne!(started["error_code"], json!("remote_denied"), "{started}");
    // hostd closes a start's empty tab when the phone leaves (`abandon`).
    let closed = client.request(json!({"cmd":"close-surface","surface":surface}));
    assert_eq!(closed["ok"], json!(true), "{closed}");
}

#[test]
fn every_other_command_is_refused() {
    let (_fake, mux, mut client) = phone("phone-refused");
    let (terminal, pane) = terminal_pane(&mux);
    for frame in [
        json!({"cmd":"new-tab","pane":pane}),
        json!({"cmd":"create-terminal","cols":80,"rows":24}),
        json!({"cmd":"send-key","surface":terminal,"key":"enter"}),
        json!({"cmd":"read-screen","surface":terminal}),
        json!({"cmd":"agent-session-permission","surface":terminal,"permission_id":"p","option_id":"o"}),
        json!({"cmd":"agent-session-trust","surface":terminal,"cwd":"/tmp"}),
        json!({"cmd":"agent-session-fork","surface":terminal,"through_seq":1}),
        json!({"cmd":"conversation-list"}),
        json!({"cmd":"shutdown-daemon"}),
        json!({"type":"request","op":"workspace.create"}),
    ] {
        denied(&client.request(frame));
    }
}

#[test]
fn a_command_bearing_param_is_refused_on_an_allowed_command() {
    let (_fake, _mux, mut client) = phone("phone-command-param");
    for param in ["initial_command", "command", "tmux_start_command", "pane_start_command"] {
        let mut frame = json!({"cmd":"create-workspace","name":"x"});
        frame[param] = json!("touch /tmp/owned");
        denied(&client.request(frame));
    }
}

#[test]
fn a_tab_must_be_this_stores_agent_tab_and_a_close_an_unbound_one() {
    let (_fake, mux, mut client) = phone("phone-tabs");
    let (terminal, pane) = terminal_pane(&mux);
    denied(&client.request(json!({"cmd":"new-conversation-tab","pane":pane,
        "agent_session":{"host":"install:brain","harness":"claude"}})));
    denied(&client.request(json!({"cmd":"new-conversation-tab","pane":pane})));
    denied(&client.request(json!({"cmd":"close-surface","surface":terminal})));
    // A tab whose chat is bound is not the phone's to close.
    let host = agent_session_attach::agent_session_start::store_host(&mux);
    // A chat this machine started, as `agent-session-start` records it.
    mux.control_clients.agent_sessions.known_children.remember(["acp_bound"]);
    let bound = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":host,"session":"acp_bound","harness":"claude"}}),
    )["surface"]
        .clone();
    denied(&client.request(json!({"cmd":"close-surface","surface":bound})));
}

#[test]
fn the_declaration_sticks_for_the_connections_life() {
    let (_fake, mux, mut client) = phone("phone-sticky");
    let info = client.request(json!({"cmd":"set-client-info","capabilities":[]}));
    assert_eq!(info["ok"], json!(true), "{info}");
    let (_, pane) = terminal_pane(&mux);
    denied(&client.request(json!({"cmd":"new-tab","pane":pane})));
}

#[test]
fn a_connection_that_is_not_a_phones_is_not_held_to_the_list() {
    let fake = FakeAcpmux::start("not-phone");
    let mux = mux_with(&fake, "not-phone");
    let mut client = Client::connect(&mux, "not-phone");
    let (_, pane) = terminal_pane(&mux);
    let created = client.request(json!({"cmd":"new-tab","pane":pane}));
    assert_eq!(created["ok"], json!(true), "{created}");
}
