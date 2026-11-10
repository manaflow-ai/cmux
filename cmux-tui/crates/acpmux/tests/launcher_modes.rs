//! A launcher profile of Claude Code (`claude-sr2`: `sr2 claude`, kind `claude-stdio`, its own
//! family so it stays out of the default Claude row) runs Claude Code with Claude Code's modes.
//! A client that is not the person (the CLI outside any chat, an agent) may start or move it into
//! a mode that asks (`default`, `plan`) as it may on `claude`; a mode that does not ask
//! (`acceptEdits`, `auto`, `bypassPermissions`) still needs the person (`hub/start_gate.rs`,
//! `hub/person.rs`). Bench round 5, row 9: `acpmux new -m claude-sr2 --mode default` was refused
//! with "mode default does not ask before it acts". From a remote (Web) connection the launcher
//! profile gets exactly Claude's remote set, and a family with no reviewed row fails closed.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

mod launcher_modes {
    use super::*;

    /// `claude` and the launcher profile `claude-sr2` run the same Claude Code stand-in. The person's
    /// start level is `standard` (Claude Code's own start mode), so no start reaches full access by
    /// the person's rule.
    fn hub() -> Arc<Hub> {
        let _ = &HERMETIC;
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {
                "claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
                "claude-sr2": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "family": "claude-sr2"},
            },
            "defaultHarness": "claude",
            "permissionPolicy": "approve-all",
            "defaultPermissionMode": "standard",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// The CLI outside any chat: a unix socket connection that is not the person.
    struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

    impl Client {
        fn new(hub: &Arc<Hub>) -> Self {
            let (in_tx, in_rx) = mpsc::channel(64);
            let (out_tx, out_rx) = mpsc::channel(4096);
            tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
            Client(in_tx, out_rx, 0)
        }

        async fn call(&mut self, m: &str, params: Value) -> Value {
            self.2 += 1;
            let id = self.2;
            self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
            loop {
                let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                    .await
                    .expect("an answer in time")
                    .unwrap();
                let v: Value = serde_json::from_str(&line).unwrap();
                if v.get("id") == Some(&json!(id)) {
                    return v;
                }
            }
        }

        /// `session/new` on `harness`, in `mode` when one is given.
        async fn new_chat(&mut self, harness: &str, mode: Option<&str>) -> Value {
            let mut meta = json!({"harness": harness});
            if let Some(m) = mode {
                meta["mode"] = json!(m);
            }
            self.call(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await
        }

        async fn mode(&mut self, id: &str) -> String {
            let r = self.call("_acpmux/info", json!({"sessionId": id})).await;
            r["result"]["modes"]["currentModeId"].as_str().unwrap_or_default().to_owned()
        }
    }

    /// A start on `harness` in asking mode `mode` from the CLI starts, in that mode.
    async fn starts_in(harness: &str, mode: &str) {
        let hub = hub();
        let mut cli = Client::new(&hub);
        let r = cli.new_chat(harness, Some(mode)).await;
        assert!(r.get("error").is_none(), "{harness} --mode {mode}: {r}");
        let id = r["result"]["sessionId"].as_str().expect("a session id").to_owned();
        assert_eq!(cli.mode(&id).await, mode, "{harness} runs in {mode}");
        hub.shutdown_all().await;
    }

    /// The CLI moves a running chat on `harness` into asking mode `mode`.
    async fn moves_to(harness: &str, mode: &str) {
        let hub = hub();
        let mut cli = Client::new(&hub);
        let r = cli.new_chat(harness, None).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let other = if mode == "plan" { "default" } else { "plan" };
        for m in [other, mode] {
            let set = cli.call("session/set_mode", json!({"sessionId": id, "modeId": m})).await;
            assert!(set.get("error").is_none(), "{harness} set_mode {m}: {set}");
        }
        assert_eq!(cli.mode(&id).await, mode);
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn the_cli_starts_a_launcher_profile_in_claudes_default_mode() {
        starts_in("claude-sr2", "default").await;
    }

    #[tokio::test]
    async fn the_cli_starts_a_launcher_profile_in_claudes_plan_mode() {
        starts_in("claude-sr2", "plan").await;
    }

    #[tokio::test]
    async fn the_cli_moves_a_launcher_profile_chat_into_claudes_default_mode() {
        moves_to("claude-sr2", "default").await;
    }

    #[tokio::test]
    async fn the_cli_moves_a_launcher_profile_chat_into_claudes_plan_mode() {
        moves_to("claude-sr2", "plan").await;
    }

    /// The plain Claude profile, for comparison: the same asking modes start and move.
    #[tokio::test]
    async fn the_cli_starts_and_moves_plain_claude_in_its_asking_modes() {
        for mode in ["default", "plan"] {
            starts_in("claude", mode).await;
            moves_to("claude", mode).await;
        }
    }

    /// A mode that does not ask needs the person on either profile, at the start and as a move.
    #[tokio::test]
    async fn a_mode_that_does_not_ask_still_needs_the_person_on_both_profiles() {
        for harness in ["claude", "claude-sr2"] {
            for mode in ["acceptEdits", "auto", "bypassPermissions"] {
                let hub = hub();
                let mut cli = Client::new(&hub);
                let r = cli.new_chat(harness, Some(mode)).await;
                assert_eq!(
                    r["error"]["data"]["reason"], "permission.person_required",
                    "{harness} --mode {mode}: {r}"
                );
                let r = cli.new_chat(harness, None).await;
                let id =
                    r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
                // A set that changes nothing widens nothing (cmux#37392): only a real move is judged.
                if cli.mode(&id).await != mode {
                    let params = json!({"sessionId": id, "modeId": mode});
                    let set = cli.call("session/set_mode", params).await;
                    assert_eq!(
                        set["error"]["data"]["reason"], "permission.person_required",
                        "{harness} set_mode {mode}: {set}"
                    );
                }
                hub.shutdown_all().await;
            }
        }
    }

    /// A home for Web tests: a Web root, the two Claude Code profiles, and `lane`, an ACP agent of a
    /// family with no reviewed asking row.
    fn web_hub(tag: &str) -> (Arc<Hub>, std::path::PathBuf) {
        let _ = &HERMETIC;
        let d = std::env::temp_dir().join(format!("alm-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("work")).unwrap();
        let d = std::fs::canonicalize(&d).unwrap();
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {
                "claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
                "claude-sr2": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "family": "claude-sr2"},
                "lane": {"argv": ["python3", FAKE_AGENT], "family": "lane"},
            },
            "defaultHarness": "claude",
            "permissionPolicy": "ask",
            "defaultPermissionMode": "standard",
            "webRoots": [d.join("work")],
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        (Hub::new(cfg, store), d)
    }

    fn web_client(hub: &Arc<Hub>) -> Client {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Web));
        Client(in_tx, out_rx, 0)
    }

    /// From a remote (Web) connection, a launcher profile of Claude Code gets exactly Claude's set.
    ///
    /// A start from the Web passes the mode gate as `claude`'s does: both get the same outcome,
    /// and neither reads "no reviewed asking mode". (A Web start of a `claude-stdio` profile then
    /// runs the remote chain's sandbox canary, which this test binary cannot pass on Linux, so the
    /// outcome there is `remote.sandbox_refused` for both.) A chat the unix socket started is moved
    /// by the Web between `default` and `plan`, and refused `acceptEdits`, `auto` and
    /// `bypassPermissions`, as `claude` is.
    #[tokio::test]
    async fn from_the_web_a_launcher_profile_gets_claudes_asking_modes_and_no_others() {
        let (hub, d) = web_hub("web");
        let mut web = web_client(&hub);
        let mut cli = Client::new(&hub);
        let mut starts = Vec::new();
        for harness in ["claude", "claude-sr2"] {
            let r = web
                .call(
                    "session/new",
                    json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
                )
                .await;
            let message = r["error"]["message"].as_str().unwrap_or_default();
            assert!(!message.contains("no reviewed asking mode"), "{harness} from the Web: {r}");
            let outcome = match r["result"]["sessionId"].as_str() {
                Some(id) => {
                    assert_eq!(
                        cli.mode(id).await,
                        "default",
                        "{harness} starts in Claude's asking default"
                    );
                    "started".to_owned()
                }
                None => r["error"]["data"]["reason"].as_str().unwrap_or(message).to_owned(),
            };
            starts.push(outcome);
        }
        assert_eq!(starts[0], starts[1], "claude-sr2 starts from the Web as claude does");
        for harness in ["claude", "claude-sr2"] {
            let r = cli
                .call(
                    "session/new",
                    json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
                )
                .await;
            let id = r["result"]["sessionId"]
                .as_str()
                .unwrap_or_else(|| panic!("{harness}: {r}"))
                .to_owned();
            assert_eq!(
                cli.mode(&id).await,
                "default",
                "{harness} starts in Claude's asking default"
            );
            for mode in ["plan", "default"] {
                let set =
                    web.call("session/set_mode", json!({"sessionId": id, "modeId": mode})).await;
                assert!(
                    set.get("error").is_none(),
                    "{harness} set_mode {mode} from the Web: {set}"
                );
                assert_eq!(cli.mode(&id).await, mode);
            }
            for mode in ["acceptEdits", "auto", "bypassPermissions"] {
                let set =
                    web.call("session/set_mode", json!({"sessionId": id, "modeId": mode})).await;
                let message = set["error"]["message"].as_str().unwrap_or_default();
                assert!(
                    message.contains("never from a remote WebSocket"),
                    "{harness} {mode} from the Web: {set}"
                );
            }
            assert_eq!(cli.mode(&id).await, "default", "{harness} stays in default");
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A profile whose family has no reviewed asking row fails closed from the Web: it does not start.
    #[tokio::test]
    async fn from_the_web_a_family_with_no_asking_row_does_not_start() {
        let (hub, d) = web_hub("norow");
        let mut web = web_client(&hub);
        let r = web
            .call(
                "session/new",
                json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "lane"}}}),
            )
            .await;
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("no reviewed asking mode"), "{r}");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }
}
