//! The owner phone stamp (RFD 0135 gate 4): the phone the Cloud link's owner check admitted
//! rides its Cloud mobile prompts to acpmux as `ownerPhone`, never with Full access; nothing
//! else gets it.
use super::super::agent_session_attach_tests::{
    Client, FakeAcpmux, SESSION, agent_tab, assert_code, mux_with,
};
use super::super::*;
use cmux_link::token::VmKind;

const PHONE_CAPABILITIES: [&str; 3] =
    ["cloud-mobile-chat-v1", "conversation-tabs-v1", "agent-session-tabs-v1"];

fn declare_phone(client: &mut Client) {
    let info = client.request(json!({"cmd":"set-client-info","kind":"ios",
        "capabilities": PHONE_CAPABILITIES}));
    assert_eq!(info["ok"], json!(true), "{info}");
}

/// The prompt a phone-shaped stream sends to acpmux after `stamp` (none: no stamp).
fn phone_prompt(label: &str, stamp: Option<&str>, declare: bool) -> Value {
    let fake = FakeAcpmux::start(label);
    let mux = mux_with(&fake, label);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, label);
    if let Some(device) = stamp {
        let reply =
            client.request(serde_json::from_str(&cmux_link::owner_phone::line(device)).unwrap());
        assert_eq!(reply["ok"], json!(true), "{reply}");
    }
    if declare {
        declare_phone(&mut client);
    }
    let attached = client.request(json!({"cmd":"agent-session-attach","surface":surface,
        "limit":400,"kinds":["transcript"]}));
    assert_eq!(attached["ok"], json!(true), "{attached}");
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-session-prompt","surface":surface,
        "prompt_id":"phone-1","text":"from the phone"}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/prompt"));
    sent["params"]["_meta"]["acpmux"].clone()
}

#[test]
fn the_owner_checked_phones_prompt_carries_it_without_full_access() {
    let meta = phone_prompt("owner-phone", Some("install-phone"), true);
    assert_eq!(meta["via"], json!("cloud-mobile"), "{meta}");
    assert_eq!(meta["ownerPhone"], json!({"device":"install-phone","fullAccess":false}), "{meta}");
}

#[test]
fn an_unstamped_phone_or_a_stamped_non_phone_carries_no_claim() {
    let meta = phone_prompt("owner-phone-none", None, true);
    assert_eq!(meta["via"], json!("cloud-mobile"), "{meta}");
    assert!(meta.get("ownerPhone").is_none(), "{meta}");
    // A stamp on a connection that never declares the phone's capability counts for nothing.
    let meta = phone_prompt("owner-phone-local", Some("install-phone"), false);
    assert!(meta.get("via").is_none() && meta.get("ownerPhone").is_none(), "{meta}");
}

#[test]
fn one_stamp_only_never_on_a_carrier_stream_and_no_role_after_it() {
    let fake = FakeAcpmux::start("owner-phone-once");
    let mux = mux_with(&fake, "owner-phone-once");
    let mut client = Client::connect(&mux, "owner-phone-once");
    let line =
        |d: &str| -> Value { serde_json::from_str(&cmux_link::owner_phone::line(d)).unwrap() };
    assert_eq!(client.request(line("install-a"))["ok"], json!(true));
    assert_code(&client.request(line("install-b")), "owner_phone.already_stamped");
    let role = client.request(
        serde_json::from_str(&cmux_link::carrier_role::line(Some(VmKind::Owner))).unwrap(),
    );
    assert_code(&role, "carrier_role.already_stamped");
    assert_code(
        &client.request(json!({"cmd":"owner-phone","device":"x","fullAccess":true})),
        "owner_phone.malformed",
    );

    // A carrier stream (a teammate's or the session host's) takes no phone stamp.
    let mut carrier = Client::connect(&mux, "owner-phone-carrier");
    let role = client_role(&mut carrier, VmKind::Team);
    assert_eq!(role["ok"], json!(true), "{role}");
    assert_code(&carrier.request(line("install-a")), "owner_phone.carrier_stream");
}

fn client_role(client: &mut Client, role: VmKind) -> Value {
    client.request(serde_json::from_str(&cmux_link::carrier_role::line(Some(role))).unwrap())
}
