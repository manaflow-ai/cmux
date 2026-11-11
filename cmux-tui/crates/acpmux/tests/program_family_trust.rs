//! A policy check judges a chat by a family that only the config entry or the program its agent
//! really runs can give (lead, W5-L): the entry's explicit `family`, the Claude Code kind, or the
//! exact name of a program of acpmux's list, confirmed by the file it runs (its own name, or the
//! `name` of the npm package it is in). Never a part of a program's name, another argv word, the
//! entry's name, or a link that runs another agent. A chat whose program names no family keeps a
//! narrower policy only through a mode that asks for every agent (`ask`), a believed claim or
//! the gate; else it does not start, and the refusal says to add `"family"` to its entry.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

mod program_family_trust {
    use super::*;

    /// A program at `path` that runs the stand-in agent.
    fn program(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("#!/bin/sh\nexec python3 {FAKE_AGENT} \"$@\"\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// A link at `link` to `target`.
    fn link(target: &Path, link: &Path) {
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        symlink(target, link).unwrap();
    }

    /// An npm global install of package `package` under `prefix`: its `bin/<name>` links to the
    /// package's `file`, a program in a folder with the package's `package.json`.
    fn npm(prefix: &Path, name: &str, package: &str, file: &str) -> PathBuf {
        let root = prefix.join("lib/node_modules").join(package);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("package.json"), json!({"name": package}).to_string()).unwrap();
        program(&root.join(file));
        let bin = prefix.join("bin").join(name);
        link(&root.join(file), &bin);
        bin
    }

    /// An entry that runs `argv` with the stand-in's settings `env`. It makes no
    /// asksBeforeTools claim (`FAKE_ASK_CLAIM=0`), so only a mode can hold its policy.
    fn entry(argv: Value, env: Value) -> Value {
        let mut all = json!({"FAKE_ASK_CLAIM": "0"});
        for (k, v) in env.as_object().unwrap() {
            all[k] = v.clone();
        }
        json!({"argv": argv, "env": all})
    }

    /// A daemon whose default policy is approve-all (only a chat's own policy is narrow) and
    /// whose start level is `standard`, with one entry per case. The stand-in offers no mode
    /// unless `FAKE_MODES` names them.
    fn hub(tag: &str) -> (Arc<Hub>, PathBuf) {
        let _ = &HERMETIC;
        let d = std::env::temp_dir().join(format!("pft-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("work")).unwrap();
        let d = std::fs::canonicalize(&d).unwrap();
        let bin = d.join("bin");
        // A program whose name only contains an agent's name.
        program(&bin.join("my-opencode-wrapper"));
        program(&bin.join("claude-proxy"));
        // A program of no known name, under an entry named after an agent.
        program(&bin.join("agent"));
        // A link named opencode that runs a program named codex.
        program(&d.join("real/codex"));
        link(&d.join("real/codex"), &bin.join("opencode"));
        // A link named opencode in the chat folder to a program of no known name.
        program(&d.join("work/tools/runner"));
        link(&d.join("work/tools/runner"), &d.join("work/opencode"));
        // The npm layouts of Codex and Claude Code.
        let codex = npm(&d.join("npm"), "codex", "@openai/codex", "bin/codex.js");
        let claude = npm(&d.join("npm"), "claude", "@anthropic-ai/claude-code", "cli.js");
        let s = |p: PathBuf| p.to_string_lossy().into_owned();
        let none = json!({});
        let claude_modes = json!({"FAKE_MODES": "default,plan"});
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {
                "wrapper": entry(json!([s(bin.join("my-opencode-wrapper"))]), none.clone()),
                "proxy": entry(json!([s(bin.join("claude-proxy"))]), claude_modes.clone()),
                "opencode": entry(json!([s(bin.join("agent"))]), none.clone()),
                "word": entry(
                    json!(["/usr/bin/env", "OPENCODE_HINT=1", "python3", FAKE_AGENT]),
                    none.clone(),
                ),
                "linked": entry(json!([s(bin.join("opencode"))]), none.clone()),
                "folder": entry(json!([s(d.join("work/opencode"))]), none.clone()),
                "declared": {
                    "argv": [s(bin.join("agent"))],
                    "family": "opencode",
                    "env": {"FAKE_ASK_CLAIM": "0"},
                },
                "npm-codex": entry(json!([s(codex)]), json!({"FAKE_MODES": "ask,read-only"})),
                "npm-claude": entry(json!([s(claude)]), claude_modes),
            },
            "defaultHarness": "declared",
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
        /// The CLI outside any chat: a unix socket connection.
        fn cli(hub: &Arc<Hub>) -> Self {
            let (in_tx, in_rx) = mpsc::channel(64);
            let (out_tx, out_rx) = mpsc::channel(4096);
            tokio::spawn(serve_connection_authed(
                hub.clone(),
                in_rx,
                out_tx,
                Origin::Local,
                ConnAuth::LocalSocket,
            ));
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
                    .expect("the connection stays open");
                let v: Value = serde_json::from_str(&line).unwrap();
                if v.get("id") == Some(&json!(id)) {
                    return v;
                }
            }
        }

        /// `session/new` on `harness` in folder `d` under policy `ask`: the whole reply.
        async fn new_chat(&mut self, d: &Path, harness: &str) -> Value {
            let meta = json!({"harness": harness, "policy": "ask"});
            let params =
                json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": meta}});
            self.call("session/new", params).await
        }
    }

    /// Each entry whose family was only guessed (a part of the program's name, an argv word,
    /// the entry's name, a link named for one agent that runs another, a link in the chat
    /// folder) gets no family's mode table and no OpenCode exception: under policy `ask` its
    /// chat does not start, and the refusal names the entry and the `"family"` to add.
    #[tokio::test]
    async fn a_guessed_family_holds_no_policy() {
        let (hub, d) = hub("guess");
        let mut cli = Client::cli(&hub);
        for harness in ["wrapper", "proxy", "opencode", "word", "linked", "folder"] {
            let r = cli.new_chat(&d, harness).await;
            assert_eq!(
                r["error"]["data"]["reason"],
                json!("policy_unenforceable"),
                "{harness}: {r}"
            );
            let message = r["error"]["message"].as_str().unwrap_or_default();
            assert!(message.contains(harness), "{harness}: {message}");
            assert!(message.contains("\"family\""), "{harness}: {message}");
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Guards: an entry's explicit family is the owner's word, and the npm layouts of Codex
    /// (`codex` links to `@openai/codex/bin/codex.js`) and Claude Code (`claude` links to
    /// `@anthropic-ai/claude-code/cli.js`) keep their family: their chats start under `ask`.
    #[tokio::test]
    async fn a_declared_or_installed_family_holds_the_policy() {
        let (hub, d) = hub("known");
        let mut cli = Client::cli(&hub);
        for harness in ["declared", "npm-codex", "npm-claude"] {
            let r = cli.new_chat(&d, harness).await;
            assert!(r["result"]["sessionId"].is_string(), "{harness}: {r}");
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
    }
}
