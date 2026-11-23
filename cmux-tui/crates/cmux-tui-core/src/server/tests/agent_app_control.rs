//! Settings > Agents > Agents Can Change cmux (`agents.appControl`,
//! server/agent_app_control.rs): on `read` an agent in cmux may read the app
//! but not change it; `change` (the default) is the behavior before it.

use super::*;
use crate::mux::settings::SettingsPaths;
use crate::resource::ResourceOperation;
use crate::server::agent_app_control::{Ask, LEGACY_ALLOWED, REASON, is_agent, refuse_line};

struct Rig {
    mux: Arc<Mux>,
    _dir: cmux_unix_socket::TestDir,
}

fn rig(name: &str) -> Rig {
    let dir = cmux_unix_socket::short_test_dir(&format!("aac-{name}"));
    let mux = test_mux();
    assert!(mux.start_settings_owner(SettingsPaths {
        config: dir.path().join("cmux-next.json"),
        seed: None,
        state_dir: Some(dir.path().to_path_buf()),
        reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
        watch: false,
    }));
    Rig { mux, _dir: dir }
}

impl Rig {
    fn set(&self, value: &str, origin: cmux_config::Origin) -> Result<(), cmux_config::Refusal> {
        self.mux
            .settings_apply(cmux_config::Op::Set {
                target: cmux_config::Target::Key("agents.appControl".into()),
                value: json!(value),
                meta: cmux_config::WriteMeta { origin, idempotency_key: None, if_revision: None },
            })
            .map(|_| ())
    }

    /// The person's own switch, from the Settings page.
    fn read_only(&self) {
        self.set("read", cmux_config::Origin::App).unwrap();
        assert!(self.mux.agents_read_only());
    }

    /// A local connection the daemon types as a process in a cmux terminal.
    fn agent(&self) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
        let (writer, outbound) = captured_writer();
        let client = self.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        origin_gate::set_local_peer_for_test(
            &self.mux,
            client,
            crate::request_origin::LocalPeer::Terminal("term_agent".into()),
        );
        (client, writer, outbound)
    }

    /// A local connection from outside cmux (the person's own).
    fn person(&self) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
        let (writer, outbound) = captured_writer();
        let client = self.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        (client, writer, outbound)
    }
}

fn v2(operation: &str) -> String {
    json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"aac",
        "operation":operation,
        "params":{},
    })
    .to_string()
}

fn legacy(cmd: &str) -> String {
    json!({"id":7,"cmd":cmd}).to_string()
}

#[test]
fn agent_app_control_legacy_allow_list_is_sorted_and_unique() {
    let list = LEGACY_ALLOWED;
    assert!(list.windows(2).all(|pair| pair[0] < pair[1]), "LEGACY_ALLOWED must stay sorted");
}

#[test]
fn agent_app_control_classifies_lines() {
    let ask =
        |line: &str| Ask::of(&serde_json::from_str::<Value>(line).unwrap()).allowed_read_only();
    assert!(ask(&v2("workspace.list")), "a v2 read is allowed");
    assert!(!ask(&v2("workspace.create")), "a v2 mutation is refused");
    assert!(ask(&v2("agent.report")), "an agent's own report is allowed");
    assert!(ask(&v2("notification.create")), "a notification is allowed");
    assert!(!ask(&v2("no.such.operation")), "an unknown v2 operation is refused");
    assert!(ask(&legacy("list-workspaces")), "a legacy read is allowed");
    assert!(ask(&legacy("report-agent")), "a legacy report is allowed");
    assert!(!ask(&legacy("new-workspace")), "a legacy change is refused");
    assert!(!ask(&legacy("send-text")), "typing into a terminal is refused");
    assert!(!ask(r#"{"kind":"other wire"}"#), "a line no rule knows is refused");
    assert_eq!(
        Ask::of(&serde_json::from_str::<Value>(&v2("workspace.create")).unwrap()),
        Ask::Resource(Some(ResourceOperation::WorkspaceCreate))
    );
}

#[test]
fn agent_app_control_agents_are_terminals_and_agent_chats() {
    assert!(is_agent(&crate::Actor::Terminal { id: "term_1".into() }));
    assert!(!is_agent(&crate::Actor::local_user()));
    assert!(!is_agent(&crate::Actor::Frontend { install_id: "install".into() }));
}

#[test]
fn agent_app_control_change_is_the_default_and_refuses_nothing() {
    let rig = rig("default");
    assert!(!rig.mux.agents_read_only());
    let (client, writer, outbound) = rig.agent();
    assert!(refuse_line(&rig.mux, client, &legacy("new-workspace"), &writer).is_none());
    assert!(refuse_line(&rig.mux, client, &v2("workspace.create"), &writer).is_none());
    assert!(outbound.try_pop().is_none());
}

#[test]
fn agent_app_control_read_refuses_an_agents_change_and_allows_its_reads() {
    let rig = rig("read");
    rig.read_only();
    let (client, writer, outbound) = rig.agent();

    assert_eq!(refuse_line(&rig.mux, client, &legacy("new-workspace"), &writer), Some(true));
    let response = drain_json(&outbound).pop().expect("a refusal");
    assert_eq!(response["id"], 7);
    assert!(response["error"].as_str().unwrap().starts_with(REASON), "{response}");

    assert_eq!(refuse_line(&rig.mux, client, &v2("workspace.create"), &writer), Some(true));
    let response = drain_json(&outbound).pop().expect("a refusal");
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "origin.forbidden", "{response}");
    assert_eq!(response["error"]["details"]["reason"], REASON, "{response}");
    assert!(
        response["error"]["message"].as_str().unwrap().contains("agents.appControl"),
        "{response}"
    );

    // Off the allow list: each changes the app (a setting, another viewer).
    for change in ["set-terminal-command-history", "detach-client"] {
        assert!(LEGACY_ALLOWED.binary_search(&change).is_err(), "{change}");
        assert_eq!(refuse_line(&rig.mux, client, &legacy(change), &writer), Some(true), "{change}");
        let response = drain_json(&outbound).pop().expect("a refusal");
        assert!(response["error"].as_str().unwrap().starts_with(REASON), "{response}");
    }

    // Reads and streams of reads stay allowed.
    for read in [
        legacy("list-workspaces"),
        legacy("identify"),
        legacy("conversation-run"),
        legacy("conversation-live"),
        legacy("cloud-conversation-run"),
        legacy("snapshot-request"),
        legacy("subscribe"),
        v2("workspace.list"),
    ] {
        assert!(refuse_line(&rig.mux, client, &read, &writer).is_none(), "{read} is a read");
    }
    assert!(outbound.try_pop().is_none());
}

#[test]
fn agent_app_control_read_never_refuses_the_person_outside_cmux() {
    let rig = rig("person");
    rig.read_only();
    let (client, writer, outbound) = rig.person();
    assert!(refuse_line(&rig.mux, client, &legacy("new-workspace"), &writer).is_none());
    assert!(refuse_line(&rig.mux, client, &v2("workspace.create"), &writer).is_none());
    assert!(outbound.try_pop().is_none());
}

#[test]
fn agent_app_control_follows_the_setting_live() {
    let rig = rig("live");
    rig.read_only();
    rig.set("change", cmux_config::Origin::App).unwrap();
    assert!(!rig.mux.agents_read_only());
    let (client, writer, _outbound) = rig.agent();
    assert!(refuse_line(&rig.mux, client, &legacy("new-workspace"), &writer).is_none());
}

/// The setting is userOnly: only the person (the app, `--origin user`) may
/// change it, so an agent cannot widen it back to `change`.
#[test]
fn agent_app_control_is_user_only() {
    let rig = rig("user-only");
    rig.read_only();
    for origin in [cmux_config::Origin::Cli, cmux_config::Origin::Mcp] {
        let refusal = rig.set("change", origin).unwrap_err();
        assert!(
            matches!(refusal, cmux_config::Refusal::AgentRefused { .. }),
            "{origin:?}: {refusal:?}"
        );
    }
    assert!(rig.mux.agents_read_only());
}
