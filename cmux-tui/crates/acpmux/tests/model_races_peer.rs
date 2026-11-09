//! A race started by the owning app crosses a real peer link and creates worktrees on
//! that peer. The same remote-origin parent grants no worktree capability to its agent.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().tools(&["git"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{ConnAuth, Origin, WsAuth, peer_auth, serve_connection_authed};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc, time::Duration};
use tokio::sync::mpsc;

const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

struct Client {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    id: i64,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Client {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Client {
    async fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth, caller: Option<&str>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (outgoing, output) = mpsc::channel(4096);
        let task =
            tokio::spawn(serve_connection_authed(hub.clone(), incoming, outgoing, origin, auth));
        let mut client = Self { input, output, id: 0, task };
        let mut init = json!({"protocolVersion":1});
        if let Some(id) = caller {
            init["_meta"] = json!({"acpmux":{"callerSession":{
                "sessionId":id, "token":acpmux::hub::person::caller_token(id)
            }}});
        }
        let hello = client.ok(method::INITIALIZE, init).await;
        if origin == Origin::LocalApp {
            let challenge = &hello["_meta"]["acpmux"]["personChallenge"];
            let proof = acpmux::hub::person::person_proof(
                KEY,
                "app",
                challenge["nonce"].as_str().unwrap(),
                challenge["connection"].as_str().unwrap(),
            )
            .unwrap();
            client.ok(method::MUX_PERSON_PROVE, json!({"proof":proof})).await;
        }
        client
    }
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.id += 1;
        self.input.send(Message::request(self.id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let value: Value =
                    serde_json::from_str(&self.output.recv().await.unwrap()).unwrap();
                if value["id"] == self.id {
                    return value;
                }
            }
        })
        .await
        .expect("RPC deadline")
    }
    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let answer = self.call(m, params).await;
        assert!(answer.get("error").is_none(), "{m}: {answer}");
        answer["result"].clone()
    }
}

fn hub(root: &Path) -> Arc<Hub> {
    // The fixture says it asks before every tool call (`FAKE_ASK_CLAIM`): the races' own
    // policies hold on it.
    let mut config: Config = serde_json::from_value(json!({"harnesses":{"fake":{"argv":[
        "python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_race_agent.py")],
        "env": {"FAKE_ASK_CLAIM": "1"}}},
        "defaultHarness":"fake", "permissionPolicy":"approve-all",
        // A peer's session/new may use only a known project or a webRoots folder (not one
        // holding HOME, which is under `root` here).
        "webRoots": [root.join("repo")]}))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    config.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    let store = acpmux::store::open(&config.store, root).unwrap();
    let hub = Hub::new(config, store);
    hub.person.install_spawn_key(KEY).unwrap();
    hub
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

fn start(parent: &str) -> Value {
    json!({"parent":parent,"prompt":"task","candidates":[
        {"harness":"fake","model":"a"},{"harness":"fake","model":"b"}],
        "reviewer":{"harness":"fake","model":"review"}})
}

async fn terminal(hub: &Arc<Hub>, parent: &str, id: &str) -> Value {
    let mut events = hub.subscribe();
    let session = hub.resolve(parent).unwrap();
    tokio::time::timeout(Duration::from_secs(40), async {
        loop {
            let race = json!(hub.race_get(&session, id).unwrap());
            if matches!(race["state"].as_str(), Some("completed" | "failed" | "cancelled")) {
                return race;
            }
            events.recv().await.expect("race transition");
        }
    })
    .await
    .expect("race terminal result")
}

#[tokio::test]
async fn peer_owner_race_starts_real_worktrees_without_authorizing_agent_starts() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path();
    let home = root.join("home");
    let repo = root.join("repo");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&repo).unwrap();
    // SAFETY: this binary has one test, before any hub or background task starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("settings.json"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet.json"));
    }
    std::fs::write(root.join("settings.json"), "{}").unwrap();
    std::fs::write(root.join("fleet.json"), "{\"machines\":{}}").unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "--allow-empty", "-qm", "fixture"]);
    acpmux::trust::set(
        &acpmux::trust::Paths::current().unwrap(),
        &root.to_string_lossy(),
        "trusted",
    )
    .unwrap();
    let remote = hub(root);
    // Create it through the Peer request path, not by toggling metadata after a local start.
    let mut owner_peer = Client::new(&remote, Origin::Peer, ConnAuth::PeerToken, None).await;
    let created = owner_peer
        .ok(
            method::SESSION_NEW,
            json!({"cwd":repo,"mcpServers":[],
        "_meta":{"acpmux":{"harness":"fake","via":"app"}}}),
        )
        .await;
    let parent = created["sessionId"].as_str().unwrap();
    assert!(remote.resolve(parent).unwrap().meta().remote_origin);

    let mut agent = Client::new(&remote, Origin::Local, ConnAuth::LocalSocket, Some(parent)).await;
    let rejected = agent
        .call(
            method::MUX_SUBSESSION_START,
            json!({"prompt":"task", "worktree":true,
        "ownerAuthorizedRace":true}),
        )
        .await;
    assert_eq!(rejected["error"]["data"]["reason"], "subsessions.worktree_refused", "{rejected}");
    let mut forged = start(parent);
    forged["ownerAuthorized"] = json!(true);
    forged["_meta"] =
        json!({"acpmux":{"raceOwner":{"parent":parent,"method":method::MUX_RACE_START}}});
    let denied = agent.ok(method::MUX_RACE_START, forged).await;
    assert_eq!(denied["ownerAuthorized"], false, "{denied}");
    let failed = terminal(&remote, parent, denied["id"].as_str().unwrap()).await;
    assert_eq!(failed["state"], "failed", "{failed}");
    for candidate in failed["candidates"].as_array().unwrap() {
        assert!(candidate["error"].as_str().unwrap().contains("no worktree"), "{failed}");
        assert!(candidate["sessionId"].is_null(), "{failed}");
    }

    let local = hub(root);
    let auth = Arc::new(peer_auth::PeerAuth::create(&root.join("peer-auth")).unwrap());
    let token = std::fs::read_to_string(auth.path()).unwrap();
    let listener = acpmux::server::bind_ws("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let served = tokio::spawn(acpmux::server::serve_ws_with(
        remote.clone(),
        listener,
        "race-test-token".into(),
        WsAuth { local_app: None, peer: Some(auth) },
    ));
    local
        .add_peer("box", &url, Some("race-test-token".into()), Some(token.trim().into()), true)
        .await
        .unwrap();
    let mut person = Client::new(&local, Origin::LocalApp, ConnAuth::LocalApp, None).await;
    let qualified_parent = format!("box/{parent}");
    let started = person.ok(method::MUX_RACE_START, start(&qualified_parent)).await;
    assert_eq!(started["parent"], qualified_parent);
    assert_eq!(started["ownerAuthorized"], true);
    let done = terminal(&remote, parent, started["id"].as_str().unwrap()).await;
    assert_eq!(done["state"], "completed", "{done}");
    assert_eq!(done["winnerId"], "c1", "{done}");
    let candidates = done["candidates"].as_array().unwrap();
    assert_ne!(candidates[0]["cwd"], candidates[1]["cwd"]);
    let winner = Path::new(candidates[0]["cwd"].as_str().unwrap());
    assert_eq!(std::fs::read_to_string(winner.join("implementation.txt")).unwrap(), "a");
    assert!(!repo.join("implementation.txt").exists());
    for candidate in candidates {
        // Authorization is not an origin or policy escalation for the resulting agent.
        let child = remote.resolve(candidate["sessionId"].as_str().unwrap()).unwrap();
        assert!(child.meta().remote_origin);
    }
    let mut winner_agent = Client::new(
        &remote,
        Origin::Local,
        ConnAuth::LocalSocket,
        Some(candidates[0]["sessionId"].as_str().unwrap()),
    )
    .await;
    let inherited = winner_agent
        .call(method::MUX_SUBSESSION_START, json!({"prompt":"task", "worktree":true}))
        .await;
    assert_eq!(inherited["error"]["data"]["reason"], "subsessions.worktree_refused", "{inherited}");
    let read_back = person
        .ok(method::MUX_RACE_GET, json!({"parent":qualified_parent,"raceId":done["id"]}))
        .await;
    assert_eq!(read_back["winnerId"], "c1");
    assert_eq!(
        read_back["candidates"][0]["sessionId"],
        format!("box/{}", candidates[0]["sessionId"].as_str().unwrap())
    );
    println!(
        "PEER_RACE_RESULT {}",
        json!({"state":read_back["state"],"winner":read_back["winnerId"],
        "qualifiedWinner":read_back["candidates"][0]["sessionId"],"worktreeOutput":"a"})
    );
    local.peer_by_name("box").unwrap().stop();
    served.abort();
    let _ = served.await;
    remote.shutdown_all().await;
    local.shutdown_all().await;
}
