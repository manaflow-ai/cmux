//! A sub-session started by a chat in full access, in that chat's own folder or under it, takes
//! the trust a decision gave that folder and raises no card (`hub/trust_wait.rs`
//! `inherits_parent_trust`). Leo, 2026-10-24, on a trust card a chat in full access raised for a
//! lane under its folder: "why did this even happen in the first place? I thought we bypassed
//! this."
//!
//! - a chat in full access, in a folder the person trusted: a start under it goes on at once, with
//!   no card and no trust recorded for the child's folder;
//! - the same chat starting outside its folder still waits on a card;
//! - a chat that asks, in a trusted folder: a start under it still waits on a card;
//! - a chat in full access whose own folder nobody decided: a start under it still waits on a card;
//! - a folder the person marked untrusted under the full-access chat's folder is refused;
//! - a chat whose harness reports full access on its own (no mode cmux set) still waits on a card;
//! - a chat whose launch command skips the checks, in no mode cmux set, still waits on a card;
//! - a chat named through a link still waits on a card under the link's target;
//! - a chat in full access whose agent was started again lends its trust once cmux set the mode
//!   again, and a fallback agent that reports full access on its own lends none;
//! - a chat a Web client started still waits on a card.
//!
//! Stand-in agents (fake_agent.py). One test function: the settings file is read from this
//! process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::trust::Paths;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        Self::from(hub, Origin::Local)
    }

    fn from(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    async fn new_session(&mut self, cwd: &Path, harness: &str) -> String {
        let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    async fn pending(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id)
            .map(|s| s["pendingPermissions"].clone())
            .unwrap_or_else(|| panic!("{id} is not listed: {list}"))
    }
}

/// Whether `parent`'s start in `cwd` (on the parent's own harness) waits on a trust card: the card
/// shows on `parent` while the start has not ended. Not now then answers it, and the start ends.
async fn start_waits_on_a_card(hub: &Arc<Hub>, app: &mut Client, parent: &str, cwd: &Path) -> bool {
    let harness = hub.resolve(parent).unwrap().meta().harness;
    start_on_waits_on_a_card(hub, app, parent, cwd, &harness).await
}

/// `start_waits_on_a_card` for a child on `harness`.
async fn start_on_waits_on_a_card(
    hub: &Arc<Hub>,
    app: &mut Client,
    parent: &str,
    cwd: &Path,
    harness: &str,
) -> bool {
    let (h, p) = (hub.clone(), parent.to_owned());
    let params = json!({"prompt": "echo hi", "name": "lane", "cwd": cwd, "harness": harness});
    let start =
        tokio::spawn(async move { Client::as_session(&h, &p).await.call(START, params).await });
    let session = hub.resolve(parent).unwrap();
    for _ in 0..200 {
        if start.is_finished() {
            let started = start.await.unwrap();
            assert!(started.get("error").is_none(), "{started}");
            return false;
        }
        if let Some((card, _)) = session.pending_permissions().into_iter().next() {
            hub.respond_permission(
                &session,
                &card,
                Some("not_now".into()),
                None,
                None,
                acpmux::hub::person::Answerer::default(),
                acpmux::hub::Control::Local,
            )
            .await
            .unwrap();
            let declined = start.await.unwrap();
            assert_eq!(
                declined["error"]["data"]["reason"], "subsessions.trust_declined",
                "{declined}"
            );
            assert_eq!(app.pending(parent).await, 0);
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the start in {} neither started nor raised a card", cwd.display());
}

#[tokio::test]
async fn a_full_access_chat_lends_its_folder_trust_to_sub_sessions_under_it() {
    let root = std::fs::canonicalize({
        let d = std::env::temp_dir().join(format!("acpmux-trust-inherit-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&d).unwrap();
        d
    })
    .unwrap();
    for folder in [
        "home",
        "full/lanes/update-toggle",
        "full/bad",
        "asks/lanes",
        "undecided/lanes",
        "web/lanes",
        "spoof/lanes",
        "spoof/child",
        "linked-target/lanes",
        "skips/lanes",
        "roundtrip/lanes",
        "again/lanes",
        "failover/lanes",
        "elsewhere/lanes",
    ] {
        std::fs::create_dir_all(root.join(folder)).unwrap();
    }
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, json!({"agents": {"trust": {"autoTrust": false}}}).to_string())
        .unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let fake =
        |family: &str, env: Value| json!({"argv": ["python3", FAKE], "family": family, "env": env});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            // Offers a full-access mode, which a new chat starts in.
            "fake-full": fake("fake", json!({"FAKE_FULL_ACCESS": "1"})),
            // Launched with a command that skips the checks, in no mode cmux set.
            "skipper": {"argv": ["python3", FAKE, "--dangerously-skip-permissions"], "family": "fake"},
            // Starts in the sample harness's one mode, which asks.
            "fake-ask": fake("fake", json!({"FAKE_ASK_MODE": "1"})),
            // Falls over to a profile that starts in full access by itself and refuses mode changes.
            "fake-full-fo": {"argv": ["python3", FAKE], "family": "fake",
                             "env": {"FAKE_FULL_ACCESS": "1"}, "fallback": "fake-claims"},
            "fake-claims": fake("fake", json!({"FAKE_FULL_ACCESS": "1", "FAKE_NEW_MODE": "full-access",
                                              "FAKE_LOAD_MODE": "full-access", "FAKE_SET_MODE_FAIL": "1"})),
        },
        "defaultHarness": "fake-full",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let paths = Paths {
        claude_json: root.join("home/.claude.json"),
        codex_config: root.join("home/config.toml"),
        record: root.join("home/trust.json"),
        agent_home: None,
        cmux_worktrees: None,
    };
    hub.set_trust_gate(Some(paths.clone()));
    let decide = |dir: &str, level: &str| {
        acpmux::trust::set(&paths, &root.join(dir).to_string_lossy(), level).unwrap();
    };
    decide("full", "trusted");
    decide("asks", "trusted");
    decide("full/bad", "untrusted");
    let mut app = Client::new(&hub);

    // A chat in full access in a folder the person trusted.
    let full = app.new_session(&root.join("full"), "fake-full").await;
    let info = app.ok("_acpmux/info", json!({"sessionId": full})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
    let lane = root.join("full/lanes/update-toggle");
    assert!(
        !start_waits_on_a_card(&hub, &mut app, &full, &lane).await,
        "a card under its own folder"
    );
    assert_eq!(app.pending(&full).await, 0);
    // Nothing is recorded for the child's folder: the trust stays the parent folder's.
    let record = std::fs::read_to_string(&paths.record).unwrap_or_default();
    assert!(!record.contains("lanes"), "the child's folder was recorded: {record}");
    // Its own folder itself, too.
    assert!(!start_waits_on_a_card(&hub, &mut app, &full, &root.join("full")).await);

    // A chat in full access whose folder was named through a link: the link may point elsewhere
    // by now, so a start under where it points still asks.
    decide("linked-target", "trusted");
    std::os::unix::fs::symlink(root.join("linked-target"), root.join("link")).unwrap();
    let linked = app.new_session(&root.join("link"), "fake-full").await;
    assert!(
        start_waits_on_a_card(&hub, &mut app, &linked, &root.join("linked-target/lanes")).await,
        "a folder named through a link lent its trust"
    );

    // A chat whose launch command skips the checks but runs in no full-access mode cmux set: the
    // command stays in the record after a fallback to another profile, so it lends nothing.
    decide("skips", "trusted");
    let skips = app.new_session(&root.join("skips"), "skipper").await;
    assert!(
        start_waits_on_a_card(&hub, &mut app, &skips, &root.join("skips/lanes")).await,
        "a launch command lent its folder's trust"
    );

    // A chat cmux set to full access whose harness then leaves the mode and comes back to it by
    // itself: the return is the harness's, not cmux's, so it lends nothing.
    decide("roundtrip", "trusted");
    let roundtrip = app.new_session(&root.join("roundtrip"), "fake-full").await;
    for text in ["set-mode: normal", "set-mode: full-access"] {
        let turn = json!({"sessionId": roundtrip, "prompt": [{"type": "text", "text": text}]});
        app.ok("session/prompt", turn).await;
    }
    let info = app.ok("_acpmux/info", json!({"sessionId": roundtrip})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &roundtrip, &root.join("roundtrip/lanes")).await,
        "a mode the harness came back to by itself lent its folder's trust"
    );

    // A chat in full access whose agent died and was started again: cmux set the mode again on
    // the new agent, so it still lends its folder's trust.
    decide("again", "trusted");
    let again = app.new_session(&root.join("again"), "fake-full").await;
    let die = json!({"sessionId": again, "prompt": [{"type": "text", "text": "die: gone"}]});
    let _ = app.call("session/prompt", die).await;
    let hello = json!({"sessionId": again, "prompt": [{"type": "text", "text": "hello"}]});
    app.ok("session/prompt", hello).await;
    assert!(
        !start_waits_on_a_card(&hub, &mut app, &again, &root.join("again/lanes")).await,
        "a restarted agent cmux put back in full access lent nothing"
    );

    // A chat in full access that fell over to a profile which starts in full access by itself and
    // refuses cmux's mode change: that agent's mode is its own, so it lends nothing. (The child
    // runs on a profile that takes its mode.)
    decide("failover", "trusted");
    let fo = app.new_session(&root.join("failover"), "fake-full-fo").await;
    let limit = json!({"sessionId": fo, "prompt": [{"type": "text", "text": "limit: now"}]});
    let _ = app.call("session/prompt", limit).await;
    let meta = hub.resolve(&fo).unwrap().meta();
    assert_eq!(meta.harness, "fake-claims");
    let info = app.ok("_acpmux/info", json!({"sessionId": fo})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
    assert!(
        start_on_waits_on_a_card(&hub, &mut app, &fo, &root.join("failover/lanes"), "fake-full")
            .await,
        "a fallback agent's own full access lent its folder's trust"
    );

    // Outside its folder it still asks.
    let outside = root.join("elsewhere/lanes");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &full, &outside).await,
        "no card outside its folder"
    );

    // A folder the person marked untrusted under it is refused, with no card.
    let mut agent = Client::as_session(&hub, &full).await;
    let bad = agent
        .call(START, json!({"prompt": "echo hi", "name": "bad", "cwd": root.join("full/bad")}))
        .await;
    assert_eq!(bad["error"]["data"]["reason"], "subsessions.folder_untrusted", "{bad}");
    assert_eq!(app.pending(&full).await, 0);

    // A chat that asks, in a trusted folder: a start under it waits on a card.
    let asks = app.new_session(&root.join("asks"), "fake-ask").await;
    let info = app.ok("_acpmux/info", json!({"sessionId": asks})).await;
    assert_eq!(info["modes"]["currentModeId"], "ask", "{info}");
    let under = root.join("asks/lanes");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &asks, &under).await,
        "no card for a chat that asks"
    );

    // A chat that asks, whose harness then reports full access on its own (the agent controls
    // that report): it lends no trust, only a mode cmux set does.
    decide("spoof", "trusted");
    let spoof = app.new_session(&root.join("spoof"), "fake-ask").await;
    let turn =
        json!({"sessionId": spoof, "prompt": [{"type": "text", "text": "set-mode: full-access"}]});
    app.ok("session/prompt", turn).await;
    let info = app.ok("_acpmux/info", json!({"sessionId": spoof})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &spoof, &root.join("spoof/lanes")).await,
        "a harness's own claim of full access lent its folder's trust"
    );

    // Nor does a child it starts in its own trusted folder, which inherits the claimed mode: the
    // child's mode came from that claim, not from cmux, so the child's own start under the folder
    // still waits on a card.
    let mut agent = Client::as_session(&hub, &spoof).await;
    let start = json!({"prompt": "echo hi", "name": "child", "cwd": root.join("spoof"), "harness": "fake-ask"});
    let child = agent.ok(START, start).await["sessionId"].as_str().unwrap().to_owned();
    let info = app.ok("_acpmux/info", json!({"sessionId": child})).await;
    assert_eq!(info["modes"]["currentModeId"], "full-access", "{info}");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &child, &root.join("spoof/child")).await,
        "a child of a claimed full access lent its folder's trust"
    );

    // A chat in full access whose own folder nobody decided: a start under it waits on a card.
    let undecided = app.new_session(&root.join("undecided"), "fake-full").await;
    let under = root.join("undecided/lanes");
    assert!(
        start_waits_on_a_card(&hub, &mut app, &undecided, &under).await,
        "no card under a folder nobody trusted"
    );

    // A chat a Web client started, in a folder the person trusted: outside a Web turn it lends no
    // trust either. (A Web client's chat in full access needs the person's own switch in the app,
    // which this hermetic test cannot make; `inherits_parent_trust` refuses `remote_origin` too.)
    let mut web_cfg: Config = serde_json::from_value(json!({
        "harnesses": {"cc": fake("claude", json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"}))},
        "defaultHarness": "cc",
        "permissionPolicy": "approve-all",
        "webRoots": [root],
    }))
    .unwrap();
    web_cfg.store.mode = StoreMode::Memory;
    let web_store = acpmux::store::open(&web_cfg.store, Path::new("/nonexistent")).unwrap();
    let web_hub = Hub::new(web_cfg, web_store);
    web_hub.set_trust_gate(Some(paths.clone()));
    decide("web", "trusted");
    let mut web = Client::from(&web_hub, Origin::Web);
    let web_parent = web.new_session(&root.join("web"), "cc").await;
    let mut web_app = Client::new(&web_hub);
    let meta = web_hub.resolve(&web_parent).unwrap().meta();
    assert!(meta.remote_origin);
    assert!(
        start_waits_on_a_card(&web_hub, &mut web_app, &web_parent, &root.join("web/lanes")).await,
        "a Web client's chat lent its folder's trust"
    );

    let _ = std::fs::remove_dir_all(&root);
}
