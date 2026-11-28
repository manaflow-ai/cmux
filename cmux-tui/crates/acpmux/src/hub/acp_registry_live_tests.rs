//! The ACP conformance cases against one real registry agent (goal acp-conformance-every-registry-agent).
//!
//! `acp_version_tests.rs` shows the negotiation rules against fake agents. This runs the same code paths against an
//! agent from the ACP Registry, started the way cmux starts it: `registry::parse` checks the entry, `Agent::launch`
//! picks how it starts here (on PATH, `npx`, `uvx`), `ChildAgent::spawn` runs it, and [`negotiate`] is the
//! `initialize` a session sends. No account or model is used: a session that needs a login passes when the agent
//! says so the way the protocol asks (an error to `session/new` after naming `authMethods`).
//!
//! It is ignored by default and needs two variables, so `cargo test` stays offline:
//! - `ACP_CONFORMANCE_REGISTRY`: a registry.json (the CDN copy a run fetched);
//! - `ACP_CONFORMANCE_AGENT`: the agent's id in it.
//!
//! Each case prints one line, `acp-case<TAB>ID<TAB>pass|fail<TAB>detail`, which the hq matrix job reads; the test
//! itself fails when any case fails. The cases:
//! - `launch`: cmux finds a way to start the agent here and the process runs;
//! - `initialize_v1`: the v1 `initialize` cmux sends gets an answer at protocolVersion 1;
//! - `v2_offer`: with the v2 offer on, [`negotiate`] agrees on 1 or 2 (directly, or by its v1 fallback);
//! - `session_new`: `session/new` answers a `sessionId`, or asks for a login it named in `authMethods`.

use super::negotiate;
use crate::agent::{ChildAgent, Tap};
use crate::config::HarnessProfile;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// An `npx`/`uvx` start downloads the package first.
const BOUND: Duration = Duration::from_secs(180);

struct Report {
    failed: Vec<String>,
}

impl Report {
    fn case(&mut self, id: &str, pass: bool, detail: impl AsRef<str>) {
        let detail = detail.as_ref().replace(['\t', '\n', '\r'], " ");
        let detail: String = detail.chars().take(300).collect();
        println!("acp-case\t{id}\t{}\t{detail}", if pass { "pass" } else { "fail" });
        if !pass {
            self.failed.push(id.to_owned());
        }
    }
}

fn hello() -> Value {
    json!({"protocolVersion": 1, "clientCapabilities": {},
           "clientInfo": {"name": "acpmux", "version": env!("CARGO_PKG_VERSION")}})
}

async fn start(profile: &HarnessProfile, cwd: &std::path::Path) -> anyhow::Result<Arc<ChildAgent>> {
    let (tx, mut rx) = tokio::sync::mpsc::channel(64);
    // Drain what the agent sends so its writer never blocks.
    tokio::spawn(async move { while rx.recv().await.is_some() {} });
    let tap: Tap = Arc::new(|_, _, _| true);
    ChildAgent::spawn("acp-conformance", profile, cwd, tx, tap).await
}

async fn within<T>(
    fut: impl std::future::Future<Output = Result<T, RpcError>>,
) -> Result<T, String> {
    match tokio::time::timeout(BOUND, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("error {}: {}", e.code, e.message)),
        Err(_) => Err(format!("no answer in {} s", BOUND.as_secs())),
    }
}

#[tokio::test]
#[ignore = "runs a real registry agent: ACP_CONFORMANCE_REGISTRY and ACP_CONFORMANCE_AGENT"]
async fn a_registry_agent_passes_the_conformance_cases() {
    let registry = std::env::var("ACP_CONFORMANCE_REGISTRY").expect("ACP_CONFORMANCE_REGISTRY");
    let id = std::env::var("ACP_CONFORMANCE_AGENT").expect("ACP_CONFORMANCE_AGENT");
    let body = std::fs::read(&registry).expect("the registry file");
    let registry = crate::registry::parse(&body).expect("a registry cmux reads");
    let mut report = Report { failed: vec![] };
    let Some(agent) = registry.agent(&id) else {
        report.case(
            "launch",
            false,
            format!("{id} is not in the registry cmux reads (dropped by its checks)"),
        );
        panic!("failed: launch");
    };
    println!("acp-agent\t{}\t{}", agent.id, agent.version);
    let which = |p: &str| crate::harness_install::which_on_path(p).map(|p| p.display().to_string());
    let launch = agent.launch(crate::registry::platform(), &which);
    let (argv, env, method) = match launch.argv_env() {
        Some((argv, env)) => (argv.to_vec(), env.clone(), launch.method().to_owned()),
        // A reserved id (cursor, gemini, ...) is cmux's built-in harness, which
        // config/discover.rs finds on PATH by its program's name, not through
        // the registry entry: the archive's program installed, with its args.
        None => match crate::registry::platform()
            .filter(|_| crate::registry::RESERVED_IDS.contains(&agent.id.as_str()))
            .and_then(|p| agent.binary.get(p))
            .and_then(|t| {
                let path = which(&crate::registry::program_name(&t.cmd)?)?;
                Some((
                    std::iter::once(path).chain(t.args.iter().cloned()).collect::<Vec<_>>(),
                    t.env.clone(),
                ))
            }) {
            Some((argv, env)) => (argv, env, "installed (built-in harness)".to_owned()),
            None => {
                report.case("launch", false, format!("no start here: {}", launch.method()));
                panic!("failed: launch");
            }
        },
    };
    let profile: HarnessProfile = serde_json::from_value(json!({"argv": argv, "env": env}))
        .expect("a profile from the launch");
    let cwd = std::env::temp_dir().join(format!("acp-conformance-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&cwd).expect("a scratch folder");

    // The first process: launch, the v1 initialize and session/new, as a session starts it.
    let child = match start(&profile, &cwd).await {
        Ok(c) => {
            report.case("launch", true, format!("{} ({})", method, agent.version));
            Some(c)
        }
        Err(e) => {
            report.case("launch", false, format!("{}: {e}", method));
            None
        }
    };
    if let Some(child) = &child {
        let init = within(negotiate(hello(), false, |p| {
            let c = child.clone();
            async move { c.request(method::INITIALIZE, p).await }
        }))
        .await;
        match &init {
            Ok(n) if n.version == Some(1) => {
                report.case("initialize_v1", true, "protocolVersion 1")
            }
            Ok(n) => report.case(
                "initialize_v1",
                false,
                format!("answered protocolVersion {:?}", n.version),
            ),
            Err(e) => report.case("initialize_v1", false, e),
        }
        match init {
            Ok(n) => {
                let auth = n
                    .result
                    .get("authMethods")
                    .and_then(Value::as_array)
                    .is_some_and(|a| !a.is_empty());
                match within(
                    child.request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []})),
                )
                .await
                {
                    Ok(r) if r.get("sessionId").and_then(Value::as_str).is_some() => {
                        report.case("session_new", true, "sessionId")
                    }
                    Ok(_) => report.case("session_new", false, "answered with no sessionId"),
                    Err(e) if auth => {
                        report.case("session_new", true, format!("asks for a login it named ({e})"))
                    }
                    Err(e) => {
                        report.case("session_new", false, format!("{e}; no authMethods named"))
                    }
                }
            }
            Err(_) => report.case("session_new", false, "initialize failed first"),
        }
        child.terminate(Duration::from_secs(5)).await;
    } else {
        report.case("initialize_v1", false, "did not start");
        report.case("session_new", false, "did not start");
    }

    // A second process for the v2 offer: an agent may close on a version it does not speak.
    match start(&profile, &cwd).await {
        Ok(child) => {
            let c = child.clone();
            let agreed = within(negotiate(hello(), true, move |p| {
                let c = c.clone();
                async move { c.request(method::INITIALIZE, p).await }
            }))
            .await;
            match agreed {
                Ok(n) if matches!(n.version, Some(1 | 2)) => report.case(
                    "v2_offer",
                    true,
                    format!(
                        "agreed {:?}{}",
                        n.version,
                        if n.fell_back { " by the v1 fallback" } else { "" }
                    ),
                ),
                Ok(n) => report.case(
                    "v2_offer",
                    false,
                    format!("agreed protocolVersion {:?}", n.version),
                ),
                Err(e) => report.case("v2_offer", false, e),
            }
            child.terminate(Duration::from_secs(5)).await;
        }
        Err(e) => report.case("v2_offer", false, format!("did not start: {e}")),
    }
    let _ = std::fs::remove_dir_all(&cwd);
    assert!(report.failed.is_empty(), "failed: {}", report.failed.join(", "));
}
