//! A provider's own family changed (`apps-provider-changed {family}`): the daemon tells the readable
//! subscribers of `<family>.changed` with an empty invalidation, so a script re-reads on a change
//! instead of polling (the threads template read `agent_chat.list` every 2 s).

use super::super::provider::ProviderClaim;
use super::super::supervisor::HostKey;
use super::*;

const PROVIDER: u64 = 9;
const APP: ProviderClaim = ProviderClaim { agent: false, verified_app: true };

fn chat_fixture() -> Fixture {
    let root = temp_dir();
    write_app(
        &root.0.join("bundled"),
        "demo",
        "cmux/demo",
        json!({"agent_chat:read":"list the chats"}),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.mount("live", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    let (tx, _rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor.register_client(
        PROVIDER,
        Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
    );
    f.supervisor.register_provider(PROVIDER, APP, vec!["agent_chat".into()]).unwrap();
    f
}

fn subscribe(f: &Fixture, sub: u64, stream: &str) {
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let generation = f.supervisor.inner.lock().unwrap().hosts[&key].generation;
    f.supervisor.on_host_message(
        &key,
        generation,
        FromHost::Subscribe { sub, stream: stream.into(), filter: json!({}) },
    );
}

#[test]
fn cmux_next_provider_changed_tells_the_readable_subscribers_of_its_family() {
    let f = chat_fixture();
    subscribe(&f, 41, "agent_chat.changed");
    assert_eq!(f.supervisor.provider_changed(PROVIDER, APP, "agent_chat").unwrap(), json!({}));
    f.wait("agent_chat.changed invalidation", |e| {
        e["event"] == "apps-log" && e["message"] == "event-body 41 {}"
    });
    assert!(f.router.calls.lock().unwrap().is_empty(), "an invalidation starts no read");
}

#[test]
fn cmux_next_provider_changed_needs_the_verified_holder_of_the_family() {
    let f = chat_fixture();
    let code = |client, claim, family: &str| {
        f.supervisor.provider_changed(client, claim, family).unwrap_err().code
    };
    assert_eq!(code(99, APP, "agent_chat"), "apps.provider.unknown", "another connection");
    assert_eq!(code(PROVIDER, APP, "fs"), "apps.provider.unknown", "a family it does not hold");
    let agent = ProviderClaim { agent: true, verified_app: true };
    assert_eq!(code(PROVIDER, agent, "agent_chat"), "apps.provider.forbidden");
    let unverified = ProviderClaim { agent: false, verified_app: false };
    assert_eq!(code(PROVIDER, unverified, "agent_chat"), "apps.provider.forbidden");
    // agent_cli keeps its demand-sequenced invalidation (`apps-agent-inventory-changed`).
    assert_eq!(code(PROVIDER, APP, "agent_cli"), "bad-request");
}
