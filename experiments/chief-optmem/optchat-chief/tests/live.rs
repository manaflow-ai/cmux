//! A live check of the native engine against the real Messages API (the
//! team subrouter unless OPTCHAT_ANTHROPIC_BASE_URL says otherwise). Ignored
//! by default: it spends real tokens. Run on the build host with
//! `cargo test --release --test live -- --ignored --nocapture`.
//!
//! Two turns over a view past the first cache mark (50k characters): the
//! second turn's first request should read the view's first piece from the
//! cache the first turn wrote (section 8), and each turn's later steps
//! should read what the step before wrote.

mod common;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::open_chat;
use optchat_chief::acpmux::SessionSpec;
use optchat_chief::native::{HttpModel, Native, NativeConfig};
use optchat_chief::prompt::{claude_md, turn_blocks};
use optchat_chief::turn::TurnStart;
use optchat_core::Kind;
use optchat_host::Config;

fn start(chat: &optchat_host::OptChat, n: u64, text: &str) -> TurnStart {
    let view = chat.render_view();
    chat.append(Kind::User, text).unwrap();
    TurnStart {
        key: format!("turn:live:{n}"),
        prompt_id: format!("live:{n}"),
        session: SessionSpec {
            name: format!("live-{n}"),
            cwd: "/tmp".into(),
            harness: String::new(),
            policy: String::new(),
            model: None,
            effort: None,
        },
        blocks: turn_blocks(&view.text, &[text.to_owned()]),
        limit: Some(Duration::from_secs(600)),
    }
}

#[test]
#[ignore = "spends real tokens; run with --ignored on a host that reaches the subrouter"]
fn two_native_turns_against_the_real_api() {
    let dir = tempfile::tempdir().unwrap();
    let chat = open_chat(&dir.path().join("chat"));
    // About 66k characters of short notes: each is its own verbatim line.
    for i in 0..600 {
        chat.append(
            Kind::Note,
            &format!("note {i:03}: the build cache for project {i} lives in /srv/cache/{i}"),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(Duration::from_secs(60))));
    let config = Config::default();
    let native = Native::new(
        NativeConfig {
            model: std::env::var("OPTCHAT_CHIEF_MODEL")
                .unwrap_or_else(|_| "claude-opus-5-5".into()),
            effort: Some("low".into()),
            max_tokens: 16_000,
            server_fallback: false,
            system: claude_md(None),
            cwd: dir.path().to_owned(),
            env: BTreeMap::new(),
            bash_timeout: Duration::from_secs(30),
            pwd_file: dir.path().join(".pwd"),
        },
        Arc::new(HttpModel::new(
            &config.base_url,
            config.api_key.clone(),
            false,
        )),
        Duration::from_secs(10),
    );
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let log = move |line: &str| {
        println!("{line}");
        sink.lock().unwrap().push(line.to_owned());
    };
    let first = start(
        &chat,
        1,
        "Run `echo live-ok` with your bash tool and tell me exactly what it printed.",
    );
    let outcome = native.run(&chat, &first, &log, &Vec::new);
    println!("turn 1: {outcome:?}");
    assert_eq!(outcome.error, None);
    assert!(outcome.reply.unwrap_or_default().contains("live-ok"));
    assert!(chat.wait_idle(None, Some(Duration::from_secs(300))));
    let second = start(
        &chat,
        2,
        "Where does the build cache for project 7 live? One line.",
    );
    let outcome = native.run(&chat, &second, &log, &Vec::new);
    println!("turn 2: {outcome:?}");
    assert_eq!(outcome.error, None);
    assert!(outcome.reply.unwrap_or_default().contains("/srv/cache/7"));
    let log = lines.lock().unwrap().clone();
    println!("usage lines:\n{}", log.join("\n"));
}

/// The compactor's acpmux route against a real acpmux daemon
/// (`ACPMUX_SOCKET`, or `ACPMUX_BIN` to start one) and its claude-sr
/// harness, with the isolation preset: one probe node, then one node of a
/// long message built through an OptChat memory.
#[test]
#[ignore = "spends real tokens; needs acpmux with the claude-sr harness"]
fn the_acpmux_compactor_builds_a_node_through_claude_sr() {
    use std::sync::Condvar;

    use optchat_chief::acpmux::{Acpmux, AgentEvent, Preset};
    use optchat_chief::compactor::{AcpmuxCompactor, CompactorSpec, prepare_dir};
    use optchat_chief::paths::Paths;
    use optchat_host::{OptChat, SystemClock};

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    paths.create().unwrap();
    std::fs::write(
        paths.claude_config.join("settings.json"),
        optchat_chief::session_dir::claude_settings().to_string(),
    )
    .unwrap();
    let harness = std::env::var("OPTCHAT_COMPACTOR_HARNESS").unwrap_or_else(|_| "claude-sr".into());
    let preset = Preset {
        name: format!("optchat-live-{}", optchat_chief::paths::home_id(dir.path())),
        harness: harness.clone(),
        env: optchat_chief::session_dir::isolation_env(&paths),
    };
    let agents = Acpmux::new(optchat_chief::acpmux_daemon::socket_path(), Some(preset));
    let up = Arc::new((Mutex::new(None::<bool>), Condvar::new()));
    let signal = up.clone();
    agents.spawn_link(
        Arc::new(move |event| {
            let state = match event {
                AgentEvent::Up(_) => Some(true),
                AgentEvent::Down => Some(false),
                _ => None,
            };
            if state.is_some() {
                *signal.0.lock().unwrap() = state;
                signal.1.notify_all();
            }
        }),
        Arc::new(|line: &str| println!("acpmux: {line}")),
    );
    let connected = {
        let guard = up.0.lock().unwrap();
        let guard =
            up.1.wait_timeout_while(guard, Duration::from_secs(40), |s| s.is_none())
                .unwrap()
                .0;
        *guard
    };
    assert_eq!(connected, Some(true), "acpmux did not connect");
    prepare_dir(&paths.compactor).unwrap();
    let model = std::env::var("OPTCHAT_COMPACTOR_MODEL").ok();
    let compactor = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        CompactorSpec {
            name: "optchat-compact-live".into(),
            cwd: paths.compactor.clone(),
            harness,
            model: Some(model.unwrap_or_else(|| optchat_host::DEFAULT_MODEL.into())),
            effort: std::env::var("OPTCHAT_COMPACTOR_EFFORT").ok(),
            timeout: Duration::from_secs(300),
            jobs: optchat_core::JOBS,
        },
    ));
    let config = Config {
        reporter: Arc::new(|r| println!("report: {r}")),
        ..Config::default()
    };
    let system = config.prompt.text(&config.agent);
    let started = std::time::Instant::now();
    let probe = optchat_host::probe(&*compactor, &system);
    println!("probe: {probe:?} in {} ms", started.elapsed().as_millis());
    assert!(probe.is_ok(), "{probe:?}");
    let chat = OptChat::open_with(
        dir.path().join("chat"),
        config,
        compactor,
        Arc::new(SystemClock),
    )
    .unwrap();
    let long = (0..120)
        .map(|i| format!("Step {i}: the deploy script copies build/{i}.tar to /srv/releases and restarts unit app-{i}."))
        .collect::<Vec<_>>()
        .join("\n");
    chat.append(Kind::Echo, &long).unwrap();
    let started = std::time::Instant::now();
    assert!(
        chat.settle(None, Some(Duration::from_secs(400))),
        "not built: {:?}",
        chat.status().failures
    );
    let view = chat.render_view().text;
    println!("built in {} ms:\n{view}", started.elapsed().as_millis());
    assert!(!view.contains("not summarized yet"), "{view}");
}
