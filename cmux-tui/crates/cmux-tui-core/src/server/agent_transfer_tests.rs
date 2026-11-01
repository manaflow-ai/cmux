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
    ABORT_FAILS_CHAT, BUNDLE_MANIFEST, BUNDLE_SESSION, Client, FakeAcpmux, MOVING_CHAT, SESSION,
    UNGUARDED_CHAT, agent_tab, assert_code, mux_with, run, terminal_pane,
};
use super::super::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink, remote_relay};
use super::{AGENT_TRANSFER_CAPABILITY, AgentTransferHost, MAX_PAGE_BYTES, try_handle};
use crate::mux::Mux;
use crate::server::AgentStartHost;

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
    // A Mac, an SSH host or a personal (owner) Cloud VM.
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::Allowed));
    mux
}

/// Skips the frames of one `agent-transfer-begin`: the begin and the reads
/// of the two bundle files the daemon scrubs.
fn skip_begin(fake: &FakeAcpmux) {
    let methods: Vec<Value> = (0..3).map(|_| fake.frame()["method"].clone()).collect();
    assert_eq!(
        methods,
        [
            json!("_acpmux/transfer_begin"),
            json!("_acpmux/transfer_read"),
            json!("_acpmux/transfer_read")
        ]
    );
}

/// Reads a whole bundle file through the daemon, in small pages.
fn read_all(client: &mut Client, path: &str) -> Vec<u8> {
    let base64 = base64::engine::general_purpose::STANDARD;
    let mut bytes = Vec::new();
    let mut offset = 0;
    loop {
        let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                         "path":path,"offset":offset,"limit":64}));
        let page = ok_data(&read).clone();
        bytes.extend(base64.decode(page["data"].as_str().unwrap()).unwrap());
        offset = page["next"].as_u64().unwrap();
        if page["eof"] == json!(true) {
            return bytes;
        }
    }
}

/// The size the begin manifest lists for `path`.
fn listed_size(begun: &Value, path: &str) -> u64 {
    let files = ok_data(begun)["manifest"]["files"].as_array().unwrap().clone();
    files.iter().find(|f| f["path"] == json!(path)).unwrap()["size"].as_u64().unwrap()
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
        json!({"id":8,"cmd":"agent-transfer-source","surface":surface}),
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

/// A Cloud machine that has run no chat has no acpmux up: a chat moved to it (Move to Cloud of a
/// running turn) starts it once, as a first chat would, instead of the move stopping there with
/// "this daemon has no acpmux or host to move chats with". Nothing else a move sends starts it.
#[test]
fn a_receive_on_a_machine_whose_acpmux_is_down_starts_it_once() {
    use std::sync::atomic::AtomicUsize;
    let fake = FakeAcpmux::start("xstart");
    let home = Home::new("start");
    let mux = transfer_mux(&fake, "atx-start", &home, true);
    // acpmux is not up yet: nothing listens on the daemon's socket until the starter runs.
    let down = home.path.join("acpmux.sock");
    mux.set_acpmux_socket(Some(down.clone()));
    let starts = Arc::new(AtomicUsize::new(0));
    let (counted, target) = (starts.clone(), fake.socket.clone());
    mux.set_acpmux_starter(Some(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        std::os::unix::fs::symlink(&target, &down).map_err(|e| e.to_string())
    })));
    let mut client = Client::connect(&mux, "xstart");
    let reply = receive(&mut client, &home.text("work/project"));
    assert_eq!(ok_data(&reply)["receive_id"], json!("rcv_1"));
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_receive"));
    assert_eq!(starts.load(Ordering::SeqCst), 1);
    // Up now: the next receive connects without starting it again.
    ok_data(&receive(&mut client, &home.text("work/project")));
    assert_eq!(starts.load(Ordering::SeqCst), 1);
}

/// A move under way never starts acpmux: its finish on a daemon whose acpmux went away is
/// unavailable, and the pump runs it again.
#[test]
fn a_finish_never_starts_acpmux() {
    use std::sync::atomic::AtomicUsize;
    let fake = FakeAcpmux::start("xnostart");
    let home = Home::new("nostart");
    let mux = transfer_mux(&fake, "atx-nostart", &home, true);
    let mut client = Client::connect(&mux, "xnostart");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    mux.set_acpmux_socket(Some(home.path.join("gone.sock")));
    let starts = Arc::new(AtomicUsize::new(0));
    let counted = starts.clone();
    mux.set_acpmux_starter(Some(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        Err("a finish must not start acpmux".into())
    })));
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_transfer.unavailable");
    assert_eq!(starts.load(Ordering::SeqCst), 0);
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
    skip_begin(&fake);
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
    let _session_read = fake.frame();
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
    skip_begin(&fake);
    for path in ["../session.json", "/etc/passwd", "", "events/../../x", "./manifest.json"] {
        assert_code(&client.request(read("xfer_1", path)), "agent_transfer.bad_request");
    }
    assert_code(
        &client.request(read("xfer_2", "events/0.ndjson")),
        "agent_transfer.unknown_transfer",
    );
    fake.no_frame();
}

// MARK: Host kind (hq-84)

/// A host source a test can switch: 0 allowed, 1 team VM, 2 unknown Cloud.
fn switchable_host(mux: &Arc<Mux>) -> Arc<AtomicU64> {
    let kind = Arc::new(AtomicU64::new(0));
    let read = kind.clone();
    mux.set_agent_start_host(Arc::new(move || match read.load(Ordering::SeqCst) {
        0 => AgentStartHost::Allowed,
        1 => AgentStartHost::TeamVm,
        _ => AgentStartHost::UnknownCloud,
    }));
    kind
}

#[test]
fn a_receive_is_refused_on_a_team_vm_and_on_a_cloud_vm_of_unknown_kind() {
    let fake = FakeAcpmux::start("xteam");
    let home = Home::new("team");
    let mux = transfer_mux(&fake, "atx-team", &home, true);
    let kind = switchable_host(&mux);
    let mut client = Client::connect(&mux, "xteam");
    kind.store(1, Ordering::SeqCst);
    assert_code(&receive(&mut client, &home.text("work/project")), "agent_session.team_vm_blocked");
    kind.store(2, Ordering::SeqCst);
    assert_code(&receive(&mut client, &home.text("work/project")), "agent_session.host_unverified");
    fake.no_connection();
    // A personal (owner) Cloud VM takes it.
    kind.store(0, Ordering::SeqCst);
    assert_eq!(
        ok_data(&receive(&mut client, &home.text("work/project")))["receive_id"],
        json!("rcv_1")
    );
}

#[test]
fn a_daemon_that_was_never_told_its_host_kind_refuses_a_receive() {
    let fake = FakeAcpmux::start("xnokind");
    let home = Home::new("nokind");
    let mux = mux_with(&fake, "atx-nokind");
    mux.set_agent_transfer_host(Some(AgentTransferHost { cloud: true, home: home.path.clone() }));
    let mut client = Client::connect(&mux, "xnokind");
    assert_code(&receive(&mut client, &home.text("work/project")), "agent_session.host_unverified");
    fake.no_connection();
}

/// A Cloud VM whose own record says `owner` takes a chat only on the
/// caller's `vm_kind: "owner"` (the Cloud API's answer): the record, which
/// its agents can write, never lets one in, at the receive or the finish.
#[test]
fn a_cloud_vm_takes_a_chat_only_on_the_callers_owner_word() {
    let fake = FakeAcpmux::start("xvmkind");
    let home = Home::new("vmkind");
    let mux = transfer_mux(&fake, "atx-vmkind", &home, true);
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let mut client = Client::connect(&mux, "xvmkind");
    let cwd = home.text("work/project");
    // No word (the param left out), then words that are not `owner`.
    assert_code(&receive(&mut client, &cwd), "agent_session.host_unverified");
    for kind in ["team", "Owner"] {
        let frame = json!({"cmd":"agent-transfer-receive","manifest":manifest(),"cwd":cwd,
                           "vm_kind":kind});
        assert_code(&client.request(frame), "agent_session.host_unverified");
    }
    fake.no_connection();
    let owner = json!({"cmd":"agent-transfer-receive","manifest":manifest(),"cwd":cwd,
                       "vm_kind":"owner"});
    assert_eq!(ok_data(&client.request(owner))["receive_id"], json!("rcv_1"));
    let _ = fake.frame();
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_session.host_unverified");
    fake.no_frame();
}

/// A machine that shows no Cloud sign (its root may have removed them): a
/// receive or finish whose `vm_kind` is not `owner`, an explicit `null`
/// included, refuses; one with no word goes on.
#[test]
fn a_word_that_is_not_owner_refuses_on_any_host() {
    let fake = FakeAcpmux::start("xvmnull");
    let home = Home::new("vmnull");
    let mux = transfer_mux(&fake, "atx-vmnull", &home, true);
    let mut client = Client::connect(&mux, "xvmnull");
    let cwd = home.text("work/project");
    for kind in [json!(null), json!("team")] {
        let frame = json!({"cmd":"agent-transfer-receive","manifest":manifest(),"cwd":cwd,
                           "vm_kind":kind});
        assert_code(&client.request(frame), "agent_session.host_unverified");
    }
    fake.no_connection();
    ok_data(&receive(&mut client, &cwd));
    let _ = fake.frame();
    let finish = json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1","vm_kind":null});
    assert_code(&client.request(finish), "agent_session.host_unverified");
    fake.no_frame();
}

#[test]
fn finish_reads_the_host_kind_again() {
    let fake = FakeAcpmux::start("xteamfin");
    let home = Home::new("teamfin");
    let mux = transfer_mux(&fake, "atx-teamfin", &home, true);
    let kind = switchable_host(&mux);
    let mut client = Client::connect(&mux, "xteamfin");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    // A team enroll lands between the receive and its finish.
    kind.store(1, Ordering::SeqCst);
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_session.team_vm_blocked");
    fake.no_frame();
}

// MARK: Receive and move slots

fn many_manifest(n: usize) -> Value {
    let mut manifest = manifest();
    manifest["transferId"] = json!(format!("xfer_many_{n}"));
    manifest
}

#[test]
fn abandoned_receives_free_their_slots_once_aborted() {
    let fake = FakeAcpmux::start("xslots");
    let home = Home::new("slots");
    let mux = transfer_mux(&fake, "atx-slots", &home, true);
    let mut client = Client::connect(&mux, "xslots");
    let cwd = home.text("work/project");
    let take = |client: &mut Client, n: usize| {
        client.request(json!({"cmd":"agent-transfer-receive","manifest":many_manifest(n),
                              "cwd":cwd}))
    };
    for n in 0..16 {
        assert_eq!(ok_data(&take(&mut client, n))["receive_id"], json!(format!("rcv_{n}")));
        let _ = fake.frame();
    }
    // The cap is checked before acpmux makes a receive (no orphan there).
    assert_code(&take(&mut client, 16), "agent_transfer.limit");
    fake.no_frame();
    let aborted =
        client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_3"}));
    assert_eq!(ok_data(&aborted)["dropped"], json!(true));
    let _ = fake.frame();
    // Asked again (a lost answer), acpmux forgets the same move again.
    let again = client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_3"}));
    assert_eq!(ok_data(&again)["forgotten"], json!(true));
    let _ = fake.frame();
    assert_eq!(ok_data(&take(&mut client, 16))["receive_id"], json!("rcv_16"));
}

#[test]
fn a_finish_that_cannot_succeed_drops_its_receive_and_a_retryable_one_keeps_it() {
    let fake = FakeAcpmux::start("xfinfail");
    let home = Home::new("finfail");
    let mux = transfer_mux(&fake, "atx-finfail", &home, true);
    let mut client = Client::connect(&mux, "xfinfail");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    let finish = |client: &mut Client, name: &str| {
        client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1","name":name}))
    };
    // Pages still missing: the receive stays for more writes.
    assert_code(&finish(&mut client, "incomplete"), "agent_transfer.refused");
    let _ = fake.frame();
    // The chat is here already: nothing a retry can change.
    assert_code(&finish(&mut client, "exists"), "agent_transfer.refused");
    let _ = fake.frame();
    assert_code(&finish(&mut client, "chat"), "agent_transfer.unknown_receive");
    fake.no_frame();
}

#[test]
fn abort_forgets_the_move_even_when_acpmux_refuses_it() {
    let fake = FakeAcpmux::start("xabortfail");
    let home = Home::new("abortfail");
    let mux = transfer_mux(&fake, "atx-abortfail", &home, false);
    let surface = agent_tab(&mux, Some(ABORT_FAILS_CHAT));
    let mut client = Client::connect(&mux, "xabortfail");
    ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
    skip_begin(&fake);
    let abort = client.request(json!({"cmd":"agent-transfer-abort","surface":surface,
                                      "transfer_id":"xfer_1"}));
    assert_code(&abort, "agent_transfer.refused");
    let _ = fake.frame();
    let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                     "path":"events/0.ndjson","offset":0}));
    assert_code(&read, "agent_transfer.unknown_transfer");
    fake.no_frame();
}

// MARK: What a bundle hands out

#[test]
fn begin_scrubs_launch_settings_from_session_json_and_keeps_its_folder() {
    let fake = FakeAcpmux::start("xscrub");
    let home = Home::new("scrub");
    let mux = transfer_mux(&fake, "atx-scrub", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xscrub");
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface}));
    let bytes = read_all(&mut client, "session.json");
    assert_eq!(bytes.len() as u64, listed_size(&begun, "session.json"));
    let scrubbed: Value = serde_json::from_slice(&bytes).unwrap();
    let original: Value = serde_json::from_str(BUNDLE_SESSION).unwrap();
    for key in ["sessionEnv", "harnessArgv", "harnessRoots", "preset", "tags"] {
        assert!(original.get(key).is_some(), "{key}");
        assert!(scrubbed.get(key).is_none(), "{key} left in {scrubbed}");
    }
    for key in ["id", "harness", "cwd", "permissionPolicy", "createdAt"] {
        assert_eq!(scrubbed[key], original[key], "{key}");
    }
}

#[test]
fn read_serves_only_paths_the_begin_manifest_lists() {
    let fake = FakeAcpmux::start("xlisted");
    let home = Home::new("listed");
    let mux = transfer_mux(&fake, "atx-listed", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xlisted");
    ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
    skip_begin(&fake);
    // On a case-insensitive disk these would name the unscrubbed files.
    for path in ["Manifest.json", "SESSION.JSON", "native/claude/s.jsonl", "events/1.ndjson"] {
        let read = client.request(json!({"cmd":"agent-transfer-read","transfer_id":"xfer_1",
                                         "path":path,"offset":0}));
        assert_code(&read, "agent_transfer.bad_request");
    }
    fake.no_frame();
}

#[test]
fn receive_abort_has_acpmux_forget_that_move_only() {
    let fake = FakeAcpmux::start("xforget");
    let home = Home::new("forget");
    let mux = transfer_mux(&fake, "atx-forget", &home, true);
    let mut client = Client::connect(&mux, "xforget");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    let aborted =
        client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&aborted)["dropped"], json!(true));
    assert_eq!(ok_data(&aborted)["landed"], json!(false));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/transfer_forget"));
    // The move and chat of the receive's own manifest, never the client's.
    assert_eq!(sent["params"], json!({"transferId":"xfer_src","sessionId":"acp_moving"}));
    // acpmux's forget is not a daemon verb, and no frame names a move.
    for frame in [
        json!({"cmd":"agent-transfer-forget","transfer_id":"xfer_src"}),
        json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1","transfer_id":"x"}),
    ] {
        assert_code(&client.request(frame), "agent_transfer.bad_request");
    }
    fake.no_frame();
}

#[test]
fn a_receive_its_finish_ended_still_answers_whether_its_chat_landed() {
    let fake = FakeAcpmux::start("xsettled");
    let home = Home::new("settled");
    let mux = transfer_mux(&fake, "atx-settled", &home, true);
    let mut client = Client::connect(&mux, "xsettled");
    let mut landed = manifest();
    landed["transferId"] = json!("xfer_landed");
    let received = client.request(json!({"cmd":"agent-transfer-receive","manifest":landed,
                                         "cwd":home.text("work/project")}));
    ok_data(&received);
    let _ = fake.frame();
    ok_data(&client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"})));
    let _ = fake.frame();
    // The pump lost the finish answer and asks: the daemon still has acpmux
    // forget the move named by the receive's own manifest.
    for _ in 0..2 {
        let asked =
            client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
        assert_eq!(ok_data(&asked)["landed"], json!(true));
        let sent = fake.frame();
        assert_eq!(sent["method"], json!("_acpmux/transfer_forget"));
        assert_eq!(sent["params"], json!({"transferId":"xfer_landed","sessionId":"acp_moving"}));
    }
    // It takes no more pages and no second finish.
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_transfer.unknown_receive");
    fake.no_frame();
}

#[test]
fn begin_of_a_chat_already_moving_names_that_move() {
    let fake = FakeAcpmux::start("xmoving");
    let home = Home::new("moving");
    let mux = transfer_mux(&fake, "atx-moving", &home, false);
    let surface = agent_tab(&mux, Some(MOVING_CHAT));
    let mut client = Client::connect(&mux, "xmoving");
    // A pump that lost its begin answer asks again: the refusal names the
    // move, so the pump can resolve it.
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface}));
    assert_code(&begun, "agent_transfer.refused");
    assert!(begun["error"].as_str().unwrap().contains("transfer.moving"), "{begun}");
    assert_eq!(begun["error_details"], json!({"transfer_id": "xfer_frozen"}));
    // Any other refusal carries no details.
    let other = agent_tab(&mux, Some(ABORT_FAILS_CHAT));
    let abort = client.request(json!({"cmd":"agent-transfer-abort","surface":other,
                                      "transfer_id":"xfer_1"}));
    assert_code(&abort, "agent_transfer.refused");
    assert!(abort.get("error_details").is_none(), "{abort}");
}

#[test]
fn a_receive_abort_whose_forget_fails_keeps_the_receive_askable() {
    let fake = FakeAcpmux::start("xforgetfail");
    let home = Home::new("forgetfail");
    let mux = transfer_mux(&fake, "atx-forgetfail", &home, true);
    let mut client = Client::connect(&mux, "xforgetfail");
    let mut failing = manifest();
    failing["transferId"] = json!("xfer_forget_fails");
    let received = client.request(json!({"cmd":"agent-transfer-receive","manifest":failing,
                                         "cwd":home.text("work/project")}));
    ok_data(&received);
    let _ = fake.frame();
    for _ in 0..2 {
        let asked =
            client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
        assert_eq!(
            ok_data(&asked),
            &json!({"dropped": false, "forgotten": false, "landed": null}),
            "the landing is unknown and the receive stays"
        );
        assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_forget"));
    }
    // Still live: it takes pages.
    let write = client.request(json!({"cmd":"agent-transfer-write","receive_id":"rcv_1",
                                      "path":"events/0.ndjson","offset":0,"data":"YWJj"}));
    ok_data(&write);
}

#[test]
fn a_receive_abort_during_a_running_finish_cannot_say_yet() {
    let fake = FakeAcpmux::start("xracing");
    let home = Home::new("racing");
    let mux = transfer_mux(&fake, "atx-racing", &home, true);
    let mut pump = Client::connect(&mux, "xracing");
    let mut asker = Client::connect(&mux, "xracing2");
    ok_data(&receive(&mut pump, &home.text("work/project")));
    let _ = fake.frame();
    let finishing =
        pump.send(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1","name":"slow"}));
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_finish"));
    let asked = asker.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&asked), &json!({"dropped": false, "forgotten": false, "landed": null}));
    // No forget raced the finish.
    fake.no_frame();
    ok_data(&pump.answer(finishing));
    // Once it settled, the question gets an answer.
    let asked = asker.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&asked)["forgotten"], json!(true));
}

#[test]
fn a_finish_that_cannot_reach_acpmux_leaves_the_receive_askable_and_finishable() {
    let fake = FakeAcpmux::start("xfinconn");
    let home = Home::new("finconn");
    let mux = transfer_mux(&fake, "atx-finconn", &home, true);
    let mut client = Client::connect(&mux, "xfinconn");
    let mut landing = manifest();
    landing["transferId"] = json!("xfer_landed");
    let received = client.request(json!({"cmd":"agent-transfer-receive","manifest":landing,
                                         "cwd":home.text("work/project")}));
    ok_data(&received);
    let _ = fake.frame();
    // acpmux restarts: the finish cannot connect.
    mux.set_acpmux_socket(Some(home.path.join("gone.sock")));
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_transfer.unavailable");
    mux.set_acpmux_socket(Some(fake.socket.clone()));
    // The pump runs again: the finish can be sent again and lands.
    ok_data(&client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"})));
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_finish"));
    let asked = client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&asked)["landed"], json!(true));
}

#[test]
fn a_receive_abort_after_a_finish_that_could_not_connect_gets_a_real_answer() {
    let fake = FakeAcpmux::start("xfinconn2");
    let home = Home::new("finconn2");
    let mux = transfer_mux(&fake, "atx-finconn2", &home, true);
    let mut client = Client::connect(&mux, "xfinconn2");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    mux.set_acpmux_socket(Some(home.path.join("gone.sock")));
    let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_code(&finish, "agent_transfer.unavailable");
    mux.set_acpmux_socket(Some(fake.socket.clone()));
    let asked = client.request(json!({"cmd":"agent-transfer-receive-abort","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&asked), &json!({"dropped": true, "forgotten": true, "landed": false}));
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_forget"));
}

#[test]
fn source_names_the_session_a_tab_is_bound_to_without_reaching_acpmux() {
    let fake = FakeAcpmux::start("xsource");
    let home = Home::new("source");
    let mux = transfer_mux(&fake, "atx-source", &home, false);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "xsource");
    let read = client.request(json!({"cmd":"agent-transfer-source","surface":surface}));
    assert_eq!(ok_data(&read), &json!({"session": SESSION}));
    // Begin answers the same session it froze, so a pump can pin it.
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface}));
    assert_eq!(ok_data(&begun)["source_session"], json!(SESSION));
    skip_begin(&fake);
    let read = client.request(json!({"cmd":"agent-transfer-source","surface":999_999}));
    assert_code(&read, "agent_transfer.unknown_tab");
    fake.no_frame();
}

// MARK: A landed chat in a tab of this machine

/// `new-conversation-tab` of a `registry:` tab that already names `session`,
/// as Move to Cloud opens a moved chat on the machine it landed on.
fn machine_tab(client: &mut Client, mux: &Arc<Mux>, session: &str) -> Value {
    let host = format!("registry:{}", mux.registry_identity().0);
    machine_tab_of(client, mux, &host, Some(session))
}

fn machine_tab_of(client: &mut Client, mux: &Arc<Mux>, host: &str, session: Option<&str>) -> Value {
    let (_, pane) = terminal_pane(mux);
    client.request(json!({"cmd":"new-conversation-tab","pane":pane,
                          "agent_session":{"host":host,"session":session,"harness":"claude"}}))
}

/// The session `agent-transfer-source` reads from the tab a create answered.
fn tab_session_of(client: &mut Client, created: &Value) -> Value {
    let surface = ok_data(created)["surface"].clone();
    let source = client.request(json!({"cmd":"agent-transfer-source","surface":surface}));
    ok_data(&source)["session"].clone()
}

/// Receives the test manifest's chat and finishes it (acpmux answers
/// `acp_moved`, while the manifest names `acp_moving`).
fn land(client: &mut Client, fake: &FakeAcpmux, home: &Home) {
    ok_data(&receive(client, &home.text("work/project")));
    let _ = fake.frame();
    let finished = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1"}));
    assert_eq!(ok_data(&finished)["session"]["sessionId"], json!("acp_moved"));
    let _ = fake.frame();
}

/// A daemon with a durable registry under `home/state` (the same one each
/// call, as after a restart).
fn persistent_mux(fake: &FakeAcpmux, home: &Home) -> Arc<Mux> {
    let root = home.path.join("state");
    let mux = Mux::open_persistent("landed", crate::SurfaceOptions::default(), &root).unwrap();
    mux.set_acpmux_socket(Some(fake.socket.clone()));
    mux.set_agent_transfer_host(Some(AgentTransferHost { cloud: true, home: home.path.clone() }));
    mux.set_agent_start_host(Arc::new(|| AgentStartHost::Allowed));
    mux
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

#[test]
fn a_chat_this_daemon_landed_opens_in_a_tab_of_this_machine_and_no_other_does() {
    let fake = FakeAcpmux::start("xlandtab");
    let home = Home::new("landtab");
    let mux = transfer_mux(&fake, "atx-landtab", &home, true);
    let mut client = Client::connect(&mux, "xlandtab");
    let mismatch = "conversation_tab.machine_mismatch";
    // Nothing landed yet: still another machine's chat.
    assert_code(&machine_tab(&mut client, &mux, "acp_moved"), mismatch);
    land(&mut client, &fake, &home);
    // The session acpmux's finish answered opens in this store's own tab.
    let opened = machine_tab(&mut client, &mux, "acp_moved");
    assert_eq!(tab_session_of(&mut client, &opened), json!("acp_moved"));
    // The manifest's id (a client's), any other session, and another
    // store's host are still refused.
    assert_code(&machine_tab(&mut client, &mux, "acp_moving"), mismatch);
    assert_code(&machine_tab(&mut client, &mux, "acp_other"), mismatch);
    let elsewhere = machine_tab_of(&mut client, &mux, "registry:another-store", Some("acp_moved"));
    assert_code(&elsewhere, mismatch);
    // A bind into a tab of this machine stays refused, landed chat or not.
    let unbound =
        machine_tab_of(&mut client, &mux, &format!("registry:{}", mux.registry_identity().0), None);
    let surface = ok_data(&unbound)["surface"].clone();
    let bind = client.request(json!({"cmd":"bind-conversation-tab-session","surface":surface,
                                     "session":"acp_moved","expected_session":null}));
    assert_code(&bind, mismatch);
    fake.no_frame();
}

#[test]
fn a_receive_that_did_not_land_opens_no_tab_of_this_machine() {
    let fake = FakeAcpmux::start("xnoland");
    let home = Home::new("noland");
    let mux = transfer_mux(&fake, "atx-noland", &home, true);
    let mut client = Client::connect(&mux, "xnoland");
    ok_data(&receive(&mut client, &home.text("work/project")));
    let _ = fake.frame();
    for name in ["incomplete", "exists"] {
        let finish = client.request(json!({"cmd":"agent-transfer-finish","receive_id":"rcv_1",
                                           "name":name}));
        assert_code(&finish, "agent_transfer.refused");
        let _ = fake.frame();
    }
    for session in ["acp_moving", "acp_moved"] {
        assert_code(&machine_tab(&mut client, &mux, session), "conversation_tab.machine_mismatch");
    }
    fake.no_frame();
}

#[test]
fn a_landed_chat_still_opens_in_a_tab_of_this_machine_after_a_restart() {
    let fake = FakeAcpmux::start("xlandkeep");
    let home = Home::new("landkeep");
    let open = || persistent_mux(&fake, &home);
    let mux = open();
    let mut client = Client::connect(&mux, "xlandkeep");
    land(&mut client, &fake, &home);
    drop(client);
    mux.shutdown();
    drop(mux);
    let mux = open();
    let mut client = Client::connect(&mux, "xlandkeep2");
    let opened = machine_tab(&mut client, &mux, "acp_moved");
    assert_eq!(tab_session_of(&mut client, &opened), json!("acp_moved"));
    assert_code(&machine_tab(&mut client, &mux, "acp_other"), "conversation_tab.machine_mismatch");
    drop(client);
    mux.shutdown();
    fake.no_frame();
}

#[test]
fn a_landed_chat_this_daemon_moved_away_again_opens_no_tab_of_this_machine() {
    let fake = FakeAcpmux::start("xlandaway");
    let home = Home::new("landaway");
    let mux = transfer_mux(&fake, "atx-landaway", &home, true);
    let mut client = Client::connect(&mux, "xlandaway");
    land(&mut client, &fake, &home);
    let opened = machine_tab(&mut client, &mux, "acp_moved");
    let surface = ok_data(&opened)["surface"].clone();
    // The chat leaves this machine again (back to the Mac) and the move commits.
    let begun = client.request(json!({"cmd":"agent-transfer-begin","surface":surface}));
    assert_eq!(ok_data(&begun)["source_session"], json!("acp_moved"));
    skip_begin(&fake);
    let committed = client.request(json!({"cmd":"agent-transfer-commit","surface":surface,
                                          "transfer_id":"xfer_1","to":{"machine":"mac"}}));
    ok_data(&committed);
    let _ = fake.frame();
    // It is another machine's chat again: no new tab of this machine names it.
    assert_code(&machine_tab(&mut client, &mux, "acp_moved"), "conversation_tab.machine_mismatch");
    assert_eq!(fake.frame()["method"], json!("_acpmux/info"));
    fake.no_frame();
}

/// Acpmux remains the authority across cmux restarts and watcher actions.
#[test]
fn live_root_transfer_revocation_survives_restart_and_both_abort_paths_clear_it() {
    use crate::state::conversation_tabs::ConversationTabTarget;
    use crate::state::conversation_tabs_store::ConversationTabRecord;

    // The baseline has no authority query. Ignore it when present so a baseline
    // run fails on authorization behavior after restart, not RPC implementation.
    fn transfer_frame(fake: &FakeAcpmux) -> Value {
        loop {
            let frame = fake.frame();
            if frame["method"] != json!("_acpmux/info") {
                return frame;
            }
        }
    }
    fn skip_begin(fake: &FakeAcpmux) {
        for method in ["_acpmux/transfer_begin", "_acpmux/transfer_read", "_acpmux/transfer_read"] {
            assert_eq!(transfer_frame(fake)["method"], json!(method));
        }
    }

    for committed in [false, true] {
        let fake = FakeAcpmux::start("root-transfer");
        let home = Home::new("root-transfer");
        let mux = persistent_mux(&fake, &home);
        let (_, pane) = terminal_pane(&mux);
        let surface = mux
            .new_conversation_tab(
                ConversationTabTarget::Pane(Some(pane)),
                ConversationTabRecord::AgentSession {
                    host: format!("registry:{}", mux.registry_identity().0),
                    session: Some(SESSION.into()),
                    harness: Some("claude".into()),
                    host_name: None,
                },
                None,
                None,
            )
            .unwrap()
            .surface
            .id;
        let content = mux.with_state(|state| {
            state.surfaces[&surface].resource_identity().unwrap().content_id.clone()
        });
        let mut client = Client::connect(&mux, "root-transfer");
        ok_data(&machine_tab(&mut client, &mux, SESSION));
        ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
        skip_begin(&fake);
        assert_code(&machine_tab(&mut client, &mux, SESSION), "conversation_tab.machine_mismatch");
        if committed {
            ok_data(&client.request(json!({"cmd":"agent-transfer-commit","surface":surface,
                "transfer_id":"xfer_1","to":{"machine":"mac"}})));
            assert_eq!(transfer_frame(&fake)["method"], json!("_acpmux/transfer_commit"));
        }
        drop(client);
        mux.shutdown();
        drop(mux);

        let mux = persistent_mux(&fake, &home);
        let mut client = Client::connect(&mux, "root-transfer-restarted");
        // The persisted live tab must still exist: absent proof would hide the bug.
        let surface = mux
            .with_state(|state| {
                state.surfaces.values().find_map(|surface| {
                    (surface.resource_identity()?.content_id == content).then_some(surface.id)
                })
            })
            .expect("the source tab restored after restart");
        assert_code(&machine_tab(&mut client, &mux, SESSION), "conversation_tab.machine_mismatch");
        if !committed {
            ok_data(&client.request(json!({"cmd":"agent-transfer-abort","surface":surface,
                "transfer_id":"xfer_1"})));
            assert_eq!(transfer_frame(&fake)["method"], json!("_acpmux/transfer_abort"));
            ok_data(&machine_tab(&mut client, &mux, SESSION));

            ok_data(&client.request(json!({"cmd":"agent-transfer-begin","surface":surface})));
            skip_begin(&fake);
            assert_code(
                &machine_tab(&mut client, &mux, SESSION),
                "conversation_tab.machine_mismatch",
            );
            // The acpmux watchdog acts without a cmux abort call or notification.
            fake.set_transfer_blocked(SESSION, false);
            ok_data(&machine_tab(&mut client, &mux, SESSION));
        }
        drop(client);
        mux.shutdown();
    }
}

#[cfg(unix)]
#[test]
fn a_planted_or_symlinked_landed_file_and_its_temporary_are_never_trusted() {
    let fake = FakeAcpmux::start("xlandplant");
    let home = Home::new("landplant");
    let mux = persistent_mux(&fake, &home);
    let directory = mux.session_state_directory().unwrap();
    // The landed file is a symlink to a record the daemon never wrote.
    let planted = home.path.join("elsewhere/landed.json");
    let record = json!([{"session":"acp_planted","landed_at_ms":now_ms()}]).to_string();
    std::fs::write(&planted, &record).unwrap();
    std::os::unix::fs::symlink(&planted, directory.join("agent-transfer-landed.json")).unwrap();
    // The temporary the next write uses points at a file it must not touch.
    let victim = home.path.join("elsewhere/victim");
    std::fs::write(&victim, "keep").unwrap();
    let temporary = format!("agent-transfer-landed.json.{}.tmp", std::process::id());
    std::os::unix::fs::symlink(&victim, directory.join(temporary)).unwrap();
    let mut client = Client::connect(&mux, "xlandplant");
    assert_code(
        &machine_tab(&mut client, &mux, "acp_planted"),
        "conversation_tab.machine_mismatch",
    );
    land(&mut client, &fake, &home);
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
    assert_eq!(std::fs::read_to_string(&planted).unwrap(), record);
    let opened = machine_tab(&mut client, &mux, "acp_moved");
    assert_eq!(tab_session_of(&mut client, &opened), json!("acp_moved"));
    drop(client);
    mux.shutdown();
    fake.no_frame();
}

#[test]
fn a_landed_record_from_the_future_is_not_trusted() {
    let fake = FakeAcpmux::start("xlandfuture");
    let home = Home::new("landfuture");
    let mux = persistent_mux(&fake, &home);
    let directory = mux.session_state_directory().unwrap();
    let later = now_ms() + 24 * 3600 * 1000;
    let record = json!([{"session":"acp_future","landed_at_ms":later}]).to_string();
    std::fs::write(directory.join("agent-transfer-landed.json"), record).unwrap();
    let mut client = Client::connect(&mux, "xlandfuture");
    assert_code(&machine_tab(&mut client, &mux, "acp_future"), "conversation_tab.machine_mismatch");
    drop(client);
    mux.shutdown();
    fake.no_frame();
}
