//! D13 across a peer link: the owner's own paired phone controls a Claude chat started on
//! another of the owner's machines, through the Mac it is paired with (Leo, 2026-11-15: "im still
//! hitting the \"Only the cmux app on this Mac can control a Claude chat started on this
//! mac...\" when i try to type from iphone").
//!
//! Daemon A (the Mac the phone pairs with) mirrors daemon B (another machine of the owner, its
//! coordinator's host) as peer `b`. A Claude chat B started itself runs with the owner's Claude
//! rules there. A forwards the phone's request with `via: web`, so B holds it to the Web's rules,
//! and B has no record of A's phone: before this, B refused it as any remote device. Now A says
//! on the request that it is the owner's own phone (`_meta.acpmux.ownerPhone`, by A's own pairing
//! store, as it says `personVerified`), and B takes that word from a link that presented its peer
//! token only: that link already controls every chat of B as the owner's daemon. A's other Web
//! clients, a forged claim from one of them, and a paired machine's claim stay refused.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::pairing::Role;
use acpmux::rpc::Message;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_connection_device,
    serve_ws_with,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arlcp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let _ = HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
    }

    /// A connection that presented the paired credential `token`, served as its role says (a
    /// phone as Web under its own id, as the Mac's mobile host connects for it).
    fn device(hub: &Arc<Hub>, token: &str) -> Self {
        let proof = hub.pairing.device_for(token).expect("a live credential");
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_device(hub.clone(), in_rx, out_tx, proof));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no answer")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return v;
            }
        }
    }

    async fn prompt(&mut self, s: &str, text: &str, meta: Value) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}});
        self.call("session/prompt", p).await
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

async fn until_connected(a: &Hub, name: &str) {
    let peer = a.peer_by_name(name).expect("the peer");
    let mut settled = peer.settled();
    let wait = async {
        while a.peers().into_iter().find(|p| p["name"] == name).expect("listed")["state"]
            != "connected"
        {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), wait).await.expect("the peer never connected");
}

/// B serves WebSocket with its peer token and runs a Claude chat it started itself (named
/// `coord`); A mirrors B as peer `b`. Returns A, B, B's chat id and the homes to remove.
async fn two_daemons(tag: &str) -> (Arc<Hub>, Arc<Hub>, String, Vec<PathBuf>) {
    let db = dir(&format!("{tag}-b"));
    let b = hub(&db);
    let home = std::env::temp_dir().join(format!("arlcp-{tag}-home-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        b.clone(),
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut local = Client::new(&b, Origin::Local, ConnAuth::LocalSocket);
    let p =
        json!({"cwd": db.join("work"), "mcpServers": [], "_meta": {"acpmux": {"name": "coord"}}});
    let r = local.call("session/new", p).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let r = local.prompt(&id, "hello", json!({})).await;
    assert!(r.get("error").is_none(), "{r}");
    let da = dir(&format!("{tag}-a"));
    let a = hub(&da);
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    until_connected(&a, "b").await;
    (a, b, id, vec![db, da, home])
}

async fn end(a: Arc<Hub>, b: Arc<Hub>, dirs: Vec<PathBuf>) {
    b.shutdown_all().await;
    a.shutdown_all().await;
    for d in dirs {
        let _ = std::fs::remove_dir_all(d);
    }
}

/// The owner's phone, paired with A, sends to B's Claude chat through A, and it runs; it stops
/// it too. The chat runs in the mode B gave it (the stand-in Claude starts in
/// `bypassPermissions`), which the phone's Full-access setting (on by default) covers, as it
/// does for a chat on A itself.
#[tokio::test]
async fn the_owners_phone_controls_a_claude_chat_a_peer_started_through_its_mac() {
    let (a, b, _id, dirs) = two_daemons("phone").await;
    let (_, token) = a.pairing.issue_phone("phone-iphone").unwrap();
    let mut phone = Client::device(&a, &token);
    let r = phone.prompt("b/coord", "hello from the phone", json!({})).await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let r = phone.call("session/cancel", json!({"sessionId": "b/coord"})).await;
    assert_ne!(reason(&r), "remote.local_claude_session", "{r}");
    end(a, b, dirs).await;
}

/// With the phone's Full-access setting off, B is still told it is the owner's phone (no D13
/// refusal) but holds it to the Web's asking-mode rule, as A does for its own chats.
#[tokio::test]
async fn the_phones_full_access_off_on_its_mac_puts_the_asking_rule_back_on_the_peer() {
    let (a, b, _id, dirs) = two_daemons("phone-off").await;
    let (device, token) = a.pairing.issue_phone("phone-iphone").unwrap();
    a.pairing.set_full_access(&device.id, false).unwrap();
    let mut phone = Client::device(&a, &token);
    let r = phone.prompt("b/coord", "off", json!({})).await;
    assert_eq!(reason(&r), "remote.mode_not_asking", "{r}");
    end(a, b, dirs).await;
}

/// Everyone else A forwards for stays refused on B: A's dashboard client, the same client naming
/// itself the owner's phone, and a paired `client` machine forwarding for its Web client.
#[tokio::test]
async fn others_through_the_mac_and_forged_phone_claims_stay_refused() {
    let (a, b, _id, dirs) = two_daemons("others").await;
    let forged = json!({"ownerPhone": {"device": "dv_forged", "fullAccess": true, "epoch": 1}});
    let laptop = a.pairing.issue("laptop", Role::Client).unwrap().1;
    for (who, mut c, meta) in [
        ("dashboard", Client::new(&a, Origin::Web, ConnAuth::ListenerToken), json!({})),
        ("forged dashboard", Client::new(&a, Origin::Web, ConnAuth::ListenerToken), forged.clone()),
        (
            "client machine",
            Client::device(&a, &laptop),
            json!({"via": "web", "ownerPhone": {"device": "dv_forged", "fullAccess": true, "epoch": 1}}),
        ),
    ] {
        let r = c.prompt("b/coord", "hi", meta).await;
        assert_eq!(reason(&r), "remote.local_claude_session", "{who}: {r}");
    }
    // On B itself, the claim from anything but a peer daemon's own link counts for nothing.
    let mut web = Client::new(&b, Origin::Web, ConnAuth::ListenerToken);
    let r = web.prompt("coord", "hi", forged).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "B's own Web client: {r}");
    end(a, b, dirs).await;
}

/// B takes the claim from its owner's peer daemon only when that daemon forwards for a Web
/// client of its own (`via: web`); the owner's daemon asking for itself is the owner already.
#[tokio::test]
async fn a_peer_daemons_claim_counts_only_on_its_own_link() {
    let d = dir("direct");
    let b = hub(&d);
    let mut local = Client::new(&b, Origin::Local, ConnAuth::LocalSocket);
    let p =
        json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"name": "coord"}}});
    let id = local.call("session/new", p).await["result"]["sessionId"].as_str().unwrap().to_owned();
    let claim = json!({"via": "web", "ownerPhone": {"device": "dv_forged", "fullAccess": true, "epoch": 1}});
    let mut peer = Client::new(&b, Origin::Peer, ConnAuth::PeerToken);
    let r = peer.prompt(&id, "from the owner's phone", claim.clone()).await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let mut unclaimed = Client::new(&b, Origin::Peer, ConnAuth::PeerToken);
    let r = unclaimed.prompt(&id, "a web client", json!({"via": "web"})).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    let laptop = b.pairing.issue("laptop", Role::Client).unwrap().1;
    let r = Client::device(&b, &laptop).prompt(&id, "a paired machine", claim).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&d);
}

/// Review F1: what B was told about the phone is taken back with the phone's own setting. A's
/// person turns its Full access off, then removes it: B hears it from A
/// (`_acpmux/owner_phone_changed`) and holds a turn the phone started there at its next tool,
/// as A does for its own chats (`Hub::hold_policies_again`, the remote floor).
#[tokio::test]
async fn turning_the_phone_off_or_removing_it_on_its_mac_takes_it_back_on_the_peer() {
    let (a, b, _id, dirs) = two_daemons("revoke").await;
    let (device, token) = a.pairing.issue_phone("phone-iphone").unwrap();
    let mut phone = Client::device(&a, &token);
    let r = phone.prompt("b/coord", "hello", json!({})).await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let vouched = b.pairing.vouched_for_tests();
    assert_eq!(vouched.len(), 1, "{vouched:?}");
    assert!(vouched[0].0.ends_with(&format!("/{}", device.id)) && vouched[0].1, "{vouched:?}");
    let mut mac = Client::new(&a, Origin::Local, ConnAuth::LocalSocket);
    let r = mac.call("_acpmux/pair_set", json!({"id": device.id, "fullAccess": false})).await;
    assert!(r.get("error").is_none(), "{r}");
    let vouched = b.pairing.vouched_for_tests();
    assert!(vouched.len() == 1 && !vouched[0].1, "Full access off on A is off on B: {vouched:?}");
    assert!(!b.pairing.full_access(&vouched[0].0) && b.pairing.own_phone(&vouched[0].0));
    let r = mac.call("_acpmux/pair_revoke", json!({"id": device.id})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(b.pairing.vouched_for_tests().is_empty(), "the removed phone is gone on B too");
    assert!(!b.pairing.own_phone(&vouched[0].0));
    end(a, b, dirs).await;
}

/// A notice from anything but a peer-token link changes nothing; the end of the link takes back
/// every phone vouched for on it (fail closed).
#[tokio::test]
async fn only_the_peer_daemon_takes_a_phone_back_and_its_link_end_takes_back_all() {
    let d = dir("unvouch");
    let b = hub(&d);
    let mut local = Client::new(&b, Origin::Local, ConnAuth::LocalSocket);
    let p =
        json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"name": "coord"}}});
    let id = local.call("session/new", p).await["result"]["sessionId"].as_str().unwrap().to_owned();
    let claim = |epoch: u64| json!({"via": "web", "ownerPhone": {"device": "dv_phone", "fullAccess": true, "epoch": epoch}});
    let mut peer = Client::new(&b, Origin::Peer, ConnAuth::PeerToken);
    let r = peer.prompt(&id, "from the owner's phone", claim(100)).await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");
    let changed = json!({"device": "dv_phone", "fullAccess": null, "epoch": 200});
    let mut web = Client::new(&b, Origin::Web, ConnAuth::ListenerToken);
    let r = web.call("_acpmux/owner_phone_changed", changed.clone()).await;
    assert!(r.get("error").is_some(), "{r}");
    assert_eq!(b.pairing.vouched_for_tests().len(), 1);
    let off = json!({"device": "dv_phone", "fullAccess": false, "epoch": 200});
    let r = peer.call("_acpmux/owner_phone_changed", off).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(!b.pairing.vouched_for_tests()[0].1);
    // Review F1 (follow-up): a claim the Mac read before it turned the phone off, arriving after
    // the notice, does not put Full access back; one it read after (the person turned it on
    // again) does.
    peer.prompt(&id, "a late claim", claim(150)).await;
    assert!(!b.pairing.vouched_for_tests()[0].1, "a stale claim restored Full access");
    peer.prompt(&id, "on again", claim(300)).await;
    assert!(b.pairing.vouched_for_tests()[0].1);
    // After a removal, a late claim vouches for nothing.
    let removed = json!({"device": "dv_phone", "fullAccess": null, "epoch": 400});
    let r = peer.call("_acpmux/owner_phone_changed", removed).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(b.pairing.vouched_for_tests().is_empty());
    let r = peer.prompt(&id, "a late claim", claim(350)).await;
    assert_eq!(reason(&r), "remote.local_claude_session", "{r}");
    assert!(b.pairing.vouched_for_tests().is_empty());
    peer.prompt(&id, "a new phone record", claim(500)).await;
    assert_eq!(b.pairing.vouched_for_tests().len(), 1);
    drop(peer);
    let gone = async {
        while !b.pairing.vouched_for_tests().is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(10), gone)
        .await
        .expect("the link's end kept the phone");
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&d);
}
