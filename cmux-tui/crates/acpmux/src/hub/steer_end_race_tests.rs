//! A steer still in setup when another steer finishes the turn must not lose its text.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// PROBE (scratch): this process's own Darwin background state and its main QoS class, so the
/// starter's class ("normal" means the starter's) is known.
#[cfg(target_os = "macos")]
fn own_class(label: &str) {
    // SAFETY: getpriority with PRIO_DARWIN_PROCESS on this process (who 0); no preconditions.
    let bg = unsafe {
        libc::getpriority(4 /* PRIO_DARWIN_PROCESS */, 0)
    };
    // SAFETY: qos_class_self has no preconditions.
    let qos = unsafe { libc::qos_class_self() } as u32;
    // SAFETY: getpriority(PRIO_PROCESS, 0) reads this process's nice value.
    let nice = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) };
    eprintln!("BGPROBE {label} own darwin_bg={bg} qos=0x{qos:x} nice={nice}");
}
#[cfg(not(target_os = "macos"))]
fn own_class(_label: &str) {}

fn loadavg(label: &str) {
    own_class(label);
    let out = std::process::Command::new("/usr/sbin/sysctl").args(["-n", "vm.loadavg"]).output();
    let text =
        out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
    eprintln!("BGPROBE {label} loadavg {text}");
}

/// PROBE (scratch): dumps every record with its time from the first one, pass or fail.
fn dump(hub: &Arc<Hub>, session: &Session, label: &str) {
    let records = hub.events(&session.id, 0, 100_000).unwrap_or_default();
    let t0 = records.first().map(|r| r.at).unwrap_or_default();
    for r in &records {
        let text =
            r.msg.pointer("/params/update/content/text").and_then(Value::as_str).unwrap_or("");
        eprintln!(
            "BGPROBE {label} +{:>6} ms {} {} {}",
            r.at.saturating_sub(t0),
            r.dir,
            r.kind,
            text
        );
    }
}

async fn unsent_steer_after_completion(steer_only: bool) {
    unsent_steer_at(steer_only, None).await;
}

async fn unsent_steer_at(steer_only: bool, class: Option<&str>) {
    use crate::config::{Config, StoreMode};
    let label = format!("steer_only={steer_only} class={}", class.unwrap_or("default"));
    loadavg(&format!("{label} start"));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut profile = json!({"argv": ["/usr/bin/env", "FAKE_CODEX_STEER=1", "python3", fake]});
    if let Some(class) = class {
        profile["env"] = json!({"ACPMUX_SESSION_CPU_CLASS": class});
    }
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": profile},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let mut events = hub.subscribe();
    let running = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(&session, vec![json!({"type": "text", "text": "original"})], "test", false)
                .await
        })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["content"]["text"] == "turn: original" {
                break;
            }
        }
    })
    .await
    .unwrap();
    let old_turn = session.turn().unwrap().turn_id;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let unsent = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt_with(
                &session,
                vec![json!({"type": "text", "text": "deliver this later"})],
                "test",
                true,
                PromptOptions { steer_only, ..Default::default() },
            )
            .await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    // The fake Codex harness answers only the final steer, which settles the original
    // request through steer_end. The other steer is deterministically still making copies.
    let finishing = hub.prompt(
        &session,
        vec![json!({"type": "text", "text": "finish the original turn"})],
        "test",
        true,
    );
    let finished = tokio::time::timeout(WAIT, finishing).await.unwrap().unwrap();
    assert_eq!(finished["stopReason"], "end_turn");
    let original = tokio::time::timeout(WAIT, running).await.unwrap().unwrap().unwrap();
    assert_eq!(original["stopReason"], "end_turn");
    assert!(session.turn().is_none());
    release.send(()).unwrap();
    let answer = tokio::time::timeout(WAIT, unsent).await;
    loadavg(&format!("{label} end"));
    dump(&hub, &session, &label);
    let answer = answer.unwrap().unwrap();
    if steer_only {
        let error = answer.expect_err("an unsent steer-only request cannot claim the old answer");
        assert!(error.message.starts_with(crate::claude_stdio::STEER_NO_TURN));
    } else {
        let answer = answer.unwrap();
        assert_eq!(answer["stopReason"], "end_turn");
        assert_ne!(answer["_meta"]["acpmux"]["turnId"], old_turn);
    }
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let delivered = records
        .iter()
        .filter(|r| {
            r.dir == "out"
                && r.kind == "session/prompt"
                && r.msg["params"]["prompt"].to_string().contains("deliver this later")
        })
        .count();
    assert_eq!(delivered, usize::from(!steer_only));
    let starts = records.iter().filter(|r| r.kind == "turn_started").count();
    assert_eq!(starts, if steer_only { 1 } else { 2 });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unsent_steer_gets_its_own_turn_after_another_steer_finishes() {
    unsent_steer_after_completion(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unsent_steer_only_refuses_the_completed_turns_answer() {
    unsent_steer_after_completion(true).await;
}

/// PROBE (scratch): the race at background and at normal class, one after another in one process
/// (nothing runs beside it), twice each. Prints one BGPROBE RESULT line per run; fails if any run did.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unsent_steer_probe_sequence() {
    let mut bad = Vec::new();
    for class in ["background", "normal", "background", "normal"] {
        let started = std::time::Instant::now();
        let run = tokio::spawn(unsent_steer_at(false, Some(class))).await;
        let ms = started.elapsed().as_millis();
        let ok = run.is_ok();
        eprintln!("BGPROBE RESULT class={class} ok={ok} ms={ms}");
        if !ok {
            bad.push(format!("{class} ({ms} ms)"));
        }
    }
    assert!(bad.is_empty(), "BGPROBE runs that failed: {bad:?}");
}
