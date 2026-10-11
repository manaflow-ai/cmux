//! Behavior of `agent-transfer-v1` (cmuxterm-hq#1874 slice 1): a trusted
//! local client moves an agent chat between two daemons' acpmux, and the
//! daemon forwards only the guarded form of acpmux's `acpmux.transfer.v1`.
//! The fake acpmux of `agent_session_attach_tests.rs` records every frame.
//!
//! Policy tests (AGENTS.md "Remote CLI relay"): the verbs are refused on the
//! remote relay (`cmux link`), on WebSocket clients and on stamped Unix
//! clients; the guard is always the daemon's own (a client guard, roots,
//! control, env, MCP server, session id or command param is refused before
//! anything reaches acpmux); the folder must be under the guard's roots;
//! source verbs take the chat only from a tab of this store, and a surface
//! that is not one gets the same answer as an unknown one.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::agent_session_attach_tests::{
    BUNDLE_MANIFEST, Client, FakeAcpmux, SESSION, UNGUARDED_CHAT, agent_tab, assert_code, mux_with,
    run, terminal_pane,
};
use super::super::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink, remote_relay};
use super::{AGENT_TRANSFER_CAPABILITY, AgentTransferHost, MAX_PAGE_BYTES, try_handle};
use crate::mux::Mux;

// MARK: Fixtures

/// A private home with `work/project` (the Cloud sync root) and
/// `code/project` (a Mac checkout), removed on drop.
struct Home {
    path: PathBuf,
}

impl Home {
    fn new(label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let path = PathBuf::from(format!(
            "/tmp/cmux-atx-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        for dir in ["work/project", "code/project", ".ssh/keys", "elsewhere"] {
            std::fs::create_dir_all(path.join(dir)).unwrap();
        }
        Self { path }
    }

    /// The canonical form of `rel` under this home (as the daemon forwards it).
    fn canonical(&self, rel: &str) -> String {
        canonical(&self.path.join(rel))
    }

    fn text(&self, rel: &str) -> String {
        self.path.join(rel).to_str().unwrap().to_string()
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn canonical(path: &Path) -> String {
    std::fs::canonicalize(path).unwrap().to_str().unwrap().to_string()
}

fn transfer_mux(fake: &FakeAcpmux, label: &str, home: &Home, cloud: bool) -> Arc<Mux> {
    let mux = mux_with(fake, label);
    mux.set_agent_transfer_host(Some(AgentTransferHost { cloud, home: home.path.clone() }));
    mux
}

/// The `transfer_begin` answer a source daemon hands the app.
fn manifest() -> Value {
    json!({"schema":"acpmux.transfer.v1","transferId":"xfer_src","sessionId":"acp_moving",
           "files":[{"path":"events/0.ndjson","size":3}],
           "session":{"sessionId":"acp_moving","harness":"claude"}})
}

fn receive(client: &mut Client, cwd: &str) -> Value {
    client.request(json!({"cmd":"agent-transfer-receive","manifest":manifest(),"cwd":cwd}))
}

fn ok_data(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], json!(true), "{reply}");
    &reply["data"]
}

/// Every verb, well formed, for the extra-param and trust tests.
fn every_verb(surface: u64, cwd: &str) -> Vec<Value> {
    vec![
        json!({"id":1,"cmd":"agent-transfer-receive","manifest":manifest(),"cwd":cwd}),
        json!({"id":2,"cmd":"agent-transfer-write","receive_id":"rcv_1","path":"events/0.ndjson",
               "offset":0,"data":"YWJj"}),
        json!({"id":3,"cmd":"agent-transfer-finish","receive_id":"rcv_1"}),
        json!({"id":4,"cmd":"agent-transfer-begin","surface":surface}),
        json!({"id":5,"cmd":"agent-transfer-read","transfer_id":"xfer_1","path":"events/0.ndjson",
               "offset":0}),
        json!({"id":6,"cmd":"agent-transfer-commit","surface":surface,"transfer_id":"xfer_1",
               "to":{"machine":"vm"}}),
        json!({"id":7,"cmd":"agent-transfer-abort","surface":surface,"transfer_id":"xfer_1"}),
    ]
}

// MARK: Capability and trust

#[test]
fn the_capability_is_advertised_with_an_acpmux_socket_and_a_host() {
    let fake = FakeAcpmux::start("xcap");
    let home = Home::new("cap");
    let mux = mux_with(&fake, "atx-cap");
    let advertised = |mux: &Arc<Mux>| {
        run(mux, json!({"cmd":"identify"}))["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == AGENT_TRANSFER_CAPABILITY)
    };
    assert!(!advertised(&mux), "no host: the daemon cannot build a guard");
    mux.set_agent_transfer_host(Some(AgentTransferHost { cloud: false, home: home.path.clone() }));
    assert!(advertised(&mux));
    mux.set_acpmux_socket(None);
    assert!(!advertised(&mux));
}

#[test]
fn without_a_host_every_target_verb_is_unavailable() {
    let fake = FakeAcpmux::start("xnohost");
    let home = Home::new("nohost");
    let mux = mux_with(&fake, "atx-nohost");
    let mut client = Client::connect(&mux, "xnohost");
    assert_code(&receive(&mut client, &home.text("code/project")), "agent_transfer.unavailable");
    fake.no_connection();
}

#[test]
fn the_remote_relay_denies_every_agent_transfer_verb() {
    let fake = FakeAcpmux::start("xrelay");
    let home = Home::new("relay");
    let mux = transfer_mux(&fake, "atx-relay", &home, true);
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    for frame in every_verb(surface, &home.text("work/project")) {
        assert!(remote_relay::gate::check_frame(&frame.to_string()).is_err());
        remote_relay::handle_frame(&mux, client, &frame.to_string(), &writer);
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, "remote_denied");
    }
    fake.no_connection();
}

#[test]
fn every_verb_is_refused_on_every_untrusted_connection() {
    let fake = FakeAcpmux::start("xuntrusted");
    let home = Home::new("untrusted");
    let mux = transfer_mux(&fake, "atx-untrusted", &home, true);
    let surface = agent_tab(&mux, Some(SESSION));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    // A Unix connection that carries a paired install's link stamp is remote.
    mux.record_remote_check("inst_peer").unwrap();
    let stamped = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let peer = crate::remote_relay_state::LinkPeer {
        install: "inst_peer".into(),
        user: "42".into(),
        team: "team_a".into(),
    };
    mux.bind_remote_peer(stamped, &peer).unwrap();
    let unregistered = 999_999;
    for client in [websocket, stamped, unregistered] {
        let mut answers = Vec::new();
        for frame in every_verb(surface, &home.text("work/project")) {
            assert_eq!(try_handle(&mux, client, &frame.to_string(), &writer), Some(true));
            let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
            assert_code(&reply, "agent_transfer.not_trusted");
            answers.push((reply["error"].clone(), reply["error_code"].clone()));
        }
        // One generic denial, whatever the frame names.
        answers.dedup();
        assert_eq!(answers.len(), 1, "{answers:?}");
    }
    fake.no_connection();
}

// MARK: The daemon builds the guard

#[test]
fn a_cloud_host_receive_forwards_peer_control_rooted_at_home_work() {
    let fake = FakeAcpmux::start("xcloud");
    let home = Home::new("cloud");
    let mux = transfer_mux(&fake, "atx-cloud", &home, true);
    let mut client = Client::connect(&mux, "xcloud");
    let reply = receive(&mut client, &home.text("work/project"));
    assert_eq!(ok_data(&reply)["receive_id"], json!("rcv_1"));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/transfer_receive"));
    assert_eq!(
        sent["params"],
        json!({"manifest": manifest(),
               "guard": {"control": "peer", "roots": [home.canonical("work")]}})
    );
}

#[test]
fn a_mac_receive_forwards_web_control_rooted_at_the_given_folder() {
    let fake = FakeAcpmux::start("xmac");
    let home = Home::new("mac");
    let mux = transfer_mux(&fake, "atx-mac", &home, false);
    let mut client = Client::connect(&mux, "xmac");
    let reply = receive(&mut client, &home.text("code/project"));
    assert_eq!(ok_data(&reply)["receive_id"], json!("rcv_1"));
    let sent = fake.frame();
    assert_eq!(
        sent["params"]["guard"],
        json!({"control": "web", "roots": [home.canonical("code/project")]})
    );
}

#[test]
fn write_and_finish_forward_the_receive_and_finish_uses_its_folder() {
    let fake = FakeAcpmux::start("xfinish");
    let home = Home::new("finish");
    let mux = transfer_mux(&fake, "atx-finish", &home, true);
    let mut client = Client::connect(&mux, "xfinish");
    // A path with `..` that canonicalizes under the root.
    let cwd = home.text("work/project/../project");
    ok_data(&receive(&mut client, &cwd));
    let _ = fake.frame();
    let reply = client.request(json!({"cmd":"agent-transfer-write","receive_id":"rcv_1",
                                      "path":"events/0.ndjson","offset":0,"data":"YWJj"}));
    assert_eq!(ok_data(&reply)["next"], json!(3));
    assert_eq!(
        fake.frame()["params"],
        json!({"receiveId":"rcv_1","path":"events/0.ndjson","offset":0,"data":"YWJj"})
    );
    let reply = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1",
                                      "name":"moved chat"}));
    ok_data(&reply);
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/transfer_finish"));
    assert_eq!(
        sent["params"],
        json!({"receiveId":"rcv_1","cwd":home.canonical("work/project"),"name":"moved chat"})
    );
    // A finished receive is gone.
    let again = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&again, "agent_transfer.unknown_receive");
    fake.no_frame();
}

#[test]
fn write_and_finish_take_only_a_receive_this_daemon_guarded() {
    let fake = FakeAcpmux::start("xunknown");
    let home = Home::new("unknown");
    let mux = transfer_mux(&fake, "atx-unknown", &home, true);
    let mut client = Client::connect(&mux, "xunknown");
    for frame in [
        json!({"cmd":"agent-transfer-write","receive_id":"rcv_other","path":"a","offset":0,
               "data":"YWJj"}),
        json!({"cmd":"agent-transfer-finish","receive_id":"rcv_other"}),
    ] {
        assert_code(&client.request(frame), "agent_transfer.unknown_receive");
    }
    fake.no_connection();
}

#[test]
fn an_acpmux_that_did_not_apply_the_guard_is_refused() {
    let fake = FakeAcpmux::start("xunguarded");
    let home = Home::new("unguarded");
    let mux = transfer_mux(&fake, "atx-unguarded", &home, true);
    let mut client = Client::connect(&mux, "xunguarded");
    let mut old = manifest();
    old["sessionId"] = json!(UNGUARDED_CHAT);
    let reply = client.request(json!({"cmd":"agent-transfer-receive","manifest":old,
                                      "cwd":home.text("work/project")}));
    assert_code(&reply, "agent_transfer.unguarded");
    let _ = fake.frame();
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_old"}));
    assert_code(&finish, "agent_transfer.unknown_receive");
    fake.no_frame();
}

#[test]
fn a_folder_outside_the_roots_is_refused_before_acpmux() {
    let fake = FakeAcpmux::start("xoutside");
    let home = Home::new("outside");
    std::os::unix::fs::symlink(home.path.join("elsewhere"), home.path.join("work/link")).unwrap();
    std::os::unix::fs::symlink("/", home.path.join("code/root")).unwrap();
    let cloud = transfer_mux(&fake, "atx-outside-cloud", &home, true);
    let mut client = Client::connect(&cloud, "xoutside-cloud");
    for cwd in [
        home.text("elsewhere"),
        home.text("code/project"),
        home.text("work/../elsewhere"),
        home.text("work/link"),
        home.text("work/missing"),
        home.text(""),
        "/".to_string(),
    ] {
        assert_code(&receive(&mut client, &cwd), "agent_transfer.outside_roots");
    }
    let mac = transfer_mux(&fake, "atx-outside-mac", &home, false);
    let mut client = Client::connect(&mac, "xoutside-mac");
    for cwd in [
        home.text(""),
        home.text(".ssh"),
        home.text(".ssh/keys"),
        home.text("code/root"),
        home.text("code/missing"),
        "/tmp".to_string(),
        "/".to_string(),
    ] {
        assert_code(&receive(&mut client, &cwd), "agent_transfer.outside_roots");
    }
    for cwd in ["relative/project", ""] {
        assert_code(&receive(&mut client, cwd), "agent_transfer.bad_request");
    }
    fake.no_connection();
}

#[test]
fn a_client_guard_roots_control_env_session_or_command_param_is_refused() {
    let fake = FakeAcpmux::start("xparams");
    let home = Home::new("params");
    let mux = transfer_mux(&fake, "atx-params", &home, true);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xparams");
    let extras = [
        json!({"guard":{"control":"local","roots":["/"]}}),
        json!({"roots":["/"]}),
        json!({"control":"local"}),
        json!({"env":{"PATH":"/tmp"}}),
        json!({"mcpServers":[]}),
        json!({"sessionId":"acp_other"}),
        json!({"command":"rm -rf /"}),
        json!({"initial_command":"x"}),
        json!({"tmux_start_command":"x"}),
        json!({"pane_start_command":"x"}),
        json!({"preset":"yolo"}),
    ];
    for frame in every_verb(surface, &home.text("work/project")) {
        for extra in &extras {
            let mut frame = frame.clone();
            frame.as_object_mut().unwrap().remove("id");
            for (key, value) in extra.as_object().unwrap() {
                frame[key] = value.clone();
            }
            assert_code(&client.request(frame), "agent_transfer.bad_request");
        }
    }
    fake.no_connection();
}

#[test]
fn pages_over_four_mebibytes_are_refused() {
    let fake = FakeAcpmux::start("xpages");
    let home = Home::new("pages");
    let mux = transfer_mux(&fake, "atx-pages", &home, true);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xpages");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    let base64 = base64::engine::general_purpose::STANDARD;
    let at_cap = base64.encode(vec![7u8; MAX_PAGE_BYTES]);
    let over = base64.encode(vec![7u8; MAX_PAGE_BYTES + 1]);
    let write = |data: &str| {
        json!({"cmd":"agent-transfer-write","receive_id":"rcv_1","path":"events/0.ndjson",
               "offset":0,"data":data})
    };
    assert_code(&client.request(write(&over)), "agent_transfer.bad_request");
    fake.no_frame();
    ok_data(&client.request(write(&at_cap)));
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_write"));
    ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
    let _ = fake.frame();
    let _ = fake.frame();
    let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                     "path":"events/0.ndjson","offset":0,
                                     "limit":MAX_PAGE_BYTES + 1}));
    assert_code(&read, "agent_transfer.bad_request");
    fake.no_frame();
}

// MARK: Source verbs

#[test]
fn source_verbs_take_the_chat_from_the_surface_tab() {
    let fake = FakeAcpmux::start("xsource");
    let home = Home::new("source");
    let mux = transfer_mux(&fake, "atx-source", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xsource");
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface,
                                      "interrupt":true}));
    let data = ok_data(&begun).clone();
    assert_eq!(data["transfer_id"], json!("xfer_1"));
    assert_eq!(data["manifest"]["sessionId"], json!(SESSION));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/transfer_begin"));
    assert_eq!(sent["params"], json!({"sessionId":SESSION,"interrupt":true}));
    let _manifest_read = fake.frame();
    let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                     "path":"events/0.ndjson","offset":0,"limit":1024}));
    assert_eq!(ok_data(&read)["data"], json!("YWJj"));
    assert_eq!(
        fake.frame()["params"],
        json!({"transferId":"xfer_1","path":"events/0.ndjson","offset":0,"limit":1024})
    );
    let commit = client.request(json!({"cmd":"agent-transfer-commit","surface":surface,
                                       "transfer_id":"xfer_1","to":{"machine":"vm"}}));
    ok_data(&commit);
    assert_eq!(
        fake.frame()["params"],
        json!({"sessionId":SESSION,"transferId":"xfer_1","to":{"machine":"vm"}})
    );
    let abort = client.request(json!({"cmd":"agent-transfer-abort","surface":surface,
                                      "transfer_id":"xfer_1"}));
    ok_data(&abort);
    assert_eq!(fake.frame()["params"], json!({"sessionId":SESSION,"transferId":"xfer_1"}));
}

#[test]
fn begin_strips_absolute_source_paths_from_the_bundle_manifest() {
    let fake = FakeAcpmux::start("xstrip");
    let home = Home::new("strip");
    let mux = transfer_mux(&fake, "atx-strip", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xstrip");
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface}));
    let files = ok_data(&begun)["manifest"]["files"].clone();
    let size = files
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["path"] == json!("manifest.json"))
        .unwrap()["size"]
        .as_u64()
        .unwrap();
    let mut text = Vec::new();
    let mut offset = 0;
    loop {
        let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                         "path":"manifest.json","offset":offset,"limit":64}));
        let page = ok_data(&read).clone();
        let base64 = base64::engine::general_purpose::STANDARD;
        text.extend(base64.decode(page["data"].as_str().unwrap()).unwrap());
        offset = page["next"].as_u64().unwrap();
        if page["eof"] == json!(true) {
            break;
        }
    }
    assert_eq!(text.len() as u64, size, "the manifest's declared size is the stripped size");
    let stripped: Value = serde_json::from_slice(&text).unwrap();
    let original: Value = serde_json::from_str(BUNDLE_MANIFEST).unwrap();
    assert_eq!(stripped["native"][0]["path"], original["native"][0]["path"]);
    assert!(stripped["native"][0].get("source").is_none(), "{stripped}");
    assert!(!String::from_utf8(text).unwrap().contains("/Users/someone"));
}

#[test]
fn an_unmapped_or_unbound_surface_gets_the_unknown_answer() {
    let fake = FakeAcpmux::start("xscope");
    let home = Home::new("scope");
    let mux = transfer_mux(&fake, "atx-scope", &home, false);
    let (terminal, _) = terminal_pane(&mux);
    let unbound = agent_tab(&mux, None);
    let mut client = Client::connect(&mux, "xscope");
    let mut answers = Vec::new();
    for surface in [987_654, terminal, unbound] {
        for frame in [
            json!({"cmd":"agent-transfer-begin","surface":surface}),
            json!({"cmd":"agent-transfer-commit","surface":surface,"transfer_id":"xfer_1",
                   "to":"vm"}),
            json!({"cmd":"agent-transfer-abort","surface":surface,"transfer_id":"xfer_1"}),
        ] {
            let reply = client.request(frame);
            assert_code(&reply, "agent_transfer.unknown_tab");
            answers.push(reply["error"].clone());
        }
    }
    answers.dedup();
    assert_eq!(answers.len(), 1, "{answers:?}");
    fake.no_connection();
}

#[test]
fn read_takes_only_bundle_paths_of_a_move_this_daemon_began() {
    let fake = FakeAcpmux::start("xread");
    let home = Home::new("read");
    let mux = transfer_mux(&fake, "atx-read", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xread");
    let read = |transfer: &str, path: &str| json!({"cmd":"agent-transfer-read","transfer_id":transfer,"path":path,"offset":0});
    assert_code(
        &client.request(read("xfer_1", "events/0.ndjson")),
        "agent_transfer.unknown_transfer",
    );
    fake.no_connection();
    ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
    let _ = fake.frame();
    let _ = fake.frame();
    for path in ["../session.json", "/etc/passwd", "", "events/../../x", "./manifest.json"] {
        assert_code(&client.request(read("xfer_1", path)), "agent_transfer.bad_request");
    }
    assert_code(
        &client.request(read("xfer_2", "events/0.ndjson")),
        "agent_transfer.unknown_transfer",
    );
    fake.no_frame();
}
