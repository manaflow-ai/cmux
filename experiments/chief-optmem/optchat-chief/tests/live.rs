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
        system_prompt: None,
        key: format!("turn:live:{n}"),
        prompt_id: format!("live:{n}"),
        session: SessionSpec {
            name: format!("live-{n}"),
            cwd: "/tmp".into(),
            harness: String::new(),
            policy: String::new(),
            model: None,
            effort: None,
            preset: None,
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
    let outcome = native.run(&chat, &first, &log, &Vec::new, &|| false);
    println!("turn 1: {outcome:?}");
    assert_eq!(outcome.error, None);
    assert!(outcome.reply.unwrap_or_default().contains("live-ok"));
    assert!(chat.wait_idle(None, Some(Duration::from_secs(300))));
    let second = start(
        &chat,
        2,
        "Where does the build cache for project 7 live? One line.",
    );
    let outcome = native.run(&chat, &second, &log, &Vec::new, &|| false);
    println!("turn 2: {outcome:?}");
    assert_eq!(outcome.error, None);
    assert!(outcome.reply.unwrap_or_default().contains("/srv/cache/7"));
    let log = lines.lock().unwrap().clone();
    println!("usage lines:\n{}", log.join("\n"));
}

/// The compactor's acpmux route against a real acpmux daemon
/// (`ACPMUX_SOCKET`, or `ACPMUX_BIN` to start one) and its claude-sr
/// harness, through the compactor's own required preset: the probe (with
/// its isolation check), one node of a long message built through an
/// OptChat memory, and one node whose context is a full-size view (about
/// 128 KB), with its seconds and token use printed (audit round 3, M5).
#[test]
#[ignore = "spends real tokens; needs acpmux with the claude-sr harness"]
fn the_acpmux_compactor_builds_a_node_through_claude_sr() {
    use std::sync::Condvar;

    use optchat_chief::acpmux::{Acpmux, AgentEvent};
    use optchat_chief::compactor::{
        AcpmuxCompactor, Slots, compactor_presets, compactor_spec, prepare_config,
    };
    use optchat_chief::paths::Paths;
    use optchat_host::{CompactRequest, NodeId, OptChat, SystemClock, run_node};

    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    paths.create().unwrap();
    let harness = std::env::var("OPTCHAT_COMPACTOR_HARNESS").unwrap_or_else(|_| "claude-sr".into());
    prepare_config(&paths.compactor_config).unwrap();
    let presets = compactor_presets(&paths, &home, &harness);
    let agents = Acpmux::new(optchat_chief::acpmux_daemon::socket_path(), None, presets);
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
    let model = std::env::var("OPTCHAT_COMPACTOR_MODEL")
        .unwrap_or_else(|_| optchat_host::DEFAULT_MODEL.into());
    let compactor = Arc::new(
        AcpmuxCompactor::new(
            agents.clone(),
            compactor_spec(&paths, &home, &harness, Some(&model)),
            Slots::new(optchat_core::JOBS),
        )
        .with_log(Arc::new(|line: &str| println!("compactor: {line}"))),
    );
    let config = Config {
        reporter: Arc::new(|r| println!("report: {r}")),
        ..Config::default()
    };
    let system = config.prompt.text(&config.agent);
    let started = std::time::Instant::now();
    let probe = optchat_host::probe(&*compactor, &system);
    println!("probe: {probe:?} in {} ms", started.elapsed().as_millis());
    assert!(probe.is_ok(), "{probe:?}");

    // A full-size view: about 128 KB of 500-byte lines before the step.
    let mut context = String::from("<chat>\n");
    let mut i = 0;
    while context.len() < optchat_core::VIEW - 600 {
        context.push_str(&format!(
            "user: asked for deploy {i}; talk: ran the release script for service-{i}, which copied build/{i}.tar to /srv/releases, restarted unit app-{i}, checked the health endpoint twice, saw 200 both times, and noted that the cache warmup for region {r} takes about {s} seconds; echo: ok {i}\n",
            r = i % 7,
            s = 30 + i % 50
        ));
        i += 1;
    }
    context.push_str("</chat>");
    let request = CompactRequest {
        node: NodeId::new(0, 100_000),
        system: system.clone(),
        context: context.clone(),
        step: format!(
            "For scale, this line is exactly 512 bytes:\n{}\n\nCompress this message into one line, in at most 512 bytes:\nuser: deploy service-{i} the same way and tell me when it is healthy",
            optchat_core::SCALE
        ),
        cut: None,
    };
    let started = std::time::Instant::now();
    let line = run_node(&*compactor, &request);
    println!(
        "full view ({} bytes of context): {line:?} in {} ms",
        context.len(),
        started.elapsed().as_millis()
    );
    assert!(line.is_ok(), "{line:?}");
    // No transcript of a compactor slot is left in any Claude home.
    let spec = compactor_spec(&paths, &home, &harness, Some(&model));
    let tag = format!("optchat-compact-{}", optchat_chief::paths::home_id(&home));
    for root in &spec.transcript_dirs {
        let left: Vec<String> = std::fs::read_dir(root.join("projects"))
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.contains(&tag))
                    .collect()
            })
            .unwrap_or_default();
        println!("left in {}: {left:?}", root.display());
        assert!(left.is_empty(), "transcripts left: {left:?}");
    }

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

/// The Chief on local ACP, live (README, Harnesses and cache layout): two
/// consecutive turns and two consecutive compactor nodes through a real
/// acpmux daemon (`ACPMUX_SOCKET`) with the harness in
/// `OPTCHAT_CHIEF_HARNESS` (claude-sr by default, or codex), each printing
/// its cache read and write tokens. Turns run over a memory whose view is
/// past the 100k mark, in the home's fixed session directory: on a Claude
/// harness in the cached layout (the turn preset's system prompt holds the
/// system text and the view up to 50k, one marker at the last mark), on
/// another harness with the view first and the message last.
#[test]
#[ignore = "spends real tokens; needs acpmux with the harness in OPTCHAT_CHIEF_HARNESS"]
fn two_turns_and_two_nodes_through_local_acp() {
    use std::sync::Condvar;

    use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort, Preset};
    use optchat_chief::compactor::{
        AcpmuxCompactor, Slots, compactor_presets, compactor_spec, prepare_config,
    };
    use optchat_chief::host::is_claude;
    use optchat_chief::paths::{Paths, home_id};
    use optchat_chief::prompt::{Tools, cached_layout, system_text};
    use optchat_chief::session_dir::{self, SessionSetup};
    use optchat_chief::turn::{self, Interrupt};
    use optchat_host::{CompactRequest, NodeId, run_node};

    let harness = std::env::var("OPTCHAT_CHIEF_HARNESS").unwrap_or_else(|_| "claude-sr".into());
    let claude = is_claude(&harness);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    paths.create().unwrap();
    prepare_config(&paths.compactor_config).unwrap();
    // The memory's own lines come from the fake compactor (free); the live
    // compactor is measured on its own below.
    let chat = open_chat(&paths.chat);
    for i in 0..1_300 {
        chat.append(
            Kind::Note,
            &format!(
                "note {i:04}: the build cache for project {i} lives in /srv/cache/{i} on host b{i}"
            ),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(Duration::from_secs(120))));
    optchat_chief::tools::serve(&paths.tools_socket, chat.clone()).unwrap();
    let tools = if claude {
        Tools::Mcp
    } else {
        Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let mut env = BTreeMap::new();
    env.insert("MUX_HOME".to_owned(), home.display().to_string());
    env.insert(
        "PATH".to_owned(),
        std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into()),
    );
    let setup = SessionSetup {
        exe: env!("CARGO_BIN_EXE_optchat-chief").to_owned(),
        cmux_mcp: None,
        env,
        instructions: None,
        tools: tools.clone(),
    };
    session_dir::write(&paths, &setup).unwrap();
    let system = system_text(None, &tools);
    let turn_preset = format!("optchat-chief-{}", home_id(&home));
    let agents = Acpmux::new(
        optchat_chief::acpmux_daemon::socket_path(),
        Some(Preset {
            name: turn_preset.clone(),
            harness: harness.clone(),
            env: session_dir::isolation_env(&paths),
            args: Vec::new(),
            system_prompt: claude.then(|| system.clone()),
        }),
        compactor_presets(&paths, &home, &harness),
    );
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
    {
        let guard = up.0.lock().unwrap();
        let guard =
            up.1.wait_timeout_while(guard, Duration::from_secs(40), |s| s.is_none())
                .unwrap()
                .0;
        assert_eq!(*guard, Some(true), "acpmux did not connect");
    }
    if claude {
        assert!(
            agents.system_prompt(&turn_preset),
            "this acpmux takes no preset systemPrompt"
        );
        session_dir::set_claude_md(&paths.session, None).unwrap();
    }
    let log = |line: &str| println!("host.log: {line}");
    let model = std::env::var("OPTCHAT_CHIEF_MODEL").ok();
    for n in 1..=2 {
        let view = chat.render_view().text;
        let marks = optchat_core::cache_marks(&view);
        let text = format!(
            "Live check {n}: reply with exactly the word ok{n} and nothing else. Use no tool."
        );
        chat.append(Kind::User, &text).unwrap();
        let (blocks, system_prompt, preset) = if claude {
            let layout = cached_layout(&system, &view, &text, true);
            (
                layout.blocks,
                Some(layout.system),
                Some(turn_preset.clone()),
            )
        } else {
            (turn_blocks(&view, std::slice::from_ref(&text)), None, None)
        };
        println!(
            "turn {n}: view {} characters, marks {marks:?}, {} blocks",
            view.len(),
            blocks.len()
        );
        let start = TurnStart {
            key: format!("turn:live-acp:{n}"),
            prompt_id: format!("live-acp:{stamp}:{n}"),
            session: SessionSpec {
                name: format!("optchat-live-{stamp}-{n}"),
                cwd: paths.session.clone(),
                harness: harness.clone(),
                policy: "approve-all".into(),
                model: model.clone(),
                effort: None,
                preset,
            },
            blocks,
            system_prompt,
            limit: Some(Duration::from_secs(600)),
        };
        let started = std::time::Instant::now();
        let outcome = turn::run(&*agents, &chat, &start, &Interrupt::new(), &log, &|_, _| {});
        println!(
            "turn {n}: {outcome:?} in {} ms",
            started.elapsed().as_millis()
        );
        assert_eq!(outcome.error, None);
        assert!(
            outcome
                .reply
                .unwrap_or_default()
                .contains(&format!("ok{n}")),
            "turn {n} answered"
        );
        assert!(chat.wait_idle(None, Some(Duration::from_secs(120))));
    }
    // Two consecutive nodes over one full-size view, different steps.
    let compactor_model = std::env::var("OPTCHAT_COMPACTOR_MODEL")
        .ok()
        .or_else(|| claude.then(|| optchat_host::DEFAULT_MODEL.to_owned()));
    let compactor = AcpmuxCompactor::new(
        agents.clone(),
        compactor_spec(&paths, &home, &harness, compactor_model.as_deref()),
        Slots::new(optchat_core::JOBS),
    )
    .with_log(Arc::new(|line: &str| println!("host.log: {line}")));
    let config = Config::default();
    let mut context = String::from("<chat>\n");
    let mut i = 0;
    while context.len() < optchat_core::VIEW - 600 {
        context.push_str(&format!(
            "user: asked for deploy {i}; talk: ran the release script for service-{i}, which copied build/{i}.tar to /srv/releases, restarted unit app-{i}, checked the health endpoint twice, saw 200 both times, and noted that the cache warmup for region {r} takes about {s} seconds; echo: ok {i}\n",
            r = i % 7,
            s = 30 + i % 50
        ));
        i += 1;
    }
    context.push_str("</chat>");
    for k in 0..2u64 {
        let request = CompactRequest {
            node: NodeId::new(0, 200_000 + k),
            system: config.prompt.text(&config.agent),
            context: context.clone(),
            step: format!(
                "For scale, this line is exactly 512 bytes:\n{}\n\nCompress this message into one line, in at most 512 bytes:\nuser: deploy service-{} the same way and tell me when it is healthy",
                optchat_core::SCALE,
                i + k as usize
            ),
            cut: None,
        };
        let started = std::time::Instant::now();
        let line = run_node(&compactor, &request);
        println!("node {k}: {line:?} in {} ms", started.elapsed().as_millis());
        assert!(line.is_ok(), "{line:?}");
    }
    // The turn sessions' Claude Code transcripts (claude-sr keeps them in the
    // user's ~/.claude): the test's own session directory only.
    if claude {
        let project = optchat_chief::compactor::project_dir_name(
            &std::fs::canonicalize(&paths.session).unwrap(),
        );
        let dir = optchat_chief::compactor::user_claude_home()
            .join("projects")
            .join(project);
        let _ = std::fs::remove_dir_all(dir);
    }
}
