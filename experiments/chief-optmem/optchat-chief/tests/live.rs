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
