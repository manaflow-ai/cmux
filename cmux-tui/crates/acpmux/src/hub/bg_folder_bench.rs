//! A timing harness for background-task folders at Leo's scale, run by hand, before and after
//! (`bg_folder.rs`): `ACPMUX_HOME=$(mktemp -d) cargo test --release -p acpmux --lib
//! bg_folder_bench -- --ignored --nocapture`.
//!
//! `ACPMUX_BG_BENCH_CHATS` chats (default 300) of `ACPMUX_BG_BENCH_TASKS` ended tasks each
//! (default 40), and one coordinator chat of `ACPMUX_BG_BENCH_BIG` (default 5,646: Leo's busiest,
//! 2026-11-23), each task with a record, a lock, an end mark and 2 KiB of output; two tasks of
//! every chat run (their runner's lock held). Legs, each timed in CPU time of the process:
//! `tick`, an idle look over every chat (`Hub::bg_running_count`, as `sessions_at_work` and
//! `in_use` do); `list`, the coordinator's `_acpmux/bg/list` (`Hub::bg_list`); and the same after
//! a new task's record lands (`list_after_start`).

use super::*;

fn cpu_now() -> std::time::Duration {
    // SAFETY: getrusage fills the struct it is given.
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    let tv = |t: libc::timeval| {
        std::time::Duration::from_secs(t.tv_sec as u64)
            + std::time::Duration::from_micros(t.tv_usec as u64)
    };
    tv(usage.ru_utime) + tv(usage.ru_stime)
}

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A chat's folder of `tasks` ended tasks and two running ones; the running ones' locks.
fn fill(dir: &std::path::Path, chat: &str, tasks: usize) -> Vec<cmux_file_lock::FileLock> {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join(".generation"), "g").unwrap();
    let output = "a line of a background task's output, as a CI wait prints\n".repeat(36);
    let mut held = Vec::new();
    for n in 0..tasks + 2 {
        let id = format!("bg-{n:012x}");
        let running = n >= tasks;
        let record = crate::bg_run::Record {
            id: id.clone(),
            session_id: chat.to_owned(),
            command: format!("glaeda-gh wait pr manaflow-ai/cmux#{n} --merged"),
            cwd: "/tmp".into(),
            pid: 1,
            started_at: n as u64,
            ended_at: (!running).then_some(n as u64 + 1),
            exit_code: (!running).then_some(0),
            generation: "g".into(),
            notify: true,
            ..Default::default()
        };
        crate::bg_run::write_record(dir, &record).unwrap();
        std::fs::write(dir.join(format!("{id}.out.0")), &output).unwrap();
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(crate::bg_run::lock_path(dir, &id))
            .unwrap();
        if running {
            held.push(
                cmux_file_lock::FileLock::try_take(lock, cmux_file_lock::Kind::Exclusive).unwrap(),
            );
        } else {
            std::fs::write(crate::bg_run::notified_path(dir, &id), b"").unwrap();
        }
    }
    held
}

#[test]
#[ignore = "a timing harness, run by hand"]
fn bg_folder_bench() {
    let env = |name: &str, default: usize| {
        std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
    };
    let (chats, tasks, big) = (
        env("ACPMUX_BG_BENCH_CHATS", 300),
        env("ACPMUX_BG_BENCH_TASKS", 40),
        env("ACPMUX_BG_BENCH_BIG", 5_646),
    );
    let rounds = env("ACPMUX_BG_BENCH_ROUNDS", 5);
    assert!(std::env::var_os("ACPMUX_HOME").is_some(), "set ACPMUX_HOME to an empty folder");
    let hub = hub();
    let meta = |id: &str| -> crate::store::SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "fake", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 1_000
        }))
        .unwrap()
    };
    let mut held = Vec::new();
    let mut sessions = Vec::new();
    for n in 0..=chats {
        let id = format!("chat-{n:04}");
        let session = hub.insert_test_session(meta(&id));
        held.extend(fill(&hub.bg_dir(&session), &id, if n == 0 { big } else { tasks }));
        sessions.push(session);
    }
    // Folders written a while ago, as a daemon finds them.
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(60);
    for session in &sessions {
        std::fs::File::open(hub.bg_dir(session)).unwrap().set_modified(old).unwrap();
    }
    let coordinator = sessions[0].clone();
    let files: usize =
        sessions.iter().map(|s| std::fs::read_dir(hub.bg_dir(s)).unwrap().count()).sum();
    let leg = |label: &str, run: &dyn Fn() -> usize| {
        let expect = run();
        let (cpu0, wall0) = (cpu_now(), std::time::Instant::now());
        for _ in 0..rounds {
            assert_eq!(run(), expect, "{label}: the answer changed");
        }
        let per = |d: std::time::Duration| d.as_secs_f64() * 1000.0 / rounds as f64;
        println!(
            "BG_FOLDER_BENCH {label} chats={} big={big} tasks={tasks} files={files} rounds={rounds} \
             answer={expect} cpu_ms_per_call={:.2} wall_ms_per_call={:.2}",
            chats + 1,
            per(cpu_now() - cpu0),
            per(wall0.elapsed()),
        );
    };
    leg("tick", &|| sessions.iter().map(|s| hub.bg_running_count(s)).sum());
    let list = || hub.bg_list(&coordinator)["tasks"].as_array().map_or(0, Vec::len);
    leg("list", &list);
    // A start lands a record: the coordinator's folder changed since the last look.
    let dir = hub.bg_dir(&coordinator);
    let started = std::cell::Cell::new(0usize);
    leg("list_after_start", &|| {
        let n = started.get();
        started.set(n + 1);
        let record = crate::bg_run::Record {
            id: format!("bg-new{n:06}"),
            generation: "g".into(),
            started_at: u64::MAX,
            ended_at: Some(1),
            ..Default::default()
        };
        crate::bg_run::write_record(&dir, &record).unwrap();
        list() - n
    });
    drop(held);
}
