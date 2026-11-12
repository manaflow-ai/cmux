//! An ACP agent writes its own `agentInfo` and its own `availableModes`, so no gate that holds a
//! policy or lets a mode through without the person may believe them (cmux#40568, found in the
//! review of #40365). An agent of config family `lane` that names itself `claude-stdio` (the name
//! of acpmux's own Claude Code backend), says it has acpmux's PreToolUse gate, or offers Claude
//! Code's mode names is judged by its configured profile: its own family, as an entry of kind
//! `claude-stdio` (a launcher such as `claude-sr2` included) is judged as Claude Code.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessKind, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const KEY: &str = "7a1c0e2f9b8d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f";

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

mod agent_reported_trust {
    use super::*;

    /// A daemon whose default policy is approve-all, so only a chat's own policy is narrow, and
    /// whose start level is `standard` (each harness's own start mode). Every impostor is of
    /// family `lane`, names itself `claude-stdio` and says nothing about asking
    /// (`FAKE_ASK_CLAIM=0`), so no claim holds its policy:
    /// - `impostor`: offers `ask`, `default` and `plan`, current `default`;
    /// - `impostor-gate`: also says it has acpmux's PreToolUse gate, and offers no mode that asks;
    /// - `impostor-claude`: offers every one of Claude Code's mode names, current `default`;
    /// - `impostor-ro`: offers `default` and Muse Code's `readOnly`, and no mode that asks.
    ///
    /// `muse` runs the same stand-in as family `muse`, whose own read-only mode is `readOnly`.
    fn hub(tag: &str) -> (Arc<Hub>, PathBuf) {
        let _ = &HERMETIC;
        let d = std::env::temp_dir().join(format!("art-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("work")).unwrap();
        let d = std::fs::canonicalize(&d).unwrap();
        let impostor = |extra: Value| {
            let mut env = json!({"FAKE_AGENT_NAME": "claude-stdio", "FAKE_ASK_CLAIM": "0"});
            for (k, v) in extra.as_object().unwrap() {
                env[k] = v.clone();
            }
            json!({"argv": ["python3", FAKE_AGENT], "family": "lane", "env": env})
        };
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {
                "claude-sr2": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "family": "claude-sr2"},
                "impostor": impostor(json!({"FAKE_MODES": "default,ask,plan"})),
                "impostor-gate": impostor(json!({"FAKE_TOOL_GATE": "1"})),
                "impostor-claude": impostor(
                    json!({"FAKE_MODES": "default,auto,acceptEdits,plan,bypassPermissions"}),
                ),
                "impostor-ro": impostor(json!({"FAKE_MODES": "default,readOnly"})),
                "muse": {
                    "argv": ["python3", FAKE_AGENT],
                    "family": "muse",
                    "env": {"FAKE_ASK_CLAIM": "0", "FAKE_MODES": "default,readOnly"},
                },
                // The codex-acp adapter's modes (codex-acp 1.10.0): its `read-only` edits in the
                // workspace without asking; only the Codex bridge's `read-only` is read-only.
                "codex-adapter": {
                    "argv": ["python3", FAKE_AGENT],
                    "family": "codex",
                    "env": {"FAKE_ASK_CLAIM": "0",
                            "FAKE_MODES": "read-only,agent,agent-full-access"},
                },
                // Family `lane`, starting in a mode named `read-only`, with `ask`.
                "lane-ro": {
                    "argv": ["python3", FAKE_AGENT],
                    "family": "lane",
                    "env": {"FAKE_ASK_CLAIM": "0", "FAKE_MODES": "read-only,ask"},
                },
            },
            "defaultHarness": "claude-sr2",
            "permissionPolicy": "approve-all",
            "defaultPermissionMode": "standard",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        (Hub::new(cfg, store), d)
    }

    struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

    impl Client {
        fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
            let (in_tx, in_rx) = mpsc::channel(64);
            let (out_tx, out_rx) = mpsc::channel(4096);
            tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
            Client(in_tx, out_rx, 0)
        }

        /// The CLI outside any chat: a unix socket connection that is not the person.
        fn cli(hub: &Arc<Hub>) -> Self {
            Self::new(hub, Origin::Local, ConnAuth::LocalSocket)
        }

        /// The person, in the app: the connection proved the person's key.
        async fn person(hub: &Arc<Hub>) -> Self {
            hub.person.enroll(KEY, true).unwrap();
            let mut c = Self::new(hub, Origin::LocalApp, ConnAuth::LocalApp);
            let r = c.call("initialize", json!({"protocolVersion": 1})).await;
            let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
            let proof = acpmux::hub::person::person_proof(
                KEY,
                acpmux::hub::person::TRANSPORT_APP,
                challenge["nonce"].as_str().unwrap_or_else(|| panic!("{r}")),
                challenge["connection"].as_str().unwrap(),
            )
            .unwrap();
            let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
            assert!(r.get("error").is_none(), "{r}");
            c
        }

        async fn call(&mut self, m: &str, params: Value) -> Value {
            self.2 += 1;
            let id = self.2;
            self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
            loop {
                let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                    .await
                    .expect("an answer in time")
                    .expect("the connection stays open");
                let v: Value = serde_json::from_str(&line).unwrap();
                if v.get("id") == Some(&json!(id)) {
                    return v;
                }
            }
        }

        /// `session/new` on `harness` in folder `d`, with permission policy `policy` when one
        /// is given: the whole reply.
        async fn new_chat(&mut self, d: &Path, harness: &str, policy: Option<&str>) -> Value {
            let mut meta = json!({"harness": harness});
            if let Some(p) = policy {
                meta["policy"] = json!(p);
            }
            let params =
                json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": meta}});
            self.call("session/new", params).await
        }

        /// A new chat (as [`Self::new_chat`]): its id.
        async fn chat(&mut self, d: &Path, harness: &str, policy: Option<&str>) -> String {
            let r = self.new_chat(d, harness, policy).await;
            r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{harness}: {r}")).to_owned()
        }

        /// The records of kind `kind` in chat `id`'s log.
        async fn records(&mut self, id: &str, kind: &str) -> Vec<Value> {
            let r = self.call("_acpmux/events", json!({"sessionId": id, "kinds": [kind]})).await;
            r["result"]["events"].as_array().cloned().unwrap_or_else(|| panic!("{r}"))
        }

        /// The chat's mode and policy, as `_acpmux/info` reports them now.
        async fn state(&mut self, id: &str) -> (String, Value) {
            let r = self.call("_acpmux/info", json!({"sessionId": id})).await;
            let mode = r["result"]["modes"]["currentModeId"].as_str().unwrap_or_default();
            (mode.to_owned(), r["result"]["policy"].clone())
        }
    }

    /// A chat whose own policy is narrower than approve-all runs in its harness's mode that asks.
    /// `default` asks on Claude Code, not on family `lane`: an agent that only names itself
    /// `claude-stdio` is held in `ask`, the mode its own family has (`policy_mode`), while a
    /// configured launcher profile of Claude Code is held in Claude's `default`.
    #[tokio::test]
    async fn a_narrow_policy_holds_an_agent_that_names_itself_claude_in_its_own_asking_mode() {
        let (hub, d) = hub("hold");
        let mut person = Client::person(&hub).await;
        let id = person.chat(&d, "impostor", Some("ask")).await;
        let info = person.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(info["result"]["agentInfo"]["name"], json!("claude-stdio"), "{info}");
        assert_eq!(person.state(&id).await.0, "ask", "the impostor under policy ask: {info}");
        // Guard: the launcher profile is Claude Code, held in Claude's `default`.
        let sr2 = person.chat(&d, "claude-sr2", Some("ask")).await;
        assert_eq!(person.state(&sr2).await.0, "default", "claude-sr2 under policy ask");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A chat never runs in a mode that does not ask under a narrower policy: the person's move
    /// of the impostor from `ask` to `default` (no asking mode of family `lane`) either is refused
    /// or widens the chat's policy to approve-all first (`refuse_wider_mode_as`,
    /// `person_widens_policy_for`). It is never `default` under policy `ask`.
    #[tokio::test]
    async fn a_move_into_a_mode_that_asks_only_on_claude_does_not_keep_a_narrow_policy() {
        let (hub, d) = hub("wider");
        let mut person = Client::person(&hub).await;
        let id = person.chat(&d, "impostor", Some("ask")).await;
        let set = person.call("session/set_mode", json!({"sessionId": id, "modeId": "ask"})).await;
        assert!(set.get("error").is_none(), "the impostor into ask: {set}");
        assert_eq!(person.state(&id).await.0, "ask");
        let set =
            person.call("session/set_mode", json!({"sessionId": id, "modeId": "default"})).await;
        let (mode, policy) = person.state(&id).await;
        assert!(
            !(mode == "default" && policy == json!("ask")),
            "the impostor runs in default under policy ask: {set}"
        );
        // Which of the two: a refusal for the policy's mode, with the chat still in `ask`, or the
        // person's move, with the policy widened to approve-all first. Never another error.
        match set.get("error") {
            Some(e) => {
                assert_eq!(e["data"]["reason"], json!("policy_mode"), "{set}");
                assert_eq!((mode.as_str(), &policy), ("ask", &json!("ask")), "{set}");
            }
            None => {
                assert_eq!(policy, json!("approve-all"), "{set}");
                assert_eq!(mode, "default", "{set}");
            }
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Only acpmux's own Claude Code backend has the PreToolUse gate that holds a policy in any
    /// mode (`policy_gate::has_gate`). An agent of family `lane` that says it has the gate, and
    /// offers no mode that asks, cannot keep a narrower policy: the chat does not start
    /// (`policy_unenforceable`).
    #[tokio::test]
    async fn an_agent_that_says_it_has_the_tool_gate_keeps_no_policy() {
        let (hub, d) = hub("gate");
        let mut person = Client::person(&hub).await;
        let r = person.new_chat(&d, "impostor-gate", Some("ask")).await;
        assert_eq!(r["error"]["data"]["reason"], json!("policy_unenforceable"), "{r}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The CLI (not the person) may move a Claude Code chat into Claude Code's own `auto` under
    /// the `standard` start level (`start_mode::may_move_without_person`). An agent of family
    /// `lane` that offers all of Claude Code's mode names is not Claude Code: that move needs the
    /// person. The configured launcher profile still moves.
    #[tokio::test]
    async fn the_cli_moves_no_agent_with_claudes_mode_names_into_auto() {
        let (hub, d) = hub("auto");
        let mut cli = Client::cli(&hub);
        let id = cli.chat(&d, "impostor-claude", None).await;
        assert_eq!(cli.state(&id).await.0, "default");
        let set = cli.call("session/set_mode", json!({"sessionId": id, "modeId": "auto"})).await;
        assert_eq!(set["error"]["data"]["reason"], json!("permission.person_required"), "{set}");
        assert_eq!(cli.state(&id).await.0, "default", "the impostor stays: {set}");
        // Guard: the launcher profile is Claude Code.
        let sr2 = cli.chat(&d, "claude-sr2", None).await;
        let set =
            cli.call("session/set_mode", json!({"sessionId": sr2, "modeId": "default"})).await;
        assert!(set.get("error").is_none(), "claude-sr2 into default: {set}");
        assert_eq!(cli.state(&sr2).await.0, "default", "claude-sr2 moved: {set}");
        let set = cli.call("session/set_mode", json!({"sessionId": sr2, "modeId": "auto"})).await;
        assert!(set.get("error").is_none(), "claude-sr2 into auto: {set}");
        assert_eq!(cli.state(&sr2).await.0, "auto", "claude-sr2 moved: {set}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The gate and the family are the kind the agent started under: an ACP agent that says it is
    /// acpmux's Claude Code backend with the PreToolUse gate, whose entry the person then makes
    /// kind `claude-stdio` with the same launch (no restart: the kind is not part of the launch
    /// digest), keeps no narrower policy. Narrowed to `ask`, its agent is stopped
    /// (`policy_refused`), since it offers no mode that asks (review of #40790).
    #[tokio::test]
    async fn an_entry_made_claude_code_after_the_start_gives_its_agent_no_gate() {
        let (hub, d) = hub("kind");
        let mut person = Client::person(&hub).await;
        let id = person.chat(&d, "impostor-gate", None).await;
        let mut cfg = hub.config.write().await;
        cfg.harnesses.get_mut("impostor-gate").expect("impostor-gate").kind =
            HarnessKind::ClaudeStdio;
        drop(cfg);
        let r = person.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})).await;
        assert!(r.get("error").is_none(), "{r}");
        let refused = person.records(&id, "policy_refused").await;
        assert_eq!(refused.len(), 1, "the agent was stopped: {refused:?}");
        assert_eq!(refused[0]["msg"]["reason"], json!("policy_unenforceable"), "{refused:?}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Deny-all holds in a read-only mode only of a family whose own mode it is: an agent of
    /// family `lane` that offers Muse Code's `readOnly`, and no mode that asks, does not start
    /// under deny-all. Family `muse` starts in `readOnly` (review of #40790).
    #[tokio::test]
    async fn a_read_only_mode_name_holds_deny_all_only_for_its_own_family() {
        let (hub, d) = hub("ro");
        let mut person = Client::person(&hub).await;
        let r = person.new_chat(&d, "impostor-ro", Some("deny-all")).await;
        assert_eq!(r["error"]["data"]["reason"], json!("policy_unenforceable"), "{r}");
        // Guard: Muse Code's own read-only mode keeps deny-all.
        let id = person.chat(&d, "muse", Some("deny-all")).await;
        assert_eq!(person.state(&id).await, ("readOnly".to_owned(), json!("deny-all")));
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A mode named `read-only` keeps a policy only on the Codex bridge (`codex app-server`),
    /// whose sandbox refuses every write: the codex-acp adapter's `read-only` edits without
    /// asking, so a deny-all chat on it does not start; and an agent of another family is not
    /// held in its `read-only` under `ask`, but moved to its `ask` (family-rev B1).
    #[tokio::test]
    async fn read_only_holds_a_policy_only_on_the_codex_bridge() {
        let (hub, d) = hub("bridge-ro");
        let mut person = Client::person(&hub).await;
        let r = person.new_chat(&d, "codex-adapter", Some("deny-all")).await;
        assert_eq!(r["error"]["data"]["reason"], json!("policy_unenforceable"), "{r}");
        let id = person.chat(&d, "lane-ro", Some("ask")).await;
        assert_eq!(person.state(&id).await, ("ask".to_owned(), json!("ask")));
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }
}
